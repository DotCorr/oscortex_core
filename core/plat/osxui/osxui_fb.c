/* Scanout door for osxui_button. wmde calls osxui_button_fb; that
 * calls osxui_button with a null OsGfx, which calls osxui_scan_button.
 * Not a second toolkit. Tokens de-glyph greps stay out of osxui.c. */
#include "osxui.h"

#include <stddef.h>
#include <stdint.h>

static uint32_t *s_base;
static int s_stride;
static int s_maxw;
static int s_maxh;

static int rrect_hit(int px, int py, int x, int y, int w, int h, int r) {
  int cx;
  int cy;
  int dx;
  int dy;

  if (w <= 0 || h <= 0) {
    return 0;
  }
  if (px < x || py < y || px >= x + w || py >= y + h) {
    return 0;
  }
  if (r < 1) {
    return 1;
  }
  if (r > w / 2) {
    r = w / 2;
  }
  if (r > h / 2) {
    r = h / 2;
  }
  if (px < x + r && py < y + r) {
    cx = x + r;
    cy = y + r;
  } else if (px >= x + w - r && py < y + r) {
    cx = x + w - 1 - r;
    cy = y + r;
  } else if (px < x + r && py >= y + h - r) {
    cx = x + r;
    cy = y + h - 1 - r;
  } else if (px >= x + w - r && py >= y + h - r) {
    cx = x + w - 1 - r;
    cy = y + h - 1 - r;
  } else {
    return 1;
  }
  dx = px - cx;
  dy = py - cy;
  return dx * dx + dy * dy <= r * r;
}

static void scan_dot(uint32_t *base, int stride, int maxw, int maxh, int x,
                     int y, uint32_t rgb) {
  uint8_t *row;

  if (base == 0 || stride < 4 || maxw < 1 || maxh < 1) {
    return;
  }
  if (x < 0 || y < 0 || x >= maxw || y >= maxh) {
    return;
  }
  row = (uint8_t *)base + (unsigned)y * (unsigned)stride;
  *(uint32_t *)(row + (unsigned)x * 4u) = rgb & 0x00FFFFFFu;
}

void osxui_scan_button(const OsxuiRect *r, int radius, uint32_t rgb) {
  int yy;
  int xx;
  int x1;
  int y1;

  if (r == 0 || s_base == 0) {
    return;
  }
  if (r->w <= 0 || r->h <= 0) {
    return;
  }
  x1 = r->x + r->w;
  y1 = r->y + r->h;
  yy = r->y;
  while (yy < y1) {
    xx = r->x;
    while (xx < x1) {
      if (rrect_hit(xx, yy, r->x, r->y, r->w, r->h, radius)) {
        scan_dot(s_base, s_stride, s_maxw, s_maxh, xx, yy, rgb);
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

void osxui_button_fb(uint64_t fb, uint64_t pitch, uint64_t fwh, uint64_t xy,
                     uint64_t sz, uint64_t rrgb) {
  OsxuiRect r;
  int radius;
  uint32_t rgb;

  s_base = (uint32_t *)(uintptr_t)fb;
  s_stride = (int)pitch;
  s_maxw = (int)(fwh >> 32);
  s_maxh = (int)fwh;
  r.x = (int)(xy >> 32);
  r.y = (int)xy;
  r.w = (int)(sz >> 32);
  r.h = (int)sz;
  radius = (int)(rrgb >> 32);
  rgb = (uint32_t)rrgb;
  osxui_button(0, &r, radius, rgb);
  s_base = 0;
  s_stride = 0;
  s_maxw = 0;
  s_maxh = 0;
}
