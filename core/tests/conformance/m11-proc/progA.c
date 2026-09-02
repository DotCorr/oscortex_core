/* core/tests/conformance/m11-proc/progA.c
 *
 * PROCESS A: THE FIRST PROGRAM FOR THIS OS THAT WAS COMPILED THE WAY ANYBODY
 * WOULD COMPILE ONE.
 *
 * M10's prog.c had to be built with `-mgeneral-regs-only`, because the kernel
 * had never set CR4.OSFXSR and every SSE instruction was a #UD in ring 3
 * (docs/known-gaps.md GAP-0092). THIS program is built WITHOUT that flag, at
 * -O2, and `build-progs.sh` asserts the opposite of what M10's build-prog.sh
 * asserted: the disassembly of `blobCopy` -- a function containing no inline
 * assembly at all -- MUST contain an `%xmm` register, or the milestone has not
 * been tested.
 *
 * WHAT THIS PROGRAM PROVES, AND HOW
 *
 *   1. SSE RUNS. `blobCopy` is an ordinary 64-byte struct copy through two
 *      pointers. At -O2 clang lowers it to `movups %xmm0` and friends. Before
 *      M11 that instruction was a #UD.
 *
 *   2. THE FPU STATE IS PER-PROCESS. `xmmYield` writes a pattern this program
 *      alone uses into XMM0 and XMM7, calls `yield` (syscall 3) -- which
 *      switches to the OTHER process, which writes ITS pattern into the same
 *      two registers -- and reads them back. The write, the syscall and the
 *      read-back are ONE inline-asm block, so the compiler cannot move any of
 *      them; the only thing that can put the pattern back is the kernel's
 *      `fxrstor`. A kernel that skipped it returns process B's pattern here.
 *
 *   3. TWO DIFFERENT PROGRAMS RAN. This one says `A` and exits with a status
 *      derived from its own `.data` and `.rodata`; progB.c says `B` and exits
 *      with a different one. `derive.py` reads both out of the two ELFs.
 *
 * Nothing here may assume anything about the kernel except the four syscall
 * numbers below, which are core/kernel/user.dart's and core/kernel/proc.dart's.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_WHO 2
#define SYS_YIELD 3

/* This program's XMM signature. Two 32-bit halves so a `pshufd` broadcast
 * fills all four lanes with the same recognisable word, and so a truncation to
 * 32 bits would still be visible. progB.c's is different in every nibble. */
#define XMM_PATTERN_A 0xA1A2A3A4UL

/* WHAT `movq %xmm0, %rax` ACTUALLY RETURNS, and it is not the pattern.
 *
 * `pshufd $0x00` broadcasts the low 32 bits to all FOUR lanes, so the low 64
 * bits of the register hold the pattern TWICE. `movq` moves those 64 bits. The
 * expectation therefore has to be the doubled word, and it is written out here
 * rather than derived at the comparison, because the first version of this
 * program compared against the 32-bit pattern, printed the right hex, and
 * reported `XX` on a kernel that had restored the register perfectly. A check
 * that fails when the thing under test is CORRECT is worse than no check. */
#define XMM_PATTERN_A_64 ((XMM_PATTERN_A << 32) | XMM_PATTERN_A)

/* THE ENTRY POINT IS HAND-WRITTEN ASSEMBLY, AND THAT IS AN ABI SEAM RATHER
 * THAN A FLOURISH.
 *
 * The kernel hands a new process RSP = the top of its stack window, 16-byte
 * aligned -- the same thing Linux hands `_start`. But the System V AMD64 ABI
 * says a function sees RSP congruent to 8 (mod 16) at ITS entry, because the
 * `call` that reached it pushed a return address. A `_start` compiled as an
 * ordinary C function believes the second thing while the kernel does the
 * first, and at -O2 with SSE enabled clang will happily `movaps` a local into
 * a stack slot it computed on that belief: a #GP the moment the program does
 * anything vectorised.
 *
 * This is exactly why every real libc's `_start` is assembly. `andq $-16`
 * makes RSP 16-aligned whatever it was, and the `call` then pushes 8, so
 * `progMain` sees the alignment the ABI promises it. RDI -- the kernel's one
 * argument to a process -- passes through untouched.
 */
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

/* The whole ABI: RAX = number, RDI and RSI = arguments, `int $0x80`, RAX back.
 * "memory" because the kernel reads through the pointer this hands it. */
static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

/* 64 bytes, in .data, so the copy below cannot be constant-folded away. */
typedef struct {
  unsigned long w[8];
} blob;

blob srcBlob = {{0x1111111111111111UL, 0x2222222222222222UL,
                 0x3333333333333333UL, 0x4444444444444444UL,
                 0x5555555555555555UL, 0x6666666666666666UL,
                 0x7777777777777777UL, 0x8888888888888888UL}};
blob dstBlob; /* .bss */

/* THE SSE PROOF, AND IT CONTAINS NO INLINE ASSEMBLY ON PURPOSE.
 *
 * `build-progs.sh` disassembles THIS SYMBOL BY NAME and requires an `%xmm`
 * register inside it. A check that only looked at the whole file would be
 * satisfied by `xmmYield`'s hand-written `movq %rax, %xmm0` below, and would
 * therefore pass on a program the compiler had emitted no SSE for at all --
 * which is the thing that needs proving.
 *
 * `noinline` so the symbol survives to be disassembled; `volatile`-free so
 * clang is allowed to vectorise, which is the point. */
__attribute__((noinline)) unsigned long blobCopy(blob *d, const blob *s) {
  unsigned long sum = 0;
  int i;
  *d = *s; /* -> movups %xmm0 at -O2 */
  for (i = 0; i < 8; i++) {
    sum += d->w[i];
  }
  return sum;
}

/* Writes [pat] into XMM0 and XMM7, yields, and reads both back.
 *
 * ONE asm block from the write to the read-back, so nothing the compiler does
 * can come between them. Returns 0 if BOTH registers came back holding the
 * pattern, and the offending value otherwise.
 *
 * `pshufd $0, %xmm0, %xmm0` broadcasts the low 32 bits to all four lanes, so a
 * kernel that restored only part of the register is visible too. */
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

/* .rodata -> the R+X segment. Read back by the harness OUT OF THE ELF FILE, so
 * the expected output is derived from the binary rather than typed twice. */
const char msg[] = "PROC A: SSE AND A YIELD";

/* Also .rodata, `volatile` so it must be LOADED rather than folded into an
 * immediate: the exit status then depends on the loader having mapped this
 * segment, not merely on the code having run. */
const volatile unsigned long exitStatus = 0x00A00000;

/* .data, with file content behind it. */
volatile unsigned long dataWord = 0x000A0A0A;

char out[32]; /* .bss, written before it is read */

/* EIGHT KILOBYTES OF `.bss`, AND ITS ONLY JOB IS TO MAKE PROCESS A BIGGER THAN
 * PROCESS B.
 *
 * `procCrossVa` finds a page that A has mapped and B has not, and hands it to
 * B to dereference. If the two programs mapped the SAME set of pages there
 * would be no such address -- the kernel says so out loud and refuses, which
 * is what it did the first time this harness was run with two programs of the
 * same shape. So A is given a `.bss` array large enough to push its writable
 * segment two whole pages past where B's ends, and those pages ARE process A's
 * program pages: not padding the harness invented, but memory A writes into
 * and reads back.
 *
 * `volatile` so the writes below survive -O2 and the page really is dirtied
 * before B ever runs. If isolation were broken, B's probe would print
 * `A5A5A5A5A5A5A5A5` instead of taking a #PF, which is a louder failure than a
 * missing line.
 */
#define CROSS_MARK 0xA5A5A5A5A5A5A5A5UL
volatile unsigned long crossPage[1024];

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long sum, lo, hi, bad, i, j, ret;

  (void)probe; /* A is never the cross-probe process; B is. */

  sys(SYS_WHO, 0, 0);
  sys(SYS_WRITE, (unsigned long)msg, sizeof(msg) - 1);

  /* Dirty the two extra pages BEFORE the first yield, so that by the time B
   * runs and probes, the page it is refused really does hold A's data. */
  crossPage[0] = CROSS_MARK;
  crossPage[512] = CROSS_MARK;
  crossPage[1023] = CROSS_MARK;

  /* 1. SSE. */
  sum = blobCopy(&dstBlob, &srcBlob);

  /* 2. Per-process FPU state, three times, so a kernel that got it right once
   *    by accident has to get it right three times. */
  bad = 0;
  for (i = 0; i < 3; i++) {
    /* THE SYSCALL'S RETURN VALUE IS CHECKED, AND THAT IS NOT DECORATION.
     *
     * `procYield` overwrites the SAVED frame's RAX with 1 before it switches
     * away, so a process that comes back sees "you yielded, and you are back"
     * rather than the syscall NUMBER it went in with. A mutation that deleted
     * that one line passed every other check in this harness, because nothing
     * looked at the value. Now something does. */
    ret = xmmYield(XMM_PATTERN_A, &lo, &hi);
    if (ret != 1) {
      bad = bad + 16;
    }
    out[0] = 'A';
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
    out[25] = (lo == XMM_PATTERN_A_64) ? 'O' : 'X';
    out[26] = (hi == XMM_PATTERN_A_64) ? 'K' : 'X';
    sys(SYS_WRITE, (unsigned long)out, 27);
    if (lo != XMM_PATTERN_A_64) {
      bad = bad + 1;
    }
    if (hi != XMM_PATTERN_A_64) {
      bad = bad + 1;
    }
  }

  /* 3. The status is derived from the binary: the .rodata word, plus the .data
   *    word, plus the checksum of the 64 bytes the SSE copy moved, plus one per
   *    XMM register that came back wrong. derive.py adds the first three out of
   *    the ELF, so a mismatch is either a loader bug or a lost FPU state, and
   *    the two are distinguishable because `bad` is small. */
  sys(SYS_EXIT, exitStatus + dataWord + sum + bad, 0);

  for (;;) {
    __asm__ volatile("pause");
  }
}
