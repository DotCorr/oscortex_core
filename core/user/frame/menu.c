/* core/user/frame/menu.c
 *
 * OSXUI3 — a kept FRAME widget: one main surface and a second client-
 * owned menu. Compiles against osframe.h (no private SYS_*). The
 * osxui3 harness builds it as MENU.ELF and starts it with `proc spawn`
 * (ADR-0053). One client, two regions (shmMax is 4; this client uses two).
 *
 * Attach a 240×160 main surface, paint an opener that is not the whole
 * surface, commit, then yield-loop kbdevent (24) and wmevent (25). A
 * derived make-scancode or a left press inside the opener attaches a
 * second 96×64 menu, paints colour bands, and commits. A press on a
 * menu band flips that band. A press on the main surface (not the
 * menu) leaves the menu colour unchanged and is reported as MAIN.
 *
 * -DNOCOMMIT=1 attaches the menu and never commits it (D4's control).
 *
 * Numbers come from osframe.h and the #defines derive.py reads.
 * This file contains no 0x10200000-class literal.
 */

#include "osframe.h"

#ifndef NOCOMMIT
#define NOCOMMIT 0
#endif

typedef unsigned long u64;
typedef unsigned int u32;

/* The picture. derive.py reads every one of these out of this file. */
#define WIN_W 240UL
#define WIN_H 160UL
#define SURF_X 80UL
#define SURF_Y 80UL
#define SURF_FILL 0x00C05028UL
#define OPEN_X 48UL
#define OPEN_Y 40UL
#define OPEN_W 96UL
#define OPEN_H 48UL
#define OPEN_OFF 0x0020A060UL
#define MENU_W 96UL
#define MENU_H 64UL
#define MENU_X 340UL
#define MENU_Y 100UL
#define MENU_FILL 0x00302850UL
#define BAND_X 8UL
#define BAND_Y 16UL
#define BAND_W 80UL
#define BAND_H 24UL
#define BAND_OFF 0x00D07030UL
#define BAND_ON 0x00E04090UL
#define OPEN_SCAN 0x32UL
#define DISMISS_SCAN 0x10UL
#define WIN_PAGES 38UL
#define MENU_PAGES 6UL

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
static volatile u64 marker = 0x00B30000000000B3UL;

static u64 shm_main;
static u64 shm_menu;
static u64 pix_main;
static u64 pix_menu;
static volatile u64 menu_up = 0;
static volatile u64 band_on = 0;
static u64 main_w = 0xFFUL;
static u64 scratch[8];

static char line[48];

static const char msg_ready[] = "OSXUI3 READY\n";
static const char msg_main[] = "OSXUI3 MAIN\n";
static const char msg_gone[] = "OSXUI3 GONE\n";

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

static u64 ev_type(u64 ev) { return ev & 0xFFUL; }
static u64 ev_win(u64 ev) { return (ev >> 8) & 0xFFUL; }
static u64 ev_rx(u64 ev) { return (ev >> 16) & 0xFFFFUL; }
static u64 ev_ry(u64 ev) { return (ev >> 32) & 0xFFFFUL; }

static u64 in_rect(u64 ev, u64 x, u64 y, u64 w, u64 h) {
  u64 rx = ev_rx(ev);
  u64 ry = ev_ry(ev);
  if (rx < x) {
    return 0;
  }
  if (rx >= (x + w)) {
    return 0;
  }
  if (ry < y) {
    return 0;
  }
  if (ry >= (y + h)) {
    return 0;
  }
  return 1;
}

static u32 main_pixel(u64 px, u64 py) {
  if (px >= OPEN_X) {
    if (px < (OPEN_X + OPEN_W)) {
      if (py >= OPEN_Y) {
        if (py < (OPEN_Y + OPEN_H)) {
          return (u32)OPEN_OFF;
        }
      }
    }
  }
  return (u32)SURF_FILL;
}

static void paint_main(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      p[py * WIN_W + px] = main_pixel(px, py);
      px = px + 1;
    }
    py = py + 1;
  }
}

static u32 menu_pixel(u64 px, u64 py, u64 on) {
  if (px >= BAND_X) {
    if (px < (BAND_X + BAND_W)) {
      if (py >= BAND_Y) {
        if (py < (BAND_Y + BAND_H)) {
          if (on > 0) {
            return (u32)BAND_ON;
          }
          return (u32)BAND_OFF;
        }
      }
    }
  }
  return (u32)MENU_FILL;
}

static void paint_menu(u64 va, u64 on) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < MENU_H) {
    u64 px = 0;
    while (px < MENU_W) {
      p[py * MENU_W + px] = menu_pixel(px, py, on);
      px = px + 1;
    }
    py = py + 1;
  }
}

static void paint_band(u64 va, u64 on) {
  volatile u32 *p = (volatile u32 *)va;
  u32 c = (u32)((on > 0) ? BAND_ON : BAND_OFF);
  u64 py = BAND_Y;
  while (py < (BAND_Y + BAND_H)) {
    u64 px = BAND_X;
    while (px < (BAND_X + BAND_W)) {
      p[py * MENU_W + px] = c;
      px = px + 1;
    }
    py = py + 1;
  }
}

static void commit_rect(u64 h, u64 x, u64 y, u64 w, u64 hh, u64 seq) {
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = x;
  desc[WM_DESC_Y] = y;
  desc[WM_DESC_W] = w;
  desc[WM_DESC_H] = hh;
  desc[WM_DESC_STRIDE] = seq;
  desc[WM_DESC_OFFSET] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    die(0xB3000004UL | (frames << 32));
  }
  scratch[0] = frames;
}

static u64 attach_surf(u64 h, u64 x, u64 y, u64 w, u64 hh) {
  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = h;
  desc[WM_DESC_X] = x;
  desc[WM_DESC_Y] = y;
  desc[WM_DESC_W] = w;
  desc[WM_DESC_H] = hh;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_RET_FLOOR) {
    die(0xB3000003UL | (va << 32));
  }
  return va;
}

static void open_menu(void) {
  if (menu_up != 0) {
    return;
  }
  shm_menu = sys1(SYS_SHMCREATE, MENU_PAGES);
  if (shm_menu >= WM_RET_FLOOR) {
    die(0xB3000005UL);
  }
  pix_menu = attach_surf(shm_menu, MENU_X, MENU_Y, MENU_W, MENU_H);
  paint_menu(pix_menu, 0);
  {
    unsigned n = put(0, "OSXUI3 ATTACH ");
    n = puthex(n, MENU_FILL & 0xFFFFFFUL, 8);
    n = put(n, "\n");
    emit(n);
  }
#if !NOCOMMIT
  commit_rect(shm_menu, 0, 0, MENU_W, MENU_H, 1);
  {
    unsigned n = put(0, "OSXUI3 OPEN ");
    n = puthex(n, MENU_FILL & 0xFFFFFFUL, 8);
    n = put(n, "\n");
    emit(n);
  }
#endif
  menu_up = 1;
}

static void flip_band(void) {
  if (band_on != 0) {
    return;
  }
  if (menu_up == 0) {
    return;
  }
  band_on = 1;
  paint_band(pix_menu, 1);
#if !NOCOMMIT
  commit_rect(shm_menu, BAND_X, BAND_Y, BAND_W, BAND_H, 2);
  {
    unsigned n = put(0, "OSXUI3 BAND ");
    n = puthex(n, BAND_ON & 0xFFFFFFUL, 8);
    n = put(n, "\n");
    emit(n);
  }
#endif
}

static void dismiss(void) {
  if (menu_up == 0) {
    return;
  }
  menu_up = 0;
  wr(msg_gone, sizeof(msg_gone) - 1);
}

static void on_press(u64 ev) {
  if (ev_type(ev) != WMEVENT_TYPE_PRESS) {
    return;
  }
  if (main_w == 0xFFUL) {
    main_w = ev_win(ev);
  }
  if (menu_up == 0) {
    if (in_rect(ev, OPEN_X, OPEN_Y, OPEN_W, OPEN_H) > 0) {
      open_menu();
    } else {
      wr(msg_main, sizeof(msg_main) - 1);
    }
    return;
  }
  if (ev_win(ev) != main_w) {
    if (in_rect(ev, BAND_X, BAND_Y, BAND_W, BAND_H) > 0) {
      flip_band();
    }
    return;
  }
  wr(msg_main, sizeof(msg_main) - 1);
}

void _start(void) {
  shm_main = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (shm_main >= WM_RET_FLOOR) {
    die(0xB3000002UL);
  }

  pix_main = attach_surf(shm_main, SURF_X, SURF_Y, WIN_W, WIN_H);
  paint_main(pix_main);
  commit_rect(shm_main, 0, 0, WIN_W, WIN_H, 1);
  wr(msg_ready, sizeof(msg_ready) - 1);

  if (marker != 0x00B30000000000B3UL) {
    die(0xB3000006UL);
  }

  for (;;) {
    u64 k = sys1(SYS_KBDEVENT, KBD_OP_POP);
    if (k != KBD_EMPTY) {
      if ((k & KBD_BIT_BREAK) == 0) {
        u64 sc = k & 0xFFUL;
        if (sc == OPEN_SCAN) {
          open_menu();
        } else {
          if (sc == DISMISS_SCAN) {
            dismiss();
          }
        }
      }
    }
    u64 ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    if (ev != WMEVENT_EMPTY) {
      on_press(ev);
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
