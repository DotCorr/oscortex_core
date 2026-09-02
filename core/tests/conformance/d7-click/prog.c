/* core/tests/conformance/d7-click/prog.c
 *
 * D7's test program: TWO CLIENTS, ONE SOURCE, a click in the overlap.
 *
 * Side 0 (red, behind) attaches, commits, yields, then drains wmevent.
 * Side 1 (blue, on top) attaches, commits, polls wmevent during a busy
 * hold. The harness clicks the overlap while side 1 is holding, then
 * clicks the desktop. Side 1 must print the overlap press with the
 * host-derived surface-relative coordinates; side 0 must print NONE;
 * the desktop click is printed by neither.
 *
 * SYS_WMEVENT is declared here, not in oslibc.h -- docs/syscall-registry.md
 * records that 25 lives in exactly two places.
 *
 * Freestanding: no libc. `proc coop` enters at e_entry with an EMPTY STACK
 * and no argv (GAP-0149), so this file defines its own entry point.
 */

typedef unsigned long u64;
typedef unsigned int u32;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_CHANOPEN 13
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23
#define SYS_WMEVENT 25

#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_ATTACH 1UL
#define WM_COMMIT 2UL
#define D_OP 0
#define D_HANDLE 1
#define D_X 2
#define D_Y 3
#define D_W 4
#define D_H 5
#define D_STRIDE 6
#define D_OFFSET 7
#define D_SEQ 6

#define WM_EV_POP 0UL

#define WIN_W 240UL
#define WIN_H 160UL
#define A_X 100UL
#define A_Y 120UL
#define B_X 260UL
#define B_Y 220UL
#define A_FILL 0x00C03828UL
#define B_FILL 0x001878A8UL
#define WIN_PAGES 38UL

/* Busy-spin bounds. Volatile so -O2 cannot delete them. Long enough that
 * the harness can inject both clicks inside the hold, short enough that a
 * broken kernel produces a diagnosis rather than a hung qemu. */
#define HOLD1SPIN 800000000UL
#define HOLD2SPIN 200000000UL

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

static u64 desc[8] __attribute__((aligned(64))) = {0, 0, 0, 0, 0, 0, 0, 0};
static volatile u64 marker = 0x00D70000000000D7UL;
static u64 scratch[8];

static char line[80];

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

static unsigned puthex(unsigned at, u64 v, unsigned digits) {
  static const char D[] = "0123456789ABCDEF";
  unsigned i = digits;
  while (i--) {
    line[at++] = D[(v >> (i * 4)) & 0xF];
  }
  return at;
}

static void emit(unsigned n) { sys3(SYS_WRITE, (u64)line, n, 0); }

static void report(const char *tag, u64 ev) {
  unsigned n = put(0, tag);
  if (ev == 0) {
    n = put(n, " NONE\n");
  } else {
    n = put(n, " PRESS ");
    n = puthex(n, (ev >> 16) & 0xFFFFUL, 4);
    n = put(n, " ");
    n = puthex(n, (ev >> 32) & 0xFFFFUL, 4);
    n = put(n, "\n");
  }
  emit(n);
}

static u64 paint(u64 side, u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u32 c = (u32)((side == 0) ? A_FILL : B_FILL);
  u64 sum = 0;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      p[py * WIN_W + px] = c;
      sum += (u64)c;
      px++;
    }
    py++;
  }
  return sum;
}

void _start(void) {
  u64 ep = sys1(SYS_CHANOPEN, 0);
  if (ep >= WM_FLOOR) {
    die(0xD7000001UL);
  }
  u64 side = ep & 1UL;

  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_FLOOR) {
    die(0xD7000002UL);
  }

  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = h;
  desc[D_X] = (side == 0) ? A_X : B_X;
  desc[D_Y] = (side == 0) ? A_Y : B_Y;
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_STRIDE] = 0;
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) {
    die(0xD7000003UL | (va << 32));
  }

  u64 sum = paint(side, va);

  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = h;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_SEQ] = 1;
  desc[7] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_FLOOR) {
    die(0xD7000004UL | (frames << 32));
  }
  scratch[0] = frames;
  scratch[1] = sum;

  if (side == 0) {
    sys1(SYS_YIELD, 0);
    report("D7 A", sys1(SYS_WMEVENT, WM_EV_POP));
  } else {
    /* 9. THE HOLD. Busy, not a yield loop -- see this file's header. */
    {
      volatile u64 spin = 0;
      u64 ev = 0;
      wr("D7 HOLD1\n", 9);
      while (spin < HOLD1SPIN) {
        ev = sys1(SYS_WMEVENT, WM_EV_POP);
        if (ev != 0) {
          break;
        }
        spin = spin + 1;
      }
      report("D7 B", ev);
      wr("D7 HOLD2\n", 9);
      /* Busy spin with no syscall. A pop per increment would turn
       * 200 million iterations into 200 million ring-3 entries and
       * the harness would time out waiting for D7 B2. */
      spin = 0;
      while (spin < HOLD2SPIN) {
        spin = spin + 1;
      }
      report("D7 B2", sys1(SYS_WMEVENT, WM_EV_POP));
    }
  }

  if (marker != 0x00D70000000000D7UL) {
    die(0xD7000006UL);
  }
  die((side << 56) | (scratch[0] << 48) | (scratch[1] & 0x0000FFFFFFFFFFFFUL));
}
