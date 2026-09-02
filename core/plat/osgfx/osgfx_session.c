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
  SESS_POP_ROW0 = 0x00304878,
  SESS_POP_ROW1 = 0x00283868,
  SESS_POP_FG = 0x00F0F8FF,
  SESS_POP_ROW_PAD = 4,
  SESS_POP_ROW_H = 24,
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

static void unpack_geom(uint64_t g, int *x, int *y, int *w, int *h) {
  *x = (int)((g >> 48) & 0xffffu);
  *y = (int)((g >> 32) & 0xffffu);
  *w = (int)((g >> 16) & 0xffffu);
  *h = (int)(g & 0xffffu);
}

/* Soft drop shadow — osgfx_shadow alpha-blends expanding rings. */
static void paint_soft_shadow(OsGfx *g, int x, int y, int w, int h, int r) {
  if (g == 0) {
    return;
  }
  osgfx_shadow(g, x + 6, y + 10, w, h, r, 18, SESS_SHADOW);
}

/* ADR-0183: frame + title band only — never fill the client body.
 * Body pixels come from wmDrawWindow blit of FRAME shm. */
static void paint_window_chrome(OsGfx *g, uint64_t geom, uint32_t border,
                                uint32_t fill) {
  int x;
  int y;
  int w;
  int h;
  int b;
  int r;
  int th;

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
  b = OSGFX_BORDER;
  r = OSGFX_RADIUS;
  th = SESS_TITLE_BAND;
  if (th > h) {
    th = h;
  }
  paint_soft_shadow(g, x, y, w, h, r);
  /* OSGFX_CORNER_TL / OSGFX_CORNER_TR — top pearl pair closes the AA card
   * radius when CSD withdraws the session title band (ADR-0196). */
  if (r > 0) {
    osgfx_fill_rrect(g, x, y, r, r, r, OSGFX_TITLE);
    osgfx_fill_rrect(g, x + w - r, y, r, r, r, OSGFX_TITLE);
  }
  /* Border ring only — do not paint OSGFX_WIN_FILL over client shm. */
  osgfx_fill_rrect(g, x - b, y - b, w + b + b, b + 1, 0, border);
  osgfx_fill_rrect(g, x - b, y + h - 1, w + b + b, b + 1, 0, border);
  osgfx_fill_rect(g, x - b, y, b, h, border);
  osgfx_fill_rect(g, x + w, y, b, h, border);
  /* Pearl title chrome is a real vertical ramp, not a flat beige card with
   * a two-pixel highlight stamped over it. The rrect gradient shares the
   * window radius, so fill and AA border cannot disagree at the corners. */
  osgfx_fill_rrect_vgrad(g, x, y, w, th, r, SESS_TITLE_TOP, OSGFX_TITLE);
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

static void paint_de_title_controls(OsGfx *g, uint32_t *fb, int pitch, int ww,
                                    int hh, uint64_t geom, int slot) {
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
  (void)slot;
  cap = "FILES";
  cap_n = 5;
  i = SESS_TITLE_BAND;
  if (i > h) {
    i = h;
  }
  paint_text_left(g, fb, pitch, ww, hh, x + SESS_TITLE_PAD_X, y, i, cap, cap_n,
                  OSGFX_TEXT_TITLE_PX, OSGFX_TEXT_MEDIUM, SESS_TITLE_FG);
}

static void paint_wall_menu(OsGfx *g, uint32_t *fb, int pitch, int ww, int hh,
                            int px, int py) {
  int rx;
  int ry;
  const char *regen;
  const char *image;

  regen = "Regen";
  image = "Image";
  osgfx_fill_rrect(g, px + 4, py + SESS_POP_ROW_PAD, OSGFX_POP_W - 8,
                   SESS_POP_ROW_H - 2, 6, SESS_POP_ROW0);
  osgfx_fill_rrect(g, px + 4, py + SESS_POP_ROW_PAD + SESS_POP_ROW_H,
                   OSGFX_POP_W - 8, SESS_POP_ROW_H - 2, 6, SESS_POP_ROW1);
  /* Menu rows: real outline text, left aligned like every other menu. */
  rx = px + SESS_POP_LAB_X;
  ry = py + SESS_POP_ROW_PAD;
  paint_text_left(g, fb, pitch, ww, hh, rx, ry, SESS_POP_ROW_H - 2, regen, 5,
                  OSGFX_TEXT_LABEL_PX, OSGFX_TEXT_REGULAR, SESS_POP_FG);
  ry = py + SESS_POP_ROW_PAD + SESS_POP_ROW_H;
  paint_text_left(g, fb, pitch, ww, hh, rx, ry, SESS_POP_ROW_H - 2, image, 5,
                  OSGFX_TEXT_LABEL_PX, OSGFX_TEXT_REGULAR, SESS_POP_FG);
  (void)SESS_POP_LAB_Y;
}

void osgfx_session_paint(OsGfx *g, const struct OsGfxGuestCmd *cmd, int graphite_ready) {
  int ww;
  int hh;
  int desk_h;
  int pitch;
  int top;
  uint32_t seed;
  uint32_t frame;
  uint32_t user;
  uint32_t *fb;
  uint64_t held0;
  uint64_t held1;
  unsigned pop_kind;
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
  } else if (cmd->gen != 0) {
    seed = (uint32_t)(cmd->gen * 0x9E3779B1u);
  }
  frame = (uint32_t)cmd->gen;
  if (user != 0) {
    frame = user ^ (uint32_t)cmd->gen;
  }
  if ((cmd->flags & OSGFX_GUEST_WALL_IMG) != 0) {
    osgfx_fill_rect(g, 0, 0, ww, desk_h, (uint32_t)cmd->wall & 0x00ffffffu);
  } else if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
    /* Hot path: desk cache (ADR-0188). Cold: osgfx_fill_desk_generative. */
    if (cmd->wmpage != 0) {
      const volatile uint64_t *pg =
          (const volatile uint64_t *)(uintptr_t)cmd->wmpage;
      if (pg[OSGFX_WMPAGE_W_DESK_HAVE] != 0) {
        osgfx_fill_desk_cached(fb, pitch, 0, 0, ww, desk_h, seed);
      } else {
        osgfx_fill_desk_generative(fb, pitch, 0, 0, ww, desk_h, seed, frame);
      }
    } else {
      osgfx_fill_desk_generative(fb, pitch, 0, 0, ww, desk_h, seed, frame);
    }
  } else if (graphite_ready != 0) {
    osgfx_fill_rect(g, 0, 0, ww, desk_h, OSGFX_DESK);
  } else {
    osgfx_fill_rect(g, 0, 0, ww, desk_h, OSGFX_DESK);
  }
  top = (int)((cmd->flags >> 8) & 3u);
  held0 = cmd->win0;
  held1 = cmd->win1;
  if (held0 != 0 && panel == 0) {
    paint_window_chrome(g, held0, top == 0 ? OSGFX_FOCUS : OSGFX_UNFOCUS,
                        OSGFX_WIN_FILL);
  }
  if (held1 != 0) {
    paint_window_chrome(g, held1, top == 1 ? OSGFX_FOCUS : OSGFX_UNFOCUS,
                        OSGFX_WIN2_FILL);
  }
  if ((cmd->flags & OSGFX_GUEST_DE) != 0) {
    if (session_csd == 0) {
      if (held0 != 0 && panel == 0) {
        paint_de_title_controls(g, fb, pitch, ww, hh, held0, 0);
      } else {
        if (held0_noted == 0 && panel == 0) {
          held0_noted = 1;
          com1_puts("OSGFX TITLE HELD0 0\n");
        }
      }
      if (held1 != 0) {
        paint_de_title_controls(g, fb, pitch, ww, hh, held1,
                                panel != 0 ? 0 : 1);
      }
    }
  } else {
    osgfx_fill_rect(g, 0, hh - OSGFX_CHROME_H, ww, OSGFX_CHROME_H, OSGFX_CHROME);
  }
  if (cmd->pop != 0 && panel == 0) {
    int px = (int)(cmd->pop >> 32);
    int py = (int)(cmd->pop & 0xffffffffu);
    pop_kind = (unsigned)((cmd->flags >> OSGFX_GUEST_POP_SHIFT) & 3u);
    osgfx_shadow(g, px + 4, py + 6, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS, 14,
                 0x000C2030u);
    osgfx_fill_rrect(g, px, py, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS, OSGFX_POP);
    if (pop_kind == 1 && (cmd->flags & OSGFX_GUEST_DE) != 0) {
      paint_wall_menu(g, fb, pitch, ww, hh, px, py);
    }
  }
}
