/* core/user/frame/btn.c
 *
 * OSXUI2 — a kept FRAME widget: one hit rectangle, two colours.
 * Compiles against osframe.h (no private SYS_*). The osxui2 harness
 * builds it as BTN.ELF and starts it with `proc spawn` (ADR-0053).
 *
 * Attach a 240×160 surface, paint a control that is not the whole
 * surface, commit, then yield-loop kbdevent (24) and wmevent (25).
 * A derived make-scancode or a left press inside the control flips
 * it to the second colour and commits that damage (ADR-0052). A
 * press on the surface but outside the control does not flip.
 *
 * Numbers come from osframe.h and the #defines derive.py reads.
 * This file contains no 0x10200000-class literal.
 */

#include "osframe.h"

typedef unsigned long u64;
typedef unsigned int u32;

/* The picture. derive.py reads every one of these out of this file. */
#define WIN_W 240UL
#define WIN_H 160UL
#define SURF_X 80UL
#define SURF_Y 80UL
#define SURF_FILL 0x00C05028UL
#define CTL_X 48UL
#define CTL_Y 40UL
#define CTL_W 96UL
#define CTL_H 48UL
#define CTL_OFF 0x0020A060UL
#define CTL_ON 0x00E04090UL
#define FLIP_SCAN 0x2DUL
#define WIN_PAGES 38UL

#define YIELD_SPIN 8000000UL

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

/* NON-ZERO so the RW PT_LOAD has a non-zero p_filesz (m11's segment shape). */
static volatile u64 marker = 0x00B70000000000B7UL;

static u64 shm_h;
static u64 pix_va;
static volatile u64 armed = 0;
static u64 scratch[8];

static char line[40];

static const char msg_ready[] = "OSXUI2 READY\n";
static const char msg_miss[] = "OSXUI2 MISS\n";

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

static u32 pixel_of(u64 px, u64 py, u64 on) {
  u64 hit = 0;
  if (px >= CTL_X) {
    if (px < (CTL_X + CTL_W)) {
      if (py >= CTL_Y) {
        if (py < (CTL_Y + CTL_H)) {
          hit = 1;
        }
      }
    }
  }
  if (hit > 0) {
    if (on > 0) {
      return (u32)CTL_ON;
    }
    return (u32)CTL_OFF;
  }
  return (u32)SURF_FILL;
}

static void paint_all(u64 va, u64 on) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      p[py * WIN_W + px] = pixel_of(px, py, on);
      px = px + 1;
    }
    py = py + 1;
  }
}

static void paint_ctl(u64 va, u64 on) {
  volatile u32 *p = (volatile u32 *)va;
  u32 c = (u32)((on > 0) ? CTL_ON : CTL_OFF);
  u64 py = CTL_Y;
  while (py < (CTL_Y + CTL_H)) {
    u64 px = CTL_X;
    while (px < (CTL_X + CTL_W)) {
      p[py * WIN_W + px] = c;
      px = px + 1;
    }
    py = py + 1;
  }
}

static void commit_rect(u64 x, u64 y, u64 w, u64 h, u64 seq) {
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = x;
  desc[WM_DESC_Y] = y;
  desc[WM_DESC_W] = w;
  desc[WM_DESC_H] = h;
  desc[WM_DESC_STRIDE] = seq;
  desc[WM_DESC_OFFSET] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    die(0xB7000004UL | (frames << 32));
  }
  scratch[0] = frames;
}

static void flip(void) {
  if (armed != 0) {
    return;
  }
  armed = 1;
  paint_ctl(pix_va, 1);
  commit_rect(CTL_X, CTL_Y, CTL_W, CTL_H, 2);
  unsigned n = put(0, "OSXUI2 HIT ");
  n = puthex(n, CTL_ON & 0xFFFFFFUL, 8);
  n = put(n, "\n");
  emit(n);
}

static u64 press_in_ctl(u64 ev) {
  u64 typ = ev & 0xFFUL;
  u64 rx = (ev >> 16) & 0xFFFFUL;
  u64 ry = (ev >> 32) & 0xFFFFUL;
  if (typ != WMEVENT_TYPE_PRESS) {
    return 0;
  }
  if (rx < CTL_X) {
    return 0;
  }
  if (rx >= (CTL_X + CTL_W)) {
    return 0;
  }
  if (ry < CTL_Y) {
    return 0;
  }
  if (ry >= (CTL_Y + CTL_H)) {
    return 0;
  }
  return 1;
}

void _start(void) {
  shm_h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (shm_h >= WM_RET_FLOOR) {
    die(0xB7000002UL);
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = SURF_X;
  desc[WM_DESC_Y] = SURF_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  pix_va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (pix_va >= WM_RET_FLOOR) {
    die(0xB7000003UL | (pix_va << 32));
  }

  paint_all(pix_va, 0);
  commit_rect(0, 0, WIN_W, WIN_H, 1);
  wr(msg_ready, sizeof(msg_ready) - 1);

  if (marker != 0x00B70000000000B7UL) {
    die(0xB7000006UL);
  }

  for (;;) {
    u64 k = sys1(SYS_KBDEVENT, KBD_OP_POP);
    if (k != KBD_EMPTY) {
      if ((k & KBD_BIT_BREAK) == 0) {
        if ((k & 0xFFUL) == FLIP_SCAN) {
          flip();
        }
      }
    }
    u64 ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    if (ev != WMEVENT_EMPTY) {
      if (press_in_ctl(ev) > 0) {
        flip();
      } else {
        wr(msg_miss, sizeof(msg_miss) - 1);
      }
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
