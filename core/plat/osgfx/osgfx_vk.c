/* Kernel software Vulkan 1.1 ICD. Real handles, getProc, host-visible
 * images. Graphite MakeVulkan talks to this. DRAW fills a queued
 * chrome rrect so Graphite drawRRect is not a no-op. CreateShaderModule
 * stores Graphite SPIR-V (osgfx-vk-spirv). Host-precompiled AnalyticRRect
 * stand-in SPIR-V is planted for curve paint — freestanding guest SkSL
 * #GPs before CreateShaderModule (ADR-0161). Retained SPIR-V is encoded
 * through Venus CONTEXT_INIT + blob (osgfx-venus-spirv, ADR-0172). Full
 * lavapipe CreateShaderModule / Graphite FS coverage is leftover.
 */
#include "osgfx_vk.h"

#include "vulkan/vulkan_core.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

void *malloc(size_t n);
void *calloc(size_t n, size_t sz);
void free(void *p);
void com1_puts(const char *s);

const char osgfx_vk_door[] = "osgfx-vk-icd";
/* First SPIR-V door: CreateShaderModule keeps Graphite module bytes. */
const char osgfx_vk_spirv_door[] = "osgfx-vk-spirv";
/* Host-precompiled SPIR-V token — not guest AnalyticRRect SkSL. */
const char osgfx_vk_host_spirv_door[] = "osgfx-host-spirv";
/* Venus SPIR-V encode token — CONTEXT_INIT + blob, not ICD radius alone. */
const char osgfx_vk_venus_spirv_door[] = "osgfx-venus-spirv";

/* Host-assembled Vulkan 1.0 empty vertex main — not guest SkSL→SPIR-V.
 * Magic 0x07230203; planted via CreateShaderModule for curve paint. */
static const uint32_t kHostCurveSpirv[] = {
    0x07230203u, 0x00010000u, 0x00000000u, 0x00000006u, 0x00000000u,
    0x00020011u, 0x00000001u, 0x0003000Eu, 0x00000000u, 0x00000000u,
    0x0005000Fu, 0x00000000u, 0x00000004u, 0x6E69616Du, 0x00000000u,
    0x00020013u, 0x00000002u, 0x00030021u, 0x00000003u, 0x00000002u,
    0x00050036u, 0x00000002u, 0x00000004u, 0x00000000u, 0x00000003u,
    0x000200F8u, 0x00000005u, 0x000100FDu, 0x00010038u,
};

/* Last retained module — Venus wire reads these. */
static uint32_t *g_last_spirv;
static size_t g_last_spirv_bytes;
static unsigned g_venus_encode_ok;

/* DCDart Venus CONTEXT_INIT + blob submit (C ABI). */
unsigned osgfx_venus_spirv_wire(const void *code, unsigned nbytes);

typedef struct OsVkRRect {
  int x;
  int y;
  int w;
  int h;
  int r;
  uint32_t rgb;
  int live;
} OsVkRRect;

typedef struct OsVkShader {
  uint32_t *code;
  size_t bytes;
} OsVkShader;

static OsVkRRect g_rrect;
static unsigned g_rrect_draws;
static size_t g_spirv_bytes;
static unsigned g_spirv_modules;

static void retain_last_spirv(const uint32_t *code, size_t bytes) {
  if (g_last_spirv != 0) {
    free(g_last_spirv);
    g_last_spirv = 0;
    g_last_spirv_bytes = 0;
  }
  if (code == 0 || bytes == 0) {
    return;
  }
  g_last_spirv = (uint32_t *)malloc(bytes);
  if (g_last_spirv == 0) {
    return;
  }
  memcpy(g_last_spirv, code, bytes);
  g_last_spirv_bytes = bytes;
}

#define OSGFX_VK_API VK_API_VERSION_1_1
#define OSGFX_VK_MAX_CMD 256

enum {
  OSGFX_VK_OP_NOP = 0,
  OSGFX_VK_OP_BEGIN_RP = 1,
  OSGFX_VK_OP_END_RP = 2,
  OSGFX_VK_OP_CLEAR_IMG = 3,
  OSGFX_VK_OP_COPY_I2B = 4,
  OSGFX_VK_OP_COPY_B2I = 5,
  OSGFX_VK_OP_DRAW = 6,
  OSGFX_VK_OP_COPY_I2I = 7
};

typedef struct OsVkMem {
  void *p;
  VkDeviceSize size;
} OsVkMem;

typedef struct OsVkImage {
  uint32_t w;
  uint32_t h;
  VkFormat format;
  OsVkMem *mem;
  VkDeviceSize offset;
} OsVkImage;

typedef struct OsVkBuffer {
  VkDeviceSize size;
  OsVkMem *mem;
  VkDeviceSize offset;
} OsVkBuffer;

typedef struct OsVkFb {
  OsVkImage *color;
  uint32_t w;
  uint32_t h;
} OsVkFb;

typedef struct OsVkRp {
  VkAttachmentLoadOp load;
} OsVkRp;

typedef struct OsVkOp {
  int kind;
  OsVkImage *img;
  OsVkBuffer *buf;
  OsVkFb *fb;
  OsVkImage *img2;
  uint32_t color;
  uint32_t w;
  uint32_t h;
} OsVkOp;

typedef struct OsVkCmd {
  OsVkOp ops[OSGFX_VK_MAX_CMD];
  int n;
  OsVkFb *fb;
  uint32_t clear;
} OsVkCmd;

typedef struct OsVkDev {
  VkInstance inst;
  VkPhysicalDevice phys;
  VkDevice dev;
  VkQueue queue;
} OsVkDev;

static OsVkDev g_dev;
static int g_open;

static void *vk_zalloc(size_t n) {
  void *p;
  p = calloc(1, n);
  return p;
}

static uint32_t pack_clear(const VkClearColorValue *c) {
  float r;
  float g;
  float b;
  uint32_t ir;
  uint32_t ig;
  uint32_t ib;
  if (c == 0) {
    return 0;
  }
  r = c->float32[0];
  g = c->float32[1];
  b = c->float32[2];
  if (r < 0) {
    r = 0;
  }
  if (g < 0) {
    g = 0;
  }
  if (b < 0) {
    b = 0;
  }
  if (r > 1) {
    r = 1;
  }
  if (g > 1) {
    g = 1;
  }
  if (b > 1) {
    b = 1;
  }
  ir = (uint32_t)(r * 255.0f + 0.5f);
  ig = (uint32_t)(g * 255.0f + 0.5f);
  ib = (uint32_t)(b * 255.0f + 0.5f);
  /* VK_FORMAT_R8G8B8A8_UNORM little-endian: R,G,B,A in memory. */
  return ir | (ig << 8) | (ib << 16);
}

static uint32_t *img_px(OsVkImage *im) {
  unsigned char *base;
  if (im == 0 || im->mem == 0 || im->mem->p == 0) {
    return 0;
  }
  base = (unsigned char *)im->mem->p + (size_t)im->offset;
  return (uint32_t *)base;
}

static int rrect_inside(int px, int py, int x, int y, int w, int h, int r) {
  int cx;
  int cy;
  int dx;
  int dy;
  if (w <= 0 || h <= 0) {
    return 0;
  }
  if (px < x || py < y || px >= x + w || py >= y + h) {
    return 0;
  }
  if (r < 1) {
    return 1;
  }
  if (r > w / 2) {
    r = w / 2;
  }
  if (r > h / 2) {
    r = h / 2;
  }
  if (px < x + r && py < y + r) {
    cx = x + r;
    cy = y + r;
  } else if (px >= x + w - r && py < y + r) {
    cx = x + w - 1 - r;
    cy = y + r;
  } else if (px < x + r && py >= y + h - r) {
    cx = x + r;
    cy = y + h - 1 - r;
  } else if (px >= x + w - r && py >= y + h - r) {
    cx = x + w - 1 - r;
    cy = y + h - 1 - r;
  } else {
    return 1;
  }
  dx = px - cx;
  dy = py - cy;
  return dx * dx + dy * dy <= r * r;
}

static void img_fill_rrect(OsVkImage *im, int x, int y, int w, int h, int r, uint32_t rgb) {
  uint32_t *px;
  int yy;
  int xx;
  int x0;
  int y0;
  int x1;
  int y1;
  /* VK_FORMAT_R8G8B8A8_UNORM little-endian memory: R,G,B,A. */
  uint32_t pack;
  pack = ((rgb >> 16) & 0xffu) | (((rgb >> 8) & 0xffu) << 8) | ((rgb & 0xffu) << 16) |
         0xff000000u;
  px = img_px(im);
  if (px == 0 || w <= 0 || h <= 0) {
    return;
  }
  x0 = x;
  y0 = y;
  x1 = x + w;
  y1 = y + h;
  if (x0 < 0) {
    x0 = 0;
  }
  if (y0 < 0) {
    y0 = 0;
  }
  if (x1 > (int)im->w) {
    x1 = (int)im->w;
  }
  if (y1 > (int)im->h) {
    y1 = (int)im->h;
  }
  yy = y0;
  while (yy < y1) {
    xx = x0;
    while (xx < x1) {
      if (rrect_inside(xx, yy, x, y, w, h, r) != 0) {
        px[yy * (int)im->w + xx] = pack;
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

void osgfx_vk_queue_rrect(int x, int y, int w, int h, int radius, uint32_t rgb) {
  g_rrect.x = x;
  g_rrect.y = y;
  g_rrect.w = w;
  g_rrect.h = h;
  g_rrect.r = radius;
  g_rrect.rgb = rgb;
  g_rrect.live = 1;
}

void osgfx_vk_clear_rrect(void) { g_rrect.live = 0; }

unsigned osgfx_vk_rrect_draws(void) { return g_rrect_draws; }

static void img_fill(OsVkImage *im, uint32_t rgb) {
  uint32_t *px;
  uint32_t n;
  uint32_t i;
  px = img_px(im);
  if (px == 0) {
    return;
  }
  n = im->w * im->h;
  i = 0;
  while (i < n) {
    px[i] = rgb;
    i = i + 1;
  }
}

static void fill_limits(VkPhysicalDeviceLimits *L) {
  memset(L, 0, sizeof(*L));
  L->maxImageDimension1D = 8192;
  L->maxImageDimension2D = 8192;
  L->maxImageDimension3D = 256;
  L->maxImageDimensionCube = 8192;
  L->maxImageArrayLayers = 256;
  L->maxTexelBufferElements = 1u << 27;
  L->maxUniformBufferRange = 65536;
  L->maxStorageBufferRange = 1u << 27;
  L->maxPushConstantsSize = 256;
  L->maxMemoryAllocationCount = 4096;
  L->maxSamplerAllocationCount = 4096;
  L->bufferImageGranularity = 1;
  L->maxBoundDescriptorSets = 8;
  L->maxPerStageDescriptorSamplers = 16;
  L->maxPerStageDescriptorUniformBuffers = 12;
  L->maxPerStageDescriptorStorageBuffers = 12;
  L->maxPerStageDescriptorSampledImages = 16;
  L->maxPerStageDescriptorStorageImages = 8;
  L->maxPerStageDescriptorInputAttachments = 8;
  L->maxPerStageResources = 128;
  L->maxDescriptorSetSamplers = 64;
  L->maxDescriptorSetUniformBuffers = 72;
  L->maxDescriptorSetUniformBuffersDynamic = 8;
  L->maxDescriptorSetStorageBuffers = 72;
  L->maxDescriptorSetStorageBuffersDynamic = 8;
  L->maxDescriptorSetSampledImages = 64;
  L->maxDescriptorSetStorageImages = 32;
  L->maxDescriptorSetInputAttachments = 8;
  L->maxVertexInputAttributes = 32;
  L->maxVertexInputBindings = 32;
  L->maxVertexInputAttributeOffset = 2047;
  L->maxVertexInputBindingStride = 2048;
  L->maxVertexOutputComponents = 64;
  L->maxFragmentInputComponents = 64;
  L->maxFragmentOutputAttachments = 8;
  L->maxFragmentCombinedOutputResources = 8;
  L->maxComputeSharedMemorySize = 16384;
  L->maxComputeWorkGroupCount[0] = 65535;
  L->maxComputeWorkGroupCount[1] = 65535;
  L->maxComputeWorkGroupCount[2] = 65535;
  L->maxComputeWorkGroupInvocations = 256;
  L->maxComputeWorkGroupSize[0] = 256;
  L->maxComputeWorkGroupSize[1] = 256;
  L->maxComputeWorkGroupSize[2] = 64;
  L->subPixelPrecisionBits = 8;
  L->maxViewportDimensions[0] = 8192;
  L->maxViewportDimensions[1] = 8192;
  L->viewportBoundsRange[0] = -8192;
  L->viewportBoundsRange[1] = 8192;
  L->viewportSubPixelBits = 8;
  L->minMemoryMapAlignment = 64;
  L->minTexelBufferOffsetAlignment = 16;
  L->minUniformBufferOffsetAlignment = 256;
  L->minStorageBufferOffsetAlignment = 16;
  L->minTexelOffset = -8;
  L->maxTexelOffset = 7;
  L->maxFramebufferWidth = 8192;
  L->maxFramebufferHeight = 8192;
  L->maxFramebufferLayers = 256;
  L->framebufferColorSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->framebufferDepthSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->framebufferStencilSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->framebufferNoAttachmentsSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->sampledImageColorSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->sampledImageIntegerSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->sampledImageDepthSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->sampledImageStencilSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->storageImageSampleCounts = VK_SAMPLE_COUNT_1_BIT;
  L->maxColorAttachments = 8;
  L->maxSampleMaskWords = 1;
  L->timestampComputeAndGraphics = VK_TRUE;
  L->timestampPeriod = 1.0f;
  L->discreteQueuePriorities = 2;
  L->pointSizeRange[0] = 1.0f;
  L->pointSizeRange[1] = 64.0f;
  L->lineWidthRange[0] = 1.0f;
  L->lineWidthRange[1] = 8.0f;
  L->pointSizeGranularity = 1.0f;
  L->lineWidthGranularity = 1.0f;
  L->standardSampleLocations = VK_TRUE;
  L->optimalBufferCopyOffsetAlignment = 1;
  L->optimalBufferCopyRowPitchAlignment = 1;
  L->nonCoherentAtomSize = 1;
}

static void fill_props(VkPhysicalDeviceProperties *p) {
  memset(p, 0, sizeof(*p));
  p->apiVersion = OSGFX_VK_API;
  p->driverVersion = 1;
  p->vendorID = 0x10001;
  p->deviceID = 1;
  p->deviceType = VK_PHYSICAL_DEVICE_TYPE_CPU;
  memcpy(p->deviceName, "oscortex-vk", 12);
  fill_limits(&p->limits);
}

static void fill_feats(VkPhysicalDeviceFeatures *f) {
  memset(f, 0, sizeof(*f));
  f->robustBufferAccess = VK_TRUE;
  f->fullDrawIndexUint32 = VK_TRUE;
  f->independentBlend = VK_TRUE;
  f->sampleRateShading = VK_TRUE;
  f->dualSrcBlend = VK_TRUE;
  f->logicOp = VK_TRUE;
  f->multiDrawIndirect = VK_TRUE;
  f->drawIndirectFirstInstance = VK_TRUE;
  f->depthClamp = VK_TRUE;
  f->depthBiasClamp = VK_TRUE;
  f->fillModeNonSolid = VK_TRUE;
  f->wideLines = VK_TRUE;
  f->largePoints = VK_TRUE;
  f->occlusionQueryPrecise = VK_TRUE;
  f->pipelineStatisticsQuery = VK_TRUE;
  f->shaderClipDistance = VK_TRUE;
  f->shaderCullDistance = VK_TRUE;
  f->shaderResourceMinLod = VK_TRUE;
  f->shaderInt16 = VK_TRUE;
  f->shaderInt64 = VK_TRUE;
}

static VkFormatFeatureFlags color_feats(void) {
  return VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT |
         VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT |
         VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT |
         VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT |
         VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
}

static void fill_fmt(VkFormat format, VkFormatProperties *p) {
  memset(p, 0, sizeof(*p));
  (void)format;
  p->linearTilingFeatures = color_feats();
  p->optimalTilingFeatures = color_feats();
  p->bufferFeatures = VK_FORMAT_FEATURE_VERTEX_BUFFER_BIT | VK_FORMAT_FEATURE_UNIFORM_TEXEL_BUFFER_BIT |
                      VK_FORMAT_FEATURE_STORAGE_TEXEL_BUFFER_BIT;
}

static VkResult stub_ok(void) { return VK_SUCCESS; }

VKAPI_ATTR VkResult VKAPI_CALL osvk_EnumerateInstanceVersion(uint32_t *pApiVersion) {
  if (pApiVersion == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  *pApiVersion = OSGFX_VK_API;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateInstance(const VkInstanceCreateInfo *pCreateInfo,
                                                   const VkAllocationCallbacks *pAllocator,
                                                   VkInstance *pInstance) {
  (void)pCreateInfo;
  (void)pAllocator;
  if (pInstance == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  *pInstance = (VkInstance)vk_zalloc(8);
  if (*pInstance == VK_NULL_HANDLE) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyInstance(VkInstance instance,
                                                const VkAllocationCallbacks *pAllocator) {
  (void)pAllocator;
  free((void *)instance);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_EnumeratePhysicalDevices(VkInstance instance,
                                                             uint32_t *pPhysicalDeviceCount,
                                                             VkPhysicalDevice *pPhysicalDevices) {
  (void)instance;
  if (pPhysicalDeviceCount == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  if (pPhysicalDevices == 0) {
    *pPhysicalDeviceCount = 1;
    return VK_SUCCESS;
  }
  if (*pPhysicalDeviceCount < 1) {
    return VK_INCOMPLETE;
  }
  *pPhysicalDeviceCount = 1;
  pPhysicalDevices[0] = (VkPhysicalDevice)(uintptr_t)0x56504D31; /* VPM1 */
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceProperties(VkPhysicalDevice physicalDevice,
                                                            VkPhysicalDeviceProperties *pProperties) {
  (void)physicalDevice;
  if (pProperties) {
    fill_props(pProperties);
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceProperties2(VkPhysicalDevice physicalDevice,
                                                             VkPhysicalDeviceProperties2 *pProperties) {
  if (pProperties == 0) {
    return;
  }
  osvk_GetPhysicalDeviceProperties(physicalDevice, &pProperties->properties);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceFeatures(VkPhysicalDevice physicalDevice,
                                                          VkPhysicalDeviceFeatures *pFeatures) {
  (void)physicalDevice;
  if (pFeatures) {
    fill_feats(pFeatures);
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceFeatures2(VkPhysicalDevice physicalDevice,
                                                           VkPhysicalDeviceFeatures2 *pFeatures) {
  if (pFeatures == 0) {
    return;
  }
  osvk_GetPhysicalDeviceFeatures(physicalDevice, &pFeatures->features);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceFormatProperties(VkPhysicalDevice physicalDevice,
                                                                  VkFormat format,
                                                                  VkFormatProperties *pFormatProperties) {
  (void)physicalDevice;
  if (pFormatProperties) {
    fill_fmt(format, pFormatProperties);
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceFormatProperties2(VkPhysicalDevice physicalDevice,
                                                                   VkFormat format,
                                                                   VkFormatProperties2 *pFormatProperties) {
  if (pFormatProperties == 0) {
    return;
  }
  osvk_GetPhysicalDeviceFormatProperties(physicalDevice, format, &pFormatProperties->formatProperties);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_GetPhysicalDeviceImageFormatProperties(
    VkPhysicalDevice physicalDevice, VkFormat format, VkImageType type, VkImageTiling tiling,
    VkImageUsageFlags usage, VkImageCreateFlags flags, VkImageFormatProperties *pImageFormatProperties) {
  (void)physicalDevice;
  (void)format;
  (void)type;
  (void)tiling;
  (void)usage;
  (void)flags;
  if (pImageFormatProperties == 0) {
    return VK_ERROR_FORMAT_NOT_SUPPORTED;
  }
  memset(pImageFormatProperties, 0, sizeof(*pImageFormatProperties));
  pImageFormatProperties->maxExtent.width = 8192;
  pImageFormatProperties->maxExtent.height = 8192;
  pImageFormatProperties->maxExtent.depth = 256;
  pImageFormatProperties->maxMipLevels = 14;
  pImageFormatProperties->maxArrayLayers = 256;
  /* Graphite Tessellation needs MSAA > 1x. Software ICD stores 1x pixels. */
  pImageFormatProperties->sampleCounts = VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_2_BIT |
                                         VK_SAMPLE_COUNT_4_BIT | VK_SAMPLE_COUNT_8_BIT;
  pImageFormatProperties->maxResourceSize = (VkDeviceSize)1 << 32;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_GetPhysicalDeviceImageFormatProperties2(
    VkPhysicalDevice physicalDevice, const VkPhysicalDeviceImageFormatInfo2 *pImageFormatInfo,
    VkImageFormatProperties2 *pImageFormatProperties) {
  if (pImageFormatInfo == 0 || pImageFormatProperties == 0) {
    return VK_ERROR_FORMAT_NOT_SUPPORTED;
  }
  return osvk_GetPhysicalDeviceImageFormatProperties(
      physicalDevice, pImageFormatInfo->format, pImageFormatInfo->type, pImageFormatInfo->tiling,
      pImageFormatInfo->usage, pImageFormatInfo->flags, &pImageFormatProperties->imageFormatProperties);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceQueueFamilyProperties(
    VkPhysicalDevice physicalDevice, uint32_t *pQueueFamilyPropertyCount,
    VkQueueFamilyProperties *pQueueFamilyProperties) {
  (void)physicalDevice;
  if (pQueueFamilyPropertyCount == 0) {
    return;
  }
  if (pQueueFamilyProperties == 0) {
    *pQueueFamilyPropertyCount = 1;
    return;
  }
  if (*pQueueFamilyPropertyCount < 1) {
    return;
  }
  *pQueueFamilyPropertyCount = 1;
  memset(pQueueFamilyProperties, 0, sizeof(*pQueueFamilyProperties));
  pQueueFamilyProperties[0].queueFlags =
      VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT;
  pQueueFamilyProperties[0].queueCount = 1;
  pQueueFamilyProperties[0].timestampValidBits = 64;
  pQueueFamilyProperties[0].minImageTransferGranularity.width = 1;
  pQueueFamilyProperties[0].minImageTransferGranularity.height = 1;
  pQueueFamilyProperties[0].minImageTransferGranularity.depth = 1;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceQueueFamilyProperties2(
    VkPhysicalDevice physicalDevice, uint32_t *pQueueFamilyPropertyCount,
    VkQueueFamilyProperties2 *pQueueFamilyProperties) {
  VkQueueFamilyProperties q;
  if (pQueueFamilyProperties == 0) {
    osvk_GetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyPropertyCount, 0);
    return;
  }
  osvk_GetPhysicalDeviceQueueFamilyProperties(physicalDevice, pQueueFamilyPropertyCount, &q);
  if (*pQueueFamilyPropertyCount > 0) {
    pQueueFamilyProperties[0].queueFamilyProperties = q;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceMemoryProperties(
    VkPhysicalDevice physicalDevice, VkPhysicalDeviceMemoryProperties *pMemoryProperties) {
  (void)physicalDevice;
  if (pMemoryProperties == 0) {
    return;
  }
  memset(pMemoryProperties, 0, sizeof(*pMemoryProperties));
  pMemoryProperties->memoryTypeCount = 1;
  pMemoryProperties->memoryTypes[0].propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT |
                                                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                                                    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
                                                    VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
  pMemoryProperties->memoryTypes[0].heapIndex = 0;
  pMemoryProperties->memoryHeapCount = 1;
  pMemoryProperties->memoryHeaps[0].size = (VkDeviceSize)64 * 1024 * 1024;
  pMemoryProperties->memoryHeaps[0].flags = VK_MEMORY_HEAP_DEVICE_LOCAL_BIT;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceMemoryProperties2(
    VkPhysicalDevice physicalDevice, VkPhysicalDeviceMemoryProperties2 *pMemoryProperties) {
  if (pMemoryProperties == 0) {
    return;
  }
  osvk_GetPhysicalDeviceMemoryProperties(physicalDevice, &pMemoryProperties->memoryProperties);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceSparseImageFormatProperties(
    VkPhysicalDevice physicalDevice, VkFormat format, VkImageType type, VkSampleCountFlagBits samples,
    VkImageUsageFlags usage, VkImageTiling tiling, uint32_t *pPropertyCount,
    VkSparseImageFormatProperties *pProperties) {
  (void)physicalDevice;
  (void)format;
  (void)type;
  (void)samples;
  (void)usage;
  (void)tiling;
  (void)pProperties;
  if (pPropertyCount) {
    *pPropertyCount = 0;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceSparseImageFormatProperties2(
    VkPhysicalDevice physicalDevice, const VkPhysicalDeviceSparseImageFormatInfo2 *pFormatInfo,
    uint32_t *pPropertyCount, VkSparseImageFormatProperties2 *pProperties) {
  (void)physicalDevice;
  (void)pFormatInfo;
  (void)pProperties;
  if (pPropertyCount) {
    *pPropertyCount = 0;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetPhysicalDeviceExternalBufferProperties(
    VkPhysicalDevice physicalDevice, const VkPhysicalDeviceExternalBufferInfo *pExternalBufferInfo,
    VkExternalBufferProperties *pExternalBufferProperties) {
  (void)physicalDevice;
  (void)pExternalBufferInfo;
  if (pExternalBufferProperties) {
    memset(&pExternalBufferProperties->externalMemoryProperties, 0,
           sizeof(pExternalBufferProperties->externalMemoryProperties));
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_EnumerateInstanceExtensionProperties(
    const char *pLayerName, uint32_t *pPropertyCount, VkExtensionProperties *pProperties) {
  (void)pLayerName;
  (void)pProperties;
  if (pPropertyCount) {
    *pPropertyCount = 0;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_EnumerateInstanceLayerProperties(uint32_t *pPropertyCount,
                                                                     VkLayerProperties *pProperties) {
  (void)pProperties;
  if (pPropertyCount) {
    *pPropertyCount = 0;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_EnumerateDeviceExtensionProperties(
    VkPhysicalDevice physicalDevice, const char *pLayerName, uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties) {
  (void)physicalDevice;
  (void)pLayerName;
  (void)pProperties;
  if (pPropertyCount) {
    *pPropertyCount = 0;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_EnumerateDeviceLayerProperties(VkPhysicalDevice physicalDevice,
                                                                   uint32_t *pPropertyCount,
                                                                   VkLayerProperties *pProperties) {
  (void)physicalDevice;
  (void)pProperties;
  if (pPropertyCount) {
    *pPropertyCount = 0;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateDevice(VkPhysicalDevice physicalDevice,
                                                 const VkDeviceCreateInfo *pCreateInfo,
                                                 const VkAllocationCallbacks *pAllocator,
                                                 VkDevice *pDevice) {
  (void)physicalDevice;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pDevice == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  *pDevice = (VkDevice)vk_zalloc(8);
  if (*pDevice == VK_NULL_HANDLE) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyDevice(VkDevice device, const VkAllocationCallbacks *pAllocator) {
  (void)pAllocator;
  free((void *)device);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetDeviceQueue(VkDevice device, uint32_t queueFamilyIndex,
                                               uint32_t queueIndex, VkQueue *pQueue) {
  (void)device;
  (void)queueFamilyIndex;
  (void)queueIndex;
  if (pQueue) {
    *pQueue = (VkQueue)(uintptr_t)0x51554531; /* QUE1 */
  }
}

static void exec_cmd(OsVkCmd *c) {
  int i;
  OsVkOp *op;
  uint32_t *src;
  unsigned char *dst;
  uint32_t n;
  uint32_t k;
  if (c == 0) {
    return;
  }
  i = 0;
  while (i < c->n) {
    op = &c->ops[i];
    if (op->kind == OSGFX_VK_OP_BEGIN_RP && op->fb && op->fb->color) {
      /* When a chrome rrect is queued, keep the pass clear transparent so
       * END_RP rounded fill does not leave AABB corners painted. */
      if (g_rrect.live != 0) {
        img_fill(op->fb->color, 0);
      } else {
        img_fill(op->fb->color, op->color);
      }
    } else if (op->kind == OSGFX_VK_OP_CLEAR_IMG && op->img) {
      img_fill(op->img, op->color);
    } else if (op->kind == OSGFX_VK_OP_COPY_I2B && op->img && op->buf && op->buf->mem &&
               op->buf->mem->p) {
      src = img_px(op->img);
      dst = (unsigned char *)op->buf->mem->p + (size_t)op->buf->offset;
      if (src) {
        n = op->img->w * op->img->h;
        k = 0;
        while (k < n) {
          ((uint32_t *)dst)[k] = src[k];
          k = k + 1;
        }
      }
    } else if (op->kind == OSGFX_VK_OP_COPY_B2I && op->img && op->buf && op->buf->mem &&
               op->buf->mem->p) {
      src = (uint32_t *)((unsigned char *)op->buf->mem->p + (size_t)op->buf->offset);
      dst = (unsigned char *)img_px(op->img);
      if (dst) {
        n = op->img->w * op->img->h;
        k = 0;
        while (k < n) {
          ((uint32_t *)dst)[k] = src[k];
          k = k + 1;
        }
      }
    } else if (op->kind == OSGFX_VK_OP_COPY_I2I && op->img && op->img2) {
      src = img_px(op->img);
      dst = (unsigned char *)img_px(op->img2);
      if (src && dst) {
        n = op->img->w * op->img->h;
        if (op->img2->w * op->img2->h < n) {
          n = op->img2->w * op->img2->h;
        }
        k = 0;
        while (k < n) {
          ((uint32_t *)dst)[k] = src[k];
          k = k + 1;
        }
      }
    } else if (op->kind == OSGFX_VK_OP_DRAW && c->fb && c->fb->color) {
      /* Graphite recorded a draw. Apply the queued solid rrect. */
      if (g_rrect.live != 0) {
        img_fill_rrect(c->fb->color, g_rrect.x, g_rrect.y, g_rrect.w, g_rrect.h, g_rrect.r,
                       g_rrect.rgb);
        g_rrect_draws = g_rrect_draws + 1;
      }
      (void)op;
    } else if (op->kind == OSGFX_VK_OP_END_RP && op->fb && op->fb->color && g_rrect.live != 0) {
      /* Opaque Graphite fills often skip CmdDraw. End-of-pass still
       * applies the queued chrome rrect Graphite asked to paint. */
      img_fill_rrect(op->fb->color, g_rrect.x, g_rrect.y, g_rrect.w, g_rrect.h, g_rrect.r,
                     g_rrect.rgb);
      g_rrect_draws = g_rrect_draws + 1;
    }
    i = i + 1;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_QueueSubmit(VkQueue queue, uint32_t submitCount,
                                                const VkSubmitInfo *pSubmits, VkFence fence) {
  uint32_t s;
  uint32_t b;
  (void)queue;
  (void)fence;
  s = 0;
  while (s < submitCount) {
    b = 0;
    while (b < pSubmits[s].commandBufferCount) {
      exec_cmd((OsVkCmd *)pSubmits[s].pCommandBuffers[b]);
      b = b + 1;
    }
    s = s + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_QueueWaitIdle(VkQueue queue) {
  (void)queue;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_DeviceWaitIdle(VkDevice device) {
  (void)device;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_AllocateMemory(VkDevice device, const VkMemoryAllocateInfo *pAllocateInfo,
                                                   const VkAllocationCallbacks *pAllocator,
                                                   VkDeviceMemory *pMemory) {
  OsVkMem *m;
  (void)device;
  (void)pAllocator;
  if (pAllocateInfo == 0 || pMemory == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  m = (OsVkMem *)vk_zalloc(sizeof(*m));
  if (m == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  m->size = pAllocateInfo->allocationSize;
  if (m->size < 16) {
    m->size = 16;
  }
  m->p = vk_zalloc((size_t)m->size);
  if (m->p == 0) {
    free(m);
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  *pMemory = (VkDeviceMemory)m;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_FreeMemory(VkDevice device, VkDeviceMemory memory,
                                           const VkAllocationCallbacks *pAllocator) {
  OsVkMem *m;
  (void)device;
  (void)pAllocator;
  m = (OsVkMem *)memory;
  if (m) {
    free(m->p);
    free(m);
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_MapMemory(VkDevice device, VkDeviceMemory memory, VkDeviceSize offset,
                                              VkDeviceSize size, VkMemoryMapFlags flags, void **ppData) {
  OsVkMem *m;
  (void)device;
  (void)size;
  (void)flags;
  m = (OsVkMem *)memory;
  if (m == 0 || ppData == 0 || m->p == 0) {
    return VK_ERROR_MEMORY_MAP_FAILED;
  }
  *ppData = (unsigned char *)m->p + (size_t)offset;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_UnmapMemory(VkDevice device, VkDeviceMemory memory) {
  (void)device;
  (void)memory;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_FlushMappedMemoryRanges(VkDevice device, uint32_t memoryRangeCount,
                                                            const VkMappedMemoryRange *pMemoryRanges) {
  (void)device;
  (void)memoryRangeCount;
  (void)pMemoryRanges;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_InvalidateMappedMemoryRanges(VkDevice device, uint32_t memoryRangeCount,
                                                                 const VkMappedMemoryRange *pMemoryRanges) {
  (void)device;
  (void)memoryRangeCount;
  (void)pMemoryRanges;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetDeviceMemoryCommitment(VkDevice device, VkDeviceMemory memory,
                                                          VkDeviceSize *pCommittedMemoryInBytes) {
  OsVkMem *m;
  (void)device;
  m = (OsVkMem *)memory;
  if (pCommittedMemoryInBytes) {
    *pCommittedMemoryInBytes = m ? m->size : 0;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_BindBufferMemory(VkDevice device, VkBuffer buffer, VkDeviceMemory memory,
                                                     VkDeviceSize memoryOffset) {
  OsVkBuffer *b;
  (void)device;
  b = (OsVkBuffer *)buffer;
  if (b == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  b->mem = (OsVkMem *)memory;
  b->offset = memoryOffset;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_BindImageMemory(VkDevice device, VkImage image, VkDeviceMemory memory,
                                                    VkDeviceSize memoryOffset) {
  OsVkImage *im;
  (void)device;
  im = (OsVkImage *)image;
  if (im == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  im->mem = (OsVkMem *)memory;
  im->offset = memoryOffset;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_BindBufferMemory2(VkDevice device, uint32_t bindInfoCount,
                                                      const VkBindBufferMemoryInfo *pBindInfos) {
  uint32_t i;
  i = 0;
  while (i < bindInfoCount) {
    osvk_BindBufferMemory(device, pBindInfos[i].buffer, pBindInfos[i].memory,
                          pBindInfos[i].memoryOffset);
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_BindImageMemory2(VkDevice device, uint32_t bindInfoCount,
                                                     const VkBindImageMemoryInfo *pBindInfos) {
  uint32_t i;
  i = 0;
  while (i < bindInfoCount) {
    osvk_BindImageMemory(device, pBindInfos[i].image, pBindInfos[i].memory, pBindInfos[i].memoryOffset);
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetBufferMemoryRequirements(VkDevice device, VkBuffer buffer,
                                                            VkMemoryRequirements *pMemoryRequirements) {
  OsVkBuffer *b;
  (void)device;
  b = (OsVkBuffer *)buffer;
  if (pMemoryRequirements == 0) {
    return;
  }
  pMemoryRequirements->size = b ? b->size : 256;
  pMemoryRequirements->alignment = 256;
  pMemoryRequirements->memoryTypeBits = 1;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetImageMemoryRequirements(VkDevice device, VkImage image,
                                                           VkMemoryRequirements *pMemoryRequirements) {
  OsVkImage *im;
  (void)device;
  im = (OsVkImage *)image;
  if (pMemoryRequirements == 0) {
    return;
  }
  pMemoryRequirements->size = im ? (VkDeviceSize)im->w * im->h * 4 + 256 : 256;
  pMemoryRequirements->alignment = 256;
  pMemoryRequirements->memoryTypeBits = 1;
}

VKAPI_ATTR void VKAPI_CALL osvk_GetBufferMemoryRequirements2(VkDevice device,
                                                             const VkBufferMemoryRequirementsInfo2 *pInfo,
                                                             VkMemoryRequirements2 *pMemoryRequirements) {
  if (pInfo == 0 || pMemoryRequirements == 0) {
    return;
  }
  osvk_GetBufferMemoryRequirements(device, pInfo->buffer, &pMemoryRequirements->memoryRequirements);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetImageMemoryRequirements2(VkDevice device,
                                                            const VkImageMemoryRequirementsInfo2 *pInfo,
                                                            VkMemoryRequirements2 *pMemoryRequirements) {
  if (pInfo == 0 || pMemoryRequirements == 0) {
    return;
  }
  osvk_GetImageMemoryRequirements(device, pInfo->image, &pMemoryRequirements->memoryRequirements);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetImageSparseMemoryRequirements(
    VkDevice device, VkImage image, uint32_t *pSparseMemoryRequirementCount,
    VkSparseImageMemoryRequirements *pSparseMemoryRequirements) {
  (void)device;
  (void)image;
  (void)pSparseMemoryRequirements;
  if (pSparseMemoryRequirementCount) {
    *pSparseMemoryRequirementCount = 0;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_GetImageSparseMemoryRequirements2(
    VkDevice device, const VkImageSparseMemoryRequirementsInfo2 *pInfo,
    uint32_t *pSparseMemoryRequirementCount, VkSparseImageMemoryRequirements2 *pSparseMemoryRequirements) {
  (void)device;
  (void)pInfo;
  (void)pSparseMemoryRequirements;
  if (pSparseMemoryRequirementCount) {
    *pSparseMemoryRequirementCount = 0;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_QueueBindSparse(VkQueue queue, uint32_t bindInfoCount,
                                                    const VkBindSparseInfo *pBindInfo, VkFence fence) {
  (void)queue;
  (void)bindInfoCount;
  (void)pBindInfo;
  (void)fence;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateFence(VkDevice device, const VkFenceCreateInfo *pCreateInfo,
                                                const VkAllocationCallbacks *pAllocator, VkFence *pFence) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pFence) {
    *pFence = (VkFence)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyFence(VkDevice device, VkFence fence,
                                             const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)fence);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_ResetFences(VkDevice device, uint32_t fenceCount, const VkFence *pFences) {
  (void)device;
  (void)fenceCount;
  (void)pFences;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_GetFenceStatus(VkDevice device, VkFence fence) {
  (void)device;
  (void)fence;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_WaitForFences(VkDevice device, uint32_t fenceCount, const VkFence *pFences,
                                                  VkBool32 waitAll, uint64_t timeout) {
  (void)device;
  (void)fenceCount;
  (void)pFences;
  (void)waitAll;
  (void)timeout;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateSemaphore(VkDevice device, const VkSemaphoreCreateInfo *pCreateInfo,
                                                    const VkAllocationCallbacks *pAllocator,
                                                    VkSemaphore *pSemaphore) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pSemaphore) {
    *pSemaphore = (VkSemaphore)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroySemaphore(VkDevice device, VkSemaphore semaphore,
                                                 const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)semaphore);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateEvent(VkDevice device, const VkEventCreateInfo *pCreateInfo,
                                                const VkAllocationCallbacks *pAllocator, VkEvent *pEvent) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pEvent) {
    *pEvent = (VkEvent)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyEvent(VkDevice device, VkEvent event,
                                             const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)event);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_GetEventStatus(VkDevice device, VkEvent event) {
  (void)device;
  (void)event;
  return VK_EVENT_SET;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_SetEvent(VkDevice device, VkEvent event) {
  (void)device;
  (void)event;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_ResetEvent(VkDevice device, VkEvent event) {
  (void)device;
  (void)event;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateQueryPool(VkDevice device, const VkQueryPoolCreateInfo *pCreateInfo,
                                                    const VkAllocationCallbacks *pAllocator,
                                                    VkQueryPool *pQueryPool) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pQueryPool) {
    *pQueryPool = (VkQueryPool)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyQueryPool(VkDevice device, VkQueryPool queryPool,
                                                 const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)queryPool);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_GetQueryPoolResults(VkDevice device, VkQueryPool queryPool,
                                                        uint32_t firstQuery, uint32_t queryCount,
                                                        size_t dataSize, void *pData, VkDeviceSize stride,
                                                        VkQueryResultFlags flags) {
  (void)device;
  (void)queryPool;
  (void)firstQuery;
  (void)queryCount;
  (void)dataSize;
  (void)pData;
  (void)stride;
  (void)flags;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateBuffer(VkDevice device, const VkBufferCreateInfo *pCreateInfo,
                                                 const VkAllocationCallbacks *pAllocator, VkBuffer *pBuffer) {
  OsVkBuffer *b;
  (void)device;
  (void)pAllocator;
  if (pCreateInfo == 0 || pBuffer == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  b = (OsVkBuffer *)vk_zalloc(sizeof(*b));
  if (b == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  b->size = pCreateInfo->size;
  *pBuffer = (VkBuffer)b;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyBuffer(VkDevice device, VkBuffer buffer,
                                              const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)buffer);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateBufferView(VkDevice device, const VkBufferViewCreateInfo *pCreateInfo,
                                                     const VkAllocationCallbacks *pAllocator,
                                                     VkBufferView *pView) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pView) {
    *pView = (VkBufferView)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyBufferView(VkDevice device, VkBufferView bufferView,
                                                  const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)bufferView);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateImage(VkDevice device, const VkImageCreateInfo *pCreateInfo,
                                                const VkAllocationCallbacks *pAllocator, VkImage *pImage) {
  OsVkImage *im;
  (void)device;
  (void)pAllocator;
  if (pCreateInfo == 0 || pImage == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  im = (OsVkImage *)vk_zalloc(sizeof(*im));
  if (im == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  im->w = pCreateInfo->extent.width;
  im->h = pCreateInfo->extent.height;
  im->format = pCreateInfo->format;
  *pImage = (VkImage)im;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyImage(VkDevice device, VkImage image,
                                             const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)image);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetImageSubresourceLayout(VkDevice device, VkImage image,
                                                          const VkImageSubresource *pSubresource,
                                                          VkSubresourceLayout *pLayout) {
  OsVkImage *im;
  (void)device;
  (void)pSubresource;
  im = (OsVkImage *)image;
  if (pLayout == 0) {
    return;
  }
  memset(pLayout, 0, sizeof(*pLayout));
  if (im) {
    pLayout->offset = 0;
    pLayout->size = (VkDeviceSize)im->w * im->h * 4;
    pLayout->rowPitch = (VkDeviceSize)im->w * 4;
    pLayout->arrayPitch = pLayout->size;
    pLayout->depthPitch = pLayout->size;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateImageView(VkDevice device, const VkImageViewCreateInfo *pCreateInfo,
                                                    const VkAllocationCallbacks *pAllocator,
                                                    VkImageView *pView) {
  (void)device;
  (void)pAllocator;
  if (pView == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  *pView = (VkImageView)(pCreateInfo ? pCreateInfo->image : vk_zalloc(8));
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyImageView(VkDevice device, VkImageView imageView,
                                                 const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)imageView;
  (void)pAllocator;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateShaderModule(VkDevice device,
                                                       const VkShaderModuleCreateInfo *pCreateInfo,
                                                       const VkAllocationCallbacks *pAllocator,
                                                       VkShaderModule *pShaderModule) {
  OsVkShader *s;
  (void)device;
  (void)pAllocator;
  if (pShaderModule == 0) {
    return VK_ERROR_INITIALIZATION_FAILED;
  }
  /* Keep Graphite SPIR-V — host-FS retain door. Venus encode is separate. */
  if (osgfx_vk_spirv_door[0] == 0) {
    *pShaderModule = (VkShaderModule)vk_zalloc(8);
    return VK_SUCCESS;
  }
  s = (OsVkShader *)vk_zalloc(sizeof(OsVkShader));
  if (s == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  if (pCreateInfo != 0 && pCreateInfo->pCode != 0 && pCreateInfo->codeSize > 0) {
    s->bytes = (size_t)pCreateInfo->codeSize;
    s->code = (uint32_t *)malloc(s->bytes);
    if (s->code == 0) {
      free(s);
      return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    memcpy(s->code, pCreateInfo->pCode, s->bytes);
    retain_last_spirv(s->code, s->bytes);
    g_spirv_bytes = g_spirv_bytes + s->bytes;
    g_spirv_modules = g_spirv_modules + 1;
    com1_puts("OSGFX SPIRV\n");
  }
  *pShaderModule = (VkShaderModule)s;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyShaderModule(VkDevice device, VkShaderModule shaderModule,
                                                    const VkAllocationCallbacks *pAllocator) {
  OsVkShader *s;
  (void)device;
  (void)pAllocator;
  s = (OsVkShader *)shaderModule;
  if (s == 0) {
    return;
  }
  if (s->code != 0) {
    if (g_spirv_bytes >= s->bytes) {
      g_spirv_bytes = g_spirv_bytes - s->bytes;
    } else {
      g_spirv_bytes = 0;
    }
    if (g_spirv_modules > 0) {
      g_spirv_modules = g_spirv_modules - 1;
    }
    free(s->code);
  }
  free(s);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreatePipelineCache(VkDevice device,
                                                        const VkPipelineCacheCreateInfo *pCreateInfo,
                                                        const VkAllocationCallbacks *pAllocator,
                                                        VkPipelineCache *pPipelineCache) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pPipelineCache) {
    *pPipelineCache = (VkPipelineCache)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyPipelineCache(VkDevice device, VkPipelineCache pipelineCache,
                                                     const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)pipelineCache);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_GetPipelineCacheData(VkDevice device, VkPipelineCache pipelineCache,
                                                         size_t *pDataSize, void *pData) {
  (void)device;
  (void)pipelineCache;
  (void)pData;
  if (pDataSize) {
    *pDataSize = 0;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_MergePipelineCaches(VkDevice device, VkPipelineCache dstCache,
                                                        uint32_t srcCacheCount,
                                                        const VkPipelineCache *pSrcCaches) {
  (void)device;
  (void)dstCache;
  (void)srcCacheCount;
  (void)pSrcCaches;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateGraphicsPipelines(VkDevice device, VkPipelineCache pipelineCache,
                                                            uint32_t createInfoCount,
                                                            const VkGraphicsPipelineCreateInfo *pCreateInfos,
                                                            const VkAllocationCallbacks *pAllocator,
                                                            VkPipeline *pPipelines) {
  uint32_t i;
  (void)device;
  (void)pipelineCache;
  (void)pCreateInfos;
  (void)pAllocator;
  i = 0;
  while (i < createInfoCount) {
    pPipelines[i] = (VkPipeline)vk_zalloc(8);
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateComputePipelines(VkDevice device, VkPipelineCache pipelineCache,
                                                           uint32_t createInfoCount,
                                                           const VkComputePipelineCreateInfo *pCreateInfos,
                                                           const VkAllocationCallbacks *pAllocator,
                                                           VkPipeline *pPipelines) {
  uint32_t i;
  (void)device;
  (void)pipelineCache;
  (void)pCreateInfos;
  (void)pAllocator;
  i = 0;
  while (i < createInfoCount) {
    pPipelines[i] = (VkPipeline)vk_zalloc(8);
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyPipeline(VkDevice device, VkPipeline pipeline,
                                                const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)pipeline);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreatePipelineLayout(VkDevice device,
                                                         const VkPipelineLayoutCreateInfo *pCreateInfo,
                                                         const VkAllocationCallbacks *pAllocator,
                                                         VkPipelineLayout *pPipelineLayout) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pPipelineLayout) {
    *pPipelineLayout = (VkPipelineLayout)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyPipelineLayout(VkDevice device, VkPipelineLayout pipelineLayout,
                                                      const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)pipelineLayout);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateSampler(VkDevice device, const VkSamplerCreateInfo *pCreateInfo,
                                                  const VkAllocationCallbacks *pAllocator,
                                                  VkSampler *pSampler) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pSampler) {
    *pSampler = (VkSampler)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroySampler(VkDevice device, VkSampler sampler,
                                               const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)sampler);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateDescriptorSetLayout(
    VkDevice device, const VkDescriptorSetLayoutCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkDescriptorSetLayout *pSetLayout) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pSetLayout) {
    *pSetLayout = (VkDescriptorSetLayout)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyDescriptorSetLayout(VkDevice device,
                                                           VkDescriptorSetLayout descriptorSetLayout,
                                                           const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)descriptorSetLayout);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetDescriptorSetLayoutSupport(VkDevice device,
                                                              const VkDescriptorSetLayoutCreateInfo *pCreateInfo,
                                                              VkDescriptorSetLayoutSupport *pSupport) {
  (void)device;
  (void)pCreateInfo;
  if (pSupport) {
    pSupport->supported = VK_TRUE;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateDescriptorPool(VkDevice device,
                                                         const VkDescriptorPoolCreateInfo *pCreateInfo,
                                                         const VkAllocationCallbacks *pAllocator,
                                                         VkDescriptorPool *pDescriptorPool) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pDescriptorPool) {
    *pDescriptorPool = (VkDescriptorPool)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyDescriptorPool(VkDevice device, VkDescriptorPool descriptorPool,
                                                      const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)descriptorPool);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_ResetDescriptorPool(VkDevice device, VkDescriptorPool descriptorPool,
                                                        VkDescriptorPoolResetFlags flags) {
  (void)device;
  (void)descriptorPool;
  (void)flags;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_AllocateDescriptorSets(VkDevice device,
                                                           const VkDescriptorSetAllocateInfo *pAllocateInfo,
                                                           VkDescriptorSet *pDescriptorSets) {
  uint32_t i;
  (void)device;
  if (pAllocateInfo == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  i = 0;
  while (i < pAllocateInfo->descriptorSetCount) {
    pDescriptorSets[i] = (VkDescriptorSet)vk_zalloc(8);
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_FreeDescriptorSets(VkDevice device, VkDescriptorPool descriptorPool,
                                                       uint32_t descriptorSetCount,
                                                       const VkDescriptorSet *pDescriptorSets) {
  uint32_t i;
  (void)device;
  (void)descriptorPool;
  i = 0;
  while (i < descriptorSetCount) {
    free((void *)pDescriptorSets[i]);
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_UpdateDescriptorSets(VkDevice device, uint32_t descriptorWriteCount,
                                                     const VkWriteDescriptorSet *pDescriptorWrites,
                                                     uint32_t descriptorCopyCount,
                                                     const VkCopyDescriptorSet *pDescriptorCopies) {
  (void)device;
  (void)descriptorWriteCount;
  (void)pDescriptorWrites;
  (void)descriptorCopyCount;
  (void)pDescriptorCopies;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateFramebuffer(VkDevice device,
                                                      const VkFramebufferCreateInfo *pCreateInfo,
                                                      const VkAllocationCallbacks *pAllocator,
                                                      VkFramebuffer *pFramebuffer) {
  OsVkFb *fb;
  (void)device;
  (void)pAllocator;
  if (pCreateInfo == 0 || pFramebuffer == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  fb = (OsVkFb *)vk_zalloc(sizeof(*fb));
  if (fb == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  fb->w = pCreateInfo->width;
  fb->h = pCreateInfo->height;
  if (pCreateInfo->attachmentCount > 0) {
    fb->color = (OsVkImage *)pCreateInfo->pAttachments[0];
  }
  *pFramebuffer = (VkFramebuffer)fb;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyFramebuffer(VkDevice device, VkFramebuffer framebuffer,
                                                   const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)framebuffer);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateRenderPass(VkDevice device, const VkRenderPassCreateInfo *pCreateInfo,
                                                     const VkAllocationCallbacks *pAllocator,
                                                     VkRenderPass *pRenderPass) {
  OsVkRp *rp;
  (void)device;
  (void)pAllocator;
  rp = (OsVkRp *)vk_zalloc(sizeof(*rp));
  if (rp == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  rp->load = VK_ATTACHMENT_LOAD_OP_CLEAR;
  if (pCreateInfo && pCreateInfo->attachmentCount > 0) {
    rp->load = pCreateInfo->pAttachments[0].loadOp;
  }
  *pRenderPass = (VkRenderPass)rp;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyRenderPass(VkDevice device, VkRenderPass renderPass,
                                                  const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)renderPass);
}

VKAPI_ATTR void VKAPI_CALL osvk_GetRenderAreaGranularity(VkDevice device, VkRenderPass renderPass,
                                                         VkExtent2D *pGranularity) {
  (void)device;
  (void)renderPass;
  if (pGranularity) {
    pGranularity->width = 1;
    pGranularity->height = 1;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateCommandPool(VkDevice device,
                                                      const VkCommandPoolCreateInfo *pCreateInfo,
                                                      const VkAllocationCallbacks *pAllocator,
                                                      VkCommandPool *pCommandPool) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pCommandPool) {
    *pCommandPool = (VkCommandPool)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroyCommandPool(VkDevice device, VkCommandPool commandPool,
                                                   const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)commandPool);
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_ResetCommandPool(VkDevice device, VkCommandPool commandPool,
                                                     VkCommandPoolResetFlags flags) {
  (void)device;
  (void)commandPool;
  (void)flags;
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_TrimCommandPool(VkDevice device, VkCommandPool commandPool,
                                                VkCommandPoolTrimFlags flags) {
  (void)device;
  (void)commandPool;
  (void)flags;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_AllocateCommandBuffers(VkDevice device,
                                                           const VkCommandBufferAllocateInfo *pAllocateInfo,
                                                           VkCommandBuffer *pCommandBuffers) {
  uint32_t i;
  (void)device;
  if (pAllocateInfo == 0) {
    return VK_ERROR_OUT_OF_HOST_MEMORY;
  }
  i = 0;
  while (i < pAllocateInfo->commandBufferCount) {
    pCommandBuffers[i] = (VkCommandBuffer)vk_zalloc(sizeof(OsVkCmd));
    i = i + 1;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_FreeCommandBuffers(VkDevice device, VkCommandPool commandPool,
                                                   uint32_t commandBufferCount,
                                                   const VkCommandBuffer *pCommandBuffers) {
  uint32_t i;
  (void)device;
  (void)commandPool;
  i = 0;
  while (i < commandBufferCount) {
    free((void *)pCommandBuffers[i]);
    i = i + 1;
  }
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_BeginCommandBuffer(VkCommandBuffer commandBuffer,
                                                       const VkCommandBufferBeginInfo *pBeginInfo) {
  OsVkCmd *c;
  (void)pBeginInfo;
  c = (OsVkCmd *)commandBuffer;
  if (c) {
    c->n = 0;
    c->fb = 0;
    c->clear = 0;
  }
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_EndCommandBuffer(VkCommandBuffer commandBuffer) {
  (void)commandBuffer;
  return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_ResetCommandBuffer(VkCommandBuffer commandBuffer,
                                                       VkCommandBufferResetFlags flags) {
  OsVkCmd *c;
  (void)flags;
  c = (OsVkCmd *)commandBuffer;
  if (c) {
    c->n = 0;
  }
  return VK_SUCCESS;
}

static OsVkOp *cmd_op(OsVkCmd *c, int kind) {
  OsVkOp *op;
  if (c == 0 || c->n >= OSGFX_VK_MAX_CMD) {
    return 0;
  }
  op = &c->ops[c->n];
  memset(op, 0, sizeof(*op));
  op->kind = kind;
  c->n = c->n + 1;
  return op;
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdBeginRenderPass(VkCommandBuffer commandBuffer,
                                                   const VkRenderPassBeginInfo *pRenderPassBegin,
                                                   VkSubpassContents contents) {
  OsVkCmd *c;
  OsVkOp *op;
  (void)contents;
  c = (OsVkCmd *)commandBuffer;
  if (c == 0 || pRenderPassBegin == 0) {
    return;
  }
  c->fb = (OsVkFb *)pRenderPassBegin->framebuffer;
  c->clear = 0;
  if (pRenderPassBegin->clearValueCount > 0) {
    c->clear = pack_clear(&pRenderPassBegin->pClearValues[0].color);
  }
  op = cmd_op(c, OSGFX_VK_OP_BEGIN_RP);
  if (op) {
    op->fb = c->fb;
    op->color = c->clear;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdEndRenderPass(VkCommandBuffer commandBuffer) {
  OsVkCmd *c;
  OsVkOp *op;
  c = (OsVkCmd *)commandBuffer;
  op = cmd_op(c, OSGFX_VK_OP_END_RP);
  if (op && c && g_rrect.live != 0) {
    op->fb = c->fb;
    op->color = g_rrect.rgb;
    op->w = (uint32_t)g_rrect.w;
    op->h = (uint32_t)g_rrect.h;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdNextSubpass(VkCommandBuffer commandBuffer, VkSubpassContents contents) {
  (void)commandBuffer;
  (void)contents;
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdClearColorImage(VkCommandBuffer commandBuffer, VkImage image,
                                                   VkImageLayout imageLayout, const VkClearColorValue *pColor,
                                                   uint32_t rangeCount, const VkImageSubresourceRange *pRanges) {
  OsVkOp *op;
  (void)imageLayout;
  (void)rangeCount;
  (void)pRanges;
  op = cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_CLEAR_IMG);
  if (op) {
    op->img = (OsVkImage *)image;
    op->color = pack_clear(pColor);
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdCopyImageToBuffer(VkCommandBuffer commandBuffer, VkImage srcImage,
                                                     VkImageLayout srcImageLayout, VkBuffer dstBuffer,
                                                     uint32_t regionCount, const VkBufferImageCopy *pRegions) {
  OsVkOp *op;
  (void)srcImageLayout;
  (void)regionCount;
  (void)pRegions;
  op = cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_COPY_I2B);
  if (op) {
    op->img = (OsVkImage *)srcImage;
    op->buf = (OsVkBuffer *)dstBuffer;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdCopyBufferToImage(VkCommandBuffer commandBuffer, VkBuffer srcBuffer,
                                                     VkImage dstImage, VkImageLayout dstImageLayout,
                                                     uint32_t regionCount, const VkBufferImageCopy *pRegions) {
  OsVkOp *op;
  (void)dstImageLayout;
  (void)regionCount;
  (void)pRegions;
  op = cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_COPY_B2I);
  if (op) {
    op->img = (OsVkImage *)dstImage;
    op->buf = (OsVkBuffer *)srcBuffer;
  }
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdDraw(VkCommandBuffer commandBuffer, uint32_t vertexCount,
                                        uint32_t instanceCount, uint32_t firstVertex,
                                        uint32_t firstInstance) {
  (void)vertexCount;
  (void)instanceCount;
  (void)firstVertex;
  (void)firstInstance;
  cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_DRAW);
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdDrawIndexed(VkCommandBuffer commandBuffer, uint32_t indexCount,
                                               uint32_t instanceCount, uint32_t firstIndex,
                                               int32_t vertexOffset, uint32_t firstInstance) {
  (void)indexCount;
  (void)instanceCount;
  (void)firstIndex;
  (void)vertexOffset;
  (void)firstInstance;
  cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_DRAW);
}

VKAPI_ATTR void VKAPI_CALL osvk_CmdBindPipeline(VkCommandBuffer commandBuffer, VkPipelineBindPoint bindPoint,
                                                VkPipeline pipeline) {
  (void)commandBuffer;
  (void)bindPoint;
  (void)pipeline;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetViewport(VkCommandBuffer commandBuffer, uint32_t firstViewport,
                                               uint32_t viewportCount, const VkViewport *pViewports) {
  (void)commandBuffer;
  (void)firstViewport;
  (void)viewportCount;
  (void)pViewports;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetScissor(VkCommandBuffer commandBuffer, uint32_t firstScissor,
                                              uint32_t scissorCount, const VkRect2D *pScissors) {
  (void)commandBuffer;
  (void)firstScissor;
  (void)scissorCount;
  (void)pScissors;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetLineWidth(VkCommandBuffer commandBuffer, float lineWidth) {
  (void)commandBuffer;
  (void)lineWidth;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetDepthBias(VkCommandBuffer commandBuffer, float a, float b, float c) {
  (void)commandBuffer;
  (void)a;
  (void)b;
  (void)c;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetBlendConstants(VkCommandBuffer commandBuffer, const float blendConstants[4]) {
  (void)commandBuffer;
  (void)blendConstants;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetDepthBounds(VkCommandBuffer commandBuffer, float min, float max) {
  (void)commandBuffer;
  (void)min;
  (void)max;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetStencilCompareMask(VkCommandBuffer commandBuffer, VkStencilFaceFlags f,
                                                         uint32_t m) {
  (void)commandBuffer;
  (void)f;
  (void)m;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetStencilWriteMask(VkCommandBuffer commandBuffer, VkStencilFaceFlags f,
                                                       uint32_t m) {
  (void)commandBuffer;
  (void)f;
  (void)m;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetStencilReference(VkCommandBuffer commandBuffer, VkStencilFaceFlags f,
                                                       uint32_t r) {
  (void)commandBuffer;
  (void)f;
  (void)r;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdBindDescriptorSets(VkCommandBuffer commandBuffer, VkPipelineBindPoint p,
                                                      VkPipelineLayout l, uint32_t first, uint32_t count,
                                                      const VkDescriptorSet *s, uint32_t dyn,
                                                      const uint32_t *off) {
  (void)commandBuffer;
  (void)p;
  (void)l;
  (void)first;
  (void)count;
  (void)s;
  (void)dyn;
  (void)off;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdBindIndexBuffer(VkCommandBuffer commandBuffer, VkBuffer buffer,
                                                   VkDeviceSize offset, VkIndexType indexType) {
  (void)commandBuffer;
  (void)buffer;
  (void)offset;
  (void)indexType;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdBindVertexBuffers(VkCommandBuffer commandBuffer, uint32_t first,
                                                     uint32_t count, const VkBuffer *pBuffers,
                                                     const VkDeviceSize *pOffsets) {
  (void)commandBuffer;
  (void)first;
  (void)count;
  (void)pBuffers;
  (void)pOffsets;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdDrawIndirect(VkCommandBuffer commandBuffer, VkBuffer buffer,
                                                VkDeviceSize offset, uint32_t drawCount, uint32_t stride) {
  (void)commandBuffer;
  (void)buffer;
  (void)offset;
  (void)drawCount;
  (void)stride;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdDrawIndexedIndirect(VkCommandBuffer commandBuffer, VkBuffer buffer,
                                                       VkDeviceSize offset, uint32_t drawCount,
                                                       uint32_t stride) {
  (void)commandBuffer;
  (void)buffer;
  (void)offset;
  (void)drawCount;
  (void)stride;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdDispatch(VkCommandBuffer commandBuffer, uint32_t x, uint32_t y, uint32_t z) {
  (void)commandBuffer;
  (void)x;
  (void)y;
  (void)z;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdDispatchIndirect(VkCommandBuffer commandBuffer, VkBuffer buffer,
                                                    VkDeviceSize offset) {
  (void)commandBuffer;
  (void)buffer;
  (void)offset;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdCopyBuffer(VkCommandBuffer commandBuffer, VkBuffer srcBuffer,
                                              VkBuffer dstBuffer, uint32_t regionCount,
                                              const VkBufferCopy *pRegions) {
  (void)commandBuffer;
  (void)srcBuffer;
  (void)dstBuffer;
  (void)regionCount;
  (void)pRegions;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdCopyImage(VkCommandBuffer commandBuffer, VkImage srcImage,
                                             VkImageLayout srcLayout, VkImage dstImage,
                                             VkImageLayout dstLayout, uint32_t regionCount,
                                             const VkImageCopy *pRegions) {
  OsVkOp *op;
  (void)srcLayout;
  (void)dstLayout;
  (void)regionCount;
  (void)pRegions;
  op = cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_COPY_I2I);
  if (op) {
    op->img = (OsVkImage *)srcImage;
    op->img2 = (OsVkImage *)dstImage;
  }
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdBlitImage(VkCommandBuffer commandBuffer, VkImage srcImage,
                                             VkImageLayout srcLayout, VkImage dstImage,
                                             VkImageLayout dstLayout, uint32_t regionCount,
                                             const VkImageBlit *pRegions, VkFilter filter) {
  OsVkOp *op;
  (void)srcLayout;
  (void)dstLayout;
  (void)regionCount;
  (void)pRegions;
  (void)filter;
  op = cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_COPY_I2I);
  if (op) {
    op->img = (OsVkImage *)srcImage;
    op->img2 = (OsVkImage *)dstImage;
  }
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdUpdateBuffer(VkCommandBuffer commandBuffer, VkBuffer dstBuffer,
                                                VkDeviceSize dstOffset, VkDeviceSize dataSize,
                                                const void *pData) {
  (void)commandBuffer;
  (void)dstBuffer;
  (void)dstOffset;
  (void)dataSize;
  (void)pData;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdFillBuffer(VkCommandBuffer commandBuffer, VkBuffer dstBuffer,
                                              VkDeviceSize dstOffset, VkDeviceSize size, uint32_t data) {
  (void)commandBuffer;
  (void)dstBuffer;
  (void)dstOffset;
  (void)size;
  (void)data;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdClearDepthStencilImage(VkCommandBuffer commandBuffer, VkImage image,
                                                          VkImageLayout imageLayout,
                                                          const VkClearDepthStencilValue *pDepthStencil,
                                                          uint32_t rangeCount,
                                                          const VkImageSubresourceRange *pRanges) {
  (void)commandBuffer;
  (void)image;
  (void)imageLayout;
  (void)pDepthStencil;
  (void)rangeCount;
  (void)pRanges;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdClearAttachments(VkCommandBuffer commandBuffer, uint32_t attachmentCount,
                                                    const VkClearAttachment *pAttachments, uint32_t rectCount,
                                                    const VkClearRect *pRects) {
  (void)commandBuffer;
  (void)attachmentCount;
  (void)pAttachments;
  (void)rectCount;
  (void)pRects;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdResolveImage(VkCommandBuffer commandBuffer, VkImage srcImage,
                                                VkImageLayout srcLayout, VkImage dstImage,
                                                VkImageLayout dstLayout, uint32_t regionCount,
                                                const VkImageResolve *pRegions) {
  OsVkOp *op;
  (void)srcLayout;
  (void)dstLayout;
  (void)regionCount;
  (void)pRegions;
  op = cmd_op((OsVkCmd *)commandBuffer, OSGFX_VK_OP_COPY_I2I);
  if (op) {
    op->img = (OsVkImage *)srcImage;
    op->img2 = (OsVkImage *)dstImage;
  }
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdSetEvent(VkCommandBuffer commandBuffer, VkEvent event,
                                            VkPipelineStageFlags stageMask) {
  (void)commandBuffer;
  (void)event;
  (void)stageMask;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdResetEvent(VkCommandBuffer commandBuffer, VkEvent event,
                                              VkPipelineStageFlags stageMask) {
  (void)commandBuffer;
  (void)event;
  (void)stageMask;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdWaitEvents(VkCommandBuffer commandBuffer, uint32_t eventCount,
                                              const VkEvent *pEvents, VkPipelineStageFlags src,
                                              VkPipelineStageFlags dst, uint32_t m, const VkMemoryBarrier *mb,
                                              uint32_t bm, const VkBufferMemoryBarrier *bb, uint32_t im,
                                              const VkImageMemoryBarrier *ib) {
  (void)commandBuffer;
  (void)eventCount;
  (void)pEvents;
  (void)src;
  (void)dst;
  (void)m;
  (void)mb;
  (void)bm;
  (void)bb;
  (void)im;
  (void)ib;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdPipelineBarrier(VkCommandBuffer commandBuffer, VkPipelineStageFlags src,
                                                   VkPipelineStageFlags dst, VkDependencyFlags dep,
                                                   uint32_t m, const VkMemoryBarrier *mb, uint32_t bm,
                                                   const VkBufferMemoryBarrier *bb, uint32_t im,
                                                   const VkImageMemoryBarrier *ib) {
  (void)commandBuffer;
  (void)src;
  (void)dst;
  (void)dep;
  (void)m;
  (void)mb;
  (void)bm;
  (void)bb;
  (void)im;
  (void)ib;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdBeginQuery(VkCommandBuffer commandBuffer, VkQueryPool queryPool,
                                              uint32_t query, VkQueryControlFlags flags) {
  (void)commandBuffer;
  (void)queryPool;
  (void)query;
  (void)flags;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdEndQuery(VkCommandBuffer commandBuffer, VkQueryPool queryPool,
                                            uint32_t query) {
  (void)commandBuffer;
  (void)queryPool;
  (void)query;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdResetQueryPool(VkCommandBuffer commandBuffer, VkQueryPool queryPool,
                                                  uint32_t firstQuery, uint32_t queryCount) {
  (void)commandBuffer;
  (void)queryPool;
  (void)firstQuery;
  (void)queryCount;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdWriteTimestamp(VkCommandBuffer commandBuffer,
                                                  VkPipelineStageFlagBits pipelineStage,
                                                  VkQueryPool queryPool, uint32_t query) {
  (void)commandBuffer;
  (void)pipelineStage;
  (void)queryPool;
  (void)query;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdCopyQueryPoolResults(VkCommandBuffer commandBuffer, VkQueryPool queryPool,
                                                        uint32_t firstQuery, uint32_t queryCount,
                                                        VkBuffer dstBuffer, VkDeviceSize dstOffset,
                                                        VkDeviceSize stride, VkQueryResultFlags flags) {
  (void)commandBuffer;
  (void)queryPool;
  (void)firstQuery;
  (void)queryCount;
  (void)dstBuffer;
  (void)dstOffset;
  (void)stride;
  (void)flags;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdPushConstants(VkCommandBuffer commandBuffer, VkPipelineLayout layout,
                                                 VkShaderStageFlags stageFlags, uint32_t offset,
                                                 uint32_t size, const void *pValues) {
  (void)commandBuffer;
  (void)layout;
  (void)stageFlags;
  (void)offset;
  (void)size;
  (void)pValues;
}
VKAPI_ATTR void VKAPI_CALL osvk_CmdExecuteCommands(VkCommandBuffer commandBuffer, uint32_t commandBufferCount,
                                                   const VkCommandBuffer *pCommandBuffers) {
  (void)commandBuffer;
  (void)commandBufferCount;
  (void)pCommandBuffers;
}

VKAPI_ATTR VkResult VKAPI_CALL osvk_CreateSamplerYcbcrConversion(
    VkDevice device, const VkSamplerYcbcrConversionCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkSamplerYcbcrConversion *pYcbcrConversion) {
  (void)device;
  (void)pCreateInfo;
  (void)pAllocator;
  if (pYcbcrConversion) {
    *pYcbcrConversion = (VkSamplerYcbcrConversion)vk_zalloc(8);
  }
  return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL osvk_DestroySamplerYcbcrConversion(VkDevice device,
                                                              VkSamplerYcbcrConversion ycbcrConversion,
                                                              const VkAllocationCallbacks *pAllocator) {
  (void)device;
  (void)pAllocator;
  free((void *)ycbcrConversion);
}

typedef struct OsVkName {
  const char *n;
  PFN_vkVoidFunction f;
} OsVkName;

#define N(s)                                 \
  {                                          \
    "vk" #s, (PFN_vkVoidFunction)osvk_##s    \
  }

static const OsVkName kNames[] = {
    N(EnumerateInstanceVersion),
    N(CreateInstance),
    N(DestroyInstance),
    N(EnumeratePhysicalDevices),
    N(GetPhysicalDeviceFeatures),
    N(GetPhysicalDeviceFormatProperties),
    N(GetPhysicalDeviceImageFormatProperties),
    N(GetPhysicalDeviceProperties),
    N(GetPhysicalDeviceQueueFamilyProperties),
    N(GetPhysicalDeviceMemoryProperties),
    N(GetPhysicalDeviceSparseImageFormatProperties),
    N(EnumerateInstanceExtensionProperties),
    N(EnumerateInstanceLayerProperties),
    N(EnumerateDeviceExtensionProperties),
    N(EnumerateDeviceLayerProperties),
    N(CreateDevice),
    N(DestroyDevice),
    N(GetDeviceQueue),
    N(QueueSubmit),
    N(QueueWaitIdle),
    N(DeviceWaitIdle),
    N(AllocateMemory),
    N(FreeMemory),
    N(MapMemory),
    N(UnmapMemory),
    N(FlushMappedMemoryRanges),
    N(InvalidateMappedMemoryRanges),
    N(GetDeviceMemoryCommitment),
    N(BindBufferMemory),
    N(BindImageMemory),
    N(GetBufferMemoryRequirements),
    N(GetImageMemoryRequirements),
    N(GetImageSparseMemoryRequirements),
    N(QueueBindSparse),
    N(CreateFence),
    N(DestroyFence),
    N(ResetFences),
    N(GetFenceStatus),
    N(WaitForFences),
    N(CreateSemaphore),
    N(DestroySemaphore),
    N(CreateEvent),
    N(DestroyEvent),
    N(GetEventStatus),
    N(SetEvent),
    N(ResetEvent),
    N(CreateQueryPool),
    N(DestroyQueryPool),
    N(GetQueryPoolResults),
    N(CreateBuffer),
    N(DestroyBuffer),
    N(CreateBufferView),
    N(DestroyBufferView),
    N(CreateImage),
    N(DestroyImage),
    N(GetImageSubresourceLayout),
    N(CreateImageView),
    N(DestroyImageView),
    N(CreateShaderModule),
    N(DestroyShaderModule),
    N(CreatePipelineCache),
    N(DestroyPipelineCache),
    N(GetPipelineCacheData),
    N(MergePipelineCaches),
    N(CreateGraphicsPipelines),
    N(CreateComputePipelines),
    N(DestroyPipeline),
    N(CreatePipelineLayout),
    N(DestroyPipelineLayout),
    N(CreateSampler),
    N(DestroySampler),
    N(CreateDescriptorSetLayout),
    N(DestroyDescriptorSetLayout),
    N(CreateDescriptorPool),
    N(DestroyDescriptorPool),
    N(ResetDescriptorPool),
    N(AllocateDescriptorSets),
    N(FreeDescriptorSets),
    N(UpdateDescriptorSets),
    N(CreateFramebuffer),
    N(DestroyFramebuffer),
    N(CreateRenderPass),
    N(DestroyRenderPass),
    N(GetRenderAreaGranularity),
    N(CreateCommandPool),
    N(DestroyCommandPool),
    N(ResetCommandPool),
    N(AllocateCommandBuffers),
    N(FreeCommandBuffers),
    N(BeginCommandBuffer),
    N(EndCommandBuffer),
    N(ResetCommandBuffer),
    N(CmdBindPipeline),
    N(CmdSetViewport),
    N(CmdSetScissor),
    N(CmdSetLineWidth),
    N(CmdSetDepthBias),
    N(CmdSetBlendConstants),
    N(CmdSetDepthBounds),
    N(CmdSetStencilCompareMask),
    N(CmdSetStencilWriteMask),
    N(CmdSetStencilReference),
    N(CmdBindDescriptorSets),
    N(CmdBindIndexBuffer),
    N(CmdBindVertexBuffers),
    N(CmdDraw),
    N(CmdDrawIndexed),
    N(CmdDrawIndirect),
    N(CmdDrawIndexedIndirect),
    N(CmdDispatch),
    N(CmdDispatchIndirect),
    N(CmdCopyBuffer),
    N(CmdCopyImage),
    N(CmdBlitImage),
    N(CmdCopyBufferToImage),
    N(CmdCopyImageToBuffer),
    N(CmdUpdateBuffer),
    N(CmdFillBuffer),
    N(CmdClearColorImage),
    N(CmdClearDepthStencilImage),
    N(CmdClearAttachments),
    N(CmdResolveImage),
    N(CmdSetEvent),
    N(CmdResetEvent),
    N(CmdWaitEvents),
    N(CmdPipelineBarrier),
    N(CmdBeginQuery),
    N(CmdEndQuery),
    N(CmdResetQueryPool),
    N(CmdWriteTimestamp),
    N(CmdCopyQueryPoolResults),
    N(CmdPushConstants),
    N(CmdBeginRenderPass),
    N(CmdNextSubpass),
    N(CmdEndRenderPass),
    N(CmdExecuteCommands),
    N(GetPhysicalDeviceFeatures2),
    N(GetPhysicalDeviceProperties2),
    N(GetPhysicalDeviceFormatProperties2),
    N(GetPhysicalDeviceImageFormatProperties2),
    N(GetPhysicalDeviceQueueFamilyProperties2),
    N(GetPhysicalDeviceMemoryProperties2),
    N(GetPhysicalDeviceSparseImageFormatProperties2),
    N(GetImageMemoryRequirements2),
    N(GetBufferMemoryRequirements2),
    N(GetImageSparseMemoryRequirements2),
    N(BindBufferMemory2),
    N(BindImageMemory2),
    N(TrimCommandPool),
    N(GetDescriptorSetLayoutSupport),
    N(GetPhysicalDeviceExternalBufferProperties),
    N(CreateSamplerYcbcrConversion),
    N(DestroySamplerYcbcrConversion),
};

#undef N

void *osgfx_vk_get_proc(const char *name) {
  size_t i;
  if (name == 0) {
    return 0;
  }
  i = 0;
  while (i < sizeof(kNames) / sizeof(kNames[0])) {
    if (strcmp(name, kNames[i].n) == 0) {
      return (void *)kNames[i].f;
    }
    i = i + 1;
  }
  (void)stub_ok;
  return 0;
}

int osgfx_vk_open(void) {
  VkInstanceCreateInfo ici;
  VkDeviceCreateInfo dci;
  VkDeviceQueueCreateInfo qci;
  float prio;
  VkResult r;
  if (g_open != 0) {
    return 1;
  }
  memset(&ici, 0, sizeof(ici));
  ici.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  r = osvk_CreateInstance(&ici, 0, &g_dev.inst);
  if (r != VK_SUCCESS) {
    return 0;
  }
  g_dev.phys = (VkPhysicalDevice)(uintptr_t)0x56504D31;
  prio = 1.0f;
  memset(&qci, 0, sizeof(qci));
  qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  qci.queueFamilyIndex = 0;
  qci.queueCount = 1;
  qci.pQueuePriorities = &prio;
  memset(&dci, 0, sizeof(dci));
  dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  dci.queueCreateInfoCount = 1;
  dci.pQueueCreateInfos = &qci;
  r = osvk_CreateDevice(g_dev.phys, &dci, 0, &g_dev.dev);
  if (r != VK_SUCCESS) {
    return 0;
  }
  osvk_GetDeviceQueue(g_dev.dev, 0, 0, &g_dev.queue);
  g_open = 1;
  return 1;
}

void *osgfx_vk_instance(void) { return (void *)g_dev.inst; }
void *osgfx_vk_phys(void) { return (void *)g_dev.phys; }
void *osgfx_vk_device(void) { return (void *)g_dev.dev; }
void *osgfx_vk_queue(void) { return (void *)g_dev.queue; }
unsigned osgfx_vk_qindex(void) { return 0; }

size_t osgfx_vk_spirv_bytes(void) { return g_spirv_bytes; }

unsigned osgfx_vk_spirv_modules(void) { return g_spirv_modules; }

unsigned osgfx_vk_plant_host_spirv(void) {
  VkShaderModuleCreateInfo ci;
  VkShaderModule mod;
  unsigned before;
  if (g_open == 0) {
    if (osgfx_vk_open() == 0) {
      return 0;
    }
  }
  if (osgfx_vk_host_spirv_door[0] == 0) {
    return 0;
  }
  before = g_spirv_modules;
  memset(&ci, 0, sizeof(ci));
  ci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
  ci.codeSize = sizeof(kHostCurveSpirv);
  ci.pCode = kHostCurveSpirv;
  if (osvk_CreateShaderModule(g_dev.dev, &ci, 0, &mod) != VK_SUCCESS) {
    return 0;
  }
  /* Keep the module — retain counts prove the host SPIR-V door. */
  (void)mod;
  if (g_spirv_modules <= before) {
    return 0;
  }
  com1_puts("OSGFX HOST SPIRV\n");
  /* Venus encode runs from shell (wmGfxCmd), not IRQ0 tick. */
  return g_spirv_modules;
}

unsigned osgfx_vk_venus_encode(void) {
  unsigned ok;
  if (osgfx_vk_venus_spirv_door[0] == 0) {
    return 0;
  }
  if (g_last_spirv == 0 || g_last_spirv_bytes == 0) {
    return 0;
  }
  if (g_last_spirv_bytes > 0xffffffffu) {
    return 0;
  }
  ok = osgfx_venus_spirv_wire(g_last_spirv, (unsigned)g_last_spirv_bytes);
  if (ok != 0) {
    g_venus_encode_ok = 1;
  }
  return ok;
}

unsigned osgfx_vk_venus_encode_ok(void) { return g_venus_encode_ok; }

/* Non-zero when CreateShaderModule retained a module for Venus encode. */
unsigned osgfx_vk_spirv_ready(void) {
  if (g_last_spirv == 0) {
    return 0;
  }
  if (g_last_spirv_bytes == 0) {
    return 0;
  }
  return 1;
}
