/* core/tests/conformance/m11-proc/progB.c
 *
 * PROCESS B: THE SECOND PROGRAM, AND THE ONE THAT TRIES TO READ THE FIRST.
 *
 * A separate source file rather than progA.c compiled twice with a `-D`,
 * because "two different programs both ran" is a claim about two binaries and
 * a preprocessor flag makes it a claim about one. The two files differ in
 * their message, their XMM signature, their `.data` and `.rodata` words, the
 * number of times they yield, and in the whole of `crossProbe` below -- so the
 * serial output identifies which one printed each line without the harness
 * having to count.
 *
 * WHAT THIS ONE ADDS: THE NEGATIVE CONTROL FOR ISOLATION.
 *
 * `proc cross <lbaA> <lbaB>` hands B, in RDI, a virtual address that the
 * KERNEL computed (`procCrossVa`) from the two page tables it built: an
 * address process A has mapped and B has not. B dereferences it. It must take
 * a #PF, and the kernel must report it and tear both processes down.
 *
 * That address is inside `[0x10000000, 0x10200000)` -- the SAME window B's own
 * pages live in -- so the fault is not "the address is out of range". It is
 * "this page is not in THIS address space", which is the only version of the
 * claim worth making. `proc run` (cross = 0) hands B a zero and it runs
 * normally, which is the positive half of the same control.
 *
 * See progA.c's header for the ABI seam that makes `_start` assembly and for
 * why `blobCopy` may contain no inline asm.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_WHO 2
#define SYS_YIELD 3

/* Different in every nibble from progA.c's 0xA1A2A3A4. */
#define XMM_PATTERN_B 0xB5B6B7B8UL

/* WHAT `movq %xmm0, %rax` ACTUALLY RETURNS, and it is not the pattern.
 *
 * `pshufd $0x00` broadcasts the low 32 bits to all FOUR lanes, so the low 64
 * bits of the register hold the pattern TWICE. `movq` moves those 64 bits. The
 * expectation therefore has to be the doubled word, and it is written out here
 * rather than derived at the comparison, because the first version of this
 * program compared against the 32-bit pattern, printed the right hex, and
 * reported `XX` on a kernel that had restored the register perfectly. A check
 * that fails when the thing under test is CORRECT is worse than no check. */
#define XMM_PATTERN_B_64 ((XMM_PATTERN_B << 32) | XMM_PATTERN_B)

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

typedef struct {
  unsigned long w[8];
} blob;

blob srcBlob = {{0x0101010101010101UL, 0x0202020202020202UL,
                 0x0303030303030303UL, 0x0404040404040404UL,
                 0x0505050505050505UL, 0x0606060606060606UL,
                 0x0707070707070707UL, 0x0808080808080808UL}};
blob dstBlob;

/* No inline assembly here, deliberately -- see progA.c. */
__attribute__((noinline)) unsigned long blobCopy(blob *d, const blob *s) {
  unsigned long sum = 0;
  int i;
  *d = *s;
  for (i = 0; i < 8; i++) {
    sum += d->w[i];
  }
  return sum;
}

static unsigned long xmmYield(unsigned long pat, unsigned long *lo,
                              unsigned long *hi) {
  unsigned long r, a, b;
  __asm__ volatile(
      "movq %[p], %%xmm0\n\t"
      "pshufd $0x00, %%xmm0, %%xmm0\n\t"
      "movdqa %%xmm0, %%xmm7\n\t"
      "int $0x80\n\t"
      "movq %%xmm0, %[a]\n\t"
      "movq %%xmm7, %[b]\n\t"
      : "=a"(r), [a] "=&r"(a), [b] "=&r"(b)
      : "a"((unsigned long)SYS_YIELD), [p] "r"(pat)
      : "memory", "xmm0", "xmm7");
  *lo = a;
  *hi = b;
  return r;
}

static char hex(unsigned long v) {
  const char digits[] = "0123456789ABCDEF";
  return digits[v & 15];
}

const char msg[] = "PROC B: A DIFFERENT PROGRAM ENTIRELY";

const volatile unsigned long exitStatus = 0x00B00000;
volatile unsigned long dataWord = 0x000B0B0B;

char out[32];

/* THE READ THAT MUST FAULT.
 *
 * `volatile` so it cannot be optimised away, and the value is written into
 * `out` so that a kernel which let the read SUCCEED prints A's bytes here --
 * which is a louder failure than a missing line. If this returns at all, the
 * two address spaces were one.
 */
__attribute__((noinline)) void crossProbe(unsigned long va) {
  unsigned long v = *(volatile unsigned long *)va;
  int i;
  out[0] = 'B';
  out[1] = ' ';
  out[2] = 'R';
  out[3] = 'E';
  out[4] = 'A';
  out[5] = 'D';
  out[6] = ' ';
  for (i = 0; i < 16; i++) {
    out[7 + i] = hex(v >> (60 - 4 * i));
  }
  sys(SYS_WRITE, (unsigned long)out, 23);
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long sum, lo, hi, bad, i, j, ret;

  sys(SYS_WHO, 0, 0);
  sys(SYS_WRITE, (unsigned long)msg, sizeof(msg) - 1);

  /* The negative control, FIRST, so the fault lands at a point the harness can
   * name: after A's first yield and before anything else B does. */
  if (probe != 0) {
    crossProbe(probe);
  }

  sum = blobCopy(&dstBlob, &srcBlob);

  bad = 0;
  for (i = 0; i < 3; i++) {
    /* THE SYSCALL'S RETURN VALUE IS CHECKED, AND THAT IS NOT DECORATION.
     *
     * `procYield` overwrites the SAVED frame's RAX with 1 before it switches
     * away, so a process that comes back sees "you yielded, and you are back"
     * rather than the syscall NUMBER it went in with. A mutation that deleted
     * that one line passed every other check in this harness, because nothing
     * looked at the value. Now something does. */
    ret = xmmYield(XMM_PATTERN_B, &lo, &hi);
    if (ret != 1) {
      bad = bad + 16;
    }
    out[0] = 'B';
    out[1] = ' ';
    out[2] = 'X';
    out[3] = 'M';
    out[4] = 'M';
    out[5] = ' ';
    out[6] = hex(i);
    out[7] = ' ';
    /* All SIXTEEN hex digits of the low 64 bits, not eight: the pattern is
     * broadcast to every lane, so a kernel that restored half a register would
     * print a right-looking top half and a wrong bottom half, and eight digits
     * would hide exactly that. */
    for (j = 0; j < 16; j++) {
      out[8 + j] = hex(lo >> (60 - 4 * j));
    }
    out[24] = ' ';
    out[25] = (lo == XMM_PATTERN_B_64) ? 'O' : 'X';
    out[26] = (hi == XMM_PATTERN_B_64) ? 'K' : 'X';
    sys(SYS_WRITE, (unsigned long)out, 27);
    if (lo != XMM_PATTERN_B_64) {
      bad = bad + 1;
    }
    if (hi != XMM_PATTERN_B_64) {
      bad = bad + 1;
    }
  }

  sys(SYS_EXIT, exitStatus + dataWord + sum + bad, 0);

  for (;;) {
    __asm__ volatile("pause");
  }
}
