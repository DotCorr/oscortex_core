/* core/tests/conformance/mmap-prot/prog.c
 *
 * ADR-0163 — mprotect + MAP_FIXED on shm.
 * create → MAP_FIXED wrong VA refused → MAP_FIXED correct VA overlap
 * refused → mprotect RO → exec/escalate refused → store #PF.
 */

typedef unsigned long u64;
typedef unsigned char u8;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_SHMCREATE 16
#define SYS_SHMMAP 18
#define SYS_MPROTECT 36

#define SHM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define SHM_MAPPED 0xFFFFFFFFFFFFFFF4UL
#define SHM_EXEC 0xFFFFFFFFFFFFFFF3UL
#define SHM_BADPERM 0xFFFFFFFFFFFFFFF2UL
#define SHM_BADFIXED 0xFFFFFFFFFFFFFFEFUL

#define SHM_RO 1UL
#define SHM_RW 3UL
#define SHM_X 4UL
#define SHM_FIXED 0x100UL

#define PAGEB 4096UL
#define VA0 0x10200000UL
#define PAGES 2UL
#define MARK 0xA5UL

static inline u64 sys4(u64 n, u64 a, u64 b, u64 c, u64 d) {
  u64 r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c), "c"(d)
                   : "memory");
  return r;
}
static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  return sys4(n, a, b, c, 0);
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
  unsigned at;
  volatile u8 *probe;

  h = sys1(SYS_SHMCREATE, PAGES);
  if (h >= SHM_FLOOR) {
    at = put(0, "PROT CREATE FAIL ");
    at = puthex(at, h & 0xFFUL, 2);
    emit(at);
    die(1);
  }
  fill_page(VA0, 0, (u8)MARK);
  fill_page(VA0, 1, (u8)(MARK + 1));
  if (!check_page(VA0, 0, (u8)MARK) || !check_page(VA0, 1, (u8)(MARK + 1))) {
    wr("PROT MARKS BAD", 14);
    die(2);
  }

  /* MAP_FIXED wrong VA — refuse even while already mapped. */
  r = sys4(SYS_SHMMAP, h, SHM_RW | SHM_FIXED, 0, VA0 + PAGEB);
  if (r != SHM_BADFIXED) {
    at = put(0, "PROT FIXED BAD NOT REFUSED ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(3);
  }
  wr("MMAP FIXED BAD OK", 17);

  /* MAP_FIXED correct VA on already-mapped — overlap refuse. */
  r = sys4(SYS_SHMMAP, h, SHM_RW | SHM_FIXED, 0, VA0);
  if (r != SHM_MAPPED) {
    at = put(0, "PROT FIXED OVERLAP NOT REFUSED ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(4);
  }
  wr("MMAP FIXED OVERLAP OK", 21);

  r = sys2(SYS_MPROTECT, h, SHM_RO);
  if (r >= SHM_FLOOR) {
    at = put(0, "PROT RO FAIL ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(5);
  }
  if (!check_page(VA0, 0, (u8)MARK)) {
    wr("PROT READ LOST", 14);
    die(6);
  }

  r = sys2(SYS_MPROTECT, h, SHM_RO | SHM_X);
  if (r != SHM_EXEC) {
    at = put(0, "PROT EXEC NOT REFUSED ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(7);
  }
  wr("MMAP PROT EXEC OK", 17);

  r = sys2(SYS_MPROTECT, h, SHM_RW);
  if (r != SHM_BADPERM) {
    at = put(0, "PROT ESC NOT REFUSED ");
    at = puthex(at, r & 0xFFUL, 2);
    emit(at);
    die(8);
  }
  wr("MMAP PROT ESC OK", 16);

  wr("MMAP PROT OK", 12);
  wr("MMAP PROT WRITE PROBE", 21);
  probe = (volatile u8 *)VA0;
  *probe = (u8)0x11;
  wr("PROT STILL WRITABLE", 19);
  die(9);
}
