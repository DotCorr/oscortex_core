/* core/user/frame/play.c
 *
 * PLAY.ELF — a FRAME client that attaches a 64×64 video surface.
 * It does not decode (no libavcodec in a FRAME ELF). Hidden `play`
 * / Start copies CLIP.MP4; IRQ0 fills this shm and commits.
 * The attach reply is the address. No 0x10200000-class literal.
 * Size is the kmedia find key — not a titled CSD card (ADR-0196).
 */

#include "osframe.h"

typedef unsigned long u64;
typedef unsigned int u32;

/* Same numbers as osmedia.h OSMEDIA_WIN_*. derive.py restates them. */
#define WIN_W 64UL
#define WIN_H 64UL
#define WIN_X 200UL
#define WIN_Y 80UL
#define WIN_PAGES 4UL

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

/* NON-ZERO so the RW PT_LOAD has a non-zero p_filesz. */
static volatile u64 marker = 0x00C0408800C04088UL;

static const char msg_attach[] = "PLAY ATTACH\n";

void _start(void) {
  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_RET_FLOOR) {
    die(0xC0400002UL);
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = WIN_X;
  desc[WM_DESC_Y] = WIN_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_RET_FLOOR) {
    die(0xC0400003UL | (va << 32));
  }
  wr(msg_attach, sizeof(msg_attach) - 1);

  if (marker != 0x00C0408800C04088UL) {
    die(0xC0400006UL);
  }

  (void)va;
  for (;;) {
    volatile u64 spin = 0;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
