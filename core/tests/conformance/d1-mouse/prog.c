/* core/tests/conformance/d1-mouse/prog.c
 *
 * D1's ring-3 witness. It exists to answer ONE question that no amount of
 * kernel serial output can answer: CAN A PROGRAM AT CPL 3 READ THE POINTER?
 *
 * Everything else in `d1-mouse/run.sh` reads lines the KERNEL printed. Those
 * prove the driver decoded the device correctly and they prove nothing at all
 * about whether the result is reachable from ring 3 -- a kernel that decoded
 * perfectly into a variable no program could see would satisfy every one of
 * them. This program is the other half.
 *
 * It is loaded with `run <lba>`, which is the M10 path: an ELF off a raw disk,
 * its own address space, and -- deliberately -- the weakest caller in the
 * system. It has no channel, no file descriptor and nothing but `write` and
 * `exit` besides the one syscall under test, so "syscall 20 answered" cannot be
 * confused with "some other subsystem was already set up for it".
 *
 * WHAT IT REPORTS
 * ---------------------------------------------------------------------------
 *   USER WRITE PTR RAW <16 hex>          the packed u64 exactly as RAX held it
 *   USER WRITE PTR X <4> Y <4> B <1> N <6>   the same value taken apart here,
 *                                        in ring 3, by this program's own
 *                                        shifts -- so the field layout is
 *                                        asserted from BOTH sides of the
 *                                        privilege boundary
 *
 * ...and then exits with the low 40 bits of the packed value (position and
 * buttons), so the number also arrives at the harness through a channel the
 * program does not control the formatting of: the kernel's own exit line.
 *
 * The packet counter is deliberately NOT in the exit code. It is asserted from
 * the `N` field on its own line, so that a wrong count fails an assertion that
 * says "count", rather than making the position assertion fail for a reason
 * that has nothing to do with position.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1

/* Syscall 16. Declared here rather than included from `oslibc.h`, exactly as
 * m20-ipc's program declares its three: the libc has no pointer binding, and
 * `docs/syscall-registry.md` records that this number therefore lives in
 * exactly two places -- core/kernel/mouse.dart and this file -- and lists both.
 * `build-prog.sh` checks that these two agree. */
#define SYS_MOUSE 20

typedef unsigned long u64;

static u64 sys0(u64 n) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n) : "memory", "cc");
  return r;
}

static u64 sys2(u64 n, u64 a, u64 b) {
  u64 r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory", "cc");
  return r;
}

static void die(u64 code) {
  sys2(SYS_EXIT, code, 0);
  for (;;) {
  }
}

/* One line buffer. Written in .bss on purpose -- the kernel's `write` refuses a
 * pointer outside the caller's own window, so a buffer that ended up somewhere
 * else would be refused rather than printed, which is a check this program gets
 * for free from every line it emits. */
static char line[64];

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

void _start(void) {
  const u64 packed = sys0(SYS_MOUSE);

  unsigned n = put(0, "PTR RAW ");
  n = puthex(n, packed, 16);
  sys2(SYS_WRITE, (u64)line, n);

  /* The field layout, taken apart on THIS side of the boundary. */
  const u64 x = packed & 0xFFFFUL;
  const u64 y = (packed >> 16) & 0xFFFFUL;
  const u64 b = (packed >> 32) & 0xFFUL;
  const u64 count = (packed >> 40) & 0xFFFFFFUL;

  n = put(0, "PTR X ");
  n = puthex(n, x, 4);
  n = put(n, " Y ");
  n = puthex(n, y, 4);
  n = put(n, " B ");
  n = puthex(n, b, 1);
  n = put(n, " N ");
  n = puthex(n, count, 6);
  sys2(SYS_WRITE, (u64)line, n);

  die(packed & 0xFFFFFFFFFFUL);
}
