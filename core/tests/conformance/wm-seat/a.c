/* core/tests/conformance/wm-seat/a.c — attach first; seat after B has room. */
typedef unsigned long u64;
#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_YIELD 3
#define SYS_SHMCREATE 16
#define SYS_WMSURFACE 23
#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define WM_ATTACH 1UL
#define WM_COMMIT 2UL
#define WM_SEAT 6UL
#define WM_SEATGET 8UL
static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r; __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory"); return r;
}
static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }
static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }
static u64 desc[8] __attribute__((aligned(64)));
static const char msg[] = "WM SEAT A\n";
static const char msg_hold[] = "WM SEAT A HOLD\n";
static char line[48];
void _start(void) {
  wr(msg, sizeof(msg)-1);
  u64 h = sys1(SYS_SHMCREATE, 8);
  if (h >= WM_FLOOR) { sys1(SYS_EXIT, 1); for(;;){} }
  desc[0]=WM_ATTACH; desc[1]=h; desc[2]=80; desc[3]=80; desc[4]=64; desc[5]=64; desc[6]=0; desc[7]=0;
  u64 va = sys1(SYS_WMSURFACE, (u64)desc);
  if (va >= WM_FLOOR) { sys1(SYS_EXIT, 2); for(;;){} }
  desc[0]=WM_COMMIT; desc[1]=h; desc[2]=0; desc[3]=0; desc[4]=64; desc[5]=64; desc[6]=1;
  sys1(SYS_WMSURFACE, (u64)desc);
  wr(msg_hold, sizeof(msg_hold)-1);
  /* Do not claim seat 0 yet — that would starve the shell of keys for B. */
  u64 r=0;
  while (r < 120UL) {
    u64 s=0; while (s<25000000UL) s++;
    sys1(SYS_YIELD, 0);
    r++;
  }
  desc[0]=WM_SEAT; desc[1]=h; desc[2]=0;
  sys1(SYS_WMSURFACE, (u64)desc);
  desc[0]=WM_SEATGET;
  u64 bits = sys1(SYS_WMSURFACE, (u64)desc);
  unsigned at=0; const char *p="WM SEAT A BITS ";
  while (*p) line[at++]=*p++;
  line[at++] = (char)('0' + (bits & 3));
  line[at++] = '\n';
  wr(line, at);
  for (;;) { u64 s=0; while (s<30000000UL) s++; sys1(SYS_YIELD, 0); }
}
