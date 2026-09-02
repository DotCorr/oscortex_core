/* core/tests/conformance/d9-focus/prog.c
 *
 * D9's test program: TWO CLIENTS, ONE SOURCE, keyboard focus.
 *
 * Built twice (`-DSIDE=0` and `-DSIDE=1`) so `proc run` loads two
 * programs, not one program twice. Side 0 (red) is the unfocused
 * window; side 1 (blue) is clicked. Both attach, commit, discard
 * leftover scancodes, then poll syscall 24, burn, and yield. The burn
 * is what keeps the unfocused client alive through the other client's
 * compose; yield is what lets it finish once it is alone.
 *
 * The harness clicks a point that is ONLY inside side 1, then injects
 * derived keys. Side 1 must print the derived make+break sequence;
 * side 0 must print NONE. That is the focus gate: the queue is still
 * global, so without the gate either client could pop.
 *
 * SYS_KBDEVENT is declared here, not in oslibc.h -- docs/syscall-registry.md
 * records that 24 lives in the kernel and the harnesses that use it.
 *
 * Freestanding: no libc. `proc run` enters at e_entry with an EMPTY STACK
 * and no argv (GAP-0149), so this file defines its own entry point.
 */

#ifndef SIDE
#define SIDE 0
#endif

typedef unsigned long u64;
typedef unsigned int u32;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23
#define SYS_KBDEVENT 24

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

#define KBD_POP 0UL

#define WIN_W 240UL
#define WIN_H 160UL
#define A_X 100UL
#define A_Y 120UL
#define B_X 260UL
#define B_Y 220UL
#define A_FILL 0x00C03828UL
#define B_FILL 0x001878A8UL
#define WIN_PAGES 38UL

#define SEQ_N 6UL
#define HOLD_ROUNDS 400UL
#define HOLD_BURN 40000000UL

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
static volatile u64 marker = 0x00D90000000000D9UL;
static u64 scratch[8];
static u64 seq[SEQ_N];

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

static void report(const char *tag, u64 n, const u64 *ev) {
  unsigned at = put(0, tag);
  if (n == 0) {
    at = put(at, " NONE\n");
  } else {
    at = put(at, " SEQ N ");
    at = puthex(at, n, 2);
    at = put(at, " ");
    u64 i = 0;
    while (i < n) {
      at = puthex(at, ev[i], 3);
      at = put(at, " ");
      i = i + 1;
    }
    at = put(at, "\n");
  }
  emit(at);
}

static u64 paint(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u32 c = (u32)((SIDE == 0) ? A_FILL : B_FILL);
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
  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_FLOOR) {
    die(0xD9000002UL);
  }

  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = h;
  if (SIDE == 0) {
    desc[D_X] = A_X;
    desc[D_Y] = A_Y;
  } else {
    desc[D_X] = B_X;
    desc[D_Y] = B_Y;
  }
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_STRIDE] = 0;
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) {
    die(0xD9000003UL | (va << 32));
  }

  u64 sum = paint(va);

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
    die(0xD9000004UL | (frames << 32));
  }
  scratch[0] = frames;
  scratch[1] = sum;

  {
    u64 junk = 0;
    while (sys1(SYS_KBDEVENT, KBD_POP) != 0) {
      junk = junk + 1;
      if (junk > 64) {
        break;
      }
    }
  }

    /* 9. THE HOLD. Pop then yield -- see this file's header. */
    {
      volatile u64 spin = 0;
      u64 got = 0;
      if (SIDE == 0) {
        wr("D9 A HOLD\n", 10);
      } else {
        wr("D9 B HOLD\n", 10);
      }
      while (spin < HOLD_ROUNDS) {
        u64 ev = sys1(SYS_KBDEVENT, KBD_POP);
        if (ev != 0) {
          if (got < SEQ_N) {
            seq[got] = ev;
          }
          got = got + 1;
          if (got >= SEQ_N) {
            break;
          }
        }
        {
          volatile u64 burn = 0;
          while (burn < HOLD_BURN) {
            burn = burn + 1;
          }
        }
        sys1(SYS_YIELD, 0);
        spin = spin + 1;
      }
      if (SIDE == 0) {
        report("D9 A", got, seq);
      } else {
        report("D9 B", got, seq);
      }
    }

  if (marker != 0x00D90000000000D9UL) {
    die(0xD9000006UL);
  }
  die(((u64)SIDE << 56) | (scratch[0] << 48) | (scratch[1] & 0x0000FFFFFFFFFFFFUL));
}
