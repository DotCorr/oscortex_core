/* core/user/frame/play.c
 *
 * PLAY.ELF — titled, resizable media card. Caption 4 (280×200) so
 * kmedia still finds this surface and blits the 64×64 decoder tile
 * into the body. Traffic-light CSD, task/context identity, and two
 * nonblank controls. The hidden 64×64 attach size remains a kmedia
 * fallback for `play` without this ELF.
 */

#include "osframe.h"
#include "osxui_app.h"

typedef unsigned long u64;
typedef unsigned int u32;

#define WIN_W 280UL
#define WIN_H 200UL
#define WIN_X 200UL
#define WIN_Y 80UL
#define WIN_PAGES 55UL
#define TILE_X 16UL
#define TILE_Y 40UL
#define TILE_W 64UL
#define TILE_H 64UL
#define CTL0_X 96UL
#define CTL0_Y 48UL
#define CTL1_X 168UL
#define CTL1_Y 48UL
#define CTL_W 64UL
#define CTL_H 28UL
#define BODY_FILL 0x00182820UL
#define CTL_IDLE 0x003080A0UL
#define CTL_ON 0x00F0A018UL
#define YIELD_SPIN 8000UL

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
static volatile u64 marker = 0x00C0408800C04088UL;
static u64 shm_h;
static u64 pix_va;
static u64 armed;

static const char msg_attach[] = "PLAY ATTACH\n";
static const char msg_ready[] = "PLAY READY\n";
static const char msg_csd[] = "PLAY CSD";
static const char msg_hit[] = "PLAY HIT\n";
static const char cap_play[] = "PLAY";

static void fill_rect(u64 va, u64 x, u64 y, u64 w, u64 h, u32 c) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = y;
  while (py < (y + h)) {
    if (py < WIN_H) {
      u64 px = x;
      while (px < (x + w)) {
        if (px < WIN_W) {
          p[py * WIN_W + px] = c;
        }
        px = px + 1;
      }
    }
    py = py + 1;
  }
}

static void paint_body(u64 va, u64 on) {
  fill_rect(va, 0, OSXUI_CSD_H, WIN_W, WIN_H - OSXUI_CSD_H, (u32)BODY_FILL);
  fill_rect(va, TILE_X, TILE_Y, TILE_W, TILE_H, 0x00101018UL);
  fill_rect(va, CTL0_X, CTL0_Y, CTL_W, CTL_H, (u32)((on > 0) ? CTL_ON : CTL_IDLE));
  fill_rect(va, CTL1_X, CTL1_Y, CTL_W, CTL_H, (u32)CTL_IDLE);
}

static void commit_all(u64 seq) {
  desc[WM_DESC_OP] = WM_OP_COMMIT;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = 0;
  desc[WM_DESC_Y] = 0;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = seq;
  desc[WM_DESC_OFFSET] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_RET_FLOOR) {
    die(0xC0400004UL | (frames << 32));
  }
}

static u64 press_in_ctl(u64 ev) {
  u64 typ = ev & 0xFFUL;
  u64 rx = (ev >> 16) & 0xFFFFUL;
  u64 ry = (ev >> 32) & 0xFFFFUL;
  if (typ != WMEVENT_TYPE_PRESS) {
    return 0;
  }
  if (rx < CTL0_X) {
    return 0;
  }
  if (rx >= (CTL0_X + CTL_W)) {
    return 0;
  }
  if (ry < CTL0_Y) {
    return 0;
  }
  if (ry >= (CTL0_Y + CTL_H)) {
    return 0;
  }
  return 1;
}

void _start(void) {
  shm_h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (shm_h >= WM_RET_FLOOR) {
    die(0xC0400002UL);
  }

  desc[WM_DESC_OP] = WM_OP_ATTACH;
  desc[WM_DESC_HANDLE] = shm_h;
  desc[WM_DESC_X] = WIN_X;
  desc[WM_DESC_Y] = WIN_Y;
  desc[WM_DESC_W] = WIN_W;
  desc[WM_DESC_H] = WIN_H;
  desc[WM_DESC_STRIDE] = 0;
  desc[WM_DESC_OFFSET] = 0;
  pix_va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (pix_va >= WM_RET_FLOOR) {
    die(0xC0400003UL | (pix_va << 32));
  }
  wr(msg_attach, sizeof(msg_attach) - 1);

  paint_body(pix_va, 0);
  osxui_app_csd(shm_h, WIN_W, cap_play, 4UL);
  wr(msg_csd, sizeof(msg_csd) - 1);
  commit_all(1);
  wr(msg_ready, sizeof(msg_ready) - 1);

  if (marker != 0x00C0408800C04088UL) {
    die(0xC0400006UL);
  }

  for (;;) {
    u64 ev = sys1(SYS_WMEVENT, WMEVENT_OP_POP);
    if (ev != WMEVENT_EMPTY) {
      if (press_in_ctl(ev) > 0) {
        if (armed == 0) {
          armed = 1;
          paint_body(pix_va, 1);
          osxui_app_csd(shm_h, WIN_W, cap_play, 4UL);
          commit_all(2);
          wr(msg_hit, sizeof(msg_hit) - 1);
        }
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
