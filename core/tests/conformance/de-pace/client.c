/* core/tests/conformance/de-pace/client.c
 *
 * A RESIDENT CLIENT THAT COMMITS IN A LOOP. d3-session's client commits once
 * and then yields forever, which is exactly the wrong shape for ADR-0188: a
 * frame clock can only be shown to COALESCE if something is producing damage
 * faster than the cap.
 *
 * So this one attaches, commits its whole surface once (so the compositor
 * paints the decorated window and the session paints its chrome), and then
 * commits a small damage rectangle over and over, printing a count line every
 * DPC_REPORT_EVERY commits. The rectangle MOVES down the window one step per
 * commit, so a repaint that quietly painted the wrong place would leave the
 * old patch behind for a pixel probe to find.
 *
 * Two properties the harness rests on:
 *
 *   * every commit is a PARTIAL damage (dx/dy/dw/dh smaller than the
 *     surface), so it goes through `wmComposeCommit(slot, 0, ...)` — the arm
 *     that used to discard the damage and recompose the world under `wm gfx`;
 *   * the loop yields, so the shell prompt comes back and the harness can
 *     type `wm pace` while the client is still committing.
 *
 * Freestanding: no libc, empty stack at e_entry (GAP-0149). The surface
 * address comes from wmsurface(WM_ATTACH), never from a literal.
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
#define WIN_X 100UL
#define WIN_Y 120UL
#define WIN_FILL 0x00C03828UL
#define WIN_INK 0x00F0C020UL
#define WIN_PAGES 38UL

/* The damage rectangle. Small on purpose: 16x16 out of 240x160 is 0.07% of
 * the surface and 0.03% of an 800x600 screen, which is the whole point. */
#define DMG 16UL
#define DMG_X 16UL
#define DMG_Y0 48UL
#define DMG_STEP 8UL
#define DMG_ROWS 8UL
#define DMG_PATCH 0x0040F0A0UL

/* Commits between yields, and between report lines. It yields OFTEN because
 * the harness has to be able to type `wm pace` while this is still running,
 * and it commits FOREVER for the same reason: a client that finishes is a
 * client whose damage stops arriving before the measurement does. */
#define DPC_YIELD_EVERY 16UL
#define DPC_REPORT_EVERY 256UL

/* Ring-3 spin between yields. Short: this client is meant to flood. */
#define YIELD_SPIN 20000UL

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
static volatile u64 marker = 0x00DEC0DE00DEC0DEUL;

static const char msg_attach[] = "DPC ATTACH\n";
static const char msg_commit[] = "DPC COMMIT\n";
static const char msg_batch[] = "DPC BATCH\n";
static const char msg_done[] = "DPC DONE\n";

static void paint(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < WIN_H) {
    u64 px = 0;
    while (px < WIN_W) {
      u32 c = (u32)WIN_FILL;
      if (px >= 40UL) {
        if (px < (WIN_W - 40UL)) {
          if (py >= 40UL) {
            if (py < (WIN_H - 40UL)) {
              c = (u32)WIN_INK;
            }
          }
        }
      }
      p[py * WIN_W + px] = c;
      px = px + 1;
    }
    py = py + 1;
  }
}

/* Fills the DMG x DMG patch at (DMG_X, dy) with a colour that is a function
 * of the row, so a probe can tell WHICH commit painted what it finds. */
static void patch(u64 va, u64 dy, u64 row) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  u32 c = (u32)(DMG_PATCH + (row << 4));
  while (py < DMG) {
    u64 px = 0;
    while (px < DMG) {
      p[(dy + py) * WIN_W + (DMG_X + px)] = c;
      px = px + 1;
    }
    py = py + 1;
  }
}

void _start(void) {
  u64 h = sys1(SYS_SHMCREATE, WIN_PAGES);
  if (h >= WM_FLOOR) {
    die(0xDEC00002UL);
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
    die(0xDEC00003UL | (va << 32));
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
    die(0xDEC00004UL | (frames << 32));
  }
  wr(msg_commit, sizeof(msg_commit) - 1);

  if (marker != 0x00DEC0DE00DEC0DEUL) {
    die(0xDEC00006UL);
  }
  wr(msg_done, sizeof(msg_done) - 1);

  u64 n = 0;
  for (;;) {
    u64 row = n % DMG_ROWS;
    u64 dy = DMG_Y0 + row * DMG_STEP;
    patch(va, dy, row);
    desc[D_OP] = WM_COMMIT;
    desc[D_HANDLE] = h;
    desc[D_X] = DMG_X;
    desc[D_Y] = dy;
    desc[D_W] = DMG;
    desc[D_H] = DMG;
    desc[D_SEQ] = n + 2;
    desc[7] = 0;
    u64 r = sys1(SYS_WMSURFACE, (u64)&desc[0]);
    if (r >= WM_FLOOR) {
      die(0xDEC00005UL | (r << 32));
    }
    n = n + 1;
    if ((n % DPC_REPORT_EVERY) == 0) {
      wr(msg_batch, sizeof(msg_batch) - 1);
    }
    if ((n % DPC_YIELD_EVERY) == 0) {
      volatile u64 spin = 0;
      while (spin < YIELD_SPIN) {
        spin = spin + 1;
      }
      sys1(SYS_YIELD, 0);
    }
  }
}
