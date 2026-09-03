#include "osgfx_scene.h"

static void paint_desktop(OsGfx *g) {
  osgfx_clear(g, OSGFX_DESK);
}

static void paint_chrome(OsGfx *g) {
  osgfx_fill_rect(g, 0, OSGFX_H - OSGFX_CHROME_H, OSGFX_W, OSGFX_CHROME_H,
                  OSGFX_CHROME);
}

static void paint_window_rrect(OsGfx *g, int x, int y, int w, int h,
                               uint32_t fill) {
  osgfx_shadow(g, x + 6, y + 10, w, h, OSGFX_RADIUS, 18, 0x00000000);
  osgfx_fill_rrect(g, x, y, w, h, OSGFX_RADIUS, fill);
  osgfx_fill_rrect(g, x, y, w, OSGFX_TITLE_H + 8, OSGFX_RADIUS, OSGFX_TITLE);
  osgfx_fill_rect(g, x, y + OSGFX_TITLE_H, w, 8, fill);
}

static void paint_window_square(OsGfx *g, int x, int y, int w, int h,
                                uint32_t fill) {
  osgfx_fill_rect(g, x, y, w, h, fill);
  osgfx_fill_rect(g, x, y, w, OSGFX_TITLE_H, OSGFX_TITLE);
}

void osgfx_scene_two(OsGfx *g) {
  paint_desktop(g);
  paint_window_rrect(g, OSGFX_WIN_X, OSGFX_WIN_Y, OSGFX_WIN_W, OSGFX_WIN_H,
                     OSGFX_WIN_FILL);
  paint_window_rrect(g, OSGFX_WIN2_X, OSGFX_WIN2_Y, OSGFX_WIN_W, OSGFX_WIN_H,
                     OSGFX_WIN2_FILL);
  paint_chrome(g);
}

void osgfx_scene_two_square(OsGfx *g) {
  paint_desktop(g);
  paint_window_square(g, OSGFX_WIN_X, OSGFX_WIN_Y, OSGFX_WIN_W, OSGFX_WIN_H,
                      OSGFX_WIN_FILL);
  paint_window_square(g, OSGFX_WIN2_X, OSGFX_WIN2_Y, OSGFX_WIN_W, OSGFX_WIN_H,
                      OSGFX_WIN2_FILL);
  paint_chrome(g);
}

static void paint_window_policy(OsGfx *g, int x, int y, int w, int h,
                                uint32_t fill, uint32_t border) {
  int b;

  b = OSGFX_BORDER;
  osgfx_shadow(g, x + 6, y + 10, w, h, OSGFX_RADIUS, 18, 0x00000000);
  osgfx_fill_rrect(g, x - b, y - b, w + b + b, h + b + b, OSGFX_RADIUS, border);
  osgfx_fill_rrect(g, x, y, w, h, OSGFX_RADIUS, fill);
  osgfx_fill_rrect(g, x, y, w, OSGFX_TITLE_H + 8, OSGFX_RADIUS, OSGFX_TITLE);
  osgfx_fill_rect(g, x, y + OSGFX_TITLE_H, w, 8, fill);
}

static void paint_window_policy_square(OsGfx *g, int x, int y, int w, int h,
                                      uint32_t fill, uint32_t border) {
  int b;

  b = OSGFX_BORDER;
  osgfx_fill_rect(g, x - b, y - b, w + b + b, h + b + b, border);
  osgfx_fill_rect(g, x, y, w, h, fill);
  osgfx_fill_rect(g, x, y, w, OSGFX_TITLE_H, OSGFX_TITLE);
}

void osgfx_scene_compose(OsGfx *g) {
  paint_desktop(g);
  paint_window_policy(g, OSGFX_WIN_X, OSGFX_WIN_Y, OSGFX_WIN_W, OSGFX_WIN_H,
                      OSGFX_WIN_FILL, OSGFX_UNFOCUS);
  paint_window_policy(g, OSGFX_WIN2_X, OSGFX_WIN2_Y, OSGFX_WIN_W, OSGFX_WIN_H,
                      OSGFX_WIN2_FILL, OSGFX_FOCUS);
  paint_chrome(g);
  osgfx_shadow(g, OSGFX_POP_X + 4, OSGFX_POP_Y + 6, OSGFX_POP_W, OSGFX_POP_H,
               OSGFX_RADIUS, 12, 0x00000000);
  osgfx_fill_rrect(g, OSGFX_POP_X, OSGFX_POP_Y, OSGFX_POP_W, OSGFX_POP_H,
                   OSGFX_RADIUS, OSGFX_POP);
}

void osgfx_scene_compose_square(OsGfx *g) {
  paint_desktop(g);
  paint_window_policy_square(g, OSGFX_WIN_X, OSGFX_WIN_Y, OSGFX_WIN_W,
                             OSGFX_WIN_H, OSGFX_WIN_FILL, OSGFX_UNFOCUS);
  paint_window_policy_square(g, OSGFX_WIN2_X, OSGFX_WIN2_Y, OSGFX_WIN_W,
                             OSGFX_WIN_H, OSGFX_WIN2_FILL, OSGFX_FOCUS);
  paint_chrome(g);
  osgfx_fill_rect(g, OSGFX_POP_X, OSGFX_POP_Y, OSGFX_POP_W, OSGFX_POP_H,
                  OSGFX_POP);
}

void osgfx_scene_osxui3(OsGfx *g, int menu_open, int menu_hit, int ctl_on,
                        int win_x, int win_y, int pop_x, int pop_y) {
  int mx;
  int my;
  int i;
  int bh;
  uint32_t ctl;

  paint_desktop(g);
  paint_window_rrect(g, win_x, win_y, OSGFX_WIN_W, OSGFX_WIN_H, 0x00C05028);
  ctl = 0x0020A060;
  if (ctl_on) {
    ctl = 0x00E04090;
  }
  osgfx_fill_rrect(g, win_x + 48, win_y + OSGFX_TITLE_H + 40, 96, 48, 8, ctl);
  if (menu_open) {
    mx = win_x + 8;
    my = win_y + OSGFX_TITLE_H + 8;
    osgfx_shadow(g, mx + 4, my + 6, 120, 96, 10, 14, 0x00000000);
    osgfx_fill_rrect(g, mx, my, 120, 96, 10, OSGFX_MENU_BG);
    bh = 28;
    i = 0;
    while (i < 3) {
      uint32_t band;
      band = OSGFX_MENU_IDLE;
      if (i == menu_hit) {
        band = OSGFX_MENU_HIT;
      }
      osgfx_fill_rrect(g, mx + 8, my + 8 + i * bh, 104, 24, 6, band);
      i = i + 1;
    }
  }
  paint_chrome(g);
  if (pop_x >= 0) {
    osgfx_shadow(g, pop_x + 4, pop_y + 6, OSGFX_POP_W, OSGFX_POP_H, 10, 12,
                 0x00000000);
    osgfx_fill_rrect(g, pop_x, pop_y, OSGFX_POP_W, OSGFX_POP_H, 10, OSGFX_POP);
  }
}
