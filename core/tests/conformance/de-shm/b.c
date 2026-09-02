/* core/tests/conformance/de-shm/b.c
 *
 * Second of three derived surfaces. Must attach while A is still mapped.
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

#define SURF_W 160UL
#define SURF_H 100UL
#define SURF_X 280UL
#define SURF_Y 80UL
#define SURF_FILL 0x0020A060UL
#define SURF_PAGES 16UL
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
static volatile u64 marker = 0x00B200B200B200B2UL;

static const char msg_line[] = "DE SHM B\n";
static const char msg_commit[] = "DE SHM B COMMIT\n";

static void paint(u64 va) {
  volatile u32 *p = (volatile u32 *)va;
  u64 py = 0;
  while (py < SURF_H) {
    u64 px = 0;
    while (px < SURF_W) {
      p[py * SURF_W + px] = (u32)SURF_FILL;
      px = px + 1;
    }
    py = py + 1;
  }
}

void _start(void) {
  wr(msg_line, sizeof(msg_line) - 1);

  u64 h = sys1(SYS_SHMCREATE, SURF_PAGES);
  if (h >= WM_FLOOR) {
    die(0x0B000102UL);
  }

  desc[D_OP] = WM_ATTACH;
  desc[D_HANDLE] = h;
  desc[D_X] = SURF_X;
  desc[D_Y] = SURF_Y;
  desc[D_W] = SURF_W;
  desc[D_H] = SURF_H;
  desc[D_STRIDE] = 0;
  desc[D_OFFSET] = 0;
  u64 va = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (va >= WM_FLOOR) {
    die(0x0B000103UL | (va << 32));
  }

  paint(va);

  desc[D_OP] = WM_COMMIT;
  desc[D_HANDLE] = h;
  desc[D_X] = 0;
  desc[D_Y] = 0;
  desc[D_W] = SURF_W;
  desc[D_H] = SURF_H;
  desc[D_SEQ] = 1;
  desc[7] = 0;
  u64 frames = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (frames >= WM_FLOOR) {
    die(0x0B000104UL | (frames << 32));
  }
  wr(msg_commit, sizeof(msg_commit) - 1);
  if (marker != 0x00B200B200B200B2UL) {
    die(0x0B000106UL);
  }

  for (;;) {
    volatile u64 spin = 0;
    while (spin < YIELD_SPIN) {
      spin = spin + 1;
    }
    sys1(SYS_YIELD, 0);
  }
}
