/* Widgets. Every pixel goes through osgfx.h. No blit loop here. */
#include "osxui.h"

#include <stddef.h>

int osxui_hit(const OsxuiRect *r, int px, int py) {
  if (r == 0) {
    return 0;
  }
  if (r->w <= 0 || r->h <= 0) {
    return 0;
  }
  if (px < r->x || py < r->y) {
    return 0;
  }
  if (px >= r->x + r->w || py >= r->y + r->h) {
    return 0;
  }
  return 1;
}

#ifndef OSXUI_STUB_BUTTON
#define OSXUI_STUB_BUTTON 0
#endif

void osxui_button(OsGfx *g, const OsxuiRect *r, int radius, uint32_t rgb) {
#if OSXUI_STUB_BUTTON
  (void)g;
  (void)r;
  (void)radius;
  (void)rgb;
  return;
#else
  if (r == 0) {
    return;
  }
  if (g == 0) {
    osxui_scan_button(r, radius, rgb);
    return;
  }
  osgfx_fill_rrect(g, r->x, r->y, r->w, r->h, radius, rgb);
#endif
}

void osxui_panel(OsGfx *g, const OsxuiRect *r, uint32_t rgb) {
  if (g == 0 || r == 0) {
    return;
  }
  osgfx_fill_rect(g, r->x, r->y, r->w, r->h, rgb);
}

void osxui_glass(OsGfx *g, const OsxuiRect *r, int radius, uint32_t fill) {
  if (g == 0 || r == 0 || r->w < 1 || r->h < 1) {
    return;
  }
  if (radius < 1) {
    radius = OSGFX_RADIUS;
  }
  osgfx_shadow(g, r->x + 1, r->y + 2, r->w, r->h, radius, 12, OSXUI_GLASS_SHADOW);
  osgfx_fill_rrect_vgrad(g, r->x, r->y, r->w, r->h, radius, OSXUI_GLASS_TOP, fill);
  osgfx_fill_rrect(g, r->x + 2, r->y + 1, r->w - 4, 1, 1, OSXUI_GLASS_HAIR);
}

void osxui_island(OsGfx *g, const OsxuiRect *r) {
  osxui_glass(g, r, OSXUI_ISLAND_R, OSXUI_GLASS_FILL);
}

/* Real proportional outline text through osgfx_text (Skia drawPath, AA).
 * The 8x16 osgfx_fill_glyph cell is only the no-Skia fallback now: an
 * OsGfx without a canvas cannot take an SkPath (ADR-0187).
 *
 * y is still the top of the run, and the caller's stem-truncation at the
 * first space is kept, because 8.3 name strips depend on it. */
void osxui_label(OsGfx *g, int x, int y, const char *text, int n, uint32_t rgb) {
  int i;
  int stem;

  if (g == 0 || text == 0 || n < 1) {
    return;
  }
  stem = 0;
  while (stem < n) {
    unsigned char c = (unsigned char)text[stem];
    if (c == 0 || c == (unsigned char)' ') {
      break;
    }
    stem = stem + 1;
  }
  if (stem < 1) {
    return;
  }
  if (osgfx_text(g, x, y, text, stem, OSGFX_TEXT_LABEL_PX, OSGFX_TEXT_REGULAR,
                 rgb) > 0) {
    return;
  }
  i = 0;
  while (i < stem) {
    osgfx_fill_glyph(g, x + i * OSGFX_GLYPH_W, y,
                     osgfx_glyph_rows((int)(unsigned char)text[i]), rgb);
    i = i + 1;
  }
}

void osxui_icon(OsGfx *g, int x, int y, uint32_t rgb) {
  if (g == 0) {
    return;
  }
  osgfx_fill_glyph(g, x, y, osgfx_icon_rows(), rgb);
}

static void osxui_hex_digits(char *buf, uint64_t value, int n) {
  int i;

  i = 0;
  while (i < n) {
    unsigned shift = (unsigned)((n - 1 - i) * 4);
    unsigned nib = (unsigned)((value >> shift) & 0xFu);
    if (nib < 10u) {
      buf[i] = (char)('0' + nib);
    } else {
      buf[i] = (char)('A' + (nib - 10u));
    }
    i = i + 1;
  }
}

void osxui_hex(OsGfx *g, int x, int y, uint64_t value, int n, uint32_t rgb) {
  char buf[8];

  if (n < 1) {
    return;
  }
  if (n > 8) {
    n = 8;
  }
  osxui_hex_digits(buf, value, n);
  osxui_label(g, x, y, buf, n, rgb);
}

void osxui_hex_fb(uint64_t fb, uint64_t pitch, uint64_t wh, uint64_t xy,
                  uint64_t value, uint64_t nrgb) {
  char buf[8];
  int n;

  n = (int)(nrgb >> 32);
  if (n < 1) {
    return;
  }
  if (n > 8) {
    n = 8;
  }
  osxui_hex_digits(buf, value, n);
  osxui_label_fb(fb, pitch, wh, xy, (uint64_t)(uintptr_t)buf, nrgb);
}
