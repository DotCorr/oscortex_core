/* u64 ABI so @bare can call osmedia without Pointer / String (GAP-0025). */
#include "osmedia.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static const char *g_clip = "osmedia-clip.mp4";
static const char *g_path = "osmedia.ppm";
static const char *g_last_backend = "none";

void osmedia_ffi_set_clip(const char *p) {
  if (p != 0) {
    g_clip = p;
  }
}

void osmedia_ffi_set_path(const char *p) {
  if (p != 0) {
    g_path = p;
  }
}

const char *osmedia_ffi_last_backend(void) {
  if (g_last_backend == 0) {
    return "none";
  }
  return g_last_backend;
}

uint64_t osmedia_ffi_init(uint64_t no_init) {
  if (no_init != 0) {
    setenv("OSMEDIA_NO_FFMPEG", "1", 1);
  }
  return (uint64_t)osmedia_init();
}

uint64_t osmedia_ffi_open(void) {
  OsMedia *m;
  m = osmedia_open(g_clip);
  g_last_backend = osmedia_backend_name(m);
  return (uint64_t)(uintptr_t)m;
}

void osmedia_ffi_close(uint64_t m) {
  if (m == 0) {
    return;
  }
  osmedia_close((OsMedia *)(uintptr_t)m);
}

uint64_t osmedia_ffi_decode_frame(uint64_t m) {
  if (m == 0) {
    return (uint64_t)OSMEDIA_ERR;
  }
  return (uint64_t)osmedia_decode_frame((OsMedia *)(uintptr_t)m);
}

uint64_t osmedia_ffi_readback(uint64_t m) {
  uint32_t tmp[OSMEDIA_W * OSMEDIA_H];
  int n;
  if (m == 0) {
    return 0;
  }
  n = osmedia_readback((OsMedia *)(uintptr_t)m, tmp, OSMEDIA_W * OSMEDIA_H);
  if (n < 0) {
    return 0;
  }
  return (uint64_t)n;
}

uint64_t osmedia_ffi_pixel(uint64_t m, uint64_t x, uint64_t y) {
  uint32_t pix;
  if (m == 0) {
    return 0;
  }
  if (osmedia_pixel((OsMedia *)(uintptr_t)m, (int)x, (int)y, &pix) !=
      OSMEDIA_OK) {
    return 0;
  }
  return (uint64_t)pix;
}

uint64_t osmedia_ffi_ppm(uint64_t m) {
  if (m == 0) {
    return (uint64_t)OSMEDIA_ERR;
  }
  return (uint64_t)osmedia_ppm_write((OsMedia *)(uintptr_t)m, g_path);
}

void osmedia_ffi_shutdown(void) { osmedia_shutdown(); }

uint64_t osmedia_ffi_backend_ffmpeg(void) {
  return (uint64_t)osmedia_backend_ffmpeg();
}

uint64_t osmedia_ffi_backend_is_ffmpeg(uint64_t m) {
  const char *n;
  n = osmedia_backend_name((OsMedia *)(uintptr_t)m);
  if (n == 0) {
    return 0;
  }
  if (strcmp(n, "ffmpeg") == 0) {
    return 1;
  }
  return 0;
}
