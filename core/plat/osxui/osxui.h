/* core/plat/osxui/osxui.h — desktop widgets. Paint through osgfx.h only.
 *
 * A button is a rounded rect and a hit test. A panel is a label strip.
 * Labels call osgfx_fill_glyph (fill_rect per pixel). This is not Flutter,
 * not a second box toolkit,
 * not a syscall, not compositor policy (that is wm*). When Skia
 * replaces osgfx_sw.c the calls in osxui.c do not change.
 *
 * Host harnesses link an osgfx.h backend and sample a PPM.
 * The same osxui.c compiles for kernel.elf’s triple next to osgfx_sw.c.
 */

#ifndef OSXUI_ABI_H
#define OSXUI_ABI_H

#include "osgfx.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
  OSXUI_OK = 0,
  OSXUI_ERR = 1,
  /* One button. Not the whole scene — a full-surface fill cannot pass. */
  OSXUI_BTN_X = 352,
  OSXUI_BTN_Y = 276,
  OSXUI_BTN_W = 96,
  OSXUI_BTN_H = 48,
  OSXUI_BTN_R = 10,
  OSXUI_BTN_IDLE = 0x0020A060,
  OSXUI_BTN_HIT = 0x00E04090,
  /* Label strip. Colour tile; osxui_label paints the 8.3 stem on it. */
  OSXUI_PANEL_X = 352,
  OSXUI_PANEL_Y = 252,
  OSXUI_PANEL_W = 96,
  OSXUI_PANEL_H = 18,
  OSXUI_PANEL = 0x00E8E0D0,
  OSXUI_LABEL_PAD_X = 2,
  OSXUI_LABEL_PAD_Y = 1,
  /* Dark on the pearl strip. Distinct from PANEL / DESK / IDLE. */
  OSXUI_LABEL_FG = 0x00202830,
  /* Live Start pill. Same numbers as wmde.dart / wmchrome.dart. */
  OSXUI_START_W = 96,
  OSXUI_START_H = 36,
  OSXUI_START_R = 18,
  OSXUI_START = 0x00C87840,
  /* Reflection panel hex pid. Same numbers as wmde.dart. */
  OSXUI_REFL_W = 180,
  OSXUI_REFL_H = 80,
  OSXUI_REFL_X = OSGFX_W - 180,
  OSXUI_REFL_Y = OSGFX_H - OSGFX_CHROME_H - 80,
  OSXUI_REFL_BG = 0x00406080,
  OSXUI_REFL = 0x007090B0,
  OSXUI_REFL_FG = 0x00F0F8FF,
  OSXUI_REFL_PAD_X = 16,
  OSXUI_REFL_PAD_Y = 5,
  OSXUI_REFL_N = 8,
  /* FILES list icon. Cream on the per-name band. Not text. */
  OSXUI_ICON_PAD_X = 2,
  OSXUI_ICON_FG = 0x00F8F0E0,
  /* Glass islands (ADR-0197 / ADR-0198). */
  OSXUI_GLASS_FILL = 0x00F4F6FA,
  OSXUI_GLASS_TOP = 0x00FAFCFF,
  OSXUI_GLASS_HAIR = 0x00FFFFFF,
  OSXUI_GLASS_SHADOW = 0x00081018,
  OSXUI_ISLAND_R = 20
};

typedef struct OsxuiRect {
  int x;
  int y;
  int w;
  int h;
} OsxuiRect;

/* 1 if (px,py) is inside the AABB. 0 otherwise. Null-safe 0. */
int osxui_hit(const OsxuiRect *r, int px, int py);

/* Rounded button. Calls osgfx_fill_rrect only. */
void osxui_button(OsGfx *g, const OsxuiRect *r, int radius, uint32_t rgb);

/* Label strip. Calls osgfx_fill_rect only. */
void osxui_panel(OsGfx *g, const OsxuiRect *r, uint32_t rgb);

/* 8.3 (or shorter) caption. Calls osgfx_fill_glyph per character. */
void osxui_label(OsGfx *g, int x, int y, const char *text, int n, uint32_t rgb);

/* One document icon. Calls osgfx_fill_glyph with osgfx_icon_rows. */
void osxui_icon(OsGfx *g, int x, int y, uint32_t rgb);

/* Hex digits of [value], most significant first. Calls osxui_label. */
void osxui_hex(OsGfx *g, int x, int y, uint64_t value, int n, uint32_t rgb);

/* Scanout entry for the compositor. Packed u64s so @bare can call it.
 * Implemented in osgfx_glyph.c. Not a second toolkit. */
void osxui_label_fb(uint64_t fb, uint64_t pitch, uint64_t wh, uint64_t xy,
                    uint64_t text, uint64_t nrgb);

/* Scanout document icon. Packed wh/xy like label_fb. rgb is 0x00RRGGBB. */
void osxui_icon_fb(uint64_t fb, uint64_t pitch, uint64_t wh, uint64_t xy,
                   uint64_t rgb);

/* Scanout hex. Formats [value] then calls osxui_label_fb. Packed nrgb. */
void osxui_hex_fb(uint64_t fb, uint64_t pitch, uint64_t wh, uint64_t xy,
                  uint64_t value, uint64_t nrgb);

/* Scanout button. Calls osxui_button (null OsGfx). Packed: fwh=w<<32|h,
 * xy=x<<32|y, sz=w<<32|h, rrgb=radius<<32|rgb. Not a second toolkit. */
void osxui_button_fb(uint64_t fb, uint64_t pitch, uint64_t fwh, uint64_t xy,
                     uint64_t sz, uint64_t rrgb);

/* Scanout hook when osxui_button sees a null OsGfx. osxui_fb.c. */
void osxui_scan_button(const OsxuiRect *r, int radius, uint32_t rgb);

/* Frosted glass panel: elevation, light vgrad, hairline (ADR-0197). */
void osxui_glass(OsGfx *g, const OsxuiRect *r, int radius, uint32_t fill);

/* Dock / status island — glass with island radius. */
void osxui_island(OsGfx *g, const OsxuiRect *r);

#ifdef __cplusplus
}
#endif

#endif
