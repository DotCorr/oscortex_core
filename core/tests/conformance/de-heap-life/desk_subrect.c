/* Host proof that a desk-cache uncover hole blits from the sealed full
 * field and does not rekey HAVE to the hole size. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { SW = 32, SH = 24 };

static uint32_t cache[SH * SW];
static uint32_t dest[SH * SW];
static uint64_t have;
static int have_w;
static int have_h;
static int regen;
static int blit;

static uint64_t desk_key(uint32_t seed, int w, int h) {
  uint64_t k;

  k = 0xD074A17ULL ^ (uint64_t)seed;
  k = k ^ ((uint64_t)(unsigned)w << 17);
  k = k ^ ((uint64_t)(unsigned)h << 33);
  return k | 1ULL;
}

static void desk_blit_rect(uint32_t *dst, const uint32_t *src, int sw, int sh,
                           int x0, int y0, int w, int h) {
  int yy;
  int xx;

  yy = 0;
  while (yy < h) {
    xx = 0;
    while (xx < w) {
      dst[(y0 + yy) * sw + (x0 + xx)] = src[(y0 + yy) * sw + (x0 + xx)];
      xx = xx + 1;
    }
    yy = yy + 1;
  }
}

static int fill_cached(int x, int y, int w, int h, uint32_t seed) {
  if (have_w > 0 && have_h > 0 && have == desk_key(seed, have_w, have_h) &&
      x >= 0 && y >= 0 && x + w <= have_w && y + h <= have_h) {
    desk_blit_rect(dest, cache, have_w, have_h, x, y, w, h);
    blit = blit + 1;
    return 0;
  }
  if (x == 0 && y == 0) {
    int yy;
    int xx;
    yy = 0;
    while (yy < h) {
      xx = 0;
      while (xx < w) {
        cache[yy * w + xx] = 0x100000u + (uint32_t)(yy * w + xx);
        xx = xx + 1;
      }
      yy = yy + 1;
    }
    have = desk_key(seed, w, h);
    have_w = w;
    have_h = h;
    regen = regen + 1;
    desk_blit_rect(dest, cache, w, h, 0, 0, w, h);
    blit = blit + 1;
    return 1;
  }
  return -1;
}

int main(void) {
  uint32_t seed;
  int x;
  int y;
  uint64_t first;

  seed = 0xD074A17u;
  memset(cache, 0, sizeof(cache));
  memset(dest, 0, sizeof(dest));
  if (fill_cached(0, 0, SW, SH, seed) != 1) {
    fprintf(stderr, "de-heap-life: FAIL — cold full fill did not generate\n");
    return 1;
  }
  first = have;
  if (regen != 1) {
    fprintf(stderr, "de-heap-life: FAIL — cold REGEN %d, want 1\n", regen);
    return 1;
  }
  /* Uncover a window-sized hole. Must blit, not regen. */
  if (fill_cached(6, 4, 12, 8, seed) != 0) {
    fprintf(stderr, "de-heap-life: FAIL — uncover missed the full cache\n");
    return 1;
  }
  if (regen != 1) {
    fprintf(stderr, "de-heap-life: FAIL — uncover REGEN %d, want 1\n", regen);
    return 1;
  }
  if (have != first || have_w != SW || have_h != SH) {
    fprintf(stderr, "de-heap-life: FAIL — uncover restamped the cache identity\n");
    return 1;
  }
  y = 4;
  while (y < 12) {
    x = 6;
    while (x < 18) {
      if (dest[y * SW + x] != cache[y * SW + x]) {
        fprintf(stderr, "de-heap-life: FAIL — hole pixel %d,%d is not the field\n",
                x, y);
        return 1;
      }
      x = x + 1;
    }
    y = y + 1;
  }
  if (fill_cached(0, 0, SW, SH, seed) != 0) {
    fprintf(stderr, "de-heap-life: FAIL — second full paint regenerated\n");
    return 1;
  }
  if (regen != 1 || blit < 3) {
    fprintf(stderr, "de-heap-life: FAIL — REGEN %d BLIT %d\n", regen, blit);
    return 1;
  }
  printf("de-heap-life: desk subrect REGEN %d BLIT %d identity held\n", regen,
         blit);
  return 0;
}
