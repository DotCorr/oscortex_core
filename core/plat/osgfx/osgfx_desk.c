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

/* Guest CRT memcpy is a byte loop. TCG turns `rep movsl` into a host
 * copy, which is what a 1274×666 uncover must use or restore stays ≥1s. */
static void desk_movs(uint32_t *dst, const uint32_t *src, unsigned n) {
  uint32_t *d;
  const uint32_t *s;
  unsigned c;

  if (n == 0u || dst == 0 || src == 0) {
    return;
  }
  d = dst;
  s = src;
  c = n;
  asm volatile("rep movsl" : "+D"(d), "+S"(s), "+c"(c) : : "memory");
}

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
  static const uint8_t bayer8[64] = {
      0,  48, 12, 60, 3,  51, 15, 63, 32, 16, 44, 28, 35, 19, 47, 31,
      8,  56, 4,  52, 11, 59, 7,  55, 40, 24, 36, 20, 43, 27, 39, 23,
      2,  50, 14, 62, 1,  49, 13, 61, 34, 18, 46, 30, 33, 17, 45, 29,
      10, 58, 6,  54, 9,  57, 5,  53, 42, 26, 38, 22, 41, 25, 37, 21};
  /* Scale the 0..63 threshold across one complete 8-bit quantisation step.
   * Adding 0..7, as the old hash did, affected only one pixel in 32 and left
   * broad equal-colour bands in a slowly changing field. */
  return (int)bayer8[((y & 7) << 3) | (x & 7)] * 4 + 2;
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
  r = 0x0c + (((f * 0x50) + d) >> 8);
  g = 0x28 + (((f * 0x90) + d) >> 8);
  b = 0x48 + (((f * 0x70) + d) >> 8);
  cx = (cw >> 1) - x;
  cy = (ch >> 1) - y;
  d2 = (cx * cx + cy * cy) >> 12;
  if (d2 > 255) {
    d2 = 255;
  }
  g = g + ((((255 - g) * d2) + 128 + d) >> 8);
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

/* Sub-rect copy from an existing full-field cache. Identity is (sw, sh);
 * (x0, y0, w, h) is the screen hole. Never divides. */
static void desk_blit_rect(uint32_t *dst, int dpitch, const uint32_t *src,
                           int sw, int sh, int x0, int y0, int w, int h) {
  int yy;
  uint32_t *drow;
  const uint32_t *srow;

  if (src == 0 || dst == 0 || sw < 1 || sh < 1 || w < 1 || h < 1) {
    return;
  }
  if (x0 < 0) {
    w = w + x0;
    x0 = 0;
  }
  if (y0 < 0) {
    h = h + y0;
    y0 = 0;
  }
  if (x0 + w > sw) {
    w = sw - x0;
  }
  if (y0 + h > sh) {
    h = sh - y0;
  }
  if (w < 1 || h < 1) {
    return;
  }
  yy = 0;
  while (yy < h) {
    drow = (uint32_t *)((uint8_t *)dst + (unsigned)(y0 + yy) * (unsigned)dpitch);
    srow = src + (unsigned)(y0 + yy) * (unsigned)sw + (unsigned)x0;
    desk_movs(drow + x0, srow, (unsigned)w);
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

const uint32_t *osgfx_desk_cache(int *w, int *h) {
  uint64_t *pg;
  uint32_t *buf;
  int dw;
  int dh;

  pg = desk_page();
  if (pg == 0) {
    return 0;
  }
  buf = (uint32_t *)(uintptr_t)pg[OSGFX_WMPAGE_W_DESK_BUF];
  dw = (int)pg[OSGFX_WMPAGE_W_DESK_W];
  dh = (int)pg[OSGFX_WMPAGE_W_DESK_H];
  if (buf == 0 || dw < 1 || dh < 1) {
    return 0;
  }
  if (w != 0) {
    *w = dw;
  }
  if (h != 0) {
    *h = dh;
  }
  return buf;
}

void osgfx_fill_desk_cached(uint32_t *fb, int pitch, int x, int y, int w, int h,
                            uint32_t seed) {
  uint64_t *pg;
  uint32_t *buf;
  uint64_t need;
  int have_w;
  int have_h;

  if (fb == 0 || pitch < 4 || w < 1 || h < 1) {
    return;
  }
  if (osgfx_desk_gen_door[0] == 0) {
    return;
  }
  pg = desk_page();
  if (pg != 0) {
    buf = (uint32_t *)(uintptr_t)pg[OSGFX_WMPAGE_W_DESK_BUF];
    have_w = (int)pg[OSGFX_WMPAGE_W_DESK_W];
    have_h = (int)pg[OSGFX_WMPAGE_W_DESK_H];
    /* Hit: any rect inside the sealed full-field cache. Uncover holes
     * must not rekey the cache to the hole size — that regenerated a
     * small field, restamped HAVE, and blitted wallpaper from (0,0). */
    if (buf != 0 && have_w > 0 && have_h > 0 &&
        pg[OSGFX_WMPAGE_W_DESK_HAVE] == desk_key(seed, have_w, have_h) &&
        x >= 0 && y >= 0 && x + w <= have_w && y + h <= have_h) {
      desk_blit_rect(fb, pitch, buf, have_w, have_h, x, y, w, h);
      pg[OSGFX_WMPAGE_W_DESK_BLITS] = pg[OSGFX_WMPAGE_W_DESK_BLITS] + 1;
      return;
    }
    /* Full generate only at the origin for a new identity. */
    if (buf != 0 && x == 0 && y == 0) {
      need = (uint64_t)(unsigned)w * (uint64_t)(unsigned)h;
      if (need <= pg[OSGFX_WMPAGE_W_DESK_PX]) {
        desk_gen_rect(buf, w, h, seed);
        pg[OSGFX_WMPAGE_W_DESK_HAVE] = desk_key(seed, w, h);
        pg[OSGFX_WMPAGE_W_DESK_W] = (uint64_t)(unsigned)w;
        pg[OSGFX_WMPAGE_W_DESK_H] = (uint64_t)(unsigned)h;
        pg[OSGFX_WMPAGE_W_DESK_REGEN] = pg[OSGFX_WMPAGE_W_DESK_REGEN] + 1;
        desk_blit(fb, pitch, buf, w, h, 0, 0);
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
  int sx;
  int sy;
  int sample_x;
  int sample_y;
  int cx;
  int cy;
  int dx;
  int dy;
  int rr;
  int hits;

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
  if (px >= x + r && px < x + w - r) {
    return 255;
  }
  if (py >= y + r && py < y + h - r) {
    return 255;
  }

  /* A real 4x4 area sample in fixed point. The old squared-distance ramp
   * spread the edge across four pixels and used centres that differed by one
   * pixel at the right/bottom corners. Besides looking soft rather than
   * antialiased, that asymmetry exposed dark scratch pixels at dock tips.
   *
   * Units are eighths of a pixel; samples are at 1/8, 3/8, 5/8 and 7/8.
   * This matches SkRRect's geometric centres (x+r, x+w-r), and yields
   * coverage only for the pixel area actually inside the curve. */
  rr = r * 8;
  hits = 0;
  sy = 0;
  while (sy < 4) {
    sample_y = py * 8 + 1 + sy * 2;
    if (sample_y < (y + r) * 8) {
      cy = (y + r) * 8;
    } else if (sample_y > (y + h - r) * 8) {
      cy = (y + h - r) * 8;
    } else {
      cy = sample_y;
    }
    sx = 0;
    while (sx < 4) {
      sample_x = px * 8 + 1 + sx * 2;
      if (sample_x < (x + r) * 8) {
        cx = (x + r) * 8;
      } else if (sample_x > (x + w - r) * 8) {
        cx = (x + w - r) * 8;
      } else {
        cx = sample_x;
      }
      dx = sample_x - cx;
      dy = sample_y - cy;
      if (dx * dx + dy * dy <= rr * rr) {
        hits = hits + 1;
      }
      sx = sx + 1;
    }
    sy = sy + 1;
  }
  return (hits * 255 + 8) / 16;
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
  int x0;
  int x1;
  int y0;
  int y1;
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
  x0 = x < 0 ? 0 : x;
  y0 = y < 0 ? 0 : y;
  x1 = x + w;
  y1 = y + h;
  if (x1 > dw) {
    x1 = dw;
  }
  if (y1 > dh) {
    y1 = dh;
  }
  if (x0 >= x1 || y0 >= y1 || pitch_px < dw) {
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
  yy = y0;
  while (yy < y1) {
    xx = x0;
    while (xx < x1) {
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
        dst[(unsigned)yy * (unsigned)pitch_px + (unsigned)xx] = out;
      } else {
        /* WM_PAINT_GLASS targets premultiplied client scratch. Outside the
         * rrect is transparent, never stale RGB or opaque black. */
        dst[(unsigned)yy * (unsigned)pitch_px + (unsigned)xx] = 0;
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}
