/* core/tests/conformance/hid-sess/prog.c
 *
 * ADR-0138 session client: one surface, proc spawn residency, pops
 * syscall 24. The harness focuses this window, then injects a USB
 * HID report through COM1 `usb feed` (no usb-kbd). The focused
 * kbdevent path must print the derived make+break sequence.
 *
 * Freestanding: no libc. Empty stack, no argv.
 */

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
#define WIN_X 200UL
#define WIN_Y 180UL
#define WIN_FILL 0x001878A8UL
#define WIN_PAGES 38UL

#define SEQ_N 2UL
#define HOLD_ROUNDS 800UL
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

static void report(u64 n, const u64 *ev) {
  unsigned at = put(0, "HID SESS");
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

static void paint(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u32 c = (u32)WIN_FILL;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      p[py * WIN_W + px] = c;
      px++;
    }
    py++;
  }
}

void _start(void) {
  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_FLOOR) {
    die(0x13800002UL);
  }

  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = h;
  desc[D_X] = WIN_X;
  desc[D_Y] = WIN_Y;
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_STRIDE] = 0;
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) {
    die(0x13800003UL | (va << 32));
  }

  paint(va);

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
    die(0x13800004UL | (frames << 32));
  }

  {
    u64 junk = 0;
    while (sys1(SYS_KBDEVENT, KBD_POP) != 0) {
      junk = junk + 1;
      if (junk > 64) {
        break;
      }
    }
  }

  {
    volatile u64 spin = 0;
    u64 got = 0;
    wr("HID HOLD\n", 9);
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
    report(got >= SEQ_N ? SEQ_N : got, seq);
  }

  die(0);
}
