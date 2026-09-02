/* Generative desktop wallpaper + cache (ADR-0188) + frost sampler (ADR-0198).
 * Token: osgfx-desk-gen
 *
 *   [desk_gen_rect]  field maths when the KEY changes. Column normals live in
 *                    desk_nx[]; row normals are one rounded divide per row.
 *   [desk_blit]      one 32-bit load + store per pixel — no division here.
 */
#include "osgfx.h"

#include "osgfx_guest.h"

#include <stdint.h>

extern void com1_puts(const char *s);

extern struct OsGfxGuestCmd osgfx_guest_cmd;

const char osgfx_desk_gen_door[] = "osgfx-desk-gen";

enum { OSGFX_DESK_COLS = 2048 };
enum { OSGFX_DESK_SCALE = 8192 };

static int desk_nx[OSGFX_DESK_COLS];
static int desk_gen_noted;

static int desk_gen_noted_once(void) {
  if (desk_gen_noted != 0) {
    return 0;
  }
  desk_gen_noted = 1;
  com1_puts("OSGFX DESK GEN\n");
  return 1;
}

static int desk_norm_x(int x, int w) {
  return ((x * OSGFX_DESK_SCALE) + (w >> 1)) / w;
}

static int desk_norm_y(int y, int h) {
  return ((y * OSGFX_DESK_SCALE) + (h >> 1)) / h;
}

static int desk_dither(int x, int y) {
  return ((x & 7) * 3 + (y & 7) * 5) & 7;
}

static int desk_field_n(int nx, int ny, int tx, int ty, int t) {
  int base;
  int v;
  int i;
  int sx;
  int sy;
  int p;

  base = (nx * 5 + ny * 9 + (t & 255)) >> 5;
  if (base > 255) {
    base = 255;
  }
  v = 0;
  sx = nx + tx;
  sy = ny + ty;
  i = 0;
  while (i < 3) {
    p = sx * 73 + sy * 151 + t + (i * 0x9E3779);
    p = ((p * 1103515245 + 12345) >> 16) & 255;
    v = v + (p >> (i + 3));
    sx = (sx + (ny >> 2)) >> 1;
    sy = (sy + (nx >> 2)) >> 1;
    i = i + 1;
  }
  v = base + (v >> 1);
  if (v > 255) {
    v = 255;
  }
  return v;
}

static uint32_t desk_rgb_n(int nx, int ny, int x, int y, int cw, int ch, int tx,
                           int ty, int t) {
  int f;
  int r;
  int g;
  int b;
  int cx;
  int cy;
  int d2;
  int d;

  f = desk_field_n(nx, ny, tx, ty, t);
  d = desk_dither(x, y);
  r = 0x0c + ((f * 0x50) + d) >> 8;
  g = 0x28 + ((f * 0x90) + d) >> 8;
  b = 0x48 + ((f * 0x70) + d) >> 8;
  cx = (cw >> 1) - x;
  cy = (ch >> 1) - y;
  d2 = (cx * cx + cy * cy) >> 12;
  if (d2 > 255) {
    d2 = 255;
  }
  g = g + (((255 - g) * d2) + 128 + d) >> 8;
  if (r > 255) {
    r = 255;
  }
  if (g > 255) {
    g = 255;
  }
  if (b > 255) {
    b = 255;
  }
  return ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

static uint64_t *desk_page(void) {
  uint64_t *p;

  p = (uint64_t *)(uintptr_t)osgfx_guest_cmd.wmpage;
  if (p == 0) {
    return 0;
  }
  if (p[OSGFX_WMPAGE_W_MAGIC] != OSGFX_WMPAGE_MAGIC) {
    return 0;
  }
  return p;
}

static uint64_t desk_key(uint32_t seed, int w, int h) {
  uint64_t k;

  k = 0xD074A17ULL ^ (uint64_t)seed;
  k = k ^ ((uint64_t)(unsigned)w << 17);
  k = k ^ ((uint64_t)(unsigned)h << 33);
  return k | 1ULL;
}

static void desk_fill_nx(int w) {
  int cols;
  int xx;

  cols = w;
  if (cols < 1) {
    cols = 1;
  }
  if (cols > OSGFX_DESK_COLS) {
    cols = OSGFX_DESK_COLS;
  }
  xx = 0;
  while (xx < cols) {
    desk_nx[xx] = desk_norm_x(xx, w);
    xx = xx + 1;
  }
}

static void desk_gen_rect(uint32_t *buf, int w, int h, uint32_t seed) {
  int yy;
  int xx;
  int ny;
  int tx;
  int ty;
  int t;

  if (buf == 0 || w < 1 || h < 1) {
    return;
  }
  desk_fill_nx(w);
  t = (int)seed;
  tx = (int)(seed & 255u);
  ty = (int)((seed >> 8) & 255u);
  yy = 0;
  while (yy < h) {
    ny = desk_norm_y(yy, h);
    xx = 0;
    while (xx < w) {
      buf[yy * w + xx] = desk_rgb_n(desk_nx[xx], ny, xx, yy, w, h, tx, ty, t);
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static void desk_blit(uint32_t *dst, int dpitch, const uint32_t *src, int w, int h,
                      int x0, int y0) {
  int yy;
  int xx;
  uint32_t *drow;
  const uint32_t *srow;

  yy = 0;
  while (yy < h) {
    drow = (uint32_t *)((uint8_t *)dst + (unsigned)(y0 + yy) * (unsigned)dpitch);
    srow = src + (unsigned)yy * (unsigned)w;
    xx = 0;
    while (xx < w) {
      drow[x0 + xx] = srow[xx];
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static uint32_t desk_sample_field(int sx, int sy, int sw, int sh, uint32_t seed) {
  int nx;
  int ny;
  int tx;
  int ty;
  int t;

  if (sw < 1) {
    sw = 1;
  }
  if (sh < 1) {
    sh = 1;
  }
  nx = desk_norm_x(sx, sw);
  ny = desk_norm_y(sy, sh);
  t = (int)seed;
  tx = (int)(seed & 255u);
  ty = (int)((seed >> 8) & 255u);
  return desk_rgb_n(nx, ny, sx, sy, sw, sh, tx, ty, t);
}

static uint32_t desk_sample_at(int sx, int sy, int sw, int sh, uint32_t seed) {
  uint64_t *pg;
  uint32_t *buf;
  int dw;
  int dh;

  pg = desk_page();
  if (pg != 0 && pg[OSGFX_WMPAGE_W_DESK_HAVE] == desk_key(seed, sw, sh)) {
    dw = (int)pg[OSGFX_WMPAGE_W_DESK_W];
    dh = (int)pg[OSGFX_WMPAGE_W_DESK_H];
    if (dw == sw && dh == sh && sx >= 0 && sy >= 0 && sx < dw && sy < dh) {
      buf = (uint32_t *)(uintptr_t)pg[OSGFX_WMPAGE_W_DESK_BUF];
      if (buf != 0) {
        pg[OSGFX_WMPAGE_W_DESK_READS] = pg[OSGFX_WMPAGE_W_DESK_READS] + 1;
        return buf[sy * dw + sx] & 0x00ffffffu;
      }
    }
  }
  return desk_sample_field(sx, sy, sw, sh, seed);
}

void osgfx_fill_desk_cached(uint32_t *fb, int pitch, int x, int y, int w, int h,
                            uint32_t seed) {
  uint64_t *pg;
  uint32_t *buf;
  uint64_t key;
  uint64_t need;

  if (fb == 0 || pitch < 4 || w < 1 || h < 1) {
    return;
  }
  if (osgfx_desk_gen_door[0] == 0) {
    return;
  }
  pg = desk_page();
  key = desk_key(seed, w, h);
  if (pg != 0) {
    need = (uint64_t)(unsigned)w * (uint64_t)(unsigned)h;
    if (need <= pg[OSGFX_WMPAGE_W_DESK_PX]) {
      buf = (uint32_t *)(uintptr_t)pg[OSGFX_WMPAGE_W_DESK_BUF];
      if (buf != 0 && pg[OSGFX_WMPAGE_W_DESK_HAVE] == key &&
          pg[OSGFX_WMPAGE_W_DESK_W] == (uint64_t)(unsigned)w &&
          pg[OSGFX_WMPAGE_W_DESK_H] == (uint64_t)(unsigned)h) {
        desk_blit(fb, pitch, buf, w, h, x, y);
        pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
        return;
      }
      if (buf != 0) {
        desk_gen_rect(buf, w, h, seed);
        pg[OSGFX_WMPAGE_W_DESK_HAVE] = key;
        pg[OSGFX_WMPAGE_W_DESK_W] = (uint64_t)(unsigned)w;
        pg[OSGFX_WMPAGE_W_DESK_H] = (uint64_t)(unsigned)h;
        pg[OSGFX_WMPAGE_W_DESK_REGEN] = pg[OSGFX_WMPAGE_W_DESK_REGEN] + 1;
        desk_blit(fb, pitch, buf, w, h, x, y);
        pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
        desk_gen_noted_once();
        return;
      }
    }
  }
  osgfx_fill_desk_generative(fb, pitch, x, y, w, h, seed, 0);
}

void osgfx_fill_desk_generative(uint32_t *fb, int pitch, int x, int y, int w, int h,
                                uint32_t seed, uint32_t frame) {
  int yy;
  int xx;
  uint8_t *row;
  uint32_t rgb;
  int ny;
  int tx;
  int ty;
  int t;

  (void)frame;
  if (fb == 0 || pitch < 4 || w < 1 || h < 1) {
    return;
  }
  if (osgfx_desk_gen_door[0] == 0) {
    return;
  }
  desk_fill_nx(w);
  t = (int)seed;
  tx = (int)(seed & 255u);
  ty = (int)((seed >> 8) & 255u);
  yy = y;
  while (yy < y + h) {
    row = (uint8_t *)fb + (unsigned)yy * (unsigned)pitch;
    ny = desk_norm_y(yy - y, h);
    xx = x;
    while (xx < x + w) {
      rgb = desk_rgb_n(desk_nx[xx - x], ny, xx - x, yy - y, w, h, tx, ty, t);
      ((uint32_t *)row)[xx] = rgb;
      xx = xx + 1;
    }
    yy = yy + 1;
  }
  desk_gen_noted_once();
}

static int glass_rrect_cover(int px, int py, int x, int y, int w, int h, int r) {
  int cx;
  int cy;
  int dx;
  int dy;
  int d2;
  int outer;
  int inner;

  if (w <= 0 || h <= 0) {
    return 0;
  }
  if (px < x || py < y || px >= x + w || py >= y + h) {
    return 0;
  }
  if (r < 1) {
    return 255;
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
    return 255;
  }
  dx = px - cx;
  dy = py - cy;
  d2 = dx * dx + dy * dy;
  outer = (r + 2) * (r + 2);
  inner = (r > 2) ? (r - 2) * (r - 2) : 0;
  if (d2 <= inner) {
    return 255;
  }
  if (d2 >= outer) {
    return 0;
  }
  return (255 * (outer - d2)) / (outer - inner + 1);
}

static uint32_t glass_mix(uint32_t wall, uint32_t tint) {
  int wr;
  int wg;
  int wb;
  int tr;
  int tg;
  int tb;
  int r;
  int g;
  int b;

  wr = (int)((wall >> 16) & 0xFFu);
  wg = (int)((wall >> 8) & 0xFFu);
  wb = (int)(wall & 0xFFu);
  tr = (int)((tint >> 16) & 0xFFu);
  tg = (int)((tint >> 8) & 0xFFu);
  tb = (int)(tint & 0xFFu);
  r = (wr * 122 + tr * 133) / 255;
  g = (wg * 122 + tg * 133) / 255;
  b = (wb * 122 + tb * 133) / 255;
  return ((uint32_t)(r & 0xff) << 16) | ((uint32_t)(g & 0xff) << 8) |
         (uint32_t)(b & 0xff);
}

void osgfx_glass_frost(uint32_t *dst, int pitch_px, int dw, int dh, int x, int y,
                       int w, int h, int radius, int scr_x0, int scr_y0,
                       uint32_t tint) {
  int yy;
  int xx;
  int sx;
  int sy;
  int i;
  int j;
  int n;
  int cover;
  uint32_t acc_r;
  uint32_t acc_g;
  uint32_t acc_b;
  uint32_t smp;
  uint32_t out;
  uint32_t wall;
  uint32_t seed;
  enum { BLUR_R = 2 };

  if (dst == 0 || pitch_px < 4 || w < 1 || h < 1 || dw < 1 || dh < 1) {
    return;
  }
  int desk_h;

  seed = 0xD074A17u;
  if (osgfx_guest_cmd.desk != 0) {
    seed = (uint32_t)osgfx_guest_cmd.desk;
  }
  desk_h = dh - 48;
  if (desk_h < 1) {
    desk_h = dh;
  }
  yy = y;
  while (yy < y + h) {
    xx = x;
    while (xx < x + w) {
      cover = glass_rrect_cover(xx, yy, x, y, w, h, radius);
      if (cover > 0) {
        acc_r = 0;
        acc_g = 0;
        acc_b = 0;
        n = 0;
        j = -BLUR_R;
        while (j <= BLUR_R) {
          i = -BLUR_R;
          while (i <= BLUR_R) {
            sx = scr_x0 + (xx - x) + i;
            sy = scr_y0 + (yy - y) + j;
            smp = desk_sample_at(sx, sy, dw, desk_h, seed);
            acc_r = acc_r + ((smp >> 16) & 0xFFu);
            acc_g = acc_g + ((smp >> 8) & 0xFFu);
            acc_b = acc_b + (smp & 0xFFu);
            n = n + 1;
            i = i + 1;
          }
          j = j + 1;
        }
        if (n < 1) {
          n = 1;
        }
        wall = (((acc_r / (uint32_t)n) & 0xFFu) << 16) |
               (((acc_g / (uint32_t)n) & 0xFFu) << 8) |
               ((acc_b / (uint32_t)n) & 0xFFu);
        out = glass_mix(wall, tint & 0x00ffffffu);
        /* Client glass is N32 premul. The panel compositor SRC_OVERs this
         * onto the live desk: clear pixels stay 0, and AA fringe RGB is
         * scaled by the same coverage carried in A. */
        out = ((uint32_t)(unsigned)cover << 24) |
              ((((out >> 16) & 0xffu) * (uint32_t)(unsigned)cover / 255u) << 16) |
              ((((out >> 8) & 0xffu) * (uint32_t)(unsigned)cover / 255u) << 8) |
              ((out & 0xffu) * (uint32_t)(unsigned)cover / 255u);
        ((uint32_t *)((uint8_t *)dst + (unsigned)yy * (unsigned)pitch_px))[xx] =
            out;
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}
