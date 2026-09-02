/* core/tests/conformance/de-chrome/ping.c
 *
 * Spawn target for the start / spotlight row. Prints a derived line
 * (`DE CHROME PING`) and attaches a small surface so the reflection
 * panel lists a second name. Geometry is named so derive.py reads it
 * and so the window does not cover WIN.ELF's close affordance.
 */

#include "osframe.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

#define D_OP 0
#define D_HANDLE 1
#define D_X 2
#define D_Y 3
#define D_W 4
#define D_H 5
#define D_STRIDE 6
#define D_OFFSET 7
#define D_SEQ 6

#define PING_W 160UL
#define PING_H 120UL
#define PING_X 400UL
#define PING_Y 80UL
#define PING_FILL 0x00203848UL
#define PING_PAGES 20UL
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
static volatile u64 marker = 0x00DE000200DE0002UL;

static const char msg_ping[] = "DE CHROME PING\n";
static const char msg_commit[] = "DE PING COMMIT\n";
static const char msg_csd[] = "PING CSD";
static const char cap_ping[] = "PING";

static void paint(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < PING_H) {
    u64 px = 0;
    while (px < PING_W) {
      p[py * PING_W + px] = (u32)PING_FILL;
      px = px + 1;
    }
    py = py + 1;
  }
}

void _start(void) {
  wr(msg_ping, sizeof(msg_ping) - 1);

  u64 h = sys1(SYS_SHMCREATE, PING_PAGES);
  if (h >= WM_RET_FLOOR) {
    die(0xDE000102UL);
  }

  desc[D_OP] = WM_OP_ATTACH;
  desc[D_HANDLE] = h;
  desc[D_X] = PING_X;
  desc[D_Y] = PING_Y;
  desc[D_W] = PING_W;
  desc[D_H] = PING_H;
  desc[D_STRIDE] = 0;
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_RET_FLOOR) {
    die(0xDE000103UL | (va << 32));
  }

  paint(va);
  osxui_app_csd(h, PING_W, cap_ping, 4UL);
  wr(msg_csd, sizeof(msg_csd) - 1);

  desc[D_OP] = WM_OP_COMMIT;
  desc[D_HANDLE] = h;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = PING_W;
  desc[D_H] = PING_H;
  desc[D_SEQ] = 1;
  desc[7] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    die(0xDE000104UL | (frames << 32));
  }
  wr(msg_commit, sizeof(msg_commit) - 1);
  if (marker != 0x00DE000200DE0002UL) {
    die(0xDE000106UL);
  }

  for (;;) {
    volatile u64 spin = 0;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
