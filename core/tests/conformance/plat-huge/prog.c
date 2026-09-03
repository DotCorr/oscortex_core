/* core/tests/conformance/plat-huge/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 * The bytes are identical. Only the 8.3 name may mmap the
 * 189 MiB platform window (ADR-0155).
 *
 *   PLAT.ELF  — mmap(189 MiB) maps real pages at 0x10600000.
 *               Every page is touched; write() of a string on
 *               that VA walks live tables; teardown frees them.
 *   ASK.ELF   — same binary: mmap(189 MiB) is heapRetBadArg.
 *
 * 189 MiB is the full CEF .text plant (ADR-0123 measured
 * 189095087 bytes; this window is 189 << 20). PMM / boot.S
 * identity are 256 MiB together. Not glibc. Not OnPaint.
 * Syscall 27. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_MMAP 27

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define PAGE 4096UL
#define WANT 0xBD00000UL
#define PLAT_BASE 0x10600000UL
#define WANT_PAGES 48384UL
#define PLAT_CAP 0xBD00000UL
#define APP_CAP 0x200000UL
#define SIG 0xA1550000C0DE0001UL

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
const char msgMap[] = "PLAT HUGE PAGE";

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
  return SIG + (i << 12) + w;
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long va, xor, i, w, bad, zbad, mid;
  volatile unsigned long *p;

  (void)probe;
  bad = 0;
  zbad = 0;
  xor = 0;
  mid = WANT_PAGES / 2UL;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  va = sys(SYS_MMAP, WANT, 0);
  say("ASKED", va);

  if (va > ERR_FLOOR) {
    if (va != E_BADARG) {
      bad++;
    }
    say("CAP", APP_CAP);
  } else {
    if (va != PLAT_BASE) {
      bad++;
    }
    /* Touch every page — FREED delta proves the frames; this proves
     * the leaves are live user pages, not a printed VA. */
    for (i = 0; i < WANT_PAGES; i++) {
      p = (volatile unsigned long *)(va + i * PAGE);
      if (p[0] != 0) {
        zbad++;
      }
      p[0] = mark(i, 0);
      xor ^= p[0];
    }
    /* Re-read first, middle, last — a sparse fake cannot match. */
    p = (volatile unsigned long *)(va + 0 * PAGE);
    if (p[0] != mark(0, 0)) {
      bad++;
    }
    p = (volatile unsigned long *)(va + mid * PAGE);
    if (p[0] != mark(mid, 0)) {
      bad++;
    }
    p = (volatile unsigned long *)(va + (WANT_PAGES - 1UL) * PAGE);
    if (p[0] != mark(WANT_PAGES - 1UL, 0)) {
      bad++;
    }
    for (w = 0; w < sizeof(msgMap); w++) {
      ((char *)va)[w] = msgMap[w];
    }
    if (sys(SYS_WRITE, va, sizeof(msgMap) - 1) != sizeof(msgMap) - 1) {
      bad++;
    }
    p = (volatile unsigned long *)va;
    p[0] = mark(0, 0);
    say("XOR", xor);
    say("CAP", PLAT_CAP);
  }

  say("ZBAD", zbad);
  say("BAD", bad);
  sys(SYS_EXIT, 0xA1550000UL + zbad + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
