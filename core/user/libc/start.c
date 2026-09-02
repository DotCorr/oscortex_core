/* core/user/libc/start.c — M19: the C entry contract.
 *
 * WHAT THIS FILE IS
 * ---------------------------------------------------------------------------
 * `_start` is the address the kernel `iretq`s to. Until M19 every test program
 * on this operating system carried its own `_start`, and every one of them did
 * the same three things: align the stack, zero RBP, and call a function that
 * took NO ARGUMENTS. It took no arguments because there were none — the kernel
 * entered ring 3 with RSP pointing at the top of an empty stack page and
 * nothing on it.
 *
 * M19 (core/kernel/args.dart, ADR-0023) makes the kernel build the System V
 * x86-64 initial process stack before it enters ring 3. This file is the other
 * half of that contract: it UNPACKS that stack and calls
 *
 *     int main(int argc, char **argv)
 *
 * and passes what `main` returns to the `exit` syscall. That is the whole of
 * the C entry contract, and after this file a C program written normally —
 * beginning with the line every C program begins with — is a program this
 * operating system can run.
 *
 * WHAT `_start` MUST NOT DO, AND WHY IT IS ASSEMBLY
 * ---------------------------------------------------------------------------
 * It must not touch RSP before it has read what is at RSP. A C function cannot
 * promise that: the compiler owns the prologue. So `_start` is four
 * instructions of hand-written assembly and the rest is C.
 *
 *   xorl %ebp, %ebp        the outermost frame has no parent. A debugger or an
 *                          unwinder that walks RBP stops here rather than
 *                          following whatever the kernel left behind.
 *   movq (%rsp), %rdi      argc, which the ABI puts AT RSP.
 *   leaq 8(%rsp), %rsi     argv, which is the array immediately above it.
 *   call libcStart         and the `call` is what makes the alignment work.
 *
 * THE ALIGNMENT, WHICH IS THE ONE SUBTLE THING HERE.
 * The ABI requires RSP to be 16-byte aligned AT PROCESS ENTRY, pointing at
 * argc. That is NOT the state a function sees on entry: a called function sees
 * RSP ≡ 8 (mod 16), because the `call` pushed an 8-byte return address. So
 * `_start` must NOT align RSP — the kernel already did — and the single `call`
 * below converts the process-entry state into the function-entry state exactly.
 * An `andq $-16, %rsp` here (which is what every pre-M19 `_start` on this OS
 * did) would be harmless on a stack that is already aligned and would silently
 * DESTROY argc's address if the kernel had got the alignment wrong, which is
 * precisely the bug the m19-argv harness exists to catch. It is not here.
 *
 * WHAT IS NOT HERE
 * ---------------------------------------------------------------------------
 * No `envp`: the kernel puts a NULL there and there is no environment on this
 * operating system (GAP-0146). No auxiliary vector beyond the AT_NULL that
 * terminates it (GAP-0147). No `.init_array`/`.fini_array` walk, no
 * `atexit`, no C++ static constructors, no TLS setup and no `errno` location —
 * GAP-0148 lists all of it. A `main` that returns is the only way out other
 * than calling `exit` yourself.
 */

#include "oslibc.h"

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  xorl %ebp, %ebp\n"
    "  movq (%rsp), %rdi\n"
    "  leaq 8(%rsp), %rsi\n"
    "  call libcStart\n"
    /* `libcStart` never returns — it ends in exit(), which does not come back.
     * The spin is here for the same reason syscall.c's is: falling off the end
     * of this symbol would execute whatever bytes the linker put after it. */
    "1:\n"
    "  pause\n"
    "  jmp 1b\n"
    ".size _start, . - _start\n");

/* The program's entry point, which this file exists to call. Declared here
 * rather than in oslibc.h so that the header stays a description of the
 * LIBRARY: `main` is the program's, not the library's, and a header that
 * declared it would be telling every translation unit about a symbol only this
 * one may reference. */
extern int main(int argc, char **argv);

void libcStart(unsigned long argc, char **argv);

void libcStart(unsigned long argc, char **argv) {
  /* argc arrives as the full 64-bit word the kernel wrote, and `main` takes an
   * int. The narrowing is written out rather than left implicit because the
   * kernel's bound (ARGS_MAX_COUNT) is what makes it safe: a count that could
   * not fit in an int would be a kernel that had already gone wrong. */
  exit((unsigned long)(int)main((int)argc, argv));
}
