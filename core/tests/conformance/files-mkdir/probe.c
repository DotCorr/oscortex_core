/* core/tests/conformance/files-mkdir/probe.c
 *
 * Ring-3 mkdir proof: create NEWDIR, open it as a dirent stream,
 * create IN.DAT inside it, print MKDIR OK. Host FAT-walks the image.
 */
#include "osframe.h"

typedef unsigned long u64;

#define ERR_FLOOR 0xFFFFFFFFFFFFFF00UL
#define MODE_WRITE 1UL

static char line[80];
static unsigned char buf[512];
static const char name_dir[] = "NEWDIR";
static const char name_in[] = "IN.DAT";
static const char payload[] = "IN";
static const char msg_ok[] = "MKDIR OK";
static const char msg_fail[] = "MKDIR FAIL ";

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

static void wr(const char *s, u64 n) { sys3(SYS_WRITE, (u64)s, n, 0); }

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

static void fail(u64 code) {
  unsigned at = put(0, msg_fail);
  at = puthex(at, code & 0xFFUL, 2);
  wr(line, at);
  sys1(SYS_EXIT, 1);
  for (;;) {
  }
}

void _start(void) {
  u64 r;
  u64 fd;
  u64 got;
  u64 out;

  r = sys2(SYS_MKDIR, (u64)name_dir, 6);
  if (r >= ERR_FLOOR) {
    fail(r);
  }
  fd = sys2(SYS_OPEN, (u64)name_dir, 6);
  if (fd >= ERR_FLOOR) {
    fail(fd);
  }
  got = sys3(SYS_READ, fd, (u64)buf, 512);
  if (got >= ERR_FLOOR) {
    sys1(SYS_CLOSE, fd);
    fail(got);
  }
  sys1(SYS_CLOSE, fd);
  out = sys3(SYS_OPEN, (u64)name_in, 6, MODE_WRITE);
  if (out >= ERR_FLOOR) {
    fail(out);
  }
  r = sys3(SYS_FDWRITE, out, (u64)payload, 2);
  if (r >= ERR_FLOOR) {
    sys1(SYS_CLOSE, out);
    fail(r);
  }
  sys1(SYS_CLOSE, out);
  wr(msg_ok, sizeof(msg_ok) - 1);
  sys1(SYS_EXIT, 0);
  for (;;) {
  }
}
