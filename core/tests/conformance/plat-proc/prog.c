/* core/tests/conformance/plat-proc/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 * The bytes are identical. Only the 8.3 name raises the window.
 *
 *   PLAT.ELF  — named platform process: sbrk(3 MiB) maps pages at
 *               0x10400000, past the 2 MiB app cap. write() of a
 *               string living on that heap is elfOwns walking the
 *               live tables.
 *   ASK.ELF   — same binary, no platform flag: sbrk(3 MiB) is
 *               heapRetBadArg. A one-page sbrk in the 2 MiB window
 *               still works.
 *
 * This is not glibc and not CEF OnPaint. It is the door a later
 * Content process needs (ADR-0124).
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_SBRK 4

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_NOSPACE 0xFFFFFFFFFFFFFFFDUL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define PAGE 4096UL
#define WANT 0x300000UL
#define PLAT_BASE 0x10400000UL
#define PLAT_CAP 0x1000000UL
#define APP_CAP 0x200000UL
#define WANT_PAGES 768UL
#define SIG 0xA1240000C0DE0001UL

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

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

const char msgStart[] = "PLAT START";
const char msgHeap[] = "PLAT HEAP PAGE";

char out[128];

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

static unsigned long put64(unsigned long at, unsigned long v) {
  unsigned long j;
  for (j = 0; j < 16; j++) {
    out[at + j] = hex(v >> (60 - 4 * j));
  }
  return at + 16;
}

static unsigned long putstr(unsigned long at, const char *s) {
  while (*s) {
    out[at++] = *s++;
  }
  return at;
}

static void say(const char *tag, unsigned long v) {
  unsigned long n = 0;
  n = putstr(n, tag);
  out[n++] = ' ';
  n = put64(n, v);
  sys(SYS_WRITE, (unsigned long)out, n);
}

static unsigned long mark(unsigned long i, unsigned long w) {
  return SIG + (i << 20) + w;
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long b0, big, small, xor, i, w, bad, zbad;
  volatile unsigned long *p;

  (void)probe;
  bad = 0;
  zbad = 0;
  xor = 0;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  b0 = sys(SYS_SBRK, 0, 0);
  say("BRK0", b0);

  big = sys(SYS_SBRK, WANT, 0);
  say("ASKED", big);

  if (big > ERR_FLOOR) {
    if (big != E_BADARG) {
      bad++;
    }
    small = sys(SYS_SBRK, PAGE, 0);
    say("SMALL", small);
    if (small > ERR_FLOOR) {
      bad++;
    } else {
      p = (volatile unsigned long *)small;
      if (p[0] != 0) {
        zbad++;
      }
      p[0] = mark(0, 0);
      if (p[0] != mark(0, 0)) {
        bad++;
      }
    }
    say("CAP", APP_CAP);
  } else {
    if (b0 != PLAT_BASE) {
      bad++;
    }
    if (big != b0) {
      bad++;
    }
    for (i = 0; i < WANT_PAGES; i++) {
      p = (volatile unsigned long *)(big + i * PAGE);
      if (p[0] != 0) {
        zbad++;
      }
      if (p[511] != 0) {
        zbad++;
      }
      p[0] = mark(i, 0);
      p[511] = mark(i, 511);
      xor ^= p[0];
    }
    for (i = 0; i < WANT_PAGES; i++) {
      p = (volatile unsigned long *)(big + i * PAGE);
      if (p[0] != mark(i, 0)) {
        bad++;
      }
      if (p[511] != mark(i, 511)) {
        bad++;
      }
    }
    for (w = 0; w < sizeof(msgHeap); w++) {
      ((char *)big)[w] = msgHeap[w];
    }
    if (sys(SYS_WRITE, big, sizeof(msgHeap) - 1) != sizeof(msgHeap) - 1) {
      bad++;
    }
    p = (volatile unsigned long *)big;
    p[0] = mark(0, 0);
    say("XOR", xor);
    say("CAP", PLAT_CAP);
  }

  say("ZBAD", zbad);
  say("BAD", bad);
  sys(SYS_EXIT, 0xA1240000UL + zbad + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
