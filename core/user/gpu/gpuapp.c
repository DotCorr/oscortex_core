/* core/user/gpu/gpuapp.c — a game-shaped client of osgpu.h.
 *
 * Calls create / submit(CLEAR) / readback. Does not paint UI.
 * Does not include osgfx.h. A FRAME surface app never needs this.
 * Freestanding; no oslibc.h. Writes OSGPU 1 then the three
 * return codes. Without a syscall the stub is NONE — the derived
 * GPU pixel is the kernel `osgpug` walk (G10 virgl).
 */

#include "osgpu.h"

typedef unsigned long u64;

#define SYS_EXIT 0UL
#define SYS_WRITE 1UL

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

__attribute__((noreturn)) static void die(u64 code) {
  sys3(SYS_EXIT, code, 0, 0);
  for (;;) {
  }
}

static volatile u64 marker = 0x00A01140000011A0UL;

static char line[32];

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

static unsigned putn(unsigned at, int v) {
  if (v < 0) {
    line[at++] = '-';
    v = -v;
  }
  line[at++] = (char)('0' + (v % 10));
  return at;
}

void _start(void) {
  struct osgpu_ctx ctx;
  unsigned int pix;
  int c;
  int s;
  int r;
  unsigned n;

  (void)marker;
  pix = 0;
  c = osgpu_create(&ctx);
  s = osgpu_submit(&ctx, OSGPU_KIND_CLEAR);
  r = osgpu_readback(&ctx, &pix);

  n = put(0, "OSGPU 1\n");
  wr(line, (u64)n);
  n = put(0, "OSGPU C ");
  n = putn(n, c);
  line[n++] = '\n';
  wr(line, (u64)n);
  n = put(0, "OSGPU S ");
  n = putn(n, s);
  line[n++] = '\n';
  wr(line, (u64)n);
  n = put(0, "OSGPU R ");
  n = putn(n, r);
  line[n++] = '\n';
  wr(line, (u64)n);
  die(0);
}
