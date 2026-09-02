/* core/tests/conformance/wm-clip/a.c
 *
 * ADR-0183 — process A offers clipboard bytes through wmsurface.
 * No surface attach: selection is cap-backed shm, not a window.
 */

typedef unsigned long u64;
typedef unsigned char u8;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23

#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_OFFER 3UL
#define D_OP 0
#define D_HANDLE 1
#define D_LEN 2

#define PAYLOAD "CLIPOK"
#define PAY_LEN 6UL
#define PAGES 1UL
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

static u64 desc[8] __attribute__((aligned(64)));
static const char msg_line[] = "WM CLIP A\n";
static const char msg_ok[] = "WM CLIP A OFFERED\n";

void _start(void) {
  wr(msg_line, sizeof(msg_line) - 1);

  u64 h = sys1(SYS_SHMCREATE, PAGES);
  if (h >= WM_FLOOR) {
    die(0x0C100001UL);
  }
  /* Creator maps at shm slot VA; ADR-0045 — we write through the
   * address returned only after attach normally; for a bare create the
   * region is mapped in the creator. Use the conventional base. */
  volatile u8 *p = (volatile u8 *)0x10200000UL;
  u64 i = 0;
  while (i < PAY_LEN) {
    p[i] = (u8)PAYLOAD[i];
    i = i + 1;
  }

  desc[D_OP] = WM_OFFER;
  desc[D_HANDLE] = h;
  desc[D_LEN] = PAY_LEN;
  u64 r = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (r >= WM_FLOOR) {
    die(0x0C100002UL | (r << 32));
  }
  if (r != PAY_LEN) {
    die(0x0C100003UL);
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
