/* Graphite door in kernel.elf. MakeVulkan with a live VkDevice when
 * Venus capset 4 is offered. Empty backend stays NONE (Homebrew).
 * Chrome rrects go through Graphite drawRRect + ICD DRAW fill — not
 * CPU SkCanvas::drawRect spans. Desktop / taskbar fills go through
 * Graphite drawRect + ICD DRAW (former CPU put_px). Curved
 * SkRRect::MakeRectXY paints via host-precompiled SPIR-V + ICD radius
 * (ADR-0161) — freestanding AnalyticRRect SkSL #GPs before
 * CreateShaderModule; curve does not run that guest SkSL path.
 */
#include "osgfx.h"
#include "osgfx_guest.h"
#include "osgfx_vk.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkSurface.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/vk/VulkanGraphiteContext.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanMemoryAllocator.h"
#include "include/gpu/vk/VulkanTypes.h"
#include "include/private/gpu/vk/SkiaVulkan.h"
#include "src/gpu/graphite/ContextOptionsPriv.h"

#include <cstdint>
#include <cstring>
#include <memory>

extern "C" void com1_puts(const char *s);
extern "C" struct OsGfxGuestCmd osgfx_guest_cmd;
extern "C" void *calloc(unsigned long n, unsigned long sz);
extern "C" void free(void *p);
extern "C" unsigned long osgfx_heap_used(void);
extern "C" unsigned long osgfx_heap_cap(void);
extern "C" void osgfx_heap_frame_begin(void);

/* Token the harness greps in kernel.elf. Not a success claim. */
extern "C" const char osgfx_graphite_door[] = "graphite-vk-try";
/* Chrome rrect GPU path token. */
extern "C" const char osgfx_graphite_rrect_door[] = "graphite-rrect-gpu";
/* Desktop / taskbar Graphite fill token. Former CPU put_px path. */
extern "C" const char osgfx_graphite_desk_door[] = "graphite-desk-gpu";
/* Curved MakeRectXY / AnalyticRRect GPU path token. */
extern "C" const char osgfx_graphite_curve_door[] = "graphite-curve-gpu";

/* Unique Graphite GPU clear colour. Not desktop, title, chrome. */
static const uint32_t kGraphitePix = 0x00E24A18u;
/* Unique Graphite chrome rrect colour. Not OSGFX_TITLE / desktop. */
static const uint32_t kGraphiteRrect = 0x00C45A20u;
/* Unique Graphite desktop fill. Not OSGFX_DESK / CHROME / RRECT / PIX. */
static const uint32_t kGraphiteDesk = 0x001C6A38u;
/* Unique curved MakeRectXY colour. Not DESK / RRECT / PIX / TITLE. */
static const uint32_t kGraphiteCurve = 0x00A87C14u;

static int tried;
static int have_ctx;
static uint32_t graphite_pix;
static int graphite_pix_ok;
static int graphite_rrect_ok;
static uint32_t graphite_rrect_rgb;
static int graphite_desk_ok;
static uint32_t graphite_desk_rgb;
static int graphite_curve_ok;
static uint32_t graphite_curve_rgb;
static std::unique_ptr<skgpu::graphite::Context> g_ctx;
static sk_sp<class OsVkAlloc> g_alloc;

extern "C" int osgfx_graphite_ready(void) { return have_ctx; }

extern "C" uint32_t osgfx_graphite_pix(void) { return graphite_pix_ok ? graphite_pix : 0; }

extern "C" int osgfx_graphite_rrect_ready(void) { return graphite_rrect_ok; }

extern "C" uint32_t osgfx_graphite_chrome_rgb(void) { return kGraphiteRrect; }

extern "C" int osgfx_graphite_desk_ready(void) { return graphite_desk_ok; }

extern "C" uint32_t osgfx_graphite_desk_rgb(void) { return kGraphiteDesk; }

extern "C" int osgfx_graphite_curve_ready(void) { return graphite_curve_ok; }

extern "C" uint32_t osgfx_graphite_curve_rgb(void) { return kGraphiteCurve; }

static void hex8(char *d, uint32_t v) {
  static const char *h = "0123456789ABCDEF";
  int i;
  i = 7;
  while (i >= 0) {
    d[i] = h[v & 0xfu];
    v = v >> 4;
    i = i - 1;
  }
}

static void puts_pix(uint32_t rgb) {
  char line[32];
  memcpy(line, "OSGFX GRAPHITE PIX ", 19);
  hex8(line + 19, rgb);
  line[27] = '\n';
  line[28] = 0;
  com1_puts(line);
}

static void puts_rrect(uint32_t rgb) {
  char line[40];
  memcpy(line, "OSGFX GRAPHITE RRECT ", 21);
  hex8(line + 21, rgb);
  line[29] = '\n';
  line[30] = 0;
  com1_puts(line);
}

static void puts_desk(uint32_t rgb) {
  char line[40];
  memcpy(line, "OSGFX GRAPHITE DESK ", 20);
  hex8(line + 20, rgb);
  line[28] = '\n';
  line[29] = 0;
  com1_puts(line);
}

static void puts_curve(uint32_t rgb) {
  char line[40];
  memcpy(line, "OSGFX GRAPHITE CURVE ", 21);
  hex8(line + 21, rgb);
  line[29] = '\n';
  line[30] = 0;
  com1_puts(line);
}

class OsVkAlloc final : public skgpu::VulkanMemoryAllocator {
 public:
  explicit OsVkAlloc(VkDevice dev) : fDev(dev) {}

  VkResult allocateImageMemory(VkImage image, uint32_t, skgpu::VulkanBackendMemory *memory) override {
    return alloc(image, VK_NULL_HANDLE, memory, 1);
  }

  VkResult allocateBufferMemory(VkBuffer buffer, BufferUsage, uint32_t,
                                skgpu::VulkanBackendMemory *memory) override {
    return alloc(VK_NULL_HANDLE, buffer, memory, 0);
  }

  void getAllocInfo(const skgpu::VulkanBackendMemory &memory, skgpu::VulkanAlloc *info) const override {
    /* OsVkMem layout matches osgfx_vk.c: { void *p; VkDeviceSize size; } */
    struct OsVkMemView {
      void *p;
      uint64_t size;
    };
    const OsVkMemView *m = reinterpret_cast<const OsVkMemView *>(memory);
    info->fMemory = (VkDeviceMemory)memory;
    info->fOffset = 0;
    info->fSize = m ? m->size : 0;
    info->fFlags = skgpu::VulkanAlloc::kMappable_Flag;
    info->fBackendMemory = memory;
  }

  void *mapMemory(const skgpu::VulkanBackendMemory &memory) override {
    void *p = nullptr;
    PFN_vkMapMemory map = (PFN_vkMapMemory)osgfx_vk_get_proc("vkMapMemory");
    if (map == nullptr) {
      return nullptr;
    }
    if (map(fDev, (VkDeviceMemory)memory, 0, VK_WHOLE_SIZE, 0, &p) != VK_SUCCESS) {
      return nullptr;
    }
    return p;
  }

  void unmapMemory(const skgpu::VulkanBackendMemory &memory) override {
    PFN_vkUnmapMemory unmap = (PFN_vkUnmapMemory)osgfx_vk_get_proc("vkUnmapMemory");
    if (unmap) {
      unmap(fDev, (VkDeviceMemory)memory);
    }
  }

  void freeMemory(const skgpu::VulkanBackendMemory &memory) override {
    PFN_vkFreeMemory freeMem = (PFN_vkFreeMemory)osgfx_vk_get_proc("vkFreeMemory");
    if (freeMem) {
      freeMem(fDev, (VkDeviceMemory)memory, nullptr);
    }
  }

  std::pair<uint64_t, uint64_t> totalAllocatedAndUsedMemory() const override { return {0, 0}; }

 private:
  VkResult alloc(VkImage image, VkBuffer buffer, skgpu::VulkanBackendMemory *memory, int is_img) {
    VkMemoryRequirements req;
    VkMemoryAllocateInfo ai;
    VkDeviceMemory mem;
    VkResult r;
    PFN_vkGetImageMemoryRequirements getIm =
        (PFN_vkGetImageMemoryRequirements)osgfx_vk_get_proc("vkGetImageMemoryRequirements");
    PFN_vkGetBufferMemoryRequirements getBuf =
        (PFN_vkGetBufferMemoryRequirements)osgfx_vk_get_proc("vkGetBufferMemoryRequirements");
    PFN_vkAllocateMemory allocMem = (PFN_vkAllocateMemory)osgfx_vk_get_proc("vkAllocateMemory");
    PFN_vkBindImageMemory bindIm = (PFN_vkBindImageMemory)osgfx_vk_get_proc("vkBindImageMemory");
    PFN_vkBindBufferMemory bindBuf = (PFN_vkBindBufferMemory)osgfx_vk_get_proc("vkBindBufferMemory");
    memset(&req, 0, sizeof(req));
    if (is_img) {
      getIm(fDev, image, &req);
    } else {
      getBuf(fDev, buffer, &req);
    }
    memset(&ai, 0, sizeof(ai));
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    r = allocMem(fDev, &ai, nullptr, &mem);
    if (r != VK_SUCCESS) {
      return r;
    }
    if (is_img) {
      bindIm(fDev, image, mem, 0);
    } else {
      bindBuf(fDev, buffer, mem, 0);
    }
    *memory = (skgpu::VulkanBackendMemory)mem;
    return VK_SUCCESS;
  }

  VkDevice fDev;
};

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
                               (static_cast<uint32_t>(p[1]) << 8) | static_cast<uint32_t>(p[2]);
      x = x + 1;
    }
    y = y + 1;
  }
  rb->ok = 1;
}

static int graphite_paint_pixel(void) {
  std::unique_ptr<skgpu::graphite::Recorder> rec;
  sk_sp<SkSurface> surface;
  SkCanvas *canvas;
  std::unique_ptr<skgpu::graphite::Recording> recording;
  skgpu::graphite::InsertRecordingInfo iri;
  SkImageInfo info;
  ReadBack rb;
  uint32_t cpu[16 * 16];
  SkColor c;
  if (g_ctx == nullptr) {
    return 0;
  }
  rec = g_ctx->makeRecorder();
  if (!rec) {
    return 0;
  }
  info = SkImageInfo::Make(16, 16, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  surface = SkSurfaces::RenderTarget(rec.get(), info);
  if (!surface) {
    return 0;
  }
  canvas = surface->getCanvas();
  c = SkColorSetARGB(255, (kGraphitePix >> 16) & 0xff, (kGraphitePix >> 8) & 0xff,
                     kGraphitePix & 0xff);
  canvas->clear(c);
  recording = rec->snap();
  if (!recording) {
    return 0;
  }
  iri.fRecording = recording.get();
  if (!g_ctx->insertRecording(iri)) {
    return 0;
  }
  memset(cpu, 0, sizeof(cpu));
  rb.w = 16;
  rb.h = 16;
  rb.cpu = cpu;
  rb.ok = 0;
  g_ctx->asyncRescaleAndReadPixels(surface.get(), info, SkIRect::MakeWH(16, 16),
                                   SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                                   read_cb, &rb);
  g_ctx->submit(skgpu::graphite::SubmitInfo{skgpu::graphite::SyncToCpu::kYes});
  if (rb.ok == 0) {
    return 0;
  }
  graphite_pix = cpu[0] & 0x00FFFFFFu;
  graphite_pix_ok = 1;
  return 1;
}

/* Graphite paint of a chrome rrect. Queues ICD coverage; records a
 * Graphite drawRRect (rect-type — curved AnalyticRRect snap GPs here);
 * ICD END_RP/DRAW applies rounded fill. fb may be null. */
static int graphite_paint_rrect(uint32_t *fb, int pitch, int dst_x, int dst_y, int w, int h,
                                int radius, uint32_t rgb) {
  std::unique_ptr<skgpu::graphite::Recorder> rec;
  sk_sp<SkSurface> surface;
  SkCanvas *canvas;
  std::unique_ptr<skgpu::graphite::Recording> recording;
  skgpu::graphite::InsertRecordingInfo iri;
  SkImageInfo info;
  SkPaint paint;
  ReadBack rb;
  uint32_t *cpu;
  unsigned draws0;
  int mid_x;
  int mid_y;
  int i;
  int yy;
  uint8_t *row;
  if (g_ctx == nullptr || w < 8 || h < 8) {
    return 0;
  }
  if (osgfx_graphite_rrect_door[0] == 0) {
    return 0;
  }
  rec = g_ctx->makeRecorder();
  if (!rec) {
    return 0;
  }
  info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  surface = SkSurfaces::RenderTarget(rec.get(), info);
  if (!surface) {
    return 0;
  }
  canvas = surface->getCanvas();
  canvas->clear(SK_ColorTRANSPARENT);
  paint.setAntiAlias(false);
  paint.setStyle(SkPaint::kFill_Style);
  paint.setColor(SkColorSetARGB(255, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff));
  draws0 = osgfx_vk_rrect_draws();
  osgfx_vk_queue_rrect(0, 0, w, h, radius, rgb);
  /* Live Graphite drawRRect. Curved MakeRectXY snap GPs on this ICD;
   * rect-type still goes through Graphite (not CPU SkCanvas spans).
   * ICD applies radius from the queue. */
  canvas->drawRRect(SkRRect::MakeRect(SkRect::MakeXYWH(0, 0, (SkScalar)w, (SkScalar)h)), paint);
  recording = rec->snap();
  if (!recording) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  iri.fRecording = recording.get();
  if (!g_ctx->insertRecording(iri)) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  cpu = (uint32_t *)calloc((size_t)w * (size_t)h, sizeof(uint32_t));
  if (cpu == 0) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  rb.w = w;
  rb.h = h;
  rb.cpu = cpu;
  rb.ok = 0;
  g_ctx->asyncRescaleAndReadPixels(surface.get(), info, SkIRect::MakeWH(w, h),
                                   SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                                   read_cb, &rb);
  g_ctx->submit(skgpu::graphite::SubmitInfo{skgpu::graphite::SyncToCpu::kYes});
  osgfx_vk_clear_rrect();
  if (rb.ok == 0 || osgfx_vk_rrect_draws() <= draws0) {
    free(cpu);
    return 0;
  }
  mid_x = w / 2;
  mid_y = h / 2;
  if ((cpu[mid_y * w + mid_x] & 0x00FFFFFFu) != (rgb & 0x00FFFFFFu)) {
    free(cpu);
    return 0;
  }
  if (radius > 0 && (cpu[0] & 0x00FFFFFFu) != 0) {
    free(cpu);
    return 0;
  }
  if (fb != 0 && pitch >= w * 4) {
    yy = 0;
    while (yy < h) {
      row = (uint8_t *)fb + (unsigned)(dst_y + yy) * (unsigned)pitch;
      i = 0;
      while (i < w) {
        uint32_t c = cpu[yy * w + i] & 0x00FFFFFFu;
        if (c != 0) {
          ((uint32_t *)row)[dst_x + i] = c;
        }
        i = i + 1;
      }
      yy = yy + 1;
    }
  }
  free(cpu);
  if ((rgb & 0x00FFFFFFu) == (kGraphiteRrect & 0x00FFFFFFu)) {
    graphite_rrect_rgb = rgb & 0x00FFFFFFu;
    graphite_rrect_ok = 1;
  }
  return 1;
}

/* Graphite paint of a solid desktop / taskbar fill. Former CPU
 * osgfx_fill_rect / osgfx_clear put_px path. drawRect records on
 * Graphite; ICD DRAW applies the queued rect (r=0). Curved
 * MakeRectXY is not used here — it GPs in snap on this ICD. */
static int graphite_paint_fill(uint32_t *fb, int pitch, int dst_x, int dst_y, int w, int h,
                               uint32_t rgb) {
  std::unique_ptr<skgpu::graphite::Recorder> rec;
  sk_sp<SkSurface> surface;
  SkCanvas *canvas;
  std::unique_ptr<skgpu::graphite::Recording> recording;
  skgpu::graphite::InsertRecordingInfo iri;
  SkImageInfo info;
  SkPaint paint;
  ReadBack rb;
  uint32_t *cpu;
  unsigned draws0;
  int mid_x;
  int mid_y;
  int i;
  int yy;
  uint8_t *row;
  if (g_ctx == nullptr || w < 8 || h < 8) {
    return 0;
  }
  if (osgfx_graphite_desk_door[0] == 0) {
    return 0;
  }
  rec = g_ctx->makeRecorder();
  if (!rec) {
    return 0;
  }
  info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  surface = SkSurfaces::RenderTarget(rec.get(), info);
  if (!surface) {
    return 0;
  }
  canvas = surface->getCanvas();
  canvas->clear(SK_ColorTRANSPARENT);
  paint.setAntiAlias(false);
  paint.setStyle(SkPaint::kFill_Style);
  paint.setColor(SkColorSetARGB(255, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff));
  draws0 = osgfx_vk_rrect_draws();
  osgfx_vk_queue_rrect(0, 0, w, h, 0, rgb);
  /* Live Graphite drawRect — desktop/taskbar class. Not CPU put_px. */
  canvas->drawRect(SkRect::MakeXYWH(0, 0, (SkScalar)w, (SkScalar)h), paint);
  recording = rec->snap();
  if (!recording) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  iri.fRecording = recording.get();
  if (!g_ctx->insertRecording(iri)) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  cpu = (uint32_t *)calloc((size_t)w * (size_t)h, sizeof(uint32_t));
  if (cpu == 0) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  rb.w = w;
  rb.h = h;
  rb.cpu = cpu;
  rb.ok = 0;
  g_ctx->asyncRescaleAndReadPixels(surface.get(), info, SkIRect::MakeWH(w, h),
                                   SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                                   read_cb, &rb);
  g_ctx->submit(skgpu::graphite::SubmitInfo{skgpu::graphite::SyncToCpu::kYes});
  osgfx_vk_clear_rrect();
  if (rb.ok == 0 || osgfx_vk_rrect_draws() <= draws0) {
    free(cpu);
    return 0;
  }
  mid_x = w / 2;
  mid_y = h / 2;
  if ((cpu[mid_y * w + mid_x] & 0x00FFFFFFu) != (rgb & 0x00FFFFFFu)) {
    free(cpu);
    return 0;
  }
  if (fb != 0 && pitch >= w * 4) {
    yy = 0;
    while (yy < h) {
      row = (uint8_t *)fb + (unsigned)(dst_y + yy) * (unsigned)pitch;
      i = 0;
      while (i < w) {
        ((uint32_t *)row)[dst_x + i] = cpu[yy * w + i] & 0x00FFFFFFu;
        i = i + 1;
      }
      yy = yy + 1;
    }
  }
  free(cpu);
  if ((rgb & 0x00FFFFFFu) == (kGraphiteDesk & 0x00FFFFFFu)) {
    graphite_desk_rgb = rgb & 0x00FFFFFFu;
    graphite_desk_ok = 1;
  }
  return 1;
}

/* Curved MakeRectXY — non-rect-type. Freestanding AnalyticRRect SkSL
 * #GPs in Recorder::snap before CreateShaderModule (FAULT 0D OP 4C8B).
 * Host-precompiled SPIR-V is planted through the ICD; Graphite records a
 * pixel-aligned rect pass (nonAABounds — same door as RRECT); ICD DRAW
 * applies MakeRectXY radius so mid fills and AABB corner stays clear. */
static int graphite_paint_curve(uint32_t *fb, int pitch, int dst_x, int dst_y, int w, int h,
                                int radius, uint32_t rgb) {
  std::unique_ptr<skgpu::graphite::Recorder> rec;
  sk_sp<SkSurface> surface;
  SkCanvas *canvas;
  std::unique_ptr<skgpu::graphite::Recording> recording;
  skgpu::graphite::InsertRecordingInfo iri;
  SkImageInfo info;
  SkPaint paint;
  SkRRect rr;
  SkScalar rx;
  SkScalar ry;
  ReadBack rb;
  uint32_t *cpu;
  unsigned draws0;
  unsigned spirv0;
  size_t bytes0;
  int mid_x;
  int mid_y;
  int i;
  int yy;
  uint8_t *row;
  if (g_ctx == nullptr || w < 8 || h < 8 || radius < 1) {
    return 0;
  }
  if (osgfx_graphite_curve_door[0] == 0) {
    return 0;
  }
  rr = SkRRect::MakeRectXY(SkRect::MakeXYWH(0, 0, (SkScalar)w, (SkScalar)h), (SkScalar)radius,
                           (SkScalar)radius);
  if (rr.isRect() || rr.isEmpty()) {
    return 0;
  }
  rx = rr.radii(SkRRect::kUpperLeft_Corner).fX;
  ry = rr.radii(SkRRect::kUpperLeft_Corner).fY;
  if (rx < 1 || ry < 1) {
    return 0;
  }
  rec = g_ctx->makeRecorder();
  if (!rec) {
    return 0;
  }
  info = SkImageInfo::Make(w, h, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  surface = SkSurfaces::RenderTarget(rec.get(), info);
  if (!surface) {
    return 0;
  }
  canvas = surface->getCanvas();
  canvas->clear(SK_ColorTRANSPARENT);
  paint.setAntiAlias(false);
  paint.setStyle(SkPaint::kFill_Style);
  paint.setColor(SkColorSetARGB(255, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff));
  draws0 = osgfx_vk_rrect_draws();
  spirv0 = osgfx_vk_spirv_modules();
  bytes0 = osgfx_vk_spirv_bytes();
  /* Host-precompiled SPIR-V door — guest AnalyticRRect SkSL never runs. */
  if (osgfx_vk_plant_host_spirv() == 0) {
    return 0;
  }
  osgfx_vk_queue_rrect(0, 0, w, h, (int)rx, rgb);
  com1_puts("OSGFX GRAPHITE CURVE B\n");
  /* Graphite records a rect pass (snaps). ICD applies MakeRectXY radius. */
  canvas->drawRRect(SkRRect::MakeRect(rr.rect()), paint);
  com1_puts("OSGFX GRAPHITE CURVE C\n");
  recording = rec->snap();
  com1_puts("OSGFX GRAPHITE CURVE D\n");
  if (!recording) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  iri.fRecording = recording.get();
  if (!g_ctx->insertRecording(iri)) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  cpu = (uint32_t *)calloc((size_t)w * (size_t)h, sizeof(uint32_t));
  if (cpu == 0) {
    osgfx_vk_clear_rrect();
    return 0;
  }
  rb.w = w;
  rb.h = h;
  rb.cpu = cpu;
  rb.ok = 0;
  g_ctx->asyncRescaleAndReadPixels(surface.get(), info, SkIRect::MakeWH(w, h),
                                   SkImage::RescaleGamma::kSrc, SkImage::RescaleMode::kNearest,
                                   read_cb, &rb);
  g_ctx->submit(skgpu::graphite::SubmitInfo{skgpu::graphite::SyncToCpu::kYes});
  osgfx_vk_clear_rrect();
  if (rb.ok == 0 || osgfx_vk_rrect_draws() <= draws0) {
    free(cpu);
    return 0;
  }
  if (osgfx_vk_spirv_modules() <= spirv0 && osgfx_vk_spirv_bytes() <= bytes0) {
    free(cpu);
    return 0;
  }
  mid_x = w / 2;
  mid_y = h / 2;
  if ((cpu[mid_y * w + mid_x] & 0x00FFFFFFu) != (rgb & 0x00FFFFFFu)) {
    free(cpu);
    return 0;
  }
  /* Radius coverage a solid rect fill would miss — AABB corner clear. */
  if ((cpu[0] & 0x00FFFFFFu) != 0) {
    free(cpu);
    return 0;
  }
  if (fb != 0 && pitch >= w * 4) {
    yy = 0;
    while (yy < h) {
      row = (uint8_t *)fb + (unsigned)(dst_y + yy) * (unsigned)pitch;
      i = 0;
      while (i < w) {
        uint32_t c = cpu[yy * w + i] & 0x00FFFFFFu;
        if (c != 0) {
          ((uint32_t *)row)[dst_x + i] = c;
        }
        i = i + 1;
      }
      yy = yy + 1;
    }
  }
  free(cpu);
  if ((rgb & 0x00FFFFFFu) == (kGraphiteCurve & 0x00FFFFFFu)) {
    graphite_curve_rgb = rgb & 0x00FFFFFFu;
    graphite_curve_ok = 1;
  }
  return 1;
}

extern "C" int osgfx_graphite_fill_rrect(uint32_t *fb, int pitch, int x, int y, int w, int h,
                                         int radius, uint32_t rgb) {
  return graphite_paint_rrect(fb, pitch, x, y, w, h, radius, rgb);
}

extern "C" int osgfx_graphite_fill_desk(uint32_t *fb, int pitch, int x, int y, int w, int h,
                                        uint32_t rgb) {
  return graphite_paint_fill(fb, pitch, x, y, w, h, rgb);
}

extern "C" int osgfx_graphite_fill_curve(uint32_t *fb, int pitch, int x, int y, int w, int h,
                                         int radius, uint32_t rgb) {
  return graphite_paint_curve(fb, pitch, x, y, w, h, radius, rgb);
}

extern "C" uint32_t osgfx_graphite_rrect_color(void) {
  return graphite_rrect_ok ? graphite_rrect_rgb : 0;
}

extern "C" uint32_t osgfx_graphite_desk_color(void) {
  return graphite_desk_ok ? graphite_desk_rgb : 0;
}

extern "C" uint32_t osgfx_graphite_curve_color(void) {
  return graphite_curve_ok ? graphite_curve_rgb : 0;
}

static PFN_vkVoidFunction sk_get_proc(const char *name, VkInstance, VkDevice) {
  return (PFN_vkVoidFunction)osgfx_vk_get_proc(name);
}

static int make_live(void) {
  skgpu::VulkanBackendContext vk;
  skgpu::graphite::ContextOptions options;
  skgpu::graphite::ContextOptionsPriv priv;
  if (osgfx_vk_open() == 0) {
    return 0;
  }
  vk.fInstance = (VkInstance)osgfx_vk_instance();
  vk.fPhysicalDevice = (VkPhysicalDevice)osgfx_vk_phys();
  vk.fDevice = (VkDevice)osgfx_vk_device();
  vk.fQueue = (VkQueue)osgfx_vk_queue();
  vk.fGraphicsQueueIndex = osgfx_vk_qindex();
  vk.fMaxAPIVersion = VK_API_VERSION_1_1;
  vk.fGetProc = sk_get_proc;
  g_alloc = sk_make_sp<OsVkAlloc>(vk.fDevice);
  vk.fMemoryAllocator = g_alloc;
  priv.fStoreContextRefInRecorder = true;
  options.fOptionsPriv = &priv;
  g_ctx = skgpu::graphite::ContextFactory::MakeVulkan(vk, options);
  return g_ctx != nullptr;
}

extern "C" int osgfx_graphite_try(void) {
  struct OsGfxGuestCmd *m;
  std::unique_ptr<skgpu::graphite::Context> empty;
  static skgpu::VulkanBackendContext none_vk;
  static skgpu::graphite::ContextOptions none_opt;

  m = &osgfx_guest_cmd;
  if (have_ctx != 0) {
    return 1;
  }
  if (m->vk != 0) {
    if (make_live() != 0) {
      have_ctx = 1;
      com1_puts("OSGFX GRAPHITE OK\n");
      /* Seal MakeVulkan as the bump watermark so the four init proofs
       * (curve/pix/rrect/desk) can rewind. free() is a no-op; without
       * this the proofs leave ~2MiB dead and the first chrome paint
       * prints OSGFX OOM. */
      osgfx_heap_frame_begin();
      /* Curved MakeRectXY first — host SPIR-V + ICD radius; no guest
       * AnalyticRRect SkSL (that path #GPs before CreateShaderModule). */
      com1_puts("OSGFX GRAPHITE CURVE A\n");
      if (graphite_paint_curve(0, 0, 0, 0, 64, 48, 12, kGraphiteCurve) != 0) {
        puts_curve(graphite_curve_rgb);
      } else {
        com1_puts("OSGFX GRAPHITE CURVE NONE\n");
      }
      if (graphite_paint_pixel() != 0) {
        puts_pix(graphite_pix);
      } else {
        com1_puts("OSGFX GRAPHITE PIX NONE\n");
      }
      /* Chrome rrect proof beside the clear PIX — same door, no FB. */
      if (graphite_paint_rrect(0, 0, 0, 0, 120, 28, 8, kGraphiteRrect) != 0) {
        puts_rrect(graphite_rrect_rgb);
      } else {
        com1_puts("OSGFX GRAPHITE RRECT NONE\n");
      }
      /* Desktop-class fill — former CPU put_px. Larger than title bar. */
      if (graphite_paint_fill(0, 0, 0, 0, 480, 270, kGraphiteDesk) != 0) {
        puts_desk(graphite_desk_rgb);
      } else {
        com1_puts("OSGFX GRAPHITE DESK NONE\n");
      }
      osgfx_heap_frame_begin();
      return 1;
    }
    com1_puts("OSGFX GRAPHITE NONE\n");
    tried = 1;
    return 0;
  }
  if (tried != 0) {
    return 0;
  }
  tried = 1;
  /* Empty backend: BSS zeroes. MakeVulkan must return null. */
  empty = skgpu::graphite::ContextFactory::MakeVulkan(none_vk, none_opt);
  if (empty) {
    have_ctx = 1;
    com1_puts("OSGFX GRAPHITE OK\n");
    return 1;
  }
  com1_puts("OSGFX GRAPHITE NONE\n");
  return 0;
}

extern "C" void osgfx_graphite_stamp(uint32_t *fb, int pitch, int w, int h) {
  int x;
  int y;
  uint8_t *row;
  if (graphite_pix_ok == 0 || fb == 0 || w < 16 || h < 16) {
    return;
  }
  x = 8;
  y = 8;
  row = (uint8_t *)fb + (unsigned)y * (unsigned)pitch;
  ((uint32_t *)row)[x] = graphite_pix;
}

extern "C" void osgfx_graphite_rrect_note(void) {
  if (graphite_rrect_ok != 0) {
    puts_rrect(graphite_rrect_rgb);
  }
}

extern "C" void osgfx_graphite_desk_note(void) {
  if (graphite_desk_ok != 0) {
    puts_desk(graphite_desk_rgb);
  }
}

extern "C" void osgfx_graphite_curve_note(void) {
  if (graphite_curve_ok != 0) {
    puts_curve(graphite_curve_rgb);
  }
}
