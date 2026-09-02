/* Public osgfx_* are Graphite. This file is the Metal fallback only. */
#define OsGfx OsGfxMetal
#define osgfx_create osgfx_metal_create
#define osgfx_destroy osgfx_metal_destroy
#define osgfx_clear osgfx_metal_clear
#define osgfx_fill_rect osgfx_metal_fill_rect
#define osgfx_fill_rrect osgfx_metal_fill_rrect
#define osgfx_fill_rrect_vgrad osgfx_metal_fill_rrect_vgrad
#define osgfx_shadow osgfx_metal_shadow
#define osgfx_flush osgfx_metal_flush
#define osgfx_readback osgfx_metal_readback
#define osgfx_ppm_write osgfx_metal_ppm_write
#define osgfx_present_layer osgfx_metal_present_layer
#include "osgfx.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

enum { OSGFX_MAX_CMDS = 256, KIND_SOLID = 0, KIND_GRAD = 1, KIND_SHADOW = 2 };

typedef struct {
  int kind;
  int x, y, w, h, radius, blur;
  uint32_t c0, c1;
} OsGfxCmd;

struct OsGfx {
  int w, h, n;
  OsGfxCmd cmds[OSGFX_MAX_CMDS];
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  id<MTLRenderPipelineState> pipe;
  id<MTLTexture> tex;
  uint32_t *cpu;
  int cpu_ok;
};

typedef struct {
  float rect[4];
  float color0[4];
  float color1[4];
  float viewport[2];
  float radius;
  float kind;
  float blur;
  float pad0, pad1, pad2;
} OsGfxUniforms;

static const char *kShader =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Uniforms {\n"
    "  float4 rect;\n"
    "  float4 color0;\n"
    "  float4 color1;\n"
    "  float2 viewport;\n"
    "  float radius;\n"
    "  float kind;\n"
    "  float blur;\n"
    "  float pad0;\n"
    "  float pad1;\n"
    "  float pad2;\n"
    "};\n"
    "struct VsOut { float4 pos [[position]]; };\n"
    "vertex VsOut vs_main(uint vid [[vertex_id]]) {\n"
    "  float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };\n"
    "  VsOut o; o.pos = float4(p[vid], 0.0, 1.0); return o;\n"
    "}\n"
    "float sdRoundBox(float2 p, float2 b, float r) {\n"
    "  float2 q = abs(p) - b + float2(r, r);\n"
    "  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;\n"
    "}\n"
    "fragment float4 fs_main(VsOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {\n"
    "  float2 pix = in.pos.xy;\n"
    "  float2 halfs = float2(u.rect.z, u.rect.w) * 0.5;\n"
    "  float2 center = float2(u.rect.x, u.rect.y) + halfs;\n"
    "  float rad = min(u.radius, min(halfs.x, halfs.y));\n"
    "  float sd = sdRoundBox(pix - center, halfs, rad);\n"
    "  float4 col = u.color0;\n"
    "  if (u.kind > 0.5 && u.kind < 1.5) {\n"
    "    float t = 0.0;\n"
    "    if (u.rect.w > 0.5) { t = saturate((pix.y - u.rect.y) / u.rect.w); }\n"
    "    col = mix(u.color0, u.color1, t);\n"
    "  }\n"
    "  if (u.kind > 1.5) {\n"
    "    float a = 1.0 - saturate(sd / max(u.blur, 1.0));\n"
    "    a = a * a * 0.45;\n"
    "    return float4(0.0, 0.0, 0.0, a);\n"
    "  }\n"
    "  float cover = saturate(0.5 - sd);\n"
    "  return float4(col.rgb, col.a * cover);\n"
    "}\n";

static void rgb_to_f4(uint32_t rgb, float out[4]) {
  out[0] = ((rgb >> 16) & 0xff) / 255.0f;
  out[1] = ((rgb >> 8) & 0xff) / 255.0f;
  out[2] = (rgb & 0xff) / 255.0f;
  out[3] = 1.0f;
}

static int push_cmd(OsGfx *g, int kind, int x, int y, int w, int h, int radius,
                    int blur, uint32_t c0, uint32_t c1) {
  OsGfxCmd *c;
  if (g == 0) {
    return 0;
  }
  if (g->n >= OSGFX_MAX_CMDS) {
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

OsGfx *osgfx_create(int w, int h) {
  OsGfx *g;
  MTLTextureDescriptor *td;
  NSError *err;
  id<MTLLibrary> lib;
  id<MTLFunction> vs;
  id<MTLFunction> fs;
  MTLRenderPipelineDescriptor *pd;
  MTLRenderPipelineColorAttachmentDescriptor *att;

  if (w <= 0 || h <= 0) {
    return 0;
  }
  g = calloc(1, sizeof(OsGfx));
  if (g == 0) {
    return 0;
  }
  g->w = w;
  g->h = h;
  g->device = MTLCreateSystemDefaultDevice();
  if (g->device == nil) {
    free(g);
    return 0;
  }
  g->queue = [g->device newCommandQueue];
  if (g->queue == nil) {
    free(g);
    return 0;
  }
  lib = [g->device newLibraryWithSource:@(kShader) options:nil error:&err];
  if (lib == nil) {
    fprintf(stderr, "osgfx: shader: %s\n",
            err.localizedDescription.UTF8String);
    free(g);
    return 0;
  }
  vs = [lib newFunctionWithName:@"vs_main"];
  fs = [lib newFunctionWithName:@"fs_main"];
  if (vs == nil || fs == nil) {
    free(g);
    return 0;
  }
  pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = vs;
  pd.fragmentFunction = fs;
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  att = pd.colorAttachments[0];
  att.blendingEnabled = YES;
  att.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  att.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  att.sourceAlphaBlendFactor = MTLBlendFactorOne;
  att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  g->pipe = [g->device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (g->pipe == nil) {
    fprintf(stderr, "osgfx: pipeline: %s\n",
            err.localizedDescription.UTF8String);
    free(g);
    return 0;
  }
  td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:(NSUInteger)w
                                                         height:(NSUInteger)h
                                                      mipmapped:NO];
  td.storageMode = MTLStorageModeShared;
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  g->tex = [g->device newTextureWithDescriptor:td];
  g->cpu = calloc((size_t)w * (size_t)h, sizeof(uint32_t));
  if (g->tex == nil || g->cpu == 0) {
    osgfx_destroy(g);
    return 0;
  }
  return g;
}

void osgfx_destroy(OsGfx *g) {
  if (g == 0) {
    return;
  }
  free(g->cpu);
  free(g);
}

void osgfx_clear(OsGfx *g, uint32_t rgb) {
  if (g == 0) {
    return;
  }
  g->n = 0;
  push_cmd(g, KIND_SOLID, 0, 0, g->w, g->h, 0, 0, rgb, rgb);
}

void osgfx_fill_rect(OsGfx *g, int x, int y, int w, int h, uint32_t rgb) {
  push_cmd(g, KIND_SOLID, x, y, w, h, 0, 0, rgb, rgb);
}

void osgfx_fill_rrect(OsGfx *g, int x, int y, int w, int h, int radius,
                      uint32_t rgb) {
  push_cmd(g, KIND_SOLID, x, y, w, h, radius, 0, rgb, rgb);
}

void osgfx_fill_rrect_vgrad(OsGfx *g, int x, int y, int w, int h, int radius,
                            uint32_t top, uint32_t bot) {
  push_cmd(g, KIND_GRAD, x, y, w, h, radius, 0, top, bot);
}

void osgfx_shadow(OsGfx *g, int x, int y, int w, int h, int radius, int blur,
                  uint32_t rgb) {
  push_cmd(g, KIND_SHADOW, x, y, w, h, radius, blur, rgb, rgb);
}

static int encode_to(OsGfx *g, id<MTLTexture> target) {
  id<MTLCommandBuffer> cb;
  MTLRenderPassDescriptor *rp;
  id<MTLRenderCommandEncoder> enc;
  int i;
  OsGfxUniforms u;

  if (g == 0 || target == nil) {
    return OSGFX_ERR;
  }
  cb = [g->queue commandBuffer];
  rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = target;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
  enc = [cb renderCommandEncoderWithDescriptor:rp];
  [enc setRenderPipelineState:g->pipe];
  memset(&u, 0, sizeof(u));
  u.viewport[0] = (float)g->w;
  u.viewport[1] = (float)g->h;
  i = 0;
  while (i < g->n) {
    OsGfxCmd *c;
    c = &g->cmds[i];
    u.rect[0] = (float)c->x;
    u.rect[1] = (float)c->y;
    u.rect[2] = (float)c->w;
    u.rect[3] = (float)c->h;
    rgb_to_f4(c->c0, u.color0);
    rgb_to_f4(c->c1, u.color1);
    u.radius = (float)c->radius;
    u.kind = (float)c->kind;
    u.blur = (float)c->blur;
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    i = i + 1;
  }
  [enc endEncoding];
  [cb commit];
  [cb waitUntilCompleted];
  return OSGFX_OK;
}

int osgfx_flush(OsGfx *g) {
  int rc;
  MTLRegion region;
  uint8_t *raw;
  int i;
  int n;

  if (g == 0) {
    return OSGFX_ERR;
  }
  rc = encode_to(g, g->tex);
  if (rc != OSGFX_OK) {
    return rc;
  }
  n = g->w * g->h;
  raw = malloc((size_t)n * 4);
  if (raw == 0) {
    return OSGFX_ERR;
  }
  region = MTLRegionMake2D(0, 0, (NSUInteger)g->w, (NSUInteger)g->h);
  [g->tex getBytes:raw
       bytesPerRow:(NSUInteger)g->w * 4
        fromRegion:region
       mipmapLevel:0];
  i = 0;
  while (i < n) {
    uint8_t b;
    uint8_t gv;
    uint8_t r;
    b = raw[i * 4 + 0];
    gv = raw[i * 4 + 1];
    r = raw[i * 4 + 2];
    g->cpu[i] = ((uint32_t)r << 16) | ((uint32_t)gv << 8) | (uint32_t)b;
    i = i + 1;
  }
  free(raw);
  g->cpu_ok = 1;
  return OSGFX_OK;
}

int osgfx_readback(OsGfx *g, uint32_t *out, int max_pixels) {
  int n;
  if (g == 0 || out == 0 || g->cpu_ok == 0) {
    return -1;
  }
  n = g->w * g->h;
  if (max_pixels < n) {
    return -1;
  }
  memcpy(out, g->cpu, (size_t)n * sizeof(uint32_t));
  return n;
}

int osgfx_ppm_write(OsGfx *g, const char *path) {
  FILE *f;
  int i;
  int n;
  if (g == 0 || path == 0 || g->cpu_ok == 0) {
    return OSGFX_ERR;
  }
  f = fopen(path, "wb");
  if (f == 0) {
    return OSGFX_ERR;
  }
  fprintf(f, "P6\n%d %d\n255\n", g->w, g->h);
  n = g->w * g->h;
  i = 0;
  while (i < n) {
    uint32_t p;
    unsigned char rgb[3];
    p = g->cpu[i];
    rgb[0] = (unsigned char)((p >> 16) & 0xff);
    rgb[1] = (unsigned char)((p >> 8) & 0xff);
    rgb[2] = (unsigned char)(p & 0xff);
    fwrite(rgb, 1, 3, f);
    i = i + 1;
  }
  fclose(f);
  return OSGFX_OK;
}

int osgfx_present_layer(OsGfx *g, void *metal_layer) {
  CAMetalLayer *layer;
  id<CAMetalDrawable> draw;
  id<MTLCommandBuffer> cb;
  id<MTLBlitCommandEncoder> blit;

  if (g == 0 || metal_layer == 0 || g->tex == nil) {
    return OSGFX_ERR;
  }
  if (osgfx_flush(g) != OSGFX_OK) {
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
  cb = [g->queue commandBuffer];
  blit = [cb blitCommandEncoder];
  [blit copyFromTexture:g->tex
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
