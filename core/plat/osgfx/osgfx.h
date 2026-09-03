/* core/plat/osgfx/osgfx.h — platform paint ABI. The UI language.
 *
 * This is not Flutter. This is oscortex
 * platform C, the way Android's Skia/hwui is platform C++: apps do
 * not contain it. A FRAME ELF still paints shm pixels (ADR-0051).
 * DCDart calls these symbols through the C ABI (dcdart-c-ffi.md).
 *
 * Host harnesses link Skia Graphite (osgfx_graphite.mm) with Metal
 * (osgfx_metal.m) as fallback. OSGFX_FORCE_METAL=1 selects that
 * fallback. kernel.elf links osgfx_skia.cpp + ELF libskia.a — Skia
 * CPU raster, same ABI (ADR-0110). osgfx_sw.c stays in-tree; it is
 * not the sit-in backend. Graphite MakeVulkan is linked (ADR-0129).
 * A kernel ICD + Venus arm is the VkDevice door (ADR-0134). Chrome
 * rrects go through Graphite drawRRect when Venus arms (ADR-0153).
 * Curved MakeRectXY paints via host-precompiled SPIR-V + ICD radius
 * (ADR-0161). Venus CONTEXT_INIT + blob encodes retained SPIR-V
 * (ADR-0172); full lavapipe FS coverage is leftover. Vulkan
 * must keep this header.
 *
 * Colours are 0x00RRGGBB, same packing as the kernel compositor.
 */

#ifndef OSGFX_ABI_H
#define OSGFX_ABI_H

#include <stdint.h>

struct OsGfxGuestCmd;

#ifdef __cplusplus
extern "C" {
#endif

enum {
  OSGFX_OK = 0,
  OSGFX_ERR = 1,
  OSGFX_W = 800,
  OSGFX_H = 600,
  OSGFX_WIN_X = 48,
  OSGFX_WIN_Y = 40,
  OSGFX_WIN_W = 240,
  OSGFX_WIN_H = 160,
  OSGFX_WIN2_X = 140,
  OSGFX_WIN2_Y = 90,
  OSGFX_RADIUS = 18,
  OSGFX_BLIT_INSET = 18,
  OSGFX_TITLE_H = 32,
  OSGFX_CHROME_H = 48,
  OSGFX_BORDER = 2,
  OSGFX_POP_W = 168,
  OSGFX_POP_H = 80,
  OSGFX_POP_X = 520,
  OSGFX_POP_Y = 80,
  /* Content rect is POP_W×POP_H (hit-test). Visual/effect bounds are
   * the near-white card plus Skia AA (~3px) and the south/east shadow
   * (offset 4,6; blur 14 → spread 2). Measured white bbox 174×93 is
   * this extent, not a 168×80 layout mismatch. */
  OSGFX_POP_SHADOW_OX = 4,
  OSGFX_POP_SHADOW_OY = 6,
  OSGFX_POP_SHADOW_BLUR = 14,
  OSGFX_POP_SHADOW_SPREAD = 2,
  OSGFX_POP_AA = 3,
  OSGFX_POP_VIS_L = 3,
  OSGFX_POP_VIS_T = 3,
  OSGFX_POP_VIS_R = 3,
  OSGFX_POP_VIS_B = 10,
  OSGFX_POP_VIS_W = 174,
  OSGFX_POP_VIS_H = 93,
  OSGFX_DESK = 0x00184060,
  /* Pearl title / elevated slate taskbar — designed chrome, not neon stamps. */
  OSGFX_TITLE = 0x00E8E0D0,
  OSGFX_WIN_FILL = 0x001A2430,
  OSGFX_WIN2_FILL = 0x00202838,
  OSGFX_CHROME = 0x00344050,
  OSGFX_POP = 0x00C04088,
  OSGFX_FOCUS = 0x00F5F0E8,
  OSGFX_UNFOCUS = 0x00485058,
  OSGFX_MENU_BG = 0x00203040,
  OSGFX_MENU_IDLE = 0x00304878,
  OSGFX_MENU_HIT = 0x00E04090,
  /* 8x16 console font (same bits as fbFont8x16). */
  OSGFX_GLYPH_W = 8,
  OSGFX_GLYPH_H = 16,
  /* Document icon. Same cell as a glyph. Not a PNG. */
  OSGFX_ICON_W = 8,
  OSGFX_ICON_H = 16
};

typedef struct OsGfx OsGfx;

OsGfx *osgfx_create(int w, int h);
void osgfx_destroy(OsGfx *g);

void osgfx_clear(OsGfx *g, uint32_t rgb);
void osgfx_fill_desk_generative(uint32_t *fb, int pitch, int x, int y, int w, int h,
                                uint32_t seed, uint32_t frame);
void osgfx_fill_desk_cached(uint32_t *fb, int pitch, int x, int y, int w, int h,
                            uint32_t seed);
void osgfx_glass_frost(uint32_t *dst, int pitch_px, int dw, int dh, int x, int y,
                       int w, int h, int radius, int scr_x0, int scr_y0,
                       uint32_t tint);
uint32_t *osgfx_chrome_target(const struct OsGfxGuestCmd *m);
int osgfx_chrome_fresh(const struct OsGfxGuestCmd *m);
int osgfx_chrome_is_focus_only(const struct OsGfxGuestCmd *m);
int osgfx_chrome_is_geom_only(const struct OsGfxGuestCmd *m);
void osgfx_chrome_stamp_wins(uint64_t *win0, uint64_t *win1);
void osgfx_chrome_note_uncover(uint64_t old0, uint64_t old1);
const uint32_t *osgfx_desk_cache(int *w, int *h);
int osgfx_chrome_present(const struct OsGfxGuestCmd *m);
void osgfx_chrome_begin(const struct OsGfxGuestCmd *m);
void osgfx_chrome_done(const struct OsGfxGuestCmd *m);
void osgfx_chrome_glyph_count(int hit);
uint32_t *osgfx_chrome_band(int w, int h);
int osgfx_chrome_band_fresh(int w, int h, uint32_t top, uint32_t bot);
void osgfx_chrome_band_stamp(int w, int h, uint32_t top, uint32_t bot);
void osgfx_session_paint(OsGfx *g, const struct OsGfxGuestCmd *cmd, int graphite_ready);
void osgfx_session_paint_windows(OsGfx *g, const struct OsGfxGuestCmd *cmd);
void osgfx_session_paint_geom(OsGfx *g, const struct OsGfxGuestCmd *cmd,
                              uint64_t old0, uint64_t old1);
void osgfx_session_patch_focus(OsGfx *g, const struct OsGfxGuestCmd *cmd);
void osgfx_fill_rect(OsGfx *g, int x, int y, int w, int h, uint32_t rgb);
void osgfx_fill_rrect(OsGfx *g, int x, int y, int w, int h, int radius,
                      uint32_t rgb);
/* Coverage blend into the bound store (0 = clear, 255 = opaque). Soft AA. */
void osgfx_blend_px(OsGfx *g, int x, int y, uint32_t rgb, uint8_t cov);
/* One 8x16 glyph with neighbourhood soft AA — not 1×1 paper stamps. */
void osgfx_fill_glyph(OsGfx *g, int x, int y, const uint8_t *rows, uint32_t rgb);
/* 16-byte glyph for ASCII ch. Fallback box outside 0x20..0x7E.
 * LEGACY. New chrome text goes through osgfx_text (real outlines). */
const uint8_t *osgfx_glyph_rows(int ch);

/* ---------------------------------------------------------------------------
 * Text. Real proportional TrueType outlines, rasterised live by Skia.
 *
 * osgfx_font.h holds the outline table that core/scripts/gen-osgfx-font.py
 * extracts from a real .ttf `glyf` table at build time. osgfx_text replays
 * those quadratic verbs into an SkPathBuilder and hands one SkPath per run
 * to SkCanvas::drawPath with antialiasing on. There is no 8x16 cell, no
 * fixed advance and no pre-baked mask: the size is a caller argument and
 * Skia scan-converts at that size.
 *
 * (x, y) is the top-left of the text box, not the baseline, so callers keep
 * using padding numbers. weight is OSGFX_TEXT_REGULAR / OSGFX_TEXT_MEDIUM.
 * Returns the advance width in pixels (0 on any bad argument).
 * ------------------------------------------------------------------------- */
enum {
  /* Default chrome sizes. Material-ish: label 14, title 15. */
  OSGFX_TEXT_LABEL_PX = 14,
  OSGFX_TEXT_TITLE_PX = 15,
  /* Weight selector. The faces live in osgfx_font.h / osgfx_font_data.c. */
  OSGFX_TEXT_REGULAR = 0,
  OSGFX_TEXT_MEDIUM = 1
};

int osgfx_text(OsGfx *g, int x, int y, const char *s, int n, int size_px,
               int weight, uint32_t rgb);
/* Same advance osgfx_text would consume. No painting. */
int osgfx_text_width(const char *s, int n, int size_px, int weight);
/* Ascent-to-descent box height for size_px, and the baseline inside it. */
int osgfx_text_box_h(int size_px);
int osgfx_text_baseline(int size_px);
/* Centre a cap-height run vertically in a box of height h. */
int osgfx_text_center_y(int box_y, int box_h, int size_px);
/* 16-byte document icon in .rodata. Not a String. Not a letter. */
const uint8_t *osgfx_icon_rows(void);
void osgfx_fill_rrect_vgrad(OsGfx *g, int x, int y, int w, int h, int radius,
                            uint32_t top, uint32_t bot);
void osgfx_shadow(OsGfx *g, int x, int y, int w, int h, int radius, int blur,
                  uint32_t rgb);

/* Rasterise recorded commands. 0 = OSGFX_OK. */
int osgfx_flush(OsGfx *g);

/* Read 0x00RRGGBB. Returns pixel count, or -1. */
int osgfx_readback(OsGfx *g, uint32_t *out, int max_pixels);

int osgfx_ppm_write(OsGfx *g, const char *path);

/* ADR-0194: rasterise the 16x20 pointer sprite into [out] (ARGB premul). */
int osgfx_pointer_raster(uint32_t *out, int w, int h);

/* Present the last flush into a CAMetalLayer*. Null-safe no-op if layer is 0. */
int osgfx_present_layer(OsGfx *g, void *metal_layer);

/* 1 if this process linked Skia Graphite. 0 for CPU Skia / software. */
int osgfx_backend_graphite(void);

/* "graphite", "metal", "skia", or "software". Null-safe "none". */
const char *osgfx_backend_name(const OsGfx *g);

#ifdef __cplusplus
}
#endif

#endif
