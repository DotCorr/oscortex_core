/* core/tests/conformance/wm-clip/b.c
 *
 * ADR-0183 — process B takes the selection into its own shm and
 * prints the bytes. Proof the compositor mediated the copy.
 */

typedef unsigned long u64;
typedef unsigned char u8;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23

#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_TAKE 4UL
#define D_OP 0
#define D_HANDLE 1

#define PAY_LEN 6UL
#define PAGES 1UL
#define HOLD_ROUNDS 80UL
#define HOLD_BURN 20000000UL

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
static char line[64];
static const char msg_line[] = "WM CLIP B\n";
static const char msg_wait[] = "WM CLIP B WAIT\n";

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

void _start(void) {
  wr(msg_line, sizeof(msg_line) - 1);
  wr(msg_wait, sizeof(msg_wait) - 1);

  /* Spin a bit so A can offer first when both are spawned close. */
  u64 round = 0;
  while (round < HOLD_ROUNDS) {
    u64 s = 0;
    while (s < HOLD_BURN) {
      s = s + 1;
    }
    sys1(SYS_YIELD, 0);
    round = round + 1;
  }

  u64 h = sys1(SYS_SHMCREATE, PAGES);
  if (h >= WM_FLOOR) {
    die(0x0C200001UL);
  }

  desc[D_OP] = WM_TAKE;
  desc[D_HANDLE] = h;
  u64 r = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (r >= WM_FLOOR) {
    die(0x0C200002UL | (r << 32));
  }
  if (r != PAY_LEN) {
    die(0x0C200003UL);
  }

  /* Second live region is slot 1: vmShmBase + shmSlotPages*4096. */
  volatile u8 *p = (volatile u8 *)0x10280000UL;
  unsigned at = put(0, "WM CLIP B GOT ");
  u64 i = 0;
  while (i < PAY_LEN) {
    line[at++] = (char)p[i];
    i = i + 1;
  }
  line[at++] = '\n';
  wr(line, at);
  sys1(SYS_EXIT, 0);
  for (;;) {
  }
}
