/* Linux host Skia Graphite rasterizer behind osgfx.h.
 * Vulkan + lavapipe (or any ICD). Metal is Darwin-only.
 * Same command list / drawRRect / readback as osgfx_graphite.mm. */
#include "osgfx.h"

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
#include "include/gpu/graphite/vk/VulkanGraphiteContext.h"
#include "include/gpu/vk/VulkanBackendContext.h"
#include "include/gpu/vk/VulkanExtensions.h"
#include "include/gpu/vk/VulkanMemoryAllocator.h"
#include "include/gpu/vk/VulkanTypes.h"
#include "include/private/gpu/vk/SkiaVulkan.h"

#include <vulkan/vulkan.h>

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

class HostVkAlloc final : public skgpu::VulkanMemoryAllocator {
 public:
  explicit HostVkAlloc(VkDevice dev) : fDev(dev) {}

  VkResult allocateImageMemory(VkImage image, uint32_t,
                               skgpu::VulkanBackendMemory *memory) override {
    return alloc(image, VK_NULL_HANDLE, memory, 1);
  }

  VkResult allocateBufferMemory(VkBuffer buffer, BufferUsage, uint32_t,
                                skgpu::VulkanBackendMemory *memory) override {
    return alloc(VK_NULL_HANDLE, buffer, memory, 0);
  }

  void getAllocInfo(const skgpu::VulkanBackendMemory &memory,
                    skgpu::VulkanAlloc *info) const override {
    const Slot *s = reinterpret_cast<const Slot *>(memory);
    info->fMemory = s ? s->mem : VK_NULL_HANDLE;
    info->fOffset = 0;
    info->fSize = s ? s->size : 0;
    info->fFlags = skgpu::VulkanAlloc::kMappable_Flag;
    info->fBackendMemory = memory;
  }

  void *mapMemory(const skgpu::VulkanBackendMemory &memory) override {
    const Slot *s = reinterpret_cast<const Slot *>(memory);
    void *p = nullptr;
    if (s == nullptr) {
      return nullptr;
    }
    if (vkMapMemory(fDev, s->mem, 0, VK_WHOLE_SIZE, 0, &p) != VK_SUCCESS) {
      return nullptr;
    }
    return p;
  }

  void unmapMemory(const skgpu::VulkanBackendMemory &memory) override {
    const Slot *s = reinterpret_cast<const Slot *>(memory);
    if (s != nullptr) {
      vkUnmapMemory(fDev, s->mem);
    }
  }

  void freeMemory(const skgpu::VulkanBackendMemory &memory) override {
    Slot *s = reinterpret_cast<Slot *>(memory);
    if (s == nullptr) {
      return;
    }
    vkFreeMemory(fDev, s->mem, nullptr);
    delete s;
  }

  std::pair<uint64_t, uint64_t> totalAllocatedAndUsedMemory() const override {
    return {0, 0};
  }

 private:
  struct Slot {
    VkDeviceMemory mem;
    VkDeviceSize size;
  };

  uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    uint32_t i;
    vkGetPhysicalDeviceMemoryProperties(fPhys, &mp);
    i = 0;
    while (i < mp.memoryTypeCount) {
      if ((bits & (1u << i)) != 0) {
        if ((mp.memoryTypes[i].propertyFlags & want) == want) {
          return i;
        }
      }
      i = i + 1;
    }
    return 0;
  }

  VkResult alloc(VkImage image, VkBuffer buffer, skgpu::VulkanBackendMemory *memory,
                 int is_img) {
    VkMemoryRequirements req;
    VkMemoryAllocateInfo ai;
    Slot *s;
    memset(&req, 0, sizeof(req));
    if (is_img) {
      vkGetImageMemoryRequirements(fDev, image, &req);
    } else {
      vkGetBufferMemoryRequirements(fDev, buffer, &req);
    }
    s = new Slot();
    memset(&ai, 0, sizeof(ai));
    ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = memory_type(
        req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (vkAllocateMemory(fDev, &ai, nullptr, &s->mem) != VK_SUCCESS) {
      ai.memoryTypeIndex = memory_type(req.memoryTypeBits, 0);
      if (vkAllocateMemory(fDev, &ai, nullptr, &s->mem) != VK_SUCCESS) {
        delete s;
        return VK_ERROR_OUT_OF_DEVICE_MEMORY;
      }
    }
    s->size = req.size;
    if (is_img) {
      vkBindImageMemory(fDev, image, s->mem, 0);
    } else {
      vkBindBufferMemory(fDev, buffer, s->mem, 0);
    }
    *memory = (skgpu::VulkanBackendMemory)s;
    return VK_SUCCESS;
  }

 public:
  VkPhysicalDevice fPhys = VK_NULL_HANDLE;

 private:
  VkDevice fDev;
};

struct OsGfxGraphite {
  int w, h, n;
  OsGfxCmd cmds[OSGFX_MAX_CMDS];
  std::unique_ptr<skgpu::graphite::Context> context;
  std::unique_ptr<skgpu::graphite::Recorder> recorder;
  VkInstance instance;
  VkDevice device;
  VkQueue queue;
  VkPhysicalDevice phys;
  uint32_t qindex;
  sk_sp<HostVkAlloc> alloc;
  skgpu::VulkanExtensions extensions;
  VkPhysicalDeviceFeatures features;
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

static PFN_vkVoidFunction sk_get_proc(const char *name, VkInstance inst, VkDevice dev) {
  if (dev != VK_NULL_HANDLE) {
    PFN_vkVoidFunction p = vkGetDeviceProcAddr(dev, name);
    if (p != nullptr) {
      return p;
    }
  }
  if (inst != VK_NULL_HANDLE) {
    PFN_vkVoidFunction p = vkGetInstanceProcAddr(inst, name);
    if (p != nullptr) {
      return p;
    }
  }
  return vkGetInstanceProcAddr(VK_NULL_HANDLE, name);
}

static int vk_boot(OsGfxGraphite *g) {
  VkApplicationInfo app;
  VkInstanceCreateInfo ici;
  uint32_t n = 0;
  uint32_t i;
  std::vector<VkPhysicalDevice> phys;
  uint32_t qn = 0;
  std::vector<VkQueueFamilyProperties> qf;
  int q = -1;
  float prio = 1.f;
  VkDeviceQueueCreateInfo qci;
  VkDeviceCreateInfo dci;
  const char *idev[] = {VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME,
                        VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME};

  memset(&app, 0, sizeof(app));
  app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  app.pApplicationName = "osgfx-headless";
  app.apiVersion = VK_API_VERSION_1_1;
  memset(&ici, 0, sizeof(ici));
  ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  ici.pApplicationInfo = &app;
  if (vkCreateInstance(&ici, nullptr, &g->instance) != VK_SUCCESS) {
    return 0;
  }
  vkEnumeratePhysicalDevices(g->instance, &n, nullptr);
  if (n < 1) {
    return 0;
  }
  phys.resize(n);
  vkEnumeratePhysicalDevices(g->instance, &n, phys.data());
  g->phys = phys[0];
  vkGetPhysicalDeviceQueueFamilyProperties(g->phys, &qn, nullptr);
  qf.resize(qn);
  vkGetPhysicalDeviceQueueFamilyProperties(g->phys, &qn, qf.data());
  i = 0;
  while (i < qn) {
    if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
      q = (int)i;
      break;
    }
    i = i + 1;
  }
  if (q < 0) {
    return 0;
  }
  g->qindex = (uint32_t)q;
  memset(&qci, 0, sizeof(qci));
  qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  qci.queueFamilyIndex = g->qindex;
  qci.queueCount = 1;
  qci.pQueuePriorities = &prio;
  memset(&g->features, 0, sizeof(g->features));
  vkGetPhysicalDeviceFeatures(g->phys, &g->features);
  memset(&dci, 0, sizeof(dci));
  dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  dci.queueCreateInfoCount = 1;
  dci.pQueueCreateInfos = &qci;
  dci.pEnabledFeatures = &g->features;
  dci.enabledExtensionCount = 2;
  dci.ppEnabledExtensionNames = idev;
  if (vkCreateDevice(g->phys, &dci, nullptr, &g->device) != VK_SUCCESS) {
    dci.enabledExtensionCount = 0;
    dci.ppEnabledExtensionNames = nullptr;
    if (vkCreateDevice(g->phys, &dci, nullptr, &g->device) != VK_SUCCESS) {
      return 0;
    }
  }
  vkGetDeviceQueue(g->device, g->qindex, 0, &g->queue);
  return 1;
}

static OsGfxGraphite *graphite_try_create(int w, int h) {
  OsGfxGraphite *g;
  skgpu::VulkanBackendContext vk;
  skgpu::graphite::ContextOptions options;
  const char *none = nullptr;

  g = new OsGfxGraphite();
  g->w = w;
  g->h = h;
  g->n = 0;
  g->instance = VK_NULL_HANDLE;
  g->device = VK_NULL_HANDLE;
  g->queue = VK_NULL_HANDLE;
  g->phys = VK_NULL_HANDLE;
  g->qindex = 0;
  g->cpu = nullptr;
  g->cpu_ok = 0;
  if (vk_boot(g) == 0) {
    delete g;
    return nullptr;
  }
  g->extensions.init(sk_get_proc, g->instance, g->phys, 0, &none, 0, &none);
  g->alloc = sk_make_sp<HostVkAlloc>(g->device);
  g->alloc->fPhys = g->phys;
  memset(&vk, 0, sizeof(vk));
  vk.fInstance = g->instance;
  vk.fPhysicalDevice = g->phys;
  vk.fDevice = g->device;
  vk.fQueue = g->queue;
  vk.fGraphicsQueueIndex = g->qindex;
  vk.fMaxAPIVersion = VK_API_VERSION_1_1;
  vk.fVkExtensions = &g->extensions;
  vk.fDeviceFeatures = &g->features;
  vk.fMemoryAllocator = g->alloc;
  vk.fGetProc = sk_get_proc;
  g->context = skgpu::graphite::ContextFactory::MakeVulkan(vk, options);
  if (!g->context) {
    vkDestroyDevice(g->device, nullptr);
    vkDestroyInstance(g->instance, nullptr);
    delete g;
    return nullptr;
  }
  g->recorder = g->context->makeRecorder();
  if (!g->recorder) {
    g->context.reset();
    vkDestroyDevice(g->device, nullptr);
    vkDestroyInstance(g->instance, nullptr);
    delete g;
    return nullptr;
  }
  g->cpu = static_cast<uint32_t *>(
      std::calloc(static_cast<size_t>(w) * static_cast<size_t>(h), sizeof(uint32_t)));
  if (g->cpu == nullptr) {
    g->recorder.reset();
    g->context.reset();
    vkDestroyDevice(g->device, nullptr);
    vkDestroyInstance(g->instance, nullptr);
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
  g->recorder.reset();
  g->context.reset();
  g->alloc.reset();
  if (g->device != VK_NULL_HANDLE) {
    vkDestroyDevice(g->device, nullptr);
  }
  if (g->instance != VK_NULL_HANDLE) {
    vkDestroyInstance(g->instance, nullptr);
  }
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
  g->context->asyncRescaleAndReadPixels(surface.get(), info, SkIRect::MakeWH(g->w, g->h),
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
  return "none";
}

OsGfx *osgfx_create(int w, int h) {
  OsGfxGraphite *gr;
  if (w <= 0 || h <= 0) {
    return nullptr;
  }
  gr = graphite_try_create(w, h);
  if (gr == nullptr) {
    return nullptr;
  }
  return wrap(OSGFX_KIND_GRAPHITE, gr);
}

void osgfx_destroy(OsGfx *g) {
  if (g == nullptr) {
    return;
  }
  if (g->kind == OSGFX_KIND_GRAPHITE) {
    graphite_destroy(static_cast<OsGfxGraphite *>(g->be));
  }
  std::free(g);
}

void osgfx_clear(OsGfx *g, uint32_t rgb) {
  OsGfxGraphite *gr;
  if (g == nullptr) {
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
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_SOLID, x, y, w, h, 0, 0, rgb, rgb);
}

void osgfx_fill_rrect(OsGfx *g, int x, int y, int w, int h, int radius, uint32_t rgb) {
  if (g == nullptr) {
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
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_GRAD, x, y, w, h, radius, 0, top,
           bot);
}

void osgfx_shadow(OsGfx *g, int x, int y, int w, int h, int radius, int blur,
                  uint32_t rgb) {
  if (g == nullptr) {
    return;
  }
  push_cmd(static_cast<OsGfxGraphite *>(g->be), KIND_SHADOW, x, y, w, h, radius, blur,
           rgb, rgb);
}

int osgfx_flush(OsGfx *g) {
  if (g == nullptr) {
    return OSGFX_ERR;
  }
  return graphite_flush(static_cast<OsGfxGraphite *>(g->be));
}

int osgfx_readback(OsGfx *g, uint32_t *out, int max_pixels) {
  if (g == nullptr) {
    return -1;
  }
  return graphite_readback(static_cast<OsGfxGraphite *>(g->be), out, max_pixels);
}

int osgfx_ppm_write(OsGfx *g, const char *path) {
  if (g == nullptr) {
    return OSGFX_ERR;
  }
  return graphite_ppm_write(static_cast<OsGfxGraphite *>(g->be), path);
}

int osgfx_present_layer(OsGfx *g, void *layer) {
  (void)g;
  (void)layer;
  return OSGFX_ERR;
}

} /* extern "C" */
