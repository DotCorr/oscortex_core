/* Sit-in session tick. Same compositor policy as osgfx_scene_compose
 * plus DE widgets via osxui_button → osgfx_fill_rrect.
 *
 * Every shape here is a real Skia draw: SkCanvas::drawRRect on an
 * SkRRect::MakeRectXY with antialiasing on, SkShaders::LinearGradient for
 * the taskbar, SkMaskFilter blur for elevation. Every label here is a real
 * proportional TrueType outline rasterised live by SkCanvas::drawPath
 * (osgfx_text / osgfx_font.h). There are no 8x16 glyph cells and no
 * hand-rolled coverage stamps left on this path (ADR-0187).
 */
#include "osgfx_session.h"

#include "osgfx_font.h"
#include "osxui.h"

#include <stdint.h>

extern void com1_puts(const char *s);
extern struct OsGfxGuestCmd osgfx_guest_cmd;

/* DE geometry — keep in lockstep with wmde.dart / osxui.h / wmchrome.dart. */
enum {
  SESS_START_W = 96,
  SESS_START_H = 36,
  SESS_START_R = 18,
  SESS_START_MX = 8,
  SESS_START_MY = 6,
  SESS_START = 0x00C87840,
  SESS_NOTE_W = 64,
  SESS_NOTE_H = 36,
  SESS_NOTE = 0x0038A070,
  SESS_SLOT_W = 100,
  SESS_SLOT_H = 36,
  SESS_SLOT_R = 12,
  SESS_SLOT0 = 0x00586878,
  SESS_SLOT1 = 0x00485868,
  SESS_BTN_S = 18,
  SESS_BTN_R = 9,
  SESS_BTN_GAP = 8,
  SESS_BTN_PAD_Y = 7,
  SESS_CLOSE = 0x00D45050,
  SESS_MIN = 0x00D4A840,
  SESS_MAX = 0x0068B078,
  SESS_CLOSE_HI = 0x00F0A0A0,
  SESS_MIN_HI = 0x00F0D080,
  SESS_POP_ROW0 = 0x00FFFFFF,
  SESS_POP_ROW1 = 0x00EEF2F6,
  SESS_POP_HOVER = 0x00D0E4F8,
  SESS_POP_DISABLED = 0x0090A0B0,
  SESS_POP_EDGE = 0x00C8D0D8,
  SESS_POP_FG = 0x00202830,
  SESS_POP_ROW_PAD = 8,
  SESS_POP_ROW_H = 28,
  SESS_POP_LAB_X = 8,
  SESS_POP_LAB_Y = 4,
  SESS_TITLE_BAND = 32,
  SESS_TITLE_TOP = 0x00F4F0E8,
  SESS_CHROME_TOP = 0x00485868,
  SESS_CHROME_BOT = 0x00283040,
  SESS_START_PAD_X = 28,
  SESS_START_PAD_Y = 10,
  SESS_SLOT_PAD_X = 16,
  SESS_SLOT_PAD_Y = 10,
  SESS_TITLE_PAD_X = 14,
  SESS_TITLE_PAD_Y = 8,
  SESS_LABEL_FG = 0x00F4F0E8,
  SESS_TITLE_FG = 0x00202830,
  SESS_SHADOW = 0x00081018,
  /* Traffic-light rim: one shade down from the fill, so the disc reads as
   * a control instead of a flat dot. Skia AA does the edge. */
  SESS_CLOSE_RIM = 0x00A03A3A,
  SESS_MIN_RIM = 0x00A87C28,
  SESS_MAX_RIM = 0x00487850
};

const char osgfx_session_door[] = "osgfx-session-tick";
const char osgfx_session_chrome_door[] = "osgfx-session-chrome";

static int chrome_noted;
static int title_noted;
static int held0_noted;
/* Geom-only max/restore: skip the 18px CPU shadow ring. Title slices
 * plus a 2px border patch the new rect; unchanged windows stay in cache. */
static int g_geom_no_shadow;

static void unpack_geom(uint64_t g, int *x, int *y, int *w, int *h) {
  *x = (int)((g >> 48) & 0xffffu);
  *y = (int)((g >> 32) & 0xffffu);
  *w = (int)((g >> 16) & 0xffffu);
  *h = (int)(g & 0xffffu);
}

/* Soft drop shadow — osgfx_shadow alpha-blends expanding rings.
 * A maximized 1280×672 ring at blur 18 is the 583-tick TCG stall. Skip
 * when the window is large enough that the shadow falls off-screen or
 * the blur would dominate a raise/max interaction. */
static int skip_soft_shadow(int x, int y, int w, int h, int fb_w, int fb_h) {
  long area;

  if (g_geom_no_shadow != 0) {
    return 1;
  }
  if (w < 1 || h < 1) {
    return 1;
  }
  area = (long)w * (long)h;
  if (area > 360000L) {
    return 1;
  }
  if (fb_w > 0 && fb_h > 0) {
    if (x <= 16 && y <= 16) {
      if ((x + w) >= (fb_w - 16)) {
        if ((y + h) >= (fb_h - OSGFX_CHROME_H - 16)) {
          return 1;
        }
      }
    }
  }
  return 0;
}

static void paint_soft_shadow(OsGfx *g, int x, int y, int w, int h, int r) {
  if (g == 0) {
    return;
  }
  osgfx_shadow(g, x + 6, y + 10, w, h, r, 18, SESS_SHADOW);
}

/* Mid-span sides only. An AABB through the curve stamped OSGFX_FOCUS
 * (near-white) onto wallpaper and read as corner teeth. Corner pixels
 * are the coverage difference of the outer vs inner rrect. */
static void paint_border_corner(OsGfx *g, int x0, int y0, int x1, int y1, int wx,
                                int wy, int ww, int wh, int r, int b,
                                uint32_t border) {
  int xx;
  int yy;
  int cov;
  int cov_o;
  int cov_i;
  int orad;

  orad = r + b;
  yy = y0;
  while (yy < y1) {
    xx = x0;
    while (xx < x1) {
      cov_o = osgfx_rrect_cover(xx, yy, wx - b, wy - b, ww + b + b, wh + b + b,
                                orad);
      cov_i = osgfx_rrect_cover(xx, yy, wx, wy, ww, wh, r);
      cov = cov_o - cov_i;
      if (cov > 255) {
        cov = 255;
      }
      if (cov > 0) {
        osgfx_blend_px(g, xx, yy, border, (uint8_t)cov);
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static void paint_window_borders(OsGfx *g, uint64_t geom, uint32_t border) {
  int x;
  int y;
  int w;
  int h;
  int b;
  int r;
  int mid_w;
  int mid_h;

  if (g == 0 || geom == 0) {
    return;
  }
  unpack_geom(geom, &x, &y, &w, &h);
  if (w < 8 || h < 8) {
    return;
  }
  if (h <= OSGFX_CHROME_H + 4) {
    return;
  }
  b = OSGFX_BORDER;
  r = OSGFX_RADIUS;
  if (r + r > w) {
    r = w / 2;
  }
  if (r + r > h) {
    r = h / 2;
  }
  mid_w = w - r - r;
  mid_h = h - r - r;
  if (mid_w > 0) {
    osgfx_fill_rect(g, x + r, y - b, mid_w, b, border);
    osgfx_fill_rect(g, x + r, y + h, mid_w, b, border);
  }
  if (mid_h > 0) {
    osgfx_fill_rect(g, x - b, y + r, b, mid_h, border);
    osgfx_fill_rect(g, x + w, y + r, b, mid_h, border);
  }
  paint_border_corner(g, x - b, y - b, x + r + 1, y + r + 1, x, y, w, h, r, b,
                      border);
  paint_border_corner(g, x + w - r - 1, y - b, x + w + b, y + r + 1, x, y, w, h,
                      r, b, border);
  paint_border_corner(g, x - b, y + h - r - 1, x + r + 1, y + h + b, x, y, w, h,
                      r, b, border);
  paint_border_corner(g, x + w - r - 1, y + h - r - 1, x + w + b, y + h + b, x, y,
                      w, h, r, b, border);
}

/* ADR-0183: frame + title band only — never fill the client body.
 * Body pixels come from wmDrawWindow blit of FRAME shm. */
/* Reusable title 9-patch: Skia rrect-vgrad once, then blit caps + mid. */
enum { TITLE_SLICE_CAP = 24, TITLE_SLICE_MID = 8, TITLE_SLICE_H = 32 };
static uint32_t title_l[TITLE_SLICE_CAP * TITLE_SLICE_H];
static uint32_t title_m[TITLE_SLICE_MID * TITLE_SLICE_H];
static uint32_t title_r[TITLE_SLICE_CAP * TITLE_SLICE_H];
static int title_slices_ready;
static int title_slice_th;
static int title_slice_r;
static uint32_t title_slice_top;
static uint32_t title_slice_bot;

static uint32_t *title_px(uint32_t *fb, int pitch, int x, int y) {
  return (uint32_t *)((uint8_t *)fb + (unsigned)y * (unsigned)pitch) + x;
}

static void title_capture_slices(uint32_t *fb, int pitch, int x, int y, int w,
                                 int th, int r, uint32_t top, uint32_t bot) {
  int yy;
  int xx;
  uint32_t *row;

  if (fb == 0 || w < TITLE_SLICE_CAP * 2 + TITLE_SLICE_MID || th != TITLE_SLICE_H) {
    return;
  }
  yy = 0;
  while (yy < th) {
    row = title_px(fb, pitch, x, y + yy);
    xx = 0;
    while (xx < TITLE_SLICE_CAP) {
      title_l[yy * TITLE_SLICE_CAP + xx] = row[xx];
      title_r[yy * TITLE_SLICE_CAP + xx] = row[w - TITLE_SLICE_CAP + xx];
      xx = xx + 1;
    }
    xx = 0;
    while (xx < TITLE_SLICE_MID) {
      title_m[yy * TITLE_SLICE_MID + xx] = row[TITLE_SLICE_CAP + xx];
      xx = xx + 1;
    }
    yy = yy + 1;
  }
  {
    uint32_t mid = title_m[(th / 2) * TITLE_SLICE_MID + (TITLE_SLICE_MID / 2)];
    unsigned mr = (unsigned)((mid >> 16) & 0xffu);
    unsigned mg = (unsigned)((mid >> 8) & 0xffu);
    /* Pearl title is warm grey. Wallpaper teal in the 9-patch would
     * stamp a hole on every later width. */
    if (mr < 160u || mg < 150u) {
      title_slices_ready = 0;
      return;
    }
  }
  title_slices_ready = 1;
  title_slice_th = th;
  title_slice_r = r;
  title_slice_top = top;
  title_slice_bot = bot;
}

static int title_blit_slices(uint32_t *fb, int pitch, int x, int y, int w, int th,
                             int r, uint32_t top, uint32_t bot) {
  int yy;
  int xx;
  int mid;
  uint32_t *row;
  uint32_t px;

  if (title_slices_ready == 0 || fb == 0) {
    return 0;
  }
  if (th != title_slice_th || r != title_slice_r) {
    return 0;
  }
  if (top != title_slice_top || bot != title_slice_bot) {
    return 0;
  }
  if (w < TITLE_SLICE_CAP * 2 + TITLE_SLICE_MID) {
    return 0;
  }
  mid = w - TITLE_SLICE_CAP * 2;
  yy = 0;
  while (yy < th) {
    row = title_px(fb, pitch, x, y + yy);
    xx = 0;
    while (xx < TITLE_SLICE_CAP) {
      row[xx] = title_l[yy * TITLE_SLICE_CAP + xx];
      row[w - TITLE_SLICE_CAP + xx] = title_r[yy * TITLE_SLICE_CAP + xx];
      xx = xx + 1;
    }
    xx = 0;
    while (xx < mid) {
      px = title_m[yy * TITLE_SLICE_MID + (xx % TITLE_SLICE_MID)];
      row[TITLE_SLICE_CAP + xx] = px;
      xx = xx + 1;
    }
    yy = yy + 1;
  }
  return 1;
}

static void paint_window_chrome(OsGfx *g, uint32_t *fb, int pitch, uint64_t geom,
                                uint32_t border, uint32_t fill, int fb_w,
                                int fb_h) {
  int x;
  int y;
  int w;
  int h;
  int r;
  int th;
  int sliced;

  (void)fill;
  if (geom == 0) {
    return;
  }
  unpack_geom(geom, &x, &y, &w, &h);
  if (w < 8 || h < 8) {
    return;
  }
  /* Desk strip (taskbar surface) — no window chrome. */
  if (h <= OSGFX_CHROME_H + 4) {
    return;
  }
  r = OSGFX_RADIUS;
  th = SESS_TITLE_BAND;
  if (th > h) {
    th = h;
  }
  if (skip_soft_shadow(x, y, w, h, fb_w, fb_h) == 0) {
    paint_soft_shadow(g, x, y, w, h, r);
  }
  sliced = title_blit_slices(fb, pitch, x, y, w, th, r, SESS_TITLE_TOP,
                             OSGFX_TITLE);
  if (sliced == 0) {
    /* OSGFX_CORNER_TL / OSGFX_CORNER_TR — top pearl pair closes the AA card
     * radius when CSD withdraws the session title band (ADR-0196). */
    if (r > 0) {
      osgfx_fill_rrect(g, x, y, r, r, r, OSGFX_TITLE);
      osgfx_fill_rrect(g, x + w - r, y, r, r, r, OSGFX_TITLE);
    }
    /* Pearl title chrome is a real vertical ramp. First paint of this
     * (th, r, colours) captures 9-patch slices for later widths. */
    osgfx_fill_rrect_vgrad(g, x, y, w, th, r, SESS_TITLE_TOP, OSGFX_TITLE);
    osgfx_flush(g);
    title_capture_slices(fb, pitch, x, y, w, th, r, SESS_TITLE_TOP, OSGFX_TITLE);
  }
  if (fb != 0 && w > 8 && th > 2) {
    uint32_t probe = title_px(fb, pitch, x + (w / 2), y + (th / 2))[0];
    if (((probe >> 16) & 0xffu) < 160u) {
      int yy;
      int xx;
      /* Skia missed the cache after a bump rewind. Write pearl
       * directly so compose does not present a wallpaper title hole. */
      yy = 0;
      while (yy < th) {
        uint32_t *row = title_px(fb, pitch, x, y + yy);
        xx = 0;
        while (xx < w) {
          row[xx] = SESS_TITLE_TOP;
          xx = xx + 1;
        }
        yy = yy + 1;
      }
    }
  }
  /* Border ring only — do not paint OSGFX_WIN_FILL over client shm. */
  paint_window_borders(g, geom, border);
}

/* Live OsGfx path — osxui_button → osgfx_fill_rrect (Graphite when armed). */
static void paint_de_button(OsGfx *g, uint32_t *fb, int pitch, int ww, int hh,
                            int x, int y, int w, int h, int radius,
                            uint32_t rgb) {
  OsxuiRect r;

  r.x = x;
  r.y = y;
  r.w = w;
  r.h = h;
  if (g != 0) {
    osxui_button(g, &r, radius, rgb);
    return;
  }
  if (fb == 0) {
    return;
  }
  {
    uint64_t fwh;
    uint64_t xy;
    uint64_t sz;
    uint64_t rrgb;
    fwh = ((uint64_t)(unsigned)ww << 32) | (unsigned)hh;
    xy = ((uint64_t)(unsigned)x << 32) | (unsigned)y;
    sz = ((uint64_t)(unsigned)w << 32) | (unsigned)h;
    rrgb = ((uint64_t)(unsigned)radius << 32) | (unsigned)rgb;
    osxui_button_fb((uint64_t)(uintptr_t)fb, (uint64_t)pitch, fwh, xy, sz, rrgb);
  }
}

static int win_close_x(int wx, int ww) {
  return wx + ww - SESS_BTN_GAP - SESS_BTN_S;
}

static int win_min_x(int wx, int ww) {
  return win_close_x(wx, ww) - SESS_BTN_GAP - SESS_BTN_S;
}

static int win_max_x(int wx, int ww) {
  return win_min_x(wx, ww) - SESS_BTN_GAP - SESS_BTN_S;
}

static int win_btn_y(int wy) {
  return wy + SESS_BTN_PAD_Y;
}

/* Centre a real-outline run in a box: Skia drawPath, cap-height centred,
 * proportional advance. Falls back to the packed scanout label only when
 * there is no OsGfx at all (no Skia canvas to draw a path into). */
static void paint_text_box(OsGfx *g, uint32_t *fb, int pitch, int ww, int hh,
                           int box_x, int box_y, int box_w, int box_h,
                           const char *text, int n, int size_px, int weight,
                           uint32_t rgb) {
  int tw;
  int tx;
  int ty;

  if (text == 0 || n < 1) {
    return;
  }
  if (g != 0) {
    tw = osgfx_text_width(text, n, size_px, weight);
    tx = box_x + (box_w - tw) / 2;
    if (tx < box_x) {
      tx = box_x;
    }
    ty = osgfx_text_center_y(box_y, box_h, size_px);
    osgfx_text(g, tx, ty, text, n, size_px, weight, rgb);
    return;
  }
  if (fb == 0) {
    return;
  }
  {
    uint64_t fwh;
    uint64_t xy;
    fwh = ((uint64_t)(unsigned)ww << 32) | (unsigned)hh;
    xy = ((uint64_t)(unsigned)(box_x + 4) << 32) | (unsigned)(box_y + 10);
    osxui_label_fb((uint64_t)(uintptr_t)fb, (uint64_t)pitch, fwh, xy,
                   (uint64_t)(uintptr_t)text,
                   ((uint64_t)(unsigned)n << 32) | (uint64_t)rgb);
  }
}

/* Left-aligned real-outline run, vertically centred in a band. */
static void paint_text_left(OsGfx *g, uint32_t *fb, int pitch, int ww, int hh,
                            int x, int band_y, int band_h, const char *text,
                            int n, int size_px, int weight, uint32_t rgb) {
  if (text == 0 || n < 1) {
    return;
  }
  if (g != 0) {
    osgfx_text(g, x, osgfx_text_center_y(band_y, band_h, size_px), text, n,
               size_px, weight, rgb);
    return;
  }
  if (fb == 0) {
    return;
  }
  {
    uint64_t fwh;
    uint64_t xy;
    fwh = ((uint64_t)(unsigned)ww << 32) | (unsigned)hh;
    xy = ((uint64_t)(unsigned)x << 32) | (unsigned)(band_y + 8);
    osxui_label_fb((uint64_t)(uintptr_t)fb, (uint64_t)pitch, fwh, xy,
                   (uint64_t)(uintptr_t)text,
                   ((uint64_t)(unsigned)n << 32) | (uint64_t)rgb);
  }
}

/* Traffic-light control. radius == size/2, so Skia draws a true AA disc,
 * with a one-pixel darker rim under it instead of the old highlight blob
 * (which landed a second flat rectangle inside an 18px dot). */
static void paint_traffic(OsGfx *g, uint32_t *fb, int pitch, int ww, int hh,
                          int x, int y, uint32_t fill, uint32_t rim) {
  paint_de_button(g, fb, pitch, ww, hh, x, y, SESS_BTN_S, SESS_BTN_S,
                  SESS_BTN_S / 2, rim);
  paint_de_button(g, fb, pitch, ww, hh, x + 1, y + 1, SESS_BTN_S - 2,
                  SESS_BTN_S - 2, (SESS_BTN_S - 2) / 2, fill);
}

static int set_title_noted;

static void paint_de_title_controls(OsGfx *g, uint32_t *fb, int pitch, int ww,
                                    int hh, uint64_t geom, int cap_code) {
  int x;
  int y;
  int w;
  int h;
  int bx;
  int by;
  int i;
  const char *cap;
  int cap_n;

  if (geom == 0) {
    return;
  }
  unpack_geom(geom, &x, &y, &w, &h);
  if (w < 8 || h < 8) {
    return;
  }
  by = win_btn_y(y);
  bx = win_max_x(x, w);
  paint_traffic(g, fb, pitch, ww, hh, bx, by, SESS_MAX, SESS_MAX_RIM);
  bx = win_min_x(x, w);
  paint_traffic(g, fb, pitch, ww, hh, bx, by, SESS_MIN, SESS_MIN_RIM);
  bx = win_close_x(x, w);
  paint_traffic(g, fb, pitch, ww, hh, bx, by, SESS_CLOSE, SESS_CLOSE_RIM);
  if (title_noted == 0) {
    title_noted = 1;
    com1_puts("OSGFX TITLE CLOSE\n");
  }
  cap = "FILES";
  cap_n = 5;
  if (cap_code == 2) {
    cap = "SET";
    cap_n = 3;
    if (set_title_noted == 0) {
      set_title_noted = 1;
      com1_puts("OSGFX TITLE SET\n");
    }
  }
  i = SESS_TITLE_BAND;
  if (i > h) {
    i = h;
  }
  paint_text_left(g, fb, pitch, ww, hh, x + SESS_TITLE_PAD_X, y, i, cap, cap_n,
                  OSGFX_TEXT_TITLE_PX, OSGFX_TEXT_MEDIUM, SESS_TITLE_FG);
}

static void paint_ctx_menu(OsGfx *g, uint32_t *fb, int pitch, int ww, int hh,
                           int px, int py, unsigned kind, unsigned hover) {
  int rx;
  int ry;
  const char *lab0;
  const char *lab1;
  unsigned n0;
  unsigned n1;
  uint32_t c0;
  uint32_t c1;

  lab0 = "Regen";
  lab1 = "Image";
  n0 = 5;
  n1 = 5;
  if (kind == 4) {
    lab0 = "Close";
    lab1 = "Raise";
  } else if (kind == 5) {
    lab0 = "Raise";
    lab1 = "Close";
  }
  c0 = SESS_POP_ROW0;
  c1 = SESS_POP_ROW1;
  if ((hover & 0xFFu) == 0) {
    c0 = SESS_POP_HOVER;
  }
  if ((hover & 0xFFu) == 1) {
    c1 = SESS_POP_HOVER;
  }
  osgfx_fill_rrect(g, px + 6, py + SESS_POP_ROW_PAD, OSGFX_POP_W - 12,
                   SESS_POP_ROW_H - 2, 6, c0);
  osgfx_fill_rect(g, px + 10, py + SESS_POP_ROW_PAD + SESS_POP_ROW_H - 1,
                  OSGFX_POP_W - 20, 1, SESS_POP_EDGE);
  osgfx_fill_rrect(g, px + 6, py + SESS_POP_ROW_PAD + SESS_POP_ROW_H,
                   OSGFX_POP_W - 12, SESS_POP_ROW_H - 2, 6, c1);
  rx = px + SESS_POP_LAB_X;
  ry = py + SESS_POP_ROW_PAD;
  paint_text_left(g, fb, pitch, ww, hh, rx, ry, SESS_POP_ROW_H - 2, lab0, n0,
                  OSGFX_TEXT_LABEL_PX, OSGFX_TEXT_REGULAR,
                  (hover & 0x100u) != 0 ? SESS_POP_DISABLED : SESS_POP_FG);
  ry = py + SESS_POP_ROW_PAD + SESS_POP_ROW_H;
  paint_text_left(g, fb, pitch, ww, hh, rx, ry, SESS_POP_ROW_H - 2, lab1, n1,
                  OSGFX_TEXT_LABEL_PX, OSGFX_TEXT_REGULAR,
                  (hover & 0x200u) != 0 ? SESS_POP_DISABLED : SESS_POP_FG);
  (void)SESS_POP_LAB_Y;
}

void osgfx_session_paint(OsGfx *g, const struct OsGfxGuestCmd *cmd, int graphite_ready) {
  int ww;
  int hh;
  int desk_h;
  int pitch;
  uint32_t seed;
  uint32_t frame;
  uint32_t user;
  uint32_t *fb;
  int panel;
  int session_csd;
  static int client_noted;

  if (g == 0 || cmd == 0 || cmd->magic != OSGFX_GUEST_MAGIC) {
    return;
  }
  if (osgfx_session_door[0] == 0) {
    return;
  }
  if (osgfx_session_chrome_door[0] == 0) {
    return;
  }
  if (cmd->fb == 0) {
    return;
  }
  ww = (int)cmd->w;
  hh = (int)cmd->h;
  pitch = (int)cmd->pitch;
  if (ww < 8 || hh < 8 || pitch < ww * 4) {
    return;
  }
  fb = (uint32_t *)(uintptr_t)cmd->fb;
  /* DE session chrome door — before generative desk (Venus 1200×720 is slow). */
  if (chrome_noted == 0 && (cmd->flags & OSGFX_GUEST_DE) != 0) {
    chrome_noted = 1;
    com1_puts("OSGFX SESSION CHROME\n");
  }
  panel = (cmd->flags & OSGFX_GUEST_PANEL) != 0;
  /* Client panels own the bottom strip, not ordinary-window title chrome.
   * Keep title controls in the session so they follow live geometry. */
  session_csd = 0;
  if (panel != 0 && client_noted == 0) {
    client_noted = 1;
    com1_puts("OSGFX SESSION CHROME CLIENT\n");
    com1_puts("OSGFX SESSION STRIP CLIENT\n");
  }
  /* There is no pre-DESK fallback strip. Keep real wallpaper behind the
   * future panel so its transparent carrier and rounded ends reveal the desk
   * from the first frame instead of stale black pixels. */
  desk_h = hh;
  user = (uint32_t)cmd->desk;
  seed = 0xD074A17u;
  if (user != 0) {
    seed = user;
  }
  frame = (uint32_t)cmd->gen;
  if (user != 0) {
    frame = user ^ (uint32_t)cmd->gen;
  }
  if ((cmd->flags & OSGFX_GUEST_WALL_IMG) != 0) {
    osgfx_fill_rect(g, 0, 0, ww, desk_h, (uint32_t)cmd->wall & 0x00ffffffu);
  } else if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
    /* The cached entry point owns both paths: on a miss it generates into
     * Dart's buffer, stamps the key, and blits; on a hit it only blits.
     * Calling the uncached generator while HAVE is zero would leave HAVE zero
     * forever, so the cache could never reach its hot path. */
    if (cmd->wmpage != 0) {
      osgfx_fill_desk_cached(fb, pitch, 0, 0, ww, desk_h, seed);
    } else {
      osgfx_fill_desk_generative(fb, pitch, 0, 0, ww, desk_h, seed, frame);
    }
  } else if (graphite_ready != 0) {
    osgfx_fill_rect(g, 0, 0, ww, desk_h, OSGFX_DESK);
  } else {
    osgfx_fill_rect(g, 0, 0, ww, desk_h, OSGFX_DESK);
  }
  osgfx_session_paint_windows(g, cmd);
}

void osgfx_session_paint_geom(OsGfx *g, const struct OsGfxGuestCmd *cmd,
                              uint64_t old0, uint64_t old1) {
  uint32_t seed;
  uint32_t *fb;
  int pitch;
  int ww;
  int hh;
  int top;
  unsigned cap0;
  unsigned cap1;
  uint64_t keep0;
  uint64_t keep1;

  if (g == 0 || cmd == 0 || cmd->fb == 0) {
    return;
  }
  ww = (int)cmd->w;
  hh = (int)cmd->h;
  pitch = (int)cmd->pitch;
  fb = (uint32_t *)(uintptr_t)cmd->fb;
  seed = 0xD074A17u;
  if (cmd->desk != 0) {
    seed = (uint32_t)cmd->desk;
  }
  keep0 = cmd->win0;
  keep1 = cmd->win1;
  /* Do not blit leftover wallpaper into the chrome cache. Present
   * sources those pixels from the desk cache (osgfx_chrome_note_uncover).
   * A 1274×666 cache store was the 1.3s TCG restore. */
  (void)seed;
  cap0 = 1;
  cap1 = 1;
  if (cmd->wmpage != 0) {
    const uint64_t *page = (const uint64_t *)(uintptr_t)cmd->wmpage;
    uint64_t mail = page[OSGFX_WMPAGE_W_CAP_MAIL];
    if ((mail & 0xffu) != 0) {
      cap0 = (unsigned)(mail & 0xffu);
    }
    if (((mail >> 8) & 0xffu) != 0) {
      cap1 = (unsigned)((mail >> 8) & 0xffu);
    }
  }
  top = (int)((cmd->flags >> 8) & 3u);
  g_geom_no_shadow = 1;
  if (keep0 != 0 && keep0 != old0) {
    paint_window_chrome(g, fb, pitch, keep0,
                        top == 0 ? OSGFX_FOCUS : OSGFX_UNFOCUS, OSGFX_WIN_FILL,
                        ww, hh);
    if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
      paint_de_title_controls(g, fb, pitch, ww, hh, keep0, (int)cap0);
    }
  }
  if (keep1 != 0 && keep1 != old1) {
    paint_window_chrome(g, fb, pitch, keep1,
                        top == 1 ? OSGFX_FOCUS : OSGFX_UNFOCUS, OSGFX_WIN2_FILL,
                        ww, hh);
    if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
      paint_de_title_controls(g, fb, pitch, ww, hh, keep1, (int)cap1);
    }
  }
  /* TOP can flip with geom. Patch the 2px ring on the window we kept. */
  if (keep0 != 0 && keep0 == old0) {
    paint_window_borders(g, keep0, top == 0 ? OSGFX_FOCUS : OSGFX_UNFOCUS);
  }
  if (keep1 != 0 && keep1 == old1) {
    paint_window_borders(g, keep1, top == 1 ? OSGFX_FOCUS : OSGFX_UNFOCUS);
  }
  g_geom_no_shadow = 0;
}

void osgfx_session_paint_windows(OsGfx *g, const struct OsGfxGuestCmd *cmd) {
  int ww;
  int hh;
  int pitch;
  int top;
  uint32_t *fb;
  uint64_t held0;
  uint64_t held1;
  unsigned pop_kind;
  int panel;
  int session_csd;

  if (g == 0 || cmd == 0 || cmd->magic != OSGFX_GUEST_MAGIC) {
    return;
  }
  if (cmd->fb == 0) {
    return;
  }
  ww = (int)cmd->w;
  hh = (int)cmd->h;
  pitch = (int)cmd->pitch;
  if (ww < 8 || hh < 8 || pitch < ww * 4) {
    return;
  }
  fb = (uint32_t *)(uintptr_t)cmd->fb;
  panel = (cmd->flags & OSGFX_GUEST_PANEL) != 0;
  session_csd = 0;
  top = (int)((cmd->flags >> 8) & 3u);
  held0 = cmd->win0;
  held1 = cmd->win1;
  {
    unsigned cap0 = 1;
    unsigned cap1 = 1;
    if (cmd->wmpage != 0) {
      const uint64_t *page = (const uint64_t *)(uintptr_t)cmd->wmpage;
      uint64_t mail = page[OSGFX_WMPAGE_W_CAP_MAIL];
      if ((mail & 0xffu) != 0) {
        cap0 = (unsigned)(mail & 0xffu);
      }
      if (((mail >> 8) & 0xffu) != 0) {
        cap1 = (unsigned)((mail >> 8) & 0xffu);
      }
    }
    /* PANEL means the dock strip exists. win0/win1 are ordinary FRAME
     * clients (wmgfx skips the strip). Gating their chrome on panel
     * left FILES untitled and forced SET's caption to FILES. */
    if (held0 != 0) {
      paint_window_chrome(g, fb, pitch, held0,
                          top == 0 ? OSGFX_FOCUS : OSGFX_UNFOCUS,
                          OSGFX_WIN_FILL, ww, hh);
    }
    if (held1 != 0) {
      paint_window_chrome(g, fb, pitch, held1,
                          top == 1 ? OSGFX_FOCUS : OSGFX_UNFOCUS,
                          OSGFX_WIN2_FILL, ww, hh);
    }
    if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
      if (session_csd == 0) {
        if (held0 != 0) {
          paint_de_title_controls(g, fb, pitch, ww, hh, held0, (int)cap0);
        } else {
          if (held0_noted == 0) {
            held0_noted = 1;
            com1_puts("OSGFX TITLE HELD0 0\n");
          }
        }
        if (held1 != 0) {
          paint_de_title_controls(g, fb, pitch, ww, hh, held1, (int)cap1);
        }
      }
    } else {
      osgfx_fill_rect(g, 0, hh - OSGFX_CHROME_H, ww, OSGFX_CHROME_H,
                      OSGFX_CHROME);
    }
  }
  if (cmd->pop != 0 && panel == 0) {
    int px = (int)(cmd->pop >> 32);
    int py = (int)(cmd->pop & 0xffffffffu);
    pop_kind = (unsigned)((cmd->flags >> OSGFX_GUEST_POP_SHIFT) & 3u);
    osgfx_shadow(g, px + OSGFX_POP_SHADOW_OX, py + OSGFX_POP_SHADOW_OY,
                 OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS, OSGFX_POP_SHADOW_BLUR,
                 0x000C2030u);
    osgfx_fill_rrect(g, px, py, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS,
                     0x00F4F6FAu);
    if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
      unsigned hover = 0xFFu;
      unsigned ck = pop_kind;
      if (cmd->wmpage != 0) {
        const uint64_t *page = (const uint64_t *)(uintptr_t)cmd->wmpage;
        ck = (unsigned)page[OSGFX_WMPAGE_W_CTX_KIND];
        hover = (unsigned)page[OSGFX_WMPAGE_W_CTX_SLOT];
      }
      if (ck == 0) {
        ck = pop_kind;
      }
      paint_ctx_menu(g, fb, pitch, ww, hh, px, py, ck, hover);
    }
  }
}

/* TOP-only chrome miss: rewrite the 2px focus rings on the cached frame.
 * Title, shadow, wallpaper and traffic lights stay. */
void osgfx_session_patch_focus(OsGfx *g, const struct OsGfxGuestCmd *cmd) {
  int top;

  if (g == 0 || cmd == 0 || cmd->magic != OSGFX_GUEST_MAGIC) {
    return;
  }
  top = (int)((cmd->flags >> OSGFX_GUEST_TOP_SHIFT) & 3u);
  if (cmd->win0 != 0) {
    paint_window_borders(g, cmd->win0, top == 0 ? OSGFX_FOCUS : OSGFX_UNFOCUS);
  }
  if (cmd->win1 != 0) {
    paint_window_borders(g, cmd->win1, top == 1 ? OSGFX_FOCUS : OSGFX_UNFOCUS);
  }
}
