/* core/tests/conformance/wm-scale/prog.c — ADR-0185 integer buffer scale 2. */

typedef unsigned long u64;
typedef unsigned int u32;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23

#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_ATTACH 1UL
#define WM_COMMIT 2UL

#define SURF_X 120UL
#define SURF_Y 120UL
#define SURF_W 40UL
#define SURF_H 40UL
#define SCALE 2UL
#define BUF_W (SURF_W * SCALE)
#define BUF_H (SURF_H * SCALE)
#define FILL_A 0x00E05030UL
#define FILL_B 0x0030A070UL
#define PAGES 16UL
#define YIELD_SPIN 20000000UL

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}
static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }
static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }
__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

static u64 desc[8] __attribute__((aligned(64)));
static const char msg[] = "WM SCALE PROG\n";
static const char msg_ok[] = "WM SCALE OK\n";

void _start(void) {
  wr(msg, sizeof(msg) - 1);
  u64 h = sys1(SYS_SHMCREATE, PAGES);
  if (h >= WM_FLOOR) die(0x0C300001UL);

  desc[0] = WM_ATTACH;
  desc[1] = h;
  desc[2] = SURF_X;
  desc[3] = SURF_Y;
  desc[4] = SURF_W;
  desc[5] = SURF_H;
  desc[6] = (SCALE << 32); /* scale in high; stride 0 -> w*scale*4 */
  desc[7] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) die(0x0C300002UL | (va << 32));

  volatile u32 *p = (volatile u32 *)va;
  u64 y = 0;
  while (y < BUF_H) {
    u64 x = 0;
    while (x < BUF_W) {
      /* Checker at buffer resolution: top-left buffer 2x2 of surface (0,0) is A */
      u32 c = FILL_A;
      if (((x / SCALE) + (y / SCALE)) & 1UL) {
        c = (u32)FILL_B;
      }
      p[y * BUF_W + x] = c;
      x = x + 1;
    }
    y = y + 1;
  }

  desc[0] = WM_COMMIT;
  desc[1] = h;
  desc[2] = 0;
  desc[3] = 0;
  desc[4] = SURF_W;
  desc[5] = SURF_H;
  desc[6] = 1;
  if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_FLOOR) die(0x0C300003UL);

  wr(msg_ok, sizeof(msg_ok) - 1);
  for (;;) {
    u64 s = 0;
    while (s < YIELD_SPIN) s = s + 1;
    sys1(SYS_YIELD, 0);
  }
}
