/* u64 ABI so @bare can call osgfx without Pointer (GAP-0025). */
#include "osgfx.h"
#include "osgfx_scene.h"

#include <stdint.h>

static const char *g_path = "osgfx.ppm";

void osgfx_ffi_set_path(const char *p) {
  if (p != 0) {
    g_path = p;
  }
}

uint64_t osgfx_ffi_create(uint64_t w, uint64_t h) {
  return (uint64_t)(uintptr_t)osgfx_create((int)w, (int)h);
}

void osgfx_ffi_destroy(uint64_t g) {
  if (g == 0) {
    return;
  }
  osgfx_destroy((OsGfx *)(uintptr_t)g);
}

void osgfx_ffi_clear(uint64_t g, uint64_t rgb) {
  if (g == 0) {
    return;
  }
  osgfx_clear((OsGfx *)(uintptr_t)g, (uint32_t)rgb);
}

void osgfx_ffi_fill_rrect(uint64_t g, uint64_t x, uint64_t y, uint64_t w,
                         uint64_t h, uint64_t radius, uint64_t rgb) {
  if (g == 0) {
    return;
  }
  osgfx_fill_rrect((OsGfx *)(uintptr_t)g, (int)x, (int)y, (int)w, (int)h,
                   (int)radius, (uint32_t)rgb);
}

uint64_t osgfx_ffi_flush(uint64_t g) {
  if (g == 0) {
    return (uint64_t)OSGFX_ERR;
  }
  return (uint64_t)osgfx_flush((OsGfx *)(uintptr_t)g);
}

uint64_t osgfx_ffi_ppm(uint64_t g) {
  int rc;
  if (g == 0) {
    return (uint64_t)OSGFX_ERR;
  }
  rc = osgfx_ppm_write((OsGfx *)(uintptr_t)g, g_path);
  return (uint64_t)rc;
}

void osgfx_ffi_scene_two(uint64_t g) {
  if (g == 0) {
    return;
  }
  osgfx_scene_two((OsGfx *)(uintptr_t)g);
}

void osgfx_ffi_scene_compose(uint64_t g) {
  if (g == 0) {
    return;
  }
  osgfx_scene_compose((OsGfx *)(uintptr_t)g);
}
