/* core/tests/conformance/m18-preempt/progD.c
 *
 * PROCESS D: THE REPORTER.  IT NEVER CALLS `yield` EITHER.
 *
 * ---------------------------------------------------------------------------
 * WHY A SECOND PROGRAM, AND WHY THIS ONE
 * ---------------------------------------------------------------------------
 * progC proves a runaway does not hang the machine. It cannot prove anything
 * else, because it has no way to say anything. This program is the other half:
 * it runs alongside progC, is preempted by the same timer, and REPORTS -- so
 * that the milestone's two remaining claims are made by a program in ring 3
 * rather than only by the kernel about itself:
 *
 *   1. THE SWITCH WAS INVOLUNTARY.  This program calls `yield` ZERO times.
 *      `build-progs.sh` disassembles it and requires that the only syscall
 *      numbers loaded into RAX anywhere in the linked executable are the four
 *      below -- 3 is not among them.  It nevertheless observes, from the
 *      kernel's own count, that it has been taken off the CPU.
 *
 *   2. THE FPU STATE SURVIVED A PREEMPTIVE SWITCH.  M11 proved XMM0 and XMM7
 *      survive a switch the program ASKED for: the `int $0x80` was inside the
 *      asm block, so the exact instruction at which the state was saved was
 *      chosen by the program.  Here the state is written, and then the program
 *      spins until the kernel says it has been preempted three times.  The
 *      instruction at which `fxsave` ran was chosen by a TIMER, at an
 *      arbitrary point inside the spin loop, three separate times.  A kernel
 *      that saved the FPU on the yield path and not on the tick path passes
 *      M11 and fails here.
 *
 * ---------------------------------------------------------------------------
 * `SYS_PREEMPTS` IS WHAT MAKES THIS ASSERTABLE INSTEAD OF A STOPWATCH
 * ---------------------------------------------------------------------------
 * "Run for a while and check you got interrupted" is a wall-clock criterion: it
 * is a different test on a fast host and a slow one, and on a loaded machine it
 * is a different test twice in a row.  M1 had the same problem with the timer
 * and solved it by making the TICK COUNT the trigger rather than the elapsed
 * time.  This is that, one level up: the loop below terminates after exactly
 * `WANT_PREEMPTS` quantum expiries charged to this process, whatever the host
 * is doing, and the number comes from the kernel's per-slot counter.
 *
 * The syscall is a pure read.  It does not switch, sleep or block, so calling
 * it does not make this a cooperative program -- and progC, which makes no
 * syscalls whatsoever, is there to close even that argument.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_WHO 2
#define SYS_PREEMPTS 10

/* THREE. Not one: a kernel that saved the FPU on the first preemption and then
 * stopped would pass a single round trip. Not thirty: every extra one is two
 * more quanta of wall-clock in the harness, and the third adds no evidence the
 * second did not. M11 used three for the same reason. */
#define WANT_PREEMPTS 3

/* This program's XMM signature, different in every nibble from progC's data
 * words and from M11's two patterns. Broadcast to all four lanes by `pshufd`,
 * so `movq %xmm0, %rax` returns the word TWICE -- see M11's progA.c for why the
 * expectation has to be the doubled value and not the pattern. */
#define XMM_PATTERN_D 0xD1D2D3D4UL
#define XMM_PATTERN_D_64 ((XMM_PATTERN_D << 32) | XMM_PATTERN_D)

/* Hand-written `_start`, for M11's progA.c's reason: the kernel hands a new
 * process RSP 16-byte aligned and the System V AMD64 ABI says a function sees
 * RSP congruent to 8 mod 16, because a `call` pushed a return address. At -O2
 * with SSE on, clang will `movaps` a local into a stack slot it computed on the
 * ABI's belief, and a #GP in a program that did nothing wrong is the result. */
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

/* The whole ABI: RAX = number, RDI and RSI = arguments, `int $0x80`, RAX back. */
static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

/* 64 bytes in .data, so the copy below cannot be constant-folded away. */
typedef struct {
  unsigned long w[8];
} blob;

blob srcBlob = {{0xD111111111111111UL, 0xD222222222222222UL,
                 0xD333333333333333UL, 0xD444444444444444UL,
                 0xD555555555555555UL, 0xD666666666666666UL,
                 0xD777777777777777UL, 0xD888888888888888UL}};
blob dstBlob; /* .bss */

/* THE SSE PROOF WITH NO INLINE ASSEMBLY IN IT, kept from M11 for M11's reason:
 * a whole-file grep for `%xmm` would be satisfied by `xmmSpin`'s hand-written
 * `movq %rax, %xmm0` below, and would pass on a program clang emitted no vector
 * code for at all. `build-progs.sh` disassembles THIS SYMBOL BY NAME. */
__attribute__((noinline)) unsigned long blobCopy(blob *d, const blob *s) {
  unsigned long sum = 0;
  int i;
  *d = *s; /* -> movups %xmm0 at -O2 */
  for (i = 0; i < 8; i++) {
    sum += d->w[i];
  }
  return sum;
}

/* WRITE THE PATTERN, SPIN UNTIL PREEMPTED [want] TIMES, READ THE PATTERN BACK.
 *
 * ONE asm block from the write to the read-back, so nothing the compiler does
 * can come between them and no spill can put XMM0 or XMM7 somewhere the kernel
 * is not responsible for. The only thing that can put the pattern back after a
 * preemption is the kernel's `fxrstor`.
 *
 * The inner delay loop matters and is not padding. Without it this is a tight
 * `int $0x80` loop, and a process that spends most of its time inside a syscall
 * spends most of its time with IF clear -- so the timer tick that ought to
 * charge this process's slice arrives while it is in the kernel, is counted as
 * a KERNEL tick, and the quantum takes far longer than eight ticks of wall
 * clock to expire. The delay puts the process back in ring 3 where the
 * scheduler can see it. It is a property of THIS TEST needing to be quick, not
 * of the scheduler needing help: progC has no syscalls at all and is charged
 * every one of its ticks.
 *
 * Registers: RAX is the syscall number and result. RCX is the delay counter and
 * is in the clobber list, which is also what stops the compiler from putting
 * any input there. `want` and the syscall number are `i`mmediates, so no
 * general-purpose register has to survive the delay loop at all.
 */
static unsigned long xmmSpin(unsigned long pat, unsigned long *lo,
                             unsigned long *hi) {
  unsigned long r, a, b;
  __asm__ volatile(
      "movq %[p], %%xmm0\n\t"
      "pshufd $0x00, %%xmm0, %%xmm0\n\t"
      "movdqa %%xmm0, %%xmm7\n\t"
      "1:\n\t"
      "movq $200000, %%rcx\n\t"
      "2:\n\t"
      "decq %%rcx\n\t"
      "jnz 2b\n\t"
      "movq %[n], %%rax\n\t"
      "int $0x80\n\t"
      "cmpq %[w], %%rax\n\t"
      "jb 1b\n\t"
      "movq %%xmm0, %[a]\n\t"
      "movq %%xmm7, %[b]\n\t"
      : "=a"(r), [a] "=&r"(a), [b] "=&r"(b)
      : [p] "r"(pat), [n] "i"((unsigned long)SYS_PREEMPTS),
        [w] "i"((unsigned long)WANT_PREEMPTS)
      : "rcx", "cc", "memory", "xmm0", "xmm7");
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
const char msg[] = "PROC D: PREEMPTED, NEVER YIELDED";

/* Also .rodata, `volatile` so it must be LOADED rather than folded into an
 * immediate: the exit status then depends on the loader having mapped this
 * segment, not merely on the code having run. */
const volatile unsigned long exitStatus = 0x00D00000;

/* .data, with file content behind it. */
volatile unsigned long dataWord = 0x000D0D0D;

char out[48]; /* .bss, written before it is read */

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long sum, lo, hi, bad, j, pre;

  (void)probe;

  sys(SYS_WHO, 0, 0);
  sys(SYS_WRITE, (unsigned long)msg, sizeof(msg) - 1);

  /* 1. SSE the compiler emitted. */
  sum = blobCopy(&dstBlob, &srcBlob);

  /* 2. The XMM signature across THREE INVOLUNTARY switches. */
  bad = 0;
  pre = xmmSpin(XMM_PATTERN_D, &lo, &hi);

  /* THE RETURN VALUE IS CHECKED, and it is not decoration. `xmmSpin` leaves the
   * loop the first time the kernel reports a count that is not below
   * WANT_PREEMPTS, so RAX must be EXACTLY WANT_PREEMPTS on the way out. A
   * kernel that returned some huge number, or the syscall number, or a stale
   * value would satisfy `jb` and be invisible without this. */
  if (pre != WANT_PREEMPTS) {
    bad = bad + 16;
  }

  out[0] = 'D';
  out[1] = ' ';
  out[2] = 'X';
  out[3] = 'M';
  out[4] = 'M';
  out[5] = ' ';
  /* All SIXTEEN hex digits of the low 64 bits: the pattern is broadcast to
   * every lane, so a kernel that restored half a register would print a
   * right-looking top half, and eight digits would hide exactly that. */
  for (j = 0; j < 16; j++) {
    out[6 + j] = hex(lo >> (60 - 4 * j));
  }
  out[22] = ' ';
  out[23] = (lo == XMM_PATTERN_D_64) ? 'O' : 'X';
  out[24] = (hi == XMM_PATTERN_D_64) ? 'K' : 'X';
  out[25] = ' ';
  out[26] = 'P';
  out[27] = 'R';
  out[28] = 'E';
  out[29] = ' ';
  for (j = 0; j < 8; j++) {
    out[30 + j] = hex(pre >> (28 - 4 * j));
  }
  sys(SYS_WRITE, (unsigned long)out, 38);

  if (lo != XMM_PATTERN_D_64) {
    bad = bad + 1;
  }
  if (hi != XMM_PATTERN_D_64) {
    bad = bad + 1;
  }

  /* 3. The status is derived from the binary: the .rodata word, plus the .data
   *    word, plus the checksum of the 64 bytes the SSE copy moved, plus one per
   *    XMM register that came back wrong and sixteen if the syscall's return
   *    value was not the count it was spun on. `derive.py` adds the first three
   *    out of the ELF, so a mismatch is a loader bug, a lost FPU state or a
   *    wrong syscall result, and the three are distinguishable because `bad` is
   *    small and its terms do not overlap. */
  sys(SYS_EXIT, exitStatus + dataWord + sum + bad, 0);

  for (;;) {
    __asm__ volatile("pause");
  }
}
