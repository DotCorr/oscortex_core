/* core/plat/chrome/oschrome.h — platform Chromium Content / CEF ABI.
 *
 * Android WebView shape: Chromium is oscortex platform C++, not an app
 * ELF, not Flutter, not preview.html. The 64 KiB / 2 MiB numbers are
 * the app sandbox. They do not apply here (c-modules.md §0).
 *
 * DCDart / OSXStudio call these symbols through the C ABI
 * (dcdart-c-ffi.md). They do not #include Chromium. No syscall.
 *
 * TODAY host harnesses link the official Spotify CEF macosarm64
 * prebuilt (Chromium Content) via oschrome.mm. The running OS links
 * oschrome_guest.c (same ABI, kernel triple) plus official linux64
 * libcef `cef_initialize` (extract-cef-guest.sh) into BROWSE.ELF.
 * Mac arm64 CEF is not copied into the x86_64 blob. Host browser0
 * is not this. OSCHROME_NO_CHROMIUM=1 / --no-init is the negative:
 * same binary, pixels are not the HTML colour. oschrome_on_paint is OUR CEF-OSR stand-in (ADR-0166). Leftover:
 * wire official libcef.so. ADR-0123 measured the process-ABI block.
 * Do not call the extract. Do not treat nm of cef_initialize as paint.
 */

#ifndef OSCHROME_ABI_H
#define OSCHROME_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  OSCHROME_OK = 0,
  OSCHROME_ERR = 1,
  OSCHROME_W = 128,
  OSCHROME_H = 128,
  OSCHROME_PX = 32,
  OSCHROME_PY = 32,
  /* Colour the default data: HTML names. Not 0, not desktop 0x184060. */
  OSCHROME_PAGE = 0x00C03890,
  OSCHROME_DESK = 0x00184060,
  /* cef_paint_element_type_t PET_VIEW — CEF OSR on_paint type. */
  OSCHROME_PET_VIEW = 0
};

typedef struct OsChrome OsChrome;

/* Browser process: load the CEF framework and CefInitialize.
 * Helper subprocess: CefExecuteProcess and _exit (does not return).
 * OSCHROME_NO_CHROMIUM=1: no-op, returns OSCHROME_OK. */
int oschrome_init(int argc, char **argv);
void oschrome_shutdown(void);

OsChrome *oschrome_create(int w, int h);
void oschrome_destroy(OsChrome *b);

/* data: or file: URL. */
int oschrome_load_url(OsChrome *b, const char *url);

/* Pump the Content message loop until a view paint, or timeout_ms. */
int oschrome_pump(OsChrome *b, int timeout_ms);

/* Read 0x00RRGGBB. Returns pixel count, or -1. */
int oschrome_readback(OsChrome *b, uint32_t *out, int max_pixels);

int oschrome_pixel(OsChrome *b, int x, int y, uint32_t *out);
int oschrome_ppm_write(OsChrome *b, const char *path);

/* Write the default data: URL (PAGE colour) into buf. Returns length, or -1. */
int oschrome_default_data_url(char *buf, int buf_n);

/* 1 — this binary linked Chromium Content / CEF. Always 1 after BROWSER0. */
int oschrome_backend_chromium(void);

/* "chromium" or "none". Null-safe "none". */
const char *oschrome_backend_name(const OsChrome *b);

/* u64 ABI so @bare can call without Pointer / String (GAP-0025, GAP-0035).
 * Existing OsChrome* / const char* symbols stay; these wrap them.
 * oschrome_ffi_load_url loads the default data: URL — no String crosses. */
uint64_t oschrome_ffi_init(uint64_t no_init);
uint64_t oschrome_ffi_create(uint64_t w, uint64_t h);
void oschrome_ffi_destroy(uint64_t b);
uint64_t oschrome_ffi_load_url(uint64_t b);
uint64_t oschrome_ffi_pump(uint64_t b, uint64_t timeout_ms);
uint64_t oschrome_ffi_readback(uint64_t b);
uint64_t oschrome_ffi_pixel(uint64_t b, uint64_t x, uint64_t y);
uint64_t oschrome_ffi_ppm(uint64_t b);
void oschrome_ffi_shutdown(void);
uint64_t oschrome_ffi_backend_chromium(void);
uint64_t oschrome_ffi_backend_is_chromium(uint64_t b);

#ifdef __cplusplus
}
#endif

#endif
