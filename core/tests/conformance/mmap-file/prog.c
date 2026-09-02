/* core/tests/conformance/mmap-file/prog.c
 *
 * ADR-0164 — file-backed shm + demand paging.
 * open PLANT.DAT → shmfile → pages not present → touch → DEMAND fill →
 * contents match plant → RO store #PF.
 */

typedef unsigned long u64;
typedef unsigned char u8;

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_OPEN 5
#define SYS_CLOSE 7
#define SYS_SHMFILE 37

#define SHM_FLOOR 0xFFFFFFFFFFFFFF00UL
#define FILE_FLOOR 0xFFFFFFFFFFFFFF00UL

#define PAGEB 4096UL
#define VA0 0x10200000UL
#define PAGES 2UL

/* Must match make-image.py plant bytes. */
static const u8 magic0[8] = {'M', 'M', 'A', 'P', 'F', 'I', 'L', 'E'};
static const u8 magic1[8] = {'D', 'E', 'M', 'A', 'N', 'D', 'P', 'G'};

/* Force a non-empty RW LOAD so p_vaddr stays congruent (empty .bss
 * collapses the data PT_LOAD to VAddr 0 and the loader refuses it). */
static char keep_rw[64] __attribute__((used));

static inline u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c)
                   : "memory");
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

static int match8(volatile u8 *p, const u8 *m) {
  u64 i;
  for (i = 0; i < 8; i++) {
    if (p[i] != m[i]) {
      return 0;
    }
  }
  return 1;
}

void _start(void) {
  u64 fd;
  u64 h;
  volatile u8 *p0;
  volatile u8 *p1;
  volatile u8 *probe;
  static const char name[] = "PLANT.DAT";

  keep_rw[0] = 0;

  fd = sys3(SYS_OPEN, (u64)name, 9, 0);
  if (fd >= FILE_FLOOR) {
    wr("FILE OPEN FAIL", 14);
    die(1);
  }
  wr("MMAP FILE OPEN OK", 17);

  h = sys1(SYS_SHMFILE, fd);
  if (h >= SHM_FLOOR) {
    wr("FILE SHMFILE FAIL", 17);
    die(2);
  }
  wr("MMAP FILE CREATE OK", 19);

  /* First touch of page 0 — must demand-fill, then match plant. */
  p0 = (volatile u8 *)VA0;
  if (!match8(p0, magic0)) {
    wr("FILE PAGE0 BAD", 14);
    die(3);
  }
  wr("MMAP FILE PAGE0 OK", 18);

  /* Second page — separate demand. */
  p1 = (volatile u8 *)(VA0 + PAGEB);
  if (!match8(p1, magic1)) {
    wr("FILE PAGE1 BAD", 14);
    die(4);
  }
  wr("MMAP FILE PAGE1 OK", 18);

  /* Pattern byte after magic on page 0 (plant[8] == 0xA5). */
  if (p0[8] != (u8)0xA5) {
    wr("FILE MARK BAD", 13);
    die(5);
  }
  wr("MMAP FILE OK", 12);

  /* RO anti-vacuity: store must #PF (present, write, user). */
  wr("MMAP FILE WRITE PROBE", 21);
  probe = (volatile u8 *)VA0;
  *probe = (u8)0x11;
  wr("FILE STILL WRITABLE", 19);
  die(6);
}
