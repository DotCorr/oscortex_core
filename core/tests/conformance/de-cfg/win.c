/* core/tests/conformance/de-cfg/win.c
 *
 * Resident client for ADR-0142. Attaches, commits, then drains
 * syscall 25. Under `wm de` the first pop is configure (granted
 * geom). A later focus change is enter/leave. A resize is another
 * configure. Without `wm de` the first pop is empty — the
 * compositor placed the window and the client was not told.
 *
 * SYS_WMEVENT is declared here, not in oslibc.h.
 */

typedef unsigned long u64;
typedef unsigned int u32;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23
#define SYS_WMEVENT 25UL

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
#define WMEVENT_TYPE_PRESS 1UL
#define WMEVENT_TYPE_CONFIGURE 2UL
#define WMEVENT_TYPE_ENTER 3UL
#define WMEVENT_TYPE_LEAVE 4UL

#define WIN_W 240UL
#define WIN_H 160UL
#define A_X 100UL
#define A_Y 120UL
#define A_FILL 0x00C03828UL
#define A_INK 0x00F0C020UL
#define INK_INSET 40UL
#define WIN_PAGES 38UL
#define YIELD_SPIN 40000000UL

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
static volatile u64 marker = 0x00DE014200DE0142UL;
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

static void report(u64 ev) {
  unsigned n = put(0, "DE CFG ");
  u64 typ = ev & 0xFFUL;
  if (ev == 0) {
    n = put(n, "NONE\n");
  } else if (typ == WMEVENT_TYPE_CONFIGURE) {
    n = put(n, "CONFIGURE ");
    n = puthex(n, (ev >> 16) & 0xFFFUL, 4);
    n = put(n, " ");
    n = puthex(n, (ev >> 28) & 0xFFFUL, 4);
    n = put(n, " ");
    n = puthex(n, (ev >> 40) & 0xFFFUL, 4);
    n = put(n, " ");
    n = puthex(n, (ev >> 52) & 0xFFFUL, 4);
    n = put(n, "\n");
  } else if (typ == WMEVENT_TYPE_ENTER) {
    n = put(n, "ENTER\n");
  } else if (typ == WMEVENT_TYPE_LEAVE) {
    n = put(n, "LEAVE\n");
  } else if (typ == WMEVENT_TYPE_PRESS) {
    n = put(n, "PRESS ");
    n = puthex(n, (ev >> 16) & 0xFFFFUL, 4);
    n = put(n, " ");
    n = puthex(n, (ev >> 32) & 0xFFFFUL, 4);
    n = put(n, "\n");
  } else {
    n = put(n, "OTHER ");
    n = puthex(n, ev, 16);
    n = put(n, "\n");
  }
  emit(n);
}

static u32 pixel_of(u64 px, u64 py) {
  u64 ink = 0;
  if (px >= INK_INSET) {
    if (px < (WIN_W - INK_INSET)) {
      if (py >= INK_INSET) {
        if (py < (WIN_H - INK_INSET)) {
          ink = 1;
        }
      }
    }
  }
  if (ink > 0) {
    return (u32)A_INK;
  }
  return (u32)A_FILL;
}

static void paint(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      p[py * WIN_W + px] = pixel_of(px, py);
      px = px + 1;
    }
    py = py + 1;
  }
}

void _start(void) {
  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_FLOOR) {
    die(0xDE014202UL);
  }

  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = h;
  desc[D_X] = A_X;
  desc[D_Y] = A_Y;
  desc[D_W] = WIN_W;
  desc[D_H] = WIN_H;
  desc[D_STRIDE] = 0;
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) {
    die(0xDE014203UL | (va << 32));
  }
  wr("DE CFG ATTACH\n", 14);

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
    die(0xDE014204UL | (frames << 32));
  }
  wr("DE CFG COMMIT\n", 14);
  scratch[0] = frames;
  if (marker != 0x00DE014200DE0142UL) {
    die(0xDE014206UL);
  }

  report(sys1(SYS_WMEVENT, WM_EV_POP));

  for (;;) {
    u64 ev = sys1(SYS_WMEVENT, WM_EV_POP);
    if (ev != 0) {
      report(ev);
    }
    {
      volatile u64 spin = 0;
      while (spin < YIELD_SPIN) {
        spin = spin + 1;
      }
    }
    sys1(SYS_YIELD, 0);
  }
}
