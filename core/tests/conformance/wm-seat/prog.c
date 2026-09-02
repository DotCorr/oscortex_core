/* core/tests/conformance/wm-seat/prog.c
 *
 * ADR-0186 — one process, two surfaces, two seats.
 * Avoids shell starvation after the first surface attaches.
 */

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
#define WM_SEAT 6UL
#define WM_SEATGET 8UL

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
static char line[64];
static const char msg[] = "WM SEAT PROG\n";

static void paint(u64 va, u32 c) {
  volatile u32 *p = (volatile u32 *)va;
  u64 i = 0;
  while (i < 64UL * 64UL) {
    p[i] = c;
    i = i + 1;
  }
}

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

void _start(void) {
  wr(msg, sizeof(msg) - 1);

  u64 ha = sys1(SYS_SHMCREATE, 8);
  if (ha >= WM_FLOOR) {
    die(1);
  }
  desc[0] = WM_ATTACH;
  desc[1] = ha;
  desc[2] = 80;
  desc[3] = 80;
  desc[4] = 64;
  desc[5] = 64;
  desc[6] = 0;
  desc[7] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)desc);
  if (va >= WM_FLOOR) {
    die(2);
  }
  paint(va, 0x00C03828U);
  desc[0] = WM_COMMIT;
  desc[1] = ha;
  desc[2] = 0;
  desc[3] = 0;
  desc[4] = 64;
  desc[5] = 64;
  desc[6] = 1;
  sys1(SYS_WMSURFACE, (u64)desc);

  u64 hb = sys1(SYS_SHMCREATE, 8);
  if (hb >= WM_FLOOR) {
    die(3);
  }
  desc[0] = WM_ATTACH;
  desc[1] = hb;
  desc[2] = 200;
  desc[3] = 80;
  desc[4] = 64;
  desc[5] = 64;
  desc[6] = 0;
  desc[7] = 0;
  va = sys1(SYS_WMSURFACE, (u64)desc);
  if (va >= WM_FLOOR) {
    die(4);
  }
  paint(va, 0x001878A8U);
  desc[0] = WM_COMMIT;
  desc[1] = hb;
  desc[2] = 0;
  desc[3] = 0;
  desc[4] = 64;
  desc[5] = 64;
  desc[6] = 1;
  sys1(SYS_WMSURFACE, (u64)desc);

  desc[0] = WM_SEAT;
  desc[1] = ha;
  desc[2] = 0;
  sys1(SYS_WMSURFACE, (u64)desc);
  desc[0] = WM_SEAT;
  desc[1] = hb;
  desc[2] = 1;
  sys1(SYS_WMSURFACE, (u64)desc);

  /* SeatGet with ha in handle still returns bits for any owned window. */
  desc[0] = WM_SEATGET;
  desc[1] = 0;
  u64 bits = sys1(SYS_WMSURFACE, (u64)desc);
  unsigned at = put(0, "WM SEAT BITS ");
  line[at++] = (char)('0' + (bits & 3));
  line[at++] = '\n';
  wr(line, at);

  if (bits != 3UL) {
    die(5 | (bits << 8));
  }
  wr("WM SEAT OK\n", 11);
  for (;;) {
    u64 s = 0;
    while (s < 30000000UL) {
      s = s + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
