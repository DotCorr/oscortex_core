/* Host software backend of osgfx.h for the osxui harness.
 *
 * Same header the kernel's osgfx_sw.c implements. Not Graphite. Not a
 * second widget toolkit — widgets live in osxui.c and only call the ABI.
 * OSGFX_NO_RRECT=1 omits osgfx_fill_rrect so a link of osxui.c fails.
 */
#include "osgfx.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef OSGFX_NO_RRECT
#define OSGFX_NO_RRECT 0
#endif

struct OsGfx {
  uint32_t *px;
  int w;
  int h;
};

static void put_px(OsGfx *g, int x, int y, uint32_t rgb) {
  if (g == 0 || g->px == 0) {
    return;
  }
  if (x < 0 || y < 0 || x >= g->w || y >= g->h) {
    return;
  }
  g->px[y * g->w + x] = rgb & 0x00FFFFFFu;
}

#if !OSGFX_NO_RRECT
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
#endif

OsGfx *osgfx_create(int w, int h) {
  OsGfx *g;

  if (w < 1 || h < 1) {
    return 0;
  }
  g = (OsGfx *)calloc(1, sizeof(*g));
  if (g == 0) {
    return 0;
  }
  g->w = w;
  g->h = h;
  g->px = (uint32_t *)calloc((size_t)w * (size_t)h, sizeof(uint32_t));
  if (g->px == 0) {
    free(g);
    return 0;
  }
  return g;
}

void osgfx_destroy(OsGfx *g) {
  if (g == 0) {
    return;
  }
  free(g->px);
  free(g);
}

void osgfx_clear(OsGfx *g, uint32_t rgb) {
  int n;
  int i;

  if (g == 0 || g->px == 0) {
    return;
  }
  n = g->w * g->h;
  i = 0;
  while (i < n) {
    g->px[i] = rgb & 0x00FFFFFFu;
    i = i + 1;
  }
}

void osgfx_fill_rect(OsGfx *g, int x, int y, int w, int h, uint32_t rgb) {
  int yy;
  int xx;
  int x1;
  int y1;

  if (g == 0 || w <= 0 || h <= 0) {
    return;
  }
  x1 = x + w;
  y1 = y + h;
  yy = y;
  while (yy < y1) {
    xx = x;
    while (xx < x1) {
      put_px(g, xx, yy, rgb);
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

#if !OSGFX_NO_RRECT
void osgfx_fill_rrect(OsGfx *g, int x, int y, int w, int h, int radius,
                      uint32_t rgb) {
  int yy;
  int xx;
  int x1;
  int y1;

  if (g == 0 || w <= 0 || h <= 0) {
    return;
  }
  x1 = x + w;
  y1 = y + h;
  yy = y;
  while (yy < y1) {
    xx = x;
    while (xx < x1) {
      if (rrect_hit(xx, yy, x, y, w, h, radius)) {
        put_px(g, xx, yy, rgb);
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

void osgfx_fill_rrect_vgrad(OsGfx *g, int x, int y, int w, int h, int radius,
                            uint32_t top, uint32_t bot) {
  (void)bot;
  osgfx_fill_rrect(g, x, y, w, h, radius, top);
}

void osgfx_shadow(OsGfx *g, int x, int y, int w, int h, int radius, int blur,
                  uint32_t rgb) {
  (void)blur;
  osgfx_fill_rrect(g, x + 2, y + 2, w, h, radius, rgb);
}
#endif

int osgfx_flush(OsGfx *g) {
  if (g == 0) {
    return OSGFX_ERR;
  }
  return OSGFX_OK;
}

int osgfx_readback(OsGfx *g, uint32_t *out, int max_pixels) {
  int n;
  int i;

  if (g == 0 || g->px == 0 || out == 0 || max_pixels < 1) {
    return -1;
  }
  n = g->w * g->h;
  if (n > max_pixels) {
    n = max_pixels;
  }
  i = 0;
  while (i < n) {
    out[i] = g->px[i] & 0x00FFFFFFu;
    i = i + 1;
  }
  return n;
}

int osgfx_ppm_write(OsGfx *g, const char *path) {
  FILE *f;
  int y;
  int x;
  uint32_t c;

  if (g == 0 || g->px == 0 || path == 0) {
    return OSGFX_ERR;
  }
  f = fopen(path, "wb");
  if (f == 0) {
    return OSGFX_ERR;
  }
  if (fprintf(f, "P6\n%d %d\n255\n", g->w, g->h) < 0) {
    fclose(f);
    return OSGFX_ERR;
  }
  y = 0;
  while (y < g->h) {
    x = 0;
    while (x < g->w) {
      unsigned char rgb[3];
      c = g->px[y * g->w + x];
      rgb[0] = (unsigned char)((c >> 16) & 0xff);
      rgb[1] = (unsigned char)((c >> 8) & 0xff);
      rgb[2] = (unsigned char)(c & 0xff);
      if (fwrite(rgb, 1, 3, f) != 3) {
        fclose(f);
        return OSGFX_ERR;
      }
      x = x + 1;
    }
    y = y + 1;
  }
  fclose(f);
  return OSGFX_OK;
}

int osgfx_present_layer(OsGfx *g, void *metal_layer) {
  (void)g;
  (void)metal_layer;
  return OSGFX_OK;
}

int osgfx_backend_graphite(void) { return 0; }

const char *osgfx_backend_name(const OsGfx *g) {
  (void)g;
  return "software";
}
