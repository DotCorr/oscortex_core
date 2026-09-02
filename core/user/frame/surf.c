/* core/user/frame/surf.c
 *
 * FRAME2 — the first kept surface client. Not a harness program: this
 * file lives next to osframe.h and is the thing a second author compiles.
 * The frame2 harness builds it as SURF.ELF and starts it with `proc spawn`
 * so the prompt comes back (ADR-0053).
 *
 * Four steps, then it stays READY: shmcreate, wmsurface attach, paint,
 * commit. The attach reply is the address. This file contains no
 * 0x10200000-class literal. Numbers come from osframe.h, not a private
 * SYS_* table.
 *
 * FRAME3 (-DFRAME3=1): after attach the same client pops kbdevent. A
 * derived make scancode changes the fill and commits damage. On KEY_C
 * it create+fdwrites THEME.DAT (four bytes, the u32). -DNOKBD is the
 * colour negative: never calls kbdevent, so the rectangle stays
 * SURF_FILL and the volume has no THEME.DAT.
 *
 * -DNOCOMMIT builds FRAME2's attach-only control: attach and paint,
 * never commit. The framebuffer must stay desktop (D4's control).
 */

#include "osframe.h"

#ifndef NOCOMMIT
#define NOCOMMIT 0
#endif
#ifndef FRAME3
#define FRAME3 0
#endif
#ifndef NOKBD
#define NOKBD 0
#endif

typedef unsigned long u64;
typedef unsigned int u32;

/* The picture. derive.py reads every one of these out of this file. */
#define WIN_W 240UL
#define WIN_H 160UL
#define SURF_X 80UL
#define SURF_Y 80UL
#define SURF_FILL 0x00D06020UL
#define SURF_INK 0x00F0E040UL
#define INK_INSET 40UL
#define WIN_PAGES 38UL

#if FRAME3
/* Set-1 make codes. derive.py restates these against the XT chart. */
#define KEY_A 0x1EUL
#define KEY_C 0x2EUL
#define COLOUR_A 0x0020A0D0UL
#define COLOUR_C 0x00C040A0UL
#define THEME_FILE "THEME.DAT"
#define THEME_BYTES 4UL
#define O_WRITE 1UL
#define FILE_ERR_FLOOR 0xFFFFFFFFFFFFFF00UL
#endif

/* Tens of milliseconds of ring-3 time between yields (d3-session's shape). */
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

/* NON-ZERO so the RW PT_LOAD has a non-zero p_filesz (m11's segment shape). */
static volatile u64 marker = 0x00F2005200F20052UL;

#if !NOCOMMIT
static u64 scratch[8];
static const char msg_commit[] = "FRAME2 COMMIT\n";
#endif

static const char msg_attach[] = "FRAME2 ATTACH\n";
static const char msg_paint[] = "FRAME2 PAINT\n";

#if FRAME3
static volatile u32 fill_now = (u32)SURF_FILL;
#if !NOKBD
static u32 theme_word = 0;
static const char theme_name[] = THEME_FILE;
static const char msg_key[] = "FRAME3 KEY\n";
static const char msg_theme[] = "FRAME3 THEME\n";
#endif
#endif

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
    return (u32)SURF_INK;
  }
#if FRAME3
  return fill_now;
#else
  return (u32)SURF_FILL;
#endif
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
  if (h >= WM_RET_FLOOR) {
    die(0xF2000002UL);
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = SURF_X;
  desc[WM_DESC_Y] = SURF_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_RET_FLOOR) {
    die(0xF2000003UL | (va << 32));
  }
  wr(msg_attach, sizeof(msg_attach) - 1);

  paint(va);
  wr(msg_paint, sizeof(msg_paint) - 1);

#if !NOCOMMIT
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = 0;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 1;
  desc[WM_DESC_OFFSET] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    die(0xF2000004UL | (frames << 32));
  }
  wr(msg_commit, sizeof(msg_commit) - 1);
  scratch[0] = frames;
#endif
  if (marker != 0x00F2005200F20052UL) {
    die(0xF2000006UL);
  }

#if FRAME3 && !NOKBD
  u64 saved = 0;
#endif
  for (;;) {
    volatile u64 spin = 0;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
#if FRAME3 && !NOKBD
    u64 ev = sys1(SYS_KBDEVENT, KBD_OP_POP);
    if (ev != KBD_EMPTY) {
      if ((ev & KBD_BIT_BREAK) == 0) {
        u64 sc = ev & 0xFFUL;
        u64 changed = 0;
        if (sc == KEY_A) {
          fill_now = (u32)COLOUR_A;
          changed = 1;
        }
        if (sc == KEY_C) {
          fill_now = (u32)COLOUR_C;
          changed = 1;
        }
        if (changed > 0) {
          paint(va);
          desc[WM_DESC_OP] = WM_OP_COMMIT;
          desc[WM_DESC_HANDLE] = h;
          desc[WM_DESC_X] = 0;
          desc[WM_DESC_Y] = 0;
          desc[WM_DESC_W] = WIN_W;
          desc[WM_DESC_H] = WIN_H;
          desc[WM_DESC_STRIDE] = 1;
          desc[WM_DESC_OFFSET] = 0;
          frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
          if (frames >= WM_RET_FLOOR) {
            die(0xF3000004UL | (frames << 32));
          }
          wr(msg_key, sizeof(msg_key) - 1);
          if (sc == KEY_C) {
            if (saved == 0) {
              theme_word = fill_now;
              u64 fd = sys3(SYS_OPEN, (u64)&theme_name[0],
                            sizeof(theme_name) - 1, O_WRITE);
              if (fd < FILE_ERR_FLOOR) {
                u64 n = sys3(SYS_FDWRITE, fd, (u64)&theme_word, THEME_BYTES);
                sys1(SYS_CLOSE, fd);
                if (n == THEME_BYTES) {
                  wr(msg_theme, sizeof(msg_theme) - 1);
                  saved = 1;
                }
              }
            }
          }
        }
      }
    }
#endif
  }
}
