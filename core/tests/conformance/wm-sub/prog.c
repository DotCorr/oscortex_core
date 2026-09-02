/* core/tests/conformance/wm-sub/prog.c
 *
 * ADR-0184 — parent + child subsurface. Move parent; child abs follows.
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
#define WM_SUB 5UL
#define WM_MOVE 7UL

#define D_OP 0
#define D_HANDLE 1
#define D_X 2
#define D_Y 3
#define D_W 4
#define D_H 5
#define D_SEQ 6

#define PAR_X 100UL
#define PAR_Y 100UL
#define PAR_W 80UL
#define PAR_H 80UL
#define PAR_FILL 0x00C03828UL
#define CH_OX 16UL
#define CH_OY 16UL
#define CH_W 32UL
#define CH_H 32UL
#define CH_FILL 0x001878A8UL
#define MOV_X 200UL
#define MOV_Y 100UL
#define PAGES 8UL
#define YIELD_SPIN 20000000UL

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

static u64 desc[8] __attribute__((aligned(64)));
static const char msg[] = "WM SUB PROG\n";
static const char msg_ok[] = "WM SUB MOVED\n";

static void paint(u64 va, u64 w, u64 h, u32 fill) {
  volatile u32 *p = (volatile u32 *)va;
  u64 y = 0;
  while (y < h) {
    u64 x = 0;
    while (x < w) {
      p[y * w + x] = fill;
      x = x + 1;
    }
    y = y + 1;
  }
}

void _start(void) {
  wr(msg, sizeof(msg) - 1);

  u64 hp = sys1(SYS_SHMCREATE, PAGES);
  if (hp >= WM_FLOOR) {
    die(0x0B000001UL);
  }
  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = hp;
  desc[D_X] = PAR_X;
  desc[D_Y] = PAR_Y;
  desc[D_W] = PAR_W;
  desc[D_H] = PAR_H;
  desc[6] = 0;
  desc[7] = 0;
  u64 vap = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (vap >= WM_FLOOR) {
    die(0x0B000002UL);
  }
  paint(vap, PAR_W, PAR_H, (u32)PAR_FILL);
  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = hp;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = PAR_W;
  desc[D_H] = PAR_H;
  desc[D_SEQ] = 1;
  if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_FLOOR) {
    die(0x0B000003UL);
  }

  u64 hc = sys1(SYS_SHMCREATE, PAGES);
  if (hc >= WM_FLOOR) {
    die(0x0B000004UL);
  }
  desc[D_OP] = WM_SUB;
  desc[D_HANDLE] = hc;
  desc[2] = hp;
  desc[3] = CH_OX;
  desc[4] = CH_OY;
  desc[5] = CH_W;
  desc[6] = CH_H;
  desc[7] = 0;
  u64 vac = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (vac >= WM_FLOOR) {
    die(0x0B000005UL | (vac << 32));
  }
  paint(vac, CH_W, CH_H, (u32)CH_FILL);
  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = hc;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = CH_W;
  desc[D_H] = CH_H;
  desc[D_SEQ] = 1;
  if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_FLOOR) {
    die(0x0B000006UL);
  }

  desc[D_OP] = WM_MOVE;
  desc[D_HANDLE] = hp;
  desc[2] = MOV_X;
  desc[3] = MOV_Y;
  if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_FLOOR) {
    die(0x0B000007UL);
  }

  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = hp;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = PAR_W;
  desc[D_H] = PAR_H;
  desc[D_SEQ] = 2;
  if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_FLOOR) {
    die(0x0B000009UL);
  }

  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = hc;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = CH_W;
  desc[D_H] = CH_H;
  desc[D_SEQ] = 2;
  if (sys1(SYS_WMSURFACE, (u64)&desc[0]) >= WM_FLOOR) {
    die(0x0B000008UL);
  }

  wr(msg_ok, sizeof(msg_ok) - 1);
  for (;;) {
    u64 s = 0;
    while (s < YIELD_SPIN) {
      s = s + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
