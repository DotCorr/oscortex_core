/* core/tests/conformance/m18-preempt/progC.c
 *
 * PROCESS C: THE RUNAWAY.  IT MAKES NO SYSTEM CALLS AT ALL.
 *
 * ---------------------------------------------------------------------------
 * WHAT MAKES THIS PROGRAM DIFFERENT FROM EVERY PROGRAM THIS OS HAS RUN BEFORE
 * ---------------------------------------------------------------------------
 * M11's progA and progB were written for a COOPERATIVE kernel: each one calls
 * `yield` (syscall 3) three times, and the whole of M11's interleaving is those
 * six calls. A kernel that only switches when it is asked can run them.
 *
 * This program asks for nothing. It has no `int $0x80` in it anywhere -- not
 * one, and `build-progs.sh` disassembles the linked executable and requires the
 * count to be exactly ZERO. It cannot yield, it cannot exit, it cannot print,
 * and it cannot be talked out of running. It is the program M11's own header
 * said could not be stopped (docs/known-gaps.md GAP-0085), written down.
 *
 * ---------------------------------------------------------------------------
 * THE PROGRESS COUNTER LIVES IN R15, AND THAT IS THE POINT
 * ---------------------------------------------------------------------------
 * "Both programs made progress" has to be checked by something, and this
 * program can tell nobody anything: it has no syscalls, and its memory is in a
 * private address space the harness would have to walk four levels of page
 * table to reach.
 *
 * So the counter is kept in a REGISTER. When the timer interrupt preempts this
 * process, `isr_common` pushes all fifteen general-purpose registers and
 * `procSaveFrame` copies them into this process's slot in the kernel's process
 * table -- which is ordinary kernel `.bss`, at an address the kernel PRINTS
 * (`proc sched ... HEAD <addr>`), in an identity-mapped page. `run.sh` dumps
 * that memory with the QEMU monitor and reads R15 straight out of the saved
 * frame.
 *
 * That gives three independent things from one dump, all of them the machine's
 * own words rather than this program's:
 *
 *   * R15 is large           -- the loop really executed, millions of times;
 *   * RIP is inside this ELF's own R+X segment, at the `jmp` of the loop
 *                            -- the thing that was preempted was THIS program;
 *   * CS is the ring-3 code selector
 *                            -- it was preempted while at CPL 3, which is the
 *                               only privilege this scheduler preempts from.
 *
 * ---------------------------------------------------------------------------
 * THE LOOP IS HAND-WRITTEN ASSEMBLY BECAUSE A C LOOP WOULD NOT BE THIS LOOP
 * ---------------------------------------------------------------------------
 * `for (;;) r15++;` is not expressible in C: the register allocator owns R15,
 * and at -O2 clang deletes a loop whose only effect is a local it can prove
 * nobody reads. Writing the three instructions by hand is the honest way to get
 * exactly three instructions, and it also means this file's ENTIRE .text is
 * visible in the source -- which is what lets `build-progs.sh` assert there is
 * no `int $0x80` in it and have that assertion mean something.
 */

/* The .data and .bss words below exist for the LINK SCRIPT's sake, not the
 * program's: `prog.ld` builds a second PT_LOAD from .data + .bss, and
 * `build-progs.sh` requires that segment to have a non-empty file-backed part
 * AND a zero tail (p_memsz > p_filesz), exactly as M10 and M11 required. A
 * program with no writable data at all would produce a one-segment ELF and
 * would be testing a different loader path from the one M11 tests.
 *
 * They are also the reason this program's writable segment is LARGER than
 * progD's, which is what `procCrossVa` needs if this harness ever wants M11's
 * isolation probe. Nothing in M18 depends on that today. */
volatile unsigned long spinData = 0x0C0C0C0C0C0C0C0CUL; /* .data */
volatile unsigned long spinBss[512];                    /* .bss  */

/* .rodata, so the R+X segment has content of its own and `e_entry` lands at a
 * non-zero, non-page-aligned offset inside it (prog.ld's whole argument). */
const char msgC[] = "PROC C: NEVER YIELDS, NEVER EXITS";

/* THE WHOLE PROGRAM.
 *
 *   xorl %r15d,%r15d    -- start the progress counter at a known value, so a
 *                          non-zero R15 in the saved frame cannot be litter
 *                          left in the register by something else. It cannot
 *                          be anyway -- `enter_user` scrubs every general
 *                          purpose register before its `iretq` (ADR-0013) and
 *                          `procInitFrame` zeroes all fifteen words of a fresh
 *                          process's frame -- but this program does not have
 *                          to take the kernel's word for it.
 *   andq $-16,%rsp      -- the ABI seam M11's progA documents at length: the
 *                          kernel hands a new process a 16-aligned RSP and the
 *                          System V ABI says a function sees RSP congruent to
 *                          8 mod 16. Nothing here calls a C function, so this
 *                          is belt and braces; it is kept so that the entry
 *                          sequence is the same one every other program in
 *                          this suite uses.
 *   movabsq $0x00C0FFEEC0FFEE00,%rax
 *                       -- A LIVE VALUE IN RAX THAT NOTHING EVER WRITES AGAIN,
 *                          and it is here because a mutation survived without
 *                          it. `procYield` overwrites the SAVED frame's RAX
 *                          with 1 before it switches away, because its frame
 *                          came from an `int $0x80` whose RAX held a syscall
 *                          number; `procTick`'s frame came from a TIMER, and
 *                          its RAX is the program's own register. A kernel
 *                          that copied that one line into the preemption path
 *                          passed every check this harness had -- because the
 *                          only other program here keeps nothing live in RAX,
 *                          so overwriting it was invisible. This program does.
 *                          `run.sh` reads the constant out of THIS FILE and
 *                          requires the saved frame to hold exactly it.
 *   1: incq %r15 ; jmp 1b
 *                       -- two instructions, and neither of them can be
 *                          interrupted by anything but hardware. NEITHER
 *                          TOUCHES RAX, which is what makes the check above
 *                          mean something.
 */
__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  xorl %r15d, %r15d\n"
    "  movabsq $0x00C0FFEEC0FFEE00, %rax\n"
    "spinLoop:\n"
    "  incq %r15\n"
    "  jmp spinLoop\n"
    ".size _start, . - _start\n");

/* Referenced so the linker keeps them and so `.data` has file content. Never
 * called: `_start` above never returns and never calls anything. */
unsigned long progCTouch(void);
unsigned long progCTouch(void) {
  return spinData + spinBss[0] + (unsigned long)msgC[0];
}
