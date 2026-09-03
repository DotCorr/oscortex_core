/* Host pixel proof for osgfx_rrect_cover. No QEMU. No Skia.
 * Blends over a stable wallpaper so a second draw is idempotent. */
#include "osgfx.h"

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static uint32_t cover_blend(uint32_t src, uint32_t dst, int cov) {
  unsigned sr, sg, sb, dr, dg, db, a, ia;

  if (cov <= 0) {
    return dst & 0x00ffffffu;
  }
  if (cov >= 250) {
    return src & 0x00ffffffu;
  }
  a = (unsigned)cov;
  ia = 255u - a;
  sr = (src >> 16) & 0xffu;
  sg = (src >> 8) & 0xffu;
  sb = src & 0xffu;
  dr = (dst >> 16) & 0xffu;
  dg = (dst >> 8) & 0xffu;
  db = dst & 0xffu;
  dr = (sr * a + dr * ia) / 255u;
  dg = (sg * a + dg * ia) / 255u;
  db = (sb * a + db * ia) / 255u;
  return (dr << 16) | (dg << 8) | db;
}

static void paint(uint32_t *fb, int stride, int x, int y, int w, int h, int r,
                  uint32_t src, uint32_t wall) {
  int yy;
  int xx;
  int cov;

  yy = y - 2;
  while (yy < y + h + 2) {
    xx = x - 2;
    while (xx < x + w + 2) {
      if (yy >= 0 && xx >= 0) {
        cov = osgfx_rrect_cover(xx, yy, x, y, w, h, r);
        fb[(unsigned)yy * (unsigned)stride + (unsigned)xx] =
            cover_blend(src, wall, cov);
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static int is_wall(uint32_t c, uint32_t wall) {
  return (c & 0x00ffffffu) == (wall & 0x00ffffffu);
}

static int is_src(uint32_t c, uint32_t src) {
  return (c & 0x00ffffffu) == (src & 0x00ffffffu);
}

static int near_white(uint32_t c) {
  unsigned r = (c >> 16) & 0xffu;
  unsigned g = (c >> 8) & 0xffu;
  unsigned b = c & 0xffu;
  return r > 240u && g > 240u && b > 240u;
}

static int tealish(uint32_t c) {
  int r = (int)((c >> 16) & 0xffu);
  int g = (int)((c >> 8) & 0xffu);
  int b = (int)(c & 0xffu);
  (void)b;
  return (g - r) > 40;
}

static int corner_band_ok(uint32_t *fb, int stride, int cx, int cy, int r,
                          uint32_t src, uint32_t wall, const char *tag) {
  int x0 = cx - 1;
  int y0 = cy - 1;
  int x1 = cx + r + 2;
  int y1 = cy + r + 2;
  int xx;
  int yy;
  int n_wall = 0;
  int n_src = 0;
  int n_mix = 0;
  int n_white = 0;
  int shades = 0;
  uint32_t seen[32];
  int si;
  int found;

  yy = y0;
  while (yy < y1) {
    xx = x0;
    while (xx < x1) {
      uint32_t c = fb[(unsigned)yy * (unsigned)stride + (unsigned)xx] &
                   0x00ffffffu;
      found = 0;
      si = 0;
      while (si < shades) {
        if (seen[si] == c) {
          found = 1;
        }
        si = si + 1;
      }
      if (found == 0 && shades < 32) {
        seen[shades] = c;
        shades = shades + 1;
      }
      if (is_wall(c, wall)) {
        n_wall = n_wall + 1;
      } else if (is_src(c, src)) {
        n_src = n_src + 1;
      } else {
        n_mix = n_mix + 1;
      }
      if (near_white(c) && tealish(wall)) {
        n_white = n_white + 1;
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
  if (n_mix < 1) {
    fprintf(stderr, "FAIL %s binary stair (wall=%d src=%d mix=%d shades=%d)\n",
            tag, n_wall, n_src, n_mix, shades);
    return 0;
  }
  if (shades < 3) {
    fprintf(stderr, "FAIL %s only %d shades in corner band\n", tag, shades);
    return 0;
  }
  if (n_white > 0) {
    fprintf(stderr, "FAIL %s %d near-white pixels on teal wallpaper\n", tag,
            n_white);
    return 0;
  }
  return 1;
}

static int outside_ok(uint32_t *fb, int stride, int x, int y, int w, int h,
                      int r, uint32_t wall, const char *tag) {
  int probes[8][2];
  int i;
  uint32_t c;

  probes[0][0] = x - 1;
  probes[0][1] = y - 1;
  probes[1][0] = x + w;
  probes[1][1] = y - 1;
  probes[2][0] = x - 1;
  probes[2][1] = y + h;
  probes[3][0] = x + w;
  probes[3][1] = y + h;
  probes[4][0] = x;
  probes[4][1] = y - 1;
  probes[5][0] = x + w / 2;
  probes[5][1] = y + h;
  probes[6][0] = x - 1;
  probes[6][1] = y + h / 2;
  probes[7][0] = x + w;
  probes[7][1] = y + h / 2;
  i = 0;
  while (i < 8) {
    if (probes[i][0] >= 0 && probes[i][1] >= 0) {
      if (osgfx_rrect_cover(probes[i][0], probes[i][1], x, y, w, h, r) != 0) {
        fprintf(stderr, "FAIL %s outside probe has cover\n", tag);
        return 0;
      }
      c = fb[(unsigned)probes[i][1] * (unsigned)stride +
             (unsigned)probes[i][0]] &
          0x00ffffffu;
      if (!is_wall(c, wall)) {
        fprintf(stderr, "FAIL %s outside-mask pixel %06x != wall %06x at %d,%d\n",
                tag, c, wall, probes[i][0], probes[i][1]);
        return 0;
      }
    }
    i = i + 1;
  }
  return 1;
}

static int interior_ok(uint32_t *fb, int stride, int x, int y, int w, int h,
                       uint32_t src, const char *tag) {
  int px = x + w / 2;
  int py = y + h / 2;
  uint32_t c = fb[(unsigned)py * (unsigned)stride + (unsigned)px] & 0x00ffffffu;
  if (!is_src(c, src)) {
    fprintf(stderr, "FAIL %s interior %06x != src %06x\n", tag, c, src);
    return 0;
  }
  return 1;
}

static int mix_count(uint32_t *fb, int stride, int cx, int cy, int r,
                     uint32_t src, uint32_t wall) {
  int x0 = cx;
  int y0 = cy;
  int x1 = cx + r + 1;
  int y1 = cy + r + 1;
  int xx;
  int yy;
  int n = 0;
  uint32_t c;

  yy = y0;
  while (yy < y1) {
    xx = x0;
    while (xx < x1) {
      c = fb[(unsigned)yy * (unsigned)stride + (unsigned)xx] & 0x00ffffffu;
      if (!is_wall(c, wall) && !is_src(c, src)) {
        n = n + 1;
      }
      xx = xx + 1;
    }
    yy = yy + 1;
  }
  return n;
}

static int abs_diff(int a, int b) {
  if (a > b) {
    return a - b;
  }
  return b - a;
}

/* Centres are (x+r, x+w-r): exact pixel mirrors are not required, but
 * every corner must carry a similar coverage ramp. */
static int mirror_ok(uint32_t *fb, int stride, int x, int y, int w, int h, int r,
                     uint32_t src, uint32_t wall, const char *tag) {
  int tl = mix_count(fb, stride, x, y, r, src, wall);
  int tr = mix_count(fb, stride, x + w - r, y, r, src, wall);
  int bl = mix_count(fb, stride, x, y + h - r, r, src, wall);
  int br = mix_count(fb, stride, x + w - r, y + h - r, r, src, wall);

  if (tl < 1 || tr < 1 || bl < 1 || br < 1) {
    fprintf(stderr, "FAIL %s corner mix tl=%d tr=%d bl=%d br=%d\n", tag, tl, tr,
            bl, br);
    return 0;
  }
  if (abs_diff(tl, tr) > 6 || abs_diff(tl, bl) > 6 || abs_diff(tl, br) > 6) {
    fprintf(stderr, "FAIL %s corner mix spread tl=%d tr=%d bl=%d br=%d\n", tag,
            tl, tr, bl, br);
    return 0;
  }
  return 1;
}

static int same_buf(const uint32_t *a, const uint32_t *b, int n) {
  int i = 0;
  while (i < n) {
    if ((a[i] & 0x00ffffffu) != (b[i] & 0x00ffffffu)) {
      return 0;
    }
    i = i + 1;
  }
  return 1;
}

int main(void) {
  const int SW = 160;
  const int SH = 120;
  const int n = SW * SH;
  uint32_t *fb;
  uint32_t *a;
  uint32_t *b;
  int radii[5];
  uint32_t walls[3];
  uint32_t srcs[3];
  int ri;
  int wi;
  int si;
  int cases = 0;
  int pass = 0;
  int x;
  int y;
  int w;
  int h;
  int r;
  char tag[80];

  radii[0] = 6;
  radii[1] = 8;
  radii[2] = 12;
  radii[3] = 18;
  radii[4] = 24;
  walls[0] = 0x005bc0b7u;
  walls[1] = 0x00184060u;
  walls[2] = 0x00102030u;
  srcs[0] = 0x00e8eef4u;
  srcs[1] = 0x00e8e0d0u;
  srcs[2] = 0x00203040u;

  fb = (uint32_t *)malloc((unsigned)n * sizeof(uint32_t));
  a = (uint32_t *)malloc((unsigned)n * sizeof(uint32_t));
  b = (uint32_t *)malloc((unsigned)n * sizeof(uint32_t));
  if (fb == 0 || a == 0 || b == 0) {
    fprintf(stderr, "FAIL malloc\n");
    return 1;
  }

  ri = 0;
  while (ri < 5) {
    r = radii[ri];
    w = 80;
    h = 64;
    if (r * 2 + 8 > w) {
      w = r * 2 + 16;
    }
    if (r * 2 + 8 > h) {
      h = r * 2 + 16;
    }
    x = 16;
    y = 16;
    wi = 0;
    while (wi < 3) {
      si = 0;
      while (si < 3) {
        snprintf(tag, sizeof(tag), "r%d w%06x s%06x", r, walls[wi], srcs[si]);
        cases = cases + 1;
        {
          int i = 0;
          while (i < n) {
            fb[i] = walls[wi];
            i = i + 1;
          }
        }
        paint(fb, SW, x, y, w, h, r, srcs[si], walls[wi]);
        memcpy(a, fb, (unsigned)n * sizeof(uint32_t));
        paint(fb, SW, x, y, w, h, r, srcs[si], walls[wi]);
        memcpy(b, fb, (unsigned)n * sizeof(uint32_t));
        if (!same_buf(a, b, n)) {
          fprintf(stderr, "FAIL %s not idempotent\n", tag);
        } else if (!outside_ok(fb, SW, x, y, w, h, r, walls[wi], tag)) {
          /* already printed */
        } else if (!interior_ok(fb, SW, x, y, w, h, srcs[si], tag)) {
          /* already printed */
        } else if (!mirror_ok(fb, SW, x, y, w, h, r, srcs[si], walls[wi],
                               tag)) {
          /* already printed */
        } else if (!corner_band_ok(fb, SW, x, y, r, srcs[si], walls[wi],
                                   tag) ||
                   !corner_band_ok(fb, SW, x + w - r, y, r, srcs[si], walls[wi],
                                   tag) ||
                   !corner_band_ok(fb, SW, x, y + h - r, r, srcs[si], walls[wi],
                                   tag) ||
                   !corner_band_ok(fb, SW, x + w - r, y + h - r, r, srcs[si],
                                   walls[wi], tag)) {
          /* already printed */
        } else {
          pass = pass + 1;
        }
        si = si + 1;
      }
      wi = wi + 1;
    }
    ri = ri + 1;
  }

  /* Coverage endpoints. */
  cases = cases + 1;
  if (osgfx_rrect_cover(0, 0, 0, 0, 40, 40, 12) == 0 &&
      osgfx_rrect_cover(20, 20, 0, 0, 40, 40, 12) == 255) {
    pass = pass + 1;
  } else {
    fprintf(stderr, "FAIL coverage endpoints\n");
  }

  /* Title band is a clip of the WINDOW rrect. A short card of height
   * th clamps r and leaves wallpaper at the title/body seam. */
  {
    int th = 32;
    int wr = 18;
    int tw = 80;
    int thgt = 64;
    uint32_t wall = 0x005bc0b7u;
    uint32_t src = 0x00e8eef4u;
    int i;
    int seam;

    cases = cases + 1;
    i = 0;
    while (i < n) {
      fb[i] = wall;
      i = i + 1;
    }
    /* Paint only the title band with the full window rrect. */
    {
      int yy = y;
      while (yy < y + th) {
        int xx = x;
        while (xx < x + tw) {
          int cov = osgfx_rrect_cover(xx, yy, x, y, tw, thgt, wr);
          fb[(unsigned)yy * (unsigned)SW + (unsigned)xx] =
              cover_blend(src, wall, cov);
          xx = xx + 1;
        }
        yy = yy + 1;
      }
    }
    seam = 0;
    /* Last title row is past the top radius — must be opaque, not a
     * short-card bottom wedge. */
    if (!is_src(fb[(unsigned)(y + th - 1) * (unsigned)SW + (unsigned)x] &
                    0x00ffffffu,
                src)) {
      seam = 1;
    }
    if (!is_src(fb[(unsigned)(y + th - 1) * (unsigned)SW +
                   (unsigned)(x + tw - 1)] &
                    0x00ffffffu,
                src)) {
      seam = 1;
    }
    if (osgfx_rrect_cover(x, y + th - 1, x, y, tw, th, wr) >= 250) {
      fprintf(stderr, "FAIL title-seam short card is already opaque\n");
      seam = 1;
    }
    if (osgfx_rrect_cover(x, y + th - 1, x, y, tw, thgt, wr) < 250) {
      fprintf(stderr, "FAIL title-seam window rrect is not opaque\n");
      seam = 1;
    }
    if (seam == 0 &&
        corner_band_ok(fb, SW, x, y, wr, src, wall, "title-tl") &&
        corner_band_ok(fb, SW, x + tw - wr, y, wr, src, wall, "title-tr")) {
      pass = pass + 1;
    } else if (seam == 0) {
      /* corner_band_ok printed */
    } else {
      fprintf(stderr, "FAIL title-seam wallpaper wedge at title/body\n");
    }

    cases = cases + 1;
    if (osgfx_rrect_cover(x, y + wr, x, y, tw, thgt, wr) == 255 &&
        osgfx_rrect_cover(x + tw - 1, y + wr, x, y, tw, thgt, wr) == 255 &&
        osgfx_rrect_cover(x - 1, y + wr, x, y, tw, thgt, wr) == 0) {
      pass = pass + 1;
    } else {
      fprintf(stderr, "FAIL title mid-span coverage\n");
    }
  }

  printf("{\"cases\":%d,\"pass\":%d,\"fail\":%d,\"radii\":[6,8,12,18,24],"
         "\"corners_per_case\":4,\"backgrounds\":3,\"fills\":3}\n",
         cases, pass, cases - pass);
  free(fb);
  free(a);
  free(b);
  return pass == cases ? 0 : 1;
}
