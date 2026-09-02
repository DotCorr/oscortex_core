/* u64 ABI so @bare can call oschrome without Pointer / String (GAP-0025). */
#include "oschrome.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static int g_argc = 0;
static char **g_argv = 0;
static const char *g_path = "oschrome.ppm";
static const char *g_last_backend = "none";

void oschrome_ffi_set_args(int argc, char **argv) {
  g_argc = argc;
  g_argv = argv;
}

void oschrome_ffi_set_path(const char *p) {
  if (p != 0) {
    g_path = p;
  }
}

const char *oschrome_ffi_last_backend(void) {
  if (g_last_backend == 0) {
    return "none";
  }
  return g_last_backend;
}

uint64_t oschrome_ffi_init(uint64_t no_init) {
  static char *fallback_argv[] = {"oschrome-ffi", 0};
  if (no_init != 0) {
    setenv("OSCHROME_NO_CHROMIUM", "1", 1);
  }
  if (g_argv == 0) {
    g_argc = 1;
    g_argv = fallback_argv;
  }
  return (uint64_t)oschrome_init(g_argc, g_argv);
}

uint64_t oschrome_ffi_create(uint64_t w, uint64_t h) {
  OsChrome *b;
  b = oschrome_create((int)w, (int)h);
  g_last_backend = oschrome_backend_name(b);
  return (uint64_t)(uintptr_t)b;
}

void oschrome_ffi_destroy(uint64_t b) {
  if (b == 0) {
    return;
  }
  oschrome_destroy((OsChrome *)(uintptr_t)b);
}

uint64_t oschrome_ffi_load_url(uint64_t b) {
  char url[512];
  if (b == 0) {
    return (uint64_t)OSCHROME_ERR;
  }
  if (oschrome_default_data_url(url, (int)sizeof(url)) < 0) {
    return (uint64_t)OSCHROME_ERR;
  }
  return (uint64_t)oschrome_load_url((OsChrome *)(uintptr_t)b, url);
}

uint64_t oschrome_ffi_pump(uint64_t b, uint64_t timeout_ms) {
  if (b == 0) {
    return (uint64_t)OSCHROME_ERR;
  }
  return (uint64_t)oschrome_pump((OsChrome *)(uintptr_t)b, (int)timeout_ms);
}

uint64_t oschrome_ffi_readback(uint64_t b) {
  uint32_t tmp[OSCHROME_W * OSCHROME_H];
  int n;
  if (b == 0) {
    return 0;
  }
  n = oschrome_readback((OsChrome *)(uintptr_t)b, tmp, OSCHROME_W * OSCHROME_H);
  if (n < 0) {
    return 0;
  }
  return (uint64_t)n;
}

uint64_t oschrome_ffi_pixel(uint64_t b, uint64_t x, uint64_t y) {
  uint32_t pix;
  if (b == 0) {
    return 0;
  }
  if (oschrome_pixel((OsChrome *)(uintptr_t)b, (int)x, (int)y, &pix) !=
      OSCHROME_OK) {
    return 0;
  }
  return (uint64_t)pix;
}

uint64_t oschrome_ffi_ppm(uint64_t b) {
  if (b == 0) {
    return (uint64_t)OSCHROME_ERR;
  }
  return (uint64_t)oschrome_ppm_write((OsChrome *)(uintptr_t)b, g_path);
}

void oschrome_ffi_shutdown(void) { oschrome_shutdown(); }

uint64_t oschrome_ffi_backend_chromium(void) {
  return (uint64_t)oschrome_backend_chromium();
}

uint64_t oschrome_ffi_backend_is_chromium(uint64_t b) {
  const char *n;
  n = oschrome_backend_name((OsChrome *)(uintptr_t)b);
  if (n == 0) {
    return 0;
  }
  if (strcmp(n, "chromium") == 0) {
    return 1;
  }
  return 0;
}
