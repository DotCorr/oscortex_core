/* core/tests/conformance/frame1/prog.c
 *
 * FRAME1's ABITST: open the planted FRAME.H, read it in 512-byte
 * strides, print the first-line tag and an FNV of every byte. The
 * numbers come from osframe.h, not from a private copy in this file.
 *
 * `run` door: no sbrk, no argv. The 8.3 name is baked.
 */

#include "osframe.h"

#define FNV_INIT 0x811C9DC5UL
#define FNV_PRIME 16777619UL
#define CHUNK 512UL

typedef unsigned long u64;

static unsigned char buf[512];
static char line[120];

static u64 sys3(u64 n, u64 a, u64 b, u64 c) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "memory");
  return r;
}

static u64 sys2(u64 n, u64 a, u64 b) { return sys3(n, a, b, 0); }

__attribute__((noreturn)) static void die(u64 code) {
  sys2(SYS_EXIT, code, 0);
  for (;;) {
  }
}

static unsigned put(unsigned at, const char *s) {
  while (*s) {
    line[at++] = *s++;
  }
  return at;
}

static unsigned puthex(unsigned at, u64 v, unsigned digits) {
  static const char D[] = "0123456789abcdef";
  unsigned i = digits;
  while (i--) {
    line[at++] = D[(v >> (i * 4)) & 0xF];
  }
  return at;
}

static unsigned putdec(unsigned at, u64 v) {
  char tmp[16];
  unsigned n = 0;
  if (v == 0) {
    line[at++] = '0';
    return at;
  }
  while (v) {
    tmp[n++] = (char)('0' + (v % 10));
    v /= 10;
  }
  while (n) {
    line[at++] = tmp[--n];
  }
  return at;
}

static void emit(unsigned n) { sys2(SYS_WRITE, (u64)line, n); }

static u64 fnvUpdate(u64 h, const unsigned char *p, u64 n) {
  u64 i;
  for (i = 0; i < n; i++) {
    h ^= (u64)p[i];
    h = (h * FNV_PRIME) & 0xFFFFFFFFUL;
  }
  return h;
}

static int same(const unsigned char *a, const char *b, unsigned n) {
  unsigned i;
  for (i = 0; i < n; i++) {
    if (a[i] != (unsigned char)b[i]) {
      return 0;
    }
  }
  return 1;
}

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call progMain\n"
    "1:\n"
    "  pause\n"
    "  jmp 1b\n"
    ".size _start, . - _start\n");

void progMain(void);

void progMain(void) {
  u64 fd, got, total, h;
  u64 tagOk, ver;
  unsigned n;

  fd = sys2(SYS_OPEN, (u64) "FRAME.H", 7);
  if (fd >= 0xFFFFFFFFFFFFFF00UL) {
    n = put(0, "FRAME1 OPEN REFUSED ");
    n = puthex(n, fd & 0xFFFFFFFFUL, 8);
    emit(n);
    die(0xE1UL);
  }

  total = 0;
  h = FNV_INIT;
  tagOk = 0;
  ver = 0;
  for (;;) {
    got = sys3(SYS_READ, fd, (u64)buf, CHUNK);
    if (got >= 0xFFFFFFFFFFFFFF00UL) {
      n = put(0, "FRAME1 READ REFUSED ");
      n = puthex(n, got & 0xFFFFFFFFUL, 8);
      emit(n);
      die(0xE2UL);
    }
    if (got == 0) {
      break;
    }
    if (total == 0 && got >= 11 && same(buf, "/* OSFRAME ", 11)) {
      tagOk = 1;
      ver = (u64)(buf[11] - '0');
    }
    h = fnvUpdate(h, buf, got);
    total += got;
  }
  sys2(SYS_CLOSE, fd, 0);

  n = put(0, "FRAME1 MAGIC ");
  n = puthex(n, OSFRAME_MAGIC, 8);
  n = put(n, " VER ");
  n = putdec(n, OSFRAME_VERSION);
  n = put(n, " TAG ");
  n = putdec(n, tagOk);
  n = put(n, " FILEVER ");
  n = putdec(n, ver);
  n = put(n, " LEN ");
  n = puthex(n, total, 8);
  n = put(n, " FNV ");
  n = puthex(n, h, 8);
  emit(n);

  /* Compiled-in magic must be the one the file's first line named. */
  if (!tagOk || ver != OSFRAME_VERSION) {
    die(0xE3UL);
  }
  die((h ^ total) & 0xFFUL);
}
