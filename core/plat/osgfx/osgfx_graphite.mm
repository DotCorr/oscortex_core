/* Skia Graphite rasterizer behind osgfx.h. Metal is fallback only. */
#include "osgfx.h"
#include "osgfx_metal.h"

#include "include/core/SkBlurTypes.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkImage.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTileMode.h"
#include "include/effects/SkGradient.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/mtl/MtlBackendContext.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

enum { OSGFX_MAX_CMDS = 256, KIND_SOLID = 0, KIND_GRAD = 1, KIND_SHADOW = 2 };
enum { OSGFX_KIND_GRAPHITE = 1, OSGFX_KIND_METAL = 2 };

typedef struct {
  int kind;
  int x, y, w, h, radius, blur;
  uint32_t c0, c1;
} OsGfxCmd;

struct OsGfxGraphite {
  int w, h, n;
  OsGfxCmd cmds[OSGFX_MAX_CMDS];
  std::unique_ptr<skgpu::graphite::Context> context;
  std::unique_ptr<skgpu::graphite::Recorder> recorder;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  uint32_t *cpu;
  int cpu_ok;
};

struct OsGfx {
  int kind;
  void *be;
};

static SkColor sk_rgb(uint32_t rgb) {
  return SkColorSetARGB(255, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
}

static SkColor4f sk_rgb4(uint32_t rgb) { return SkColor4f::FromColor(sk_rgb(rgb)); }

static int force_metal(void) {
  const char *e = std::getenv("OSGFX_FORCE_METAL");
  return e != nullptr && e[0] == '1';
}

static int push_cmd(OsGfxGraphite *g, int kind, int x, int y, int w, int h, int radius,
                    int blur, uint32_t c0, uint32_t c1) {
  OsGfxCmd *c;
  if (g == nullptr || g->n >= OSGFX_MAX_CMDS) {
    return 0;
  }
  c = &g->cmds[g->n];
  c->kind = kind;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->radius = radius;
  c->blur = blur;
  c->c0 = c0;
  c->c1 = c1;
  g->n = g->n + 1;
  g->cpu_ok = 0;
  return 1;
}

static void paint_cmd(SkCanvas *canvas, const OsGfxCmd *c) {
  SkRect rect = SkRect::MakeXYWH((SkScalar)c->x, (SkScalar)c->y, (SkScalar)c->w,
                                 (SkScalar)c->h);
  SkScalar rad = (SkScalar)c->radius;
  SkRRect rrect = (rad > 0) ? SkRRect::MakeRectXY(rect, rad, rad)
                            : SkRRect::MakeRect(rect);
  SkPaint paint;
  paint.setAntiAlias(true);
  paint.setStyle(SkPaint::kFill_Style);
  if (c->kind == KIND_SHADOW) {
    SkScalar sigma = (SkScalar)c->blur * 0.5f;
    if (sigma < 0.5f) {
      sigma = 0.5f;
    }
    paint.setColor(SK_ColorBLACK);
    paint.setAlphaf(0.45f);
    paint.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, sigma));
    canvas->drawRRect(rrect, paint);
    return;
  }
  if (c->kind == KIND_GRAD) {
    SkColor4f colors[2] = {sk_rgb4(c->c0), sk_rgb4(c->c1)};
    SkPoint pts[2] = {{rect.left(), rect.top()}, {rect.left(), rect.bottom()}};
    SkGradient::Colors stops(colors, SkTileMode::kClamp);
    SkGradient grad(stops, SkGradient::Interpolation());
    paint.setShader(SkShaders::LinearGradient(pts, grad));
    canvas->drawRRect(rrect, paint);
    return;
  }
  paint.setColor(sk_rgb(c->c0));
  canvas->drawRRect(rrect, paint);
}

struct ReadBack {
  int w;
  int h;
  uint32_t *cpu;
  int ok;
};

static void read_cb(SkImage::ReadPixelsContext ctx,
                    std::unique_ptr<const SkImage::AsyncReadResult> result) {
  ReadBack *rb = reinterpret_cast<ReadBack *>(ctx);
  const uint8_t *base;
  size_t stride;
  int y;
  if (result == nullptr || result->count() != 1 || rb->cpu == nullptr) {
    return;
  }
  base = static_cast<const uint8_t *>(result->data(0));
  stride = result->rowBytes(0);
  y = 0;
  while (y < rb->h) {
    int x = 0;
    const uint8_t *row = base + static_cast<size_t>(y) * stride;
    while (x < rb->w) {
      const uint8_t *p = row + static_cast<size_t>(x) * 4;
      rb->cpu[y * rb->w + x] = (static_cast<uint32_t>(p[0]) << 16) |
                               (static_cast<uint32_t>(p[1]) << 8) |
                               static_cast<uint32_t>(p[2]);
      x = x + 1;
    }
    y = y + 1;
  }
  rb->ok = 1;
}

static OsGfxGraphite *graphite_try_create(int w, int h) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> queue;
  skgpu::graphite::MtlBackendContext backend = {};
  skgpu::graphite::ContextOptions options;
  OsGfxGraphite *g;

  if (device == nil) {
    return nullptr;
  }
  queue = [device newCommandQueue];
  if (queue == nil) {
    return nullptr;
  }
  backend.fDevice.retain((__bridge CFTypeRef)device);
  backend.fQueue.retain((__bridge CFTypeRef)queue);
  std::unique_ptr<skgpu::graphite::Context> context =
      skgpu::graphite::ContextFactory::MakeMetal(backend, options);
  if (!context) {
    return nullptr;
  }
  std::unique_ptr<skgpu::graphite::Recorder> recorder = context->makeRecorder();
  if (!recorder) {
    return nullptr;
  }
  g = new OsGfxGraphite();
  g->w = w;
  g->h = h;
  g->n = 0;
  g->context = std::move(context);
  g->recorder = std::move(recorder);
  g->device = device;
  g->queue = queue;
  g->cpu = static_cast<uint32_t *>(std::calloc(static_cast<size_t>(w) * static_cast<size_t>(h),
                                               sizeof(uint32_t)));
  g->cpu_ok = 0;
  if (g->cpu == nullptr) {
    delete g;
    return nullptr;
  }
  return g;
}

static void graphite_destroy(OsGfxGraphite *g) {
  if (g == nullptr) {
    return;
  }
  std::free(g->cpu);
  delete g;
}

static int graphite_flush(OsGfxGraphite *g) {
  SkImageInfo info;
  sk_sp<SkSurface> surface;
  SkCanvas *canvas;
  int i;
  std::unique_ptr<skgpu::graphite::Recording> recording;
  skgpu::graphite::InsertRecordingInfo iri;
  ReadBack rb;

  if (g == nullptr || !g->context || !g->recorder) {
    return OSGFX_ERR;
  }
  info = SkImageInfo::Make(g->w, g->h, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  surface = SkSurfaces::RenderTarget(g->recorder.get(), info);
  if (!surface) {
    return OSGFX_ERR;
  }
  canvas = surface->getCanvas();
  canvas->clear(SK_ColorBLACK);
  i = 0;
  while (i < g->n) {
    paint_cmd(canvas, &g->cmds[i]);
    i = i + 1;
  }
  recording = g->recorder->snap();
  if (!recording) {
    return OSGFX_ERR;
  }
  iri.fRecording = recording.get();
  if (!g->context->insertRecording(iri)) {
    return OSGFX_ERR;
  }
  rb.w = g->w;
  rb.h = g->h;
  rb.cpu = g->cpu;
  rb.ok = 0;
  g->context->asyncRescaleAndReadPixels(surface.get(), info,
                                        SkIRect::MakeWH(g->w, g->h),
                                        SkImage::RescaleGamma::kSrc,
                                        SkImage::RescaleMode::kNearest, read_cb, &rb);
  g->context->submit(skgpu::graphite::SubmitInfo{skgpu::graphite::SyncToCpu::kYes});
  if (rb.ok == 0) {
    return OSGFX_ERR;
  }
  g->cpu_ok = 1;
  return OSGFX_OK;
}

static int graphite_readback(OsGfxGraphite *g, uint32_t *out, int max_pixels) {
  int n;
  if (g == nullptr || out == nullptr || g->cpu_ok == 0) {
    return -1;
  }
  n = g->w * g->h;
  if (max_pixels < n) {
    return -1;
  }
  std::memcpy(out, g->cpu, static_cast<size_t>(n) * sizeof(uint32_t));
  return n;
}

static int graphite_ppm_write(OsGfxGraphite *g, const char *path) {
  FILE *f;
  int i;
  int n;
  if (g == nullptr || path == nullptr || g->cpu_ok == 0) {
    return OSGFX_ERR;
  }
  f = std::fopen(path, "wb");
  if (f == nullptr) {
    return OSGFX_ERR;
  }
  std::fprintf(f, "P6\n%d %d\n255\n", g->w, g->h);
  n = g->w * g->h;
  i = 0;
  while (i < n) {
    uint32_t p = g->cpu[i];
    unsigned char rgb[3];
    rgb[0] = static_cast<unsigned char>((p >> 16) & 0xff);
    rgb[1] = static_cast<unsigned char>((p >> 8) & 0xff);
    rgb[2] = static_cast<unsigned char>(p & 0xff);
    std::fwrite(rgb, 1, 3, f);
    i = i + 1;
  }
  std::fclose(f);
  return OSGFX_OK;
}

static int graphite_present_layer(OsGfxGraphite *g, void *metal_layer) {
  CAMetalLayer *layer;
  id<CAMetalDrawable> draw;
  MTLTextureDescriptor *td;
  id<MTLTexture> tex;
  id<MTLCommandBuffer> cb;
  id<MTLBlitCommandEncoder> blit;
  std::vector<uint8_t> bgra;
  int n;
  int i;

  if (g == nullptr || metal_layer == nullptr || g->device == nil) {
    return OSGFX_ERR;
  }
  if (graphite_flush(g) != OSGFX_OK) {
    return OSGFX_ERR;
  }
  layer = (__bridge CAMetalLayer *)metal_layer;
  layer.device = g->device;
  layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
  layer.drawableSize = CGSizeMake(g->w, g->h);
  draw = [layer nextDrawable];
  if (draw == nil) {
    return OSGFX_ERR;
  }
  td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)g->w
                                                         height:(NSUInteger)g->h
                                                      mipmapped:NO];
  td.storageMode = MTLStorageModeShared;
  td.usage = MTLTextureUsageShaderRead;
  tex = [g->device newTextureWithDescriptor:td];
  if (tex == nil) {
    return OSGFX_ERR;
  }
  n = g->w * g->h;
  bgra.resize(static_cast<size_t>(n) * 4);
  i = 0;
  while (i < n) {
    uint32_t p = g->cpu[i];
    bgra[static_cast<size_t>(i) * 4 + 0] = static_cast<uint8_t>(p & 0xff);
    bgra[static_cast<size_t>(i) * 4 + 1] = static_cast<uint8_t>((p >> 8) & 0xff);
    bgra[static_cast<size_t>(i) * 4 + 2] = static_cast<uint8_t>((p >> 16) & 0xff);
    bgra[static_cast<size_t>(i) * 4 + 3] = 255;
    i = i + 1;
  }
  [tex replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)g->w, (NSUInteger)g->h)
         mipmapLevel:0
           withBytes:bgra.data()
         bytesPerRow:(NSUInteger)g->w * 4];
  cb = [g->queue commandBuffer];
  blit = [cb blitCommandEncoder];
  [blit copyFromTexture:tex
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake((NSUInteger)g->w, (NSUInteger)g->h, 1)
              toTexture:draw.texture
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
  [cb presentDrawable:draw];
  [cb commit];
  return OSGFX_OK;
}

static OsGfx *wrap(int kind, void *be) {
  OsGfx *g = static_cast<OsGfx *>(std::calloc(1, sizeof(OsGfx)));
  if (g == nullptr) {
    return nullptr;
  }
  g->kind = kind;
  g->be = be;
  return g;
}

extern "C" {

int osgfx_backend_graphite(void) { return 1; }

const char *osgfx_backend_name(const OsGfx *g) {
  if (g == nullptr) {
    return "none";
  }
  if (g->kind == OSGFX_KIND_GRAPHITE) {
    return "graphite";
  }
  if (g->kind == OSGFX_KIND_METAL) {
    return "metal";
  }
  return "none";
}

OsGfx *osgfx_create(int w, int h) {
  OsGfxGraphite *gr;
  OsGfxMetal *m;
  if (w <= 0 || h <= 0) {
    return nullptr;
  }
  if (!force_metal()) {
    gr = graphite_try_create(w, h);
    if (gr != nullptr) {
      return wrap(OSGFX_KIND_GRAPHITE, gr);
    }
  }
  m = osgfx_metal_create(w, h);
  if (m == nullptr) {
    return nullptr;
  }
  return wrap(OSGFX_KIND_METAL, m);
}

void osgfx_destroy(OsGfx *g) {
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_GRAPHITE) {
    graphite_destroy(static_cast<OsGfxGraphite *>(g->be));
  } else if (g->kind == OSGFX_KIND_METAL) {
    osgfx_metal_destroy(static_cast<OsGfxMetal *>(g->be));
  }
  std::free(g);
}

void osgfx_clear(OsGfx *g, uint32_t rgb) {
  OsGfxGraphite *gr;
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    osgfx_metal_clear(static_cast<OsGfxMetal *>(g->be), rgb);
    return;
  }
  gr = static_cast<OsGfxGraphite *>(g->be);
  gr->n = 0;
  push_cmd(gr, KIND_SOLID, 0, 0, gr->w, gr->h, 0, 0, rgb, rgb);
}

void osgfx_fill_rect(OsGfx *g, int x, int y, int w, int h, uint32_t rgb) {
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    osgfx_metal_fill_rect(static_cast<OsGfxMetal *>(g->be), x, y, w, h, rgb);
    return;
  }
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_SOLID, x, y, w, h, 0, 0, rgb, rgb);
}

void osgfx_fill_rrect(OsGfx *g, int x, int y, int w, int h, int radius, uint32_t rgb) {
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    osgfx_metal_fill_rrect(static_cast<OsGfxMetal *>(g->be), x, y, w, h, radius, rgb);
    return;
  }
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_SOLID, x, y, w, h, radius, 0, rgb,
           rgb);
}

void osgfx_fill_rrect_vgrad(OsGfx *g, int x, int y, int w, int h, int radius,
                            uint32_t top, uint32_t bot) {
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    osgfx_metal_fill_rrect_vgrad(static_cast<OsGfxMetal *>(g->be), x, y, w, h, radius,
                                 top, bot);
    return;
  }
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_GRAD, x, y, w, h, radius, 0, top,
           bot);
}

void osgfx_shadow(OsGfx *g, int x, int y, int w, int h, int radius, int blur,
                  uint32_t rgb) {
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    osgfx_metal_shadow(static_cast<OsGfxMetal *>(g->be), x, y, w, h, radius, blur, rgb);
    return;
  }
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_SHADOW, x, y, w, h, radius, blur,
           rgb, rgb);
}

int osgfx_flush(OsGfx *g) {
  if (g == nullptr) {
    return OSGFX_ERR;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    return osgfx_metal_flush(static_cast<OsGfxMetal *>(g->be));
  }
  return graphite_flush(static_cast<OsGfxGraphite *>(g->be));
}

int osgfx_readback(OsGfx *g, uint32_t *out, int max_pixels) {
  if (g == nullptr) {
    return -1;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    return osgfx_metal_readback(static_cast<OsGfxMetal *>(g->be), out, max_pixels);
  }
  return graphite_readback(static_cast<OsGfxGraphite *>(g->be), out, max_pixels);
}

int osgfx_ppm_write(OsGfx *g, const char *path) {
  if (g == nullptr) {
    return OSGFX_ERR;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    return osgfx_metal_ppm_write(static_cast<OsGfxMetal *>(g->be), path);
  }
  return graphite_ppm_write(static_cast<OsGfxGraphite *>(g->be), path);
}

int osgfx_present_layer(OsGfx *g, void *metal_layer) {
  if (g == nullptr) {
    return OSGFX_ERR;
  }
  if (g->kind == OSGFX_KIND_METAL) {
    return osgfx_metal_present_layer(static_cast<OsGfxMetal *>(g->be), metal_layer);
  }
  return graphite_present_layer(static_cast<OsGfxGraphite *>(g->be), metal_layer);
}

}  /* extern "C" */
