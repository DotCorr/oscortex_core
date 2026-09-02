/* core/plat/media/osmedia.h — platform FFmpeg media ABI.
 *
 * Android MediaCodec / Stagefright shape: FFmpeg is oscortex platform C,
 * not an app ELF, not kernel.elf this slice, not Flutter. The 64 KiB /
 * 2 MiB numbers are the app sandbox. They do not apply here
 * (c-modules.md §0). exec-format.md sized ffmpeg as an app; that was
 * the wrong box.
 *
 * DCDart / OSXStudio call these symbols through the C ABI
 * (dcdart-c-ffi.md). They do not #include libav*. No syscall.
 *
 * TODAY the implementation links brew/official FFmpeg
 * (libavcodec / libavformat / libavutil). OSMEDIA_NO_FFMPEG=1 is the
 * negative: same binary, no avformat_open_input / avcodec_send_packet,
 * pixels are not the planted colour.
 */

#ifndef OSMEDIA_ABI_H
#define OSMEDIA_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  OSMEDIA_OK = 0,
  OSMEDIA_ERR = 1,
  OSMEDIA_W = 64,
  OSMEDIA_H = 64,
  OSMEDIA_PX = 16,
  OSMEDIA_PY = 16,
  /* Sit-in scanout origin for the decoded tile (ADR-0131). Below the
   * `fb` banner / prompt so console glyphs do not overwrite it. */
  OSMEDIA_BLIT_X = 16,
  OSMEDIA_BLIT_Y = 400,
  /* wmsurface video window (ADR-0135). Away from the raw Bochs tile
   * so a window-body probe cannot be satisfied by (16, 400). */
  OSMEDIA_WIN_X = 200,
  OSMEDIA_WIN_Y = 80,
  OSMEDIA_WIN_PX = 16,
  OSMEDIA_WIN_PY = 32,
  /* Colour the planted clip names. Not 0, not desktop 0x184060. */
  OSMEDIA_FRAME = 0x00C04088,
  /* Second still in a movie plant (ADR-0143). Far from FRAME (slop 20). */
  OSMEDIA_FRAME2 = 0x0020C040,
  OSMEDIA_DESK = 0x00184060
};

typedef struct OsMedia OsMedia;

/* Prepare the FFmpeg libraries. OSMEDIA_NO_FFMPEG=1: no-op, returns OK. */
int osmedia_init(void);
void osmedia_shutdown(void);

/* Open a container. Missing file returns 0. No-init returns an empty handle. */
OsMedia *osmedia_open(const char *path);
/* Open from a planted buffer (AVIO). Missing / empty returns 0. */
OsMedia *osmedia_open_mem(const uint8_t *buf, int len);
void osmedia_close(OsMedia *m);

/* Decode one video frame into RGB. */
int osmedia_decode_frame(OsMedia *m);

/* Read 0x00RRGGBB. Returns pixel count, or -1. */
int osmedia_readback(OsMedia *m, uint32_t *out, int max_pixels);

int osmedia_pixel(OsMedia *m, int x, int y, uint32_t *out);
int osmedia_ppm_write(OsMedia *m, const char *path);

/* 1 — this binary linked libavcodec / libavformat / libavutil. Always 1. */
int osmedia_backend_ffmpeg(void);

/* "ffmpeg" or "none". Null-safe "none". */
const char *osmedia_backend_name(const OsMedia *m);

/* av_version_info(), or "none". */
const char *osmedia_version(void);

/* u64 ABI so @bare can call without Pointer / String (GAP-0025, GAP-0035).
 * Existing OsMedia* / const char* symbols stay; these wrap them.
 * osmedia_ffi_open uses the path set by osmedia_ffi_set_path — no String. */
uint64_t osmedia_ffi_init(uint64_t no_init);
uint64_t osmedia_ffi_open(void);
void osmedia_ffi_close(uint64_t m);
uint64_t osmedia_ffi_decode_frame(uint64_t m);
uint64_t osmedia_ffi_readback(uint64_t m);
uint64_t osmedia_ffi_pixel(uint64_t m, uint64_t x, uint64_t y);
uint64_t osmedia_ffi_ppm(uint64_t m);
void osmedia_ffi_shutdown(void);
uint64_t osmedia_ffi_backend_ffmpeg(void);
uint64_t osmedia_ffi_backend_is_ffmpeg(uint64_t m);

#ifdef __cplusplus
}
#endif

#endif
