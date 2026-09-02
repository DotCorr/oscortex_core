/* core/tests/conformance/de-wm/win.c
 *
 * Resident compositor client for the DE-wm harness. Same geometry as
 * de-chrome WIN.ELF so close / panel probes stay derived. Title-drag
 * (ADR-0111) moves this origin; the fill must follow.
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
#define D_OP 0
#define D_HANDLE 1
#define D_X 2
#define D_Y 3
#define D_W 4
#define D_H 5
#define D_STRIDE 6
#define D_OFFSET 7
#define D_SEQ 6

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
static volatile u64 marker = 0x00DE011100DE0111UL;
static u64 scratch[8];

static const char msg_attach[] = "DE WM ATTACH\n";
static const char msg_commit[] = "DE WM COMMIT\n";

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
    die(0xDE011102UL);
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
    die(0xDE011103UL | (va << 32));
  }
  wr(msg_attach, sizeof(msg_attach) - 1);

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
    die(0xDE011104UL | (frames << 32));
  }
  wr(msg_commit, sizeof(msg_commit) - 1);
  scratch[0] = frames;
  if (marker != 0x00DE011100DE0111UL) {
    die(0xDE011106UL);
  }

  for (;;) {
    volatile u64 spin = 0;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
