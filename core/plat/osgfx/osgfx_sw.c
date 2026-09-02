/* Software osgfx backend for kernel.elf (x86_64-unknown-none-elf).
 *
 * Same osgfx.h the host Graphite/Metal backends implement. Not Graphite.
 * Not Metal. Not Mac arm64 libskia.a. The compositor calls these
 * symbols on the running OS. Later GPU/Skia replaces this .c.
 */
#include "osgfx.h"
#include "osgfx_guest.h"

struct OsGfx {
  uint32_t *px;
  int pitch;
  int w;
  int h;
};

static struct OsGfx g_one;
static uint64_t last_gen;

extern struct OsGfxGuestCmd osgfx_guest_cmd;

static void put_px(OsGfx *g, int x, int y, uint32_t rgb) {
  uint8_t *row;

  if (g == 0 || g->px == 0) {
    return;
  }
  if (x < 0 || y < 0 || x >= g->w || y >= g->h) {
    return;
  }
  row = (uint8_t *)g->px + (unsigned)y * (unsigned)g->pitch;
  *(volatile uint32_t *)((uint32_t *)row + x) = rgb & 0x00FFFFFFu;
}

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

static uint32_t mix_rgb(uint32_t a, uint32_t b, int i, int n) {
  int ar, ag, ab, br, bg, bb;

  if (n <= 1) {
    return a;
  }
  ar = (int)((a >> 16) & 0xff);
  ag = (int)((a >> 8) & 0xff);
  ab = (int)(a & 0xff);
  br = (int)((b >> 16) & 0xff);
  bg = (int)((b >> 8) & 0xff);
  bb = (int)(b & 0xff);
  ar = ar + (br - ar) * i / n;
  ag = ag + (bg - ag) * i / n;
  ab = ab + (bb - ab) * i / n;
  return ((uint32_t)ar << 16) | ((uint32_t)ag << 8) | (uint32_t)ab;
}

OsGfx *osgfx_create(int w, int h) {
  if (w < 1 || h < 1) {
    return 0;
  }
  g_one.w = w;
  g_one.h = h;
  return &g_one;
}

void osgfx_destroy(OsGfx *g) {
  (void)g;
}

void osgfx_clear(OsGfx *g, uint32_t rgb) {
  int y;
  int x;

  if (g == 0) {
    return;
  }
  y = 0;
  while (y < g->h) {
    x = 0;
    while (x < g->w) {
      put_px(g, x, y, rgb);
      x = x + 1;
    }
    y = y + 1;
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
  int yy;
  int xx;
  int x1;
  int y1;
  uint32_t rgb;

  if (g == 0 || w <= 0 || h <= 0) {
    return;
  }
  x1 = x + w;
  y1 = y + h;
  yy = y;
  while (yy < y1) {
    rgb = mix_rgb(top, bot, yy - y, h - 1);
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

void osgfx_shadow(OsGfx *g, int x, int y, int w, int h, int radius, int blur,
                  uint32_t rgb) {
  int i;
  uint32_t c;

  (void)blur;
  c = rgb;
  if (c == 0) {
    c = 0x000C2030u;
  }
  i = 0;
  while (i < 3) {
    osgfx_fill_rrect(g, x + i, y + i, w, h, radius, c);
    i = i + 1;
  }
}

int osgfx_flush(OsGfx *g) {
  if (g == 0) {
    return OSGFX_ERR;
  }
  return OSGFX_OK;
}

int osgfx_readback(OsGfx *g, uint32_t *out, int max_pixels) {
  int n;
  int i;
  int x;
  int y;
  uint8_t *row;

  if (g == 0 || g->px == 0 || out == 0 || max_pixels < 1) {
    return -1;
  }
  n = g->w * g->h;
  if (n > max_pixels) {
    n = max_pixels;
  }
  i = 0;
  while (i < n) {
    y = i / g->w;
    x = i - y * g->w;
    row = (uint8_t *)g->px + (unsigned)y * (unsigned)g->pitch;
    out[i] = ((uint32_t *)row)[x] & 0x00FFFFFFu;
    i = i + 1;
  }
  return n;
}

int osgfx_ppm_write(OsGfx *g, const char *path) {
  (void)g;
  (void)path;
  return -1;
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

static void unpack_geom(uint64_t g, int *x, int *y, int *w, int *h) {
  *x = (int)((g >> 48) & 0xffffu);
  *y = (int)((g >> 32) & 0xffffu);
  *w = (int)((g >> 16) & 0xffffu);
  *h = (int)(g & 0xffffu);
}

static void paint_window(OsGfx *g, uint64_t geom, uint32_t border) {
  int x, y, w, h, b, r;

  if (geom == 0) {
    return;
  }
  unpack_geom(geom, &x, &y, &w, &h);
  if (w < 8 || h < 8) {
    return;
  }
  b = OSGFX_BORDER;
  r = OSGFX_RADIUS;
  osgfx_shadow(g, x + 6, y + 10, w, h, r, 18, 0x000C2030u);
  osgfx_fill_rrect(g, x - b, y - b, w + b + b, h + b + b, r, border);
  osgfx_fill_rrect(g, x, y, w, OSGFX_TITLE_H + 8, r, OSGFX_TITLE);
}

/* C trampoline: IRQ0 calls this. Mailbox is filled by wmGfxKick.
 * The paint is osgfx_fill_rrect / osgfx_fill_rect, not a Dart blit. */
void osgfx_guest_tick(void) {
  struct OsGfxGuestCmd *m;
  OsGfx *g;
  int ww;
  int hh;

  m = &osgfx_guest_cmd;
  if (m->magic != OSGFX_GUEST_MAGIC) {
    return;
  }
  if ((m->flags & OSGFX_GUEST_ON) == 0) {
    return;
  }
  if (m->gen == last_gen) {
    return;
  }
  if (m->fb == 0 || m->w < 8 || m->h < 8) {
    return;
  }
  if (m->pitch < m->w * 4) {
    return;
  }
  ww = (int)m->w;
  hh = (int)m->h;
  g = osgfx_create(ww, hh);
  if (g == 0) {
    return;
  }
  g->px = (uint32_t *)(uintptr_t)m->fb;
  g->pitch = (int)m->pitch;
  paint_window(g, m->win0, OSGFX_UNFOCUS);
  paint_window(g, m->win1, OSGFX_FOCUS);
  osgfx_fill_rect(g, 0, hh - OSGFX_CHROME_H, ww, OSGFX_CHROME_H, OSGFX_CHROME);
  if (m->pop != 0) {
    int px = (int)(m->pop >> 32);
    int py = (int)(m->pop & 0xffffffffu);
    osgfx_shadow(g, px + 4, py + 6, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS, 12,
                 0x000C2030u);
    osgfx_fill_rrect(g, px, py, OSGFX_POP_W, OSGFX_POP_H, OSGFX_RADIUS,
                     OSGFX_POP);
  }
  osgfx_flush(g);
  last_gen = m->gen;
}
