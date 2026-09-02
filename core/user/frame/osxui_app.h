/* core/user/frame/osxui_app.h — the APP half of the osxui SDK (ADR-0192).
 *
 * WHAT THIS IS
 * ---------------------------------------------------------------------------
 * The calls a freestanding FRAME program makes to get REAL antialiased Skia
 * shapes and REAL proportional TrueType outline text into its own shm. Every
 * one of them is `wmsurface` (23) with an op from osframe.h; there is no new
 * syscall and no new capability. The pixels are rasterised by `osgfx_text` /
 * `osgfx_fill_rrect*` in `osgfx_skia.cpp` — the same functions, on the same
 * Roboto `glyf` outlines, that paint the compositor's own chrome (ADR-0187).
 *
 * WHY IT IS A SYSCALL AND NOT A LIBRARY
 * ---------------------------------------------------------------------------
 * A scan converter is megabytes and needs a heap; a FRAME app is a 64KiB
 * freestanding ELF with neither. The alternative that was in the tree until
 * ADR-0192 was `osxui_label_fb` (osgfx_glyph.c): an 8x16 BITMAP CELL, one
 * fixed advance, which is why FILES' rows were paper stamps under a title bar
 * that was already a live outline. The image has exactly one rasteriser and
 * this is how an app reaches it.
 *
 * WHAT THIS IS NOT
 * ---------------------------------------------------------------------------
 * Not a widget tree, not a retained scene, not a second toolkit. There is no
 * layout, no event plumbing and no state here: each call is one draw into
 * pixels the client already owns, and the client still commits them itself.
 * The kit-shaped widget helpers live in core/plat/osxui/osxui.c for code that
 * links against osgfx.h directly.
 *
 * `osxui_app_text` cannot report a failure distinctly from a zero-width run;
 * both are 0. A refusal also prints `WM REFUSE C 17 OP ...` on COM1, which is
 * where a harness looks.
 */

#ifndef OSXUI_APP_H
#define OSXUI_APP_H

#include "osframe.h"

/* Descriptor words 2..7 under WM_OP_PAINT. The eight-word overlay is the one
 * in osframe.h; these are the names it carries for a paint, and they are
 * spelled out here so a reader does not have to map "H" onto "run length".
 *
 *   2  kind          WM_PAINT_*
 *   3  (x << 32) | y            pen origin / shape origin
 *   4  shape (w << 32) | (h << 16) | radius, or text (size_px << 32) | weight
 *   5  run length in bytes (text and measure only)
 *   6  colour, or the gradient's TOP colour
 *   7  gradient BOTTOM colour, or the run's pointer
 */
#define OSXUI_APP_KIND WM_DESC_X
#define OSXUI_APP_XY WM_DESC_Y
#define OSXUI_APP_SHAPE WM_DESC_W
#define OSXUI_APP_N WM_DESC_H
#define OSXUI_APP_C0 WM_DESC_STRIDE
#define OSXUI_APP_C1 WM_DESC_OFFSET

/* One descriptor per translation unit. FRAME programs are single-threaded and
 * do not re-enter their own paint, which is the same assumption every
 * `static u64 desc[8]` in core/user/frame already makes. */
static unsigned long osxui_app_desc[WM_DESC_WORDS] __attribute__((aligned(64)));

static inline unsigned long osxui_app_call(void) {
  unsigned long r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"(SYS_WMSURFACE), "D"((unsigned long)&osxui_app_desc[0])
                   : "memory");
  return r;
}

/* The live scanout, packed `(w << 32) | h`. 0 if the compositor refused. */
static inline unsigned long osxui_app_screen(void) {
  unsigned long r;
  osxui_app_desc[WM_DESC_OP] = WM_OP_SCREEN;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_SCREEN_RECT;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

/* The live window table. Byte i is slot i (WM_TASK_*); byte 4 is how many of
 * them a taskbar would list. 0 if the compositor refused. */
static inline unsigned long osxui_app_tasks(void) {
  unsigned long r;
  osxui_app_desc[WM_DESC_OP] = WM_OP_SCREEN;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_SCREEN_TASKS;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

/* Wallpaper cache key from the compositor state page, or 0 before generate. */
static inline unsigned long osxui_app_desk_key(void) {
  unsigned long r;
  osxui_app_desc[WM_DESC_OP] = WM_OP_SCREEN;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_SCREEN_DESK_KEY;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

static inline unsigned long osxui_app_task(unsigned long t, unsigned long i) {
  return (t >> (i * 8UL)) & 0xFFUL;
}

/* Packed 8-byte 8.3 stem of slot [i], or 0. */
static inline unsigned long osxui_app_name(unsigned long i) {
  unsigned long r;
  osxui_app_desc[WM_DESC_OP] = WM_OP_SCREEN;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_SCREEN_NAME;
  osxui_app_desc[OSXUI_APP_XY] = i;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

static inline unsigned long osxui_app_screen_w(void) {
  return osxui_app_screen() >> 32;
}

static inline unsigned long osxui_app_screen_h(void) {
  return osxui_app_screen() & 0xFFFFFFFFUL;
}

/* Antialiased rounded rectangle: SkCanvas::drawRRect on SkRRect::MakeRectXY
 * with setAntiAlias(true). radius 0 is a square fill. */
static inline void osxui_app_rrect(unsigned long h, unsigned long x,
                                   unsigned long y, unsigned long w,
                                   unsigned long ht, unsigned long radius,
                                   unsigned long rgb) {
  osxui_app_desc[WM_DESC_OP] = WM_OP_PAINT;
  osxui_app_desc[WM_DESC_HANDLE] = h;
  osxui_app_desc[OSXUI_APP_KIND] = WM_PAINT_RRECT;
  osxui_app_desc[OSXUI_APP_XY] = (x << 32) | y;
  osxui_app_desc[OSXUI_APP_SHAPE] = (w << 32) | (ht << 16) | radius;
  osxui_app_desc[OSXUI_APP_N] = 0;
  osxui_app_desc[OSXUI_APP_C0] = rgb;
  osxui_app_desc[OSXUI_APP_C1] = 0;
  (void)osxui_app_call();
}

/* Vertical linear gradient through SkShaders::LinearGradient. At radius 0 the
 * OS may serve this out of its cached taskbar band (ADR-0189 §5); the pixels
 * are the same pixels either way, because it is the same draw call. */
static inline void osxui_app_vgrad(unsigned long h, unsigned long x,
                                   unsigned long y, unsigned long w,
                                   unsigned long ht, unsigned long radius,
                                   unsigned long top, unsigned long bot) {
  osxui_app_desc[WM_DESC_OP] = WM_OP_PAINT;
  osxui_app_desc[WM_DESC_HANDLE] = h;
  osxui_app_desc[OSXUI_APP_KIND] = WM_PAINT_VGRAD;
  osxui_app_desc[OSXUI_APP_XY] = (x << 32) | y;
  osxui_app_desc[OSXUI_APP_SHAPE] = (w << 32) | (ht << 16) | radius;
  osxui_app_desc[OSXUI_APP_N] = 0;
  osxui_app_desc[OSXUI_APP_C0] = top;
  osxui_app_desc[OSXUI_APP_C1] = bot;
  (void)osxui_app_call();
}

/* Material elevation: SkMaskFilter::MakeBlur on an AA rrect, clipped to
 * outside the shape so it never washes over the caller's own fill. */
static inline void osxui_app_elevate(unsigned long h, unsigned long x,
                                     unsigned long y, unsigned long w,
                                     unsigned long ht, unsigned long radius,
                                     unsigned long rgb) {
  osxui_app_desc[WM_DESC_OP] = WM_OP_PAINT;
  osxui_app_desc[WM_DESC_HANDLE] = h;
  osxui_app_desc[OSXUI_APP_KIND] = WM_PAINT_ELEVATE;
  osxui_app_desc[OSXUI_APP_XY] = (x << 32) | y;
  osxui_app_desc[OSXUI_APP_SHAPE] = (w << 32) | (ht << 16) | radius;
  osxui_app_desc[OSXUI_APP_N] = 0;
  osxui_app_desc[OSXUI_APP_C0] = rgb;
  osxui_app_desc[OSXUI_APP_C1] = 0;
  (void)osxui_app_call();
}

/* Measure a run without painting it. Packed:
 *   bits  0..31  advance in pixels — NOT `8 * n`, the sum of the face's real
 *                `hmtx` advances scaled to [size_px]
 *   bits 32..47  cap height at this size
 *   bits 48..63  ascent at this size
 * The two metrics are here so a caller can put a caption on the same optical
 * centre `osgfx_text_center_y` puts chrome's on. 0 on refusal. */
static inline unsigned long osxui_app_measure(const char *text, unsigned long n,
                                              unsigned long size_px,
                                              unsigned long weight) {
  unsigned long r;
  if (n > WM_TEXT_MAX) {
    n = WM_TEXT_MAX;
  }
  osxui_app_desc[WM_DESC_OP] = WM_OP_PAINT;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_PAINT_MEASURE;
  osxui_app_desc[OSXUI_APP_XY] = 0;
  osxui_app_desc[OSXUI_APP_SHAPE] = (size_px << 32) | weight;
  osxui_app_desc[OSXUI_APP_N] = n;
  osxui_app_desc[OSXUI_APP_C0] = 0;
  osxui_app_desc[OSXUI_APP_C1] = (unsigned long)text;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

#define OSXUI_APP_ADV(m) ((m) & 0xFFFFFFFFUL)
#define OSXUI_APP_CAP(m) (((m) >> 32) & 0xFFFFUL)
#define OSXUI_APP_ASC(m) (((m) >> 48) & 0xFFFFUL)

/* Advance only, for callers that are left-aligning. */
static inline unsigned long osxui_app_text_width(const char *text,
                                                 unsigned long n,
                                                 unsigned long size_px,
                                                 unsigned long weight) {
  return OSXUI_APP_ADV(osxui_app_measure(text, n, size_px, weight));
}

/* One run of real TrueType outlines, filled by SkCanvas::drawPath with AA.
 * ([x], [y]) is the top-left of the em box, as osgfx_text means it. Returns
 * the advance actually laid down. */
static inline unsigned long osxui_app_text(unsigned long h, unsigned long x,
                                           unsigned long y, const char *text,
                                           unsigned long n,
                                           unsigned long size_px,
                                           unsigned long weight,
                                           unsigned long rgb) {
  unsigned long r;
  if (n > WM_TEXT_MAX) {
    n = WM_TEXT_MAX;
  }
  osxui_app_desc[WM_DESC_OP] = WM_OP_PAINT;
  osxui_app_desc[WM_DESC_HANDLE] = h;
  osxui_app_desc[OSXUI_APP_KIND] = WM_PAINT_TEXT;
  osxui_app_desc[OSXUI_APP_XY] = (x << 32) | y;
  osxui_app_desc[OSXUI_APP_SHAPE] = (size_px << 32) | weight;
  osxui_app_desc[OSXUI_APP_N] = n;
  osxui_app_desc[OSXUI_APP_C0] = rgb;
  osxui_app_desc[OSXUI_APP_C1] = (unsigned long)text;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

/* A caption centred in a box, on exactly the centre chrome uses: the CAP box
 * centred in the control, not the em box, which is what stops a label with no
 * descenders from sitting visibly high. This is `osgfx_text_center_y`'s
 * arithmetic, done here from the metrics the measure call returned. */
static inline unsigned long osxui_app_label_box(
    unsigned long h, unsigned long bx, unsigned long by, unsigned long bw,
    unsigned long bh, const char *text, unsigned long n, unsigned long size_px,
    unsigned long weight, unsigned long rgb) {
  const unsigned long m = osxui_app_measure(text, n, size_px, weight);
  const unsigned long tw = OSXUI_APP_ADV(m);
  const long cap = (long)OSXUI_APP_CAP(m);
  const long asc = (long)OSXUI_APP_ASC(m);
  unsigned long x = bx;
  long y = (long)by;
  if (bw > tw) {
    x = bx + ((bw - tw) / 2);
  }
  if ((long)bh > cap) {
    y = (long)by + ((long)bh - cap) / 2 + cap - asc;
  }
  if (y < (long)by) {
    /* An ascent taller than the control: clamp rather than paint above it. */
    if (y < 0) {
      y = 0;
    }
  }
  return osxui_app_text(h, x, (unsigned long)y, text, n, size_px, weight, rgb);
}

/* Popover kind<<48 | x<<32 | y. 0 when nothing is showing. */
static inline unsigned long osxui_app_pop(void) {
  unsigned long r;
  osxui_app_desc[WM_DESC_OP] = WM_OP_SCREEN;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_SCREEN_POP;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

#define OSXUI_POP_KIND(p) (((p) >> 48) & 0xFFUL)
#define OSXUI_POP_X(p) (((p) >> 32) & 0xFFFFUL)
#define OSXUI_POP_Y(p) ((p) & 0xFFFFUL)

static inline unsigned long osxui_app_launch(unsigned long i) {
  unsigned long r;
  osxui_app_desc[WM_DESC_OP] = WM_OP_SCREEN;
  osxui_app_desc[WM_DESC_HANDLE] = 0;
  osxui_app_desc[OSXUI_APP_KIND] = WM_SCREEN_LAUNCH;
  osxui_app_desc[OSXUI_APP_XY] = i;
  r = osxui_app_call();
  if (r >= WM_RET_FLOOR) {
    return 0;
  }
  return r;
}

static inline void osxui_app_move(unsigned long h, unsigned long x,
                                  unsigned long y) {
  osxui_app_desc[WM_DESC_OP] = WM_OP_MOVE;
  osxui_app_desc[WM_DESC_HANDLE] = h;
  osxui_app_desc[WM_DESC_X] = x;
  osxui_app_desc[WM_DESC_Y] = y;
  osxui_app_desc[WM_DESC_W] = 0;
  osxui_app_desc[WM_DESC_H] = 0;
  osxui_app_desc[WM_DESC_STRIDE] = 0;
  osxui_app_desc[WM_DESC_OFFSET] = 0;
  (void)osxui_app_call();
}

/* Glass language (ADR-0197 / ADR-0198). Frost samples wallpaper + blur +
 * tint. Window CSD radius matches the compositor card (OSGFX_RADIUS).
 * Dock islands use OSXUI_ISLAND_R. */
#define OSXUI_GLASS_FILL 0x00F4F6FAUL
#define OSXUI_GLASS_TOP 0x00FAFCFFUL
#define OSXUI_GLASS_HAIR 0x00FFFFFFUL
#define OSXUI_GLASS_FG 0x00202830UL
#define OSXUI_GLASS_FG_MUTED 0x00506070UL
#define OSXUI_GLASS_SHADOW 0x00081018UL
#define OSXUI_ICON_TILE 0x00F8FAFCUL
#define OSXUI_GLASS_R 18UL
#define OSXUI_ISLAND_R 20UL
#define OSXUI_ICON_R 10UL
#define OSXUI_CSD_H 32UL
#define OSXUI_CSD_R 18UL
#define OSXUI_CSD_TOP OSXUI_GLASS_TOP
#define OSXUI_CSD_BOT 0x00E8EEF4UL
#define OSXUI_CSD_FG OSXUI_GLASS_FG
/* Mockup: thin dark line icons — not traffic-light discs. */
#define OSXUI_CSD_ICON 0x00202830UL
#define OSXUI_CSD_BTN 16UL
#define OSXUI_CSD_GAP 10UL
#define OSXUI_CSD_PAD 8UL

static inline void osxui_app_glass(unsigned long h, unsigned long x,
                                   unsigned long y, unsigned long w,
                                   unsigned long ht, unsigned long radius) {
  unsigned long r = radius;
  if (r < 1UL) {
    r = OSXUI_GLASS_R;
  }
  /* One frost paint: wallpaper sample + blur + tint into shm. */
  osxui_app_desc[WM_DESC_OP] = WM_OP_PAINT;
  osxui_app_desc[WM_DESC_HANDLE] = h;
  osxui_app_desc[OSXUI_APP_KIND] = WM_PAINT_GLASS;
  osxui_app_desc[OSXUI_APP_XY] = (x << 32) | y;
  osxui_app_desc[OSXUI_APP_SHAPE] = (w << 32) | (ht << 16) | r;
  osxui_app_desc[OSXUI_APP_N] = 0;
  osxui_app_desc[OSXUI_APP_C0] = OSXUI_GLASS_FILL;
  osxui_app_desc[OSXUI_APP_C1] = 0;
  (void)osxui_app_call();
}

static inline void osxui_app_island(unsigned long h, unsigned long x,
                                    unsigned long y, unsigned long w,
                                    unsigned long ht) {
  osxui_app_glass(h, x, y, w, ht, OSXUI_ISLAND_R);
  osxui_app_rrect(h, x + 2, y + 1, w - 4, 1, 1, OSXUI_GLASS_HAIR);
}

static inline void osxui_app_island_shadow(unsigned long h, unsigned long x,
                                           unsigned long y, unsigned long w,
                                           unsigned long ht) {
  osxui_app_elevate(h, x + 1, y + 2, w, ht, OSXUI_ISLAND_R, OSXUI_GLASS_SHADOW);
}

static inline void osxui_app_icon_btn(unsigned long h, unsigned long x,
                                      unsigned long y, unsigned long s,
                                      unsigned long rgb) {
  osxui_app_rrect(h, x, y, s, s, OSXUI_ICON_R, rgb);
}

static inline void osxui_app_icon_tile(unsigned long h, unsigned long x,
                                       unsigned long y, unsigned long s) {
  osxui_app_elevate(h, x, y + 2, s, s, OSXUI_ICON_R, OSXUI_GLASS_SHADOW);
  osxui_app_icon_btn(h, x, y, s, OSXUI_ICON_TILE);
}

static inline void osxui_app_clock(unsigned long h, unsigned long x,
                                   unsigned long y, const char *text,
                                   unsigned long n) {
  osxui_app_label_box(h, x, y, 120, 16, text, n, WM_TEXT_LABEL_PX,
                      WM_TEXT_MEDIUM, OSXUI_GLASS_FG);
}

static inline void osxui_app_chrome_min(unsigned long h, unsigned long x,
                                        unsigned long y) {
  osxui_app_rrect(h, x + 3UL, y + OSXUI_CSD_BTN / 2UL - 1UL,
                  OSXUI_CSD_BTN - 6UL, 2UL, 1UL, OSXUI_CSD_ICON);
}

static inline void osxui_app_chrome_max(unsigned long h, unsigned long x,
                                        unsigned long y) {
  osxui_app_rrect(h, x + 3UL, y + 3UL, OSXUI_CSD_BTN - 6UL, 2UL, 1UL,
                  OSXUI_CSD_ICON);
  osxui_app_rrect(h, x + 3UL, y + OSXUI_CSD_BTN - 5UL, OSXUI_CSD_BTN - 6UL, 2UL,
                  1UL, OSXUI_CSD_ICON);
  osxui_app_rrect(h, x + 3UL, y + 3UL, 2UL, OSXUI_CSD_BTN - 6UL, 1UL,
                  OSXUI_CSD_ICON);
  osxui_app_rrect(h, x + OSXUI_CSD_BTN - 5UL, y + 3UL, 2UL, OSXUI_CSD_BTN - 6UL,
                  1UL, OSXUI_CSD_ICON);
}

static inline void osxui_app_chrome_close(unsigned long h, unsigned long x,
                                          unsigned long y) {
  osxui_app_text(h, x + 4UL, y + 1UL, "x", 1UL, WM_TEXT_TITLE_PX,
                 WM_TEXT_MEDIUM, OSXUI_CSD_ICON);
}

static inline void osxui_app_csd(unsigned long h, unsigned long win_w,
                                 const char *cap, unsigned long ncap) {
  unsigned long cx;
  unsigned long mx;
  unsigned long xx;
  /* Glass CSD: light frost + hairline. Radius matches the compositor
   * card so corners stay one outline (ADR-0196). */
  osxui_app_vgrad(h, 0, 0, win_w, OSXUI_CSD_H, OSXUI_CSD_R, OSXUI_CSD_TOP,
                  OSXUI_CSD_BOT);
  osxui_app_rrect(h, 2UL, 1UL, win_w - 4UL, 2UL, 1UL, OSXUI_GLASS_HAIR);
  osxui_app_rrect(h, 0, OSXUI_CSD_H - 1UL, win_w, 1, 0, 0x00C8D0D8UL);
  cx = win_w - OSXUI_CSD_GAP - OSXUI_CSD_BTN;
  mx = cx - OSXUI_CSD_GAP - OSXUI_CSD_BTN;
  xx = mx - OSXUI_CSD_GAP - OSXUI_CSD_BTN;
  osxui_app_chrome_max(h, xx, OSXUI_CSD_PAD);
  osxui_app_chrome_min(h, mx, OSXUI_CSD_PAD);
  osxui_app_chrome_close(h, cx, OSXUI_CSD_PAD);
  if (cap != 0 && ncap > 0) {
    osxui_app_text(h, 16UL, 9UL, cap, ncap, WM_TEXT_TITLE_PX, WM_TEXT_MEDIUM,
                   OSXUI_CSD_FG);
  }
}

#define OSXUI_MENU_BG 0x00F0F4F8UL
#define OSXUI_MENU_ROW0 0x00304878UL
#define OSXUI_MENU_ROW1 0x00283868UL
#define OSXUI_MENU_FG 0x00F0F8FFUL
#define OSXUI_MENU_ROW_H 24UL
#define OSXUI_MENU_PAD 4UL
#define OSXUI_MENU_R 8UL

static inline void osxui_app_menu_row(unsigned long h, unsigned long w,
                                      unsigned long row, unsigned long rgb,
                                      const char *lab, unsigned long n) {
  unsigned long ry = OSXUI_MENU_PAD + row * OSXUI_MENU_ROW_H;
  osxui_app_rrect(h, 4UL, ry, w - 8UL, OSXUI_MENU_ROW_H - 2UL, 4UL, rgb);
  osxui_app_text(h, 8UL, ry + 4UL, lab, n, WM_TEXT_LABEL_PX, WM_TEXT_REGULAR,
                 OSXUI_MENU_FG);
}

static inline void osxui_app_menu_card(unsigned long h, unsigned long w,
                                       unsigned long ht) {
  osxui_app_elevate(h, 2UL, 4UL, w - 2UL, ht - 4UL, OSXUI_MENU_R, 0x00081018UL);
  osxui_app_rrect(h, 0, 0, w, ht, OSXUI_MENU_R, OSXUI_MENU_BG);
}

#endif /* OSXUI_APP_H */
