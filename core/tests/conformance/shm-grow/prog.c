/* core/tests/conformance/shm-grow/prog.c
 *
 * ADR-0150 — shmgrow after create (and after a wmsurface attach).
 * Creates a 2-page region, writes page 0, grows to 5, writes the new
 * pages, refuses same/shrink/oversize. Then attaches a tiny surface on
 * a second region and grows that past the attach size.
 */

typedef unsigned long u64;
typedef unsigned char u8;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_SHMCREATE 16
#define SYS_SHMGROW 34
#define SYS_WMSURFACE 23

#define SHM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define SHM_BADLEN 0xFFFFFFFFFFFFFFFDUL
#define WM_FLOOR 0xFFFFFFFFFFFFFF00UL

#define PAGEB 4096UL
#define VA0 0x10200000UL
#define OLD_PAGES 2UL
#define NEW_PAGES 5UL
#define MARK0 0xA5UL
#define MARK_NEW 0x5AUL

#define WM_ATTACH 1UL
#define WM_COMMIT 2UL

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}
static inline u64 sys2(u64 n, u64 a, u64 b) { return sys3(n, a, b, 0); }
static inline u64 sys1(u64 n, u64 a) { return sys3(n, a, 0, 0); }

static void wr(const char *s, u64 n) { sys2(SYS_WRITE, (u64)s, n); }

__attribute__((noreturn)) static void die(u64 code) {
  sys1(SYS_EXIT, code);
  for (;;) {
  }
}

static char line[96];
static u64 desc[8] __attribute__((aligned(64)));

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

static void emit(unsigned n) { wr(line, n); }

static void fill_page(u64 va, u64 page, u8 mark) {
  volatile u8 *p = (volatile u8 *)(va + page * PAGEB);
  u64 i;
  for (i = 0; i < PAGEB; i++) {
    p[i] = mark;
  }
}

static int check_page(u64 va, u64 page, u8 mark) {
  volatile u8 *p = (volatile u8 *)(va + page * PAGEB);
  u64 i;
  for (i = 0; i < PAGEB; i++) {
    if (p[i] != mark) {
      return 0;
    }
  }
  return 1;
}

void _start(void) {
  u64 h;
  u64 r;
  u64 va;
  u64 h2;
  u64 va2;
  unsigned at;
  u64 i;

  h = sys1(SYS_SHMCREATE, OLD_PAGES);
  if (h >= SHM_FLOOR) {
    at = put(0, "GROW CREATE FAIL ");
    at = puthex(at, h & 0xFFUL, 2);
    emit(at);
    die(1);
  }
  va = VA0;
  fill_page(va, 0, (u8)MARK0);
  fill_page(va, 1, (u8)MARK0);

  r = sys2(SYS_SHMGROW, h, NEW_PAGES);
  if (r != 0) {
    at = put(0, "GROW FAIL ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(2);
  }
  for (i = OLD_PAGES; i < NEW_PAGES; i++) {
    fill_page(va, i, (u8)MARK_NEW);
  }
  if (!check_page(va, 0, (u8)MARK0) || !check_page(va, 1, (u8)MARK0)) {
    wr("GROW OLD LOST", 13);
    die(3);
  }
  for (i = OLD_PAGES; i < NEW_PAGES; i++) {
    if (!check_page(va, i, (u8)MARK_NEW)) {
      wr("GROW NEW BAD", 12);
      die(4);
    }
  }

  r = sys2(SYS_SHMGROW, h, NEW_PAGES);
  if (r != SHM_BADLEN) {
    at = put(0, "GROW SAME WANT BADLEN GOT ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(5);
  }
  r = sys2(SYS_SHMGROW, h, 1);
  if (r != SHM_BADLEN) {
    at = put(0, "GROW SHRINK WANT BADLEN GOT ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(6);
  }
  r = sys2(SYS_SHMGROW, h, 200);
  if (r != SHM_BADLEN) {
    at = put(0, "GROW BIG WANT BADLEN GOT ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(7);
  }

  /* Second region: attach then grow past the attach paint size. */
  h2 = sys1(SYS_SHMCREATE, 2);
  if (h2 >= SHM_FLOOR) {
    wr("GROW ATTACH CREATE FAIL", 23);
    die(8);
  }
  va2 = VA0 + (128UL * PAGEB); /* slot 1 */
  desc[0] = WM_ATTACH;
  desc[1] = h2;
  desc[2] = 40;
  desc[3] = 40;
  desc[4] = 64;
  desc[5] = 32;
  desc[6] = 64 * 4;
  desc[7] = 0;
  r = sys1(SYS_WMSURFACE, (u64)&desc[0]);
  if (r >= WM_FLOOR) {
    at = put(0, "GROW ATTACH FAIL ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(9);
  }
  r = sys2(SYS_SHMGROW, h2, 6);
  if (r != 0) {
    at = put(0, "GROW PAST ATTACH FAIL ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(10);
  }
  fill_page(va2, 5, (u8)0xC3);
  if (!check_page(va2, 5, (u8)0xC3)) {
    wr("GROW PAST ATTACH BAD", 20);
    die(11);
  }

  wr("SHM GROW OK", 11);
  die(0);
}
