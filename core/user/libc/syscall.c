/* core/user/libc/syscall.c — the five syscalls, in one place instead of copied
 * into every program.
 *
 * WHY THIS FILE EXISTS. Every test program on this OS before M13 -- m10's,
 * m11's, m12's -- carried its own private copy of the `int $0x80` stub and its
 * own private spelling of the syscall numbers. Three copies is three chances
 * for one of them to disagree with core/kernel/user.dart, and the disagreement
 * would show up as a program that faults rather than as a build error.
 *
 * The stub itself is unchanged from those copies, deliberately: RAX carries the
 * number, RDI and RSI the two arguments, RAX comes back. "memory" is in the
 * clobber list because `write` makes the kernel READ the caller's buffer and
 * `sbrk` makes it change the caller's address space, and a compiler that cached
 * a load across either would be entitled to.
 */

#include "oslibc.h"

unsigned long sys_call(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

unsigned long write(const void *buf, size_t len) {
  return sys_call(SYS_WRITE, (unsigned long)buf, len);
}

void exit(unsigned long status) {
  sys_call(SYS_EXIT, status, 0);
  /* The kernel does not return from exit. If it ever did, spinning here is the
   * only honest thing left: falling off the end of a `noreturn` would run
   * whatever bytes follow. */
  for (;;) {
    __asm__ volatile("pause");
  }
}

void yield(void) { sys_call(SYS_YIELD, 0, 0); }

unsigned long who(void) { return sys_call(SYS_WHO, 0, 0); }

/* The last raw value `sbrk` got back, so a caller that wants to tell
 * "your address space is full" from "the machine is out of memory" still can.
 * ADR-0016 §1 made those three distinct values on purpose and a wrapper that
 * collapsed them to NULL and threw them away would have wasted that. */
static unsigned long sbrkErr;

void *sbrk(size_t inc) {
  unsigned long r = sys_call(SYS_SBRK, inc, 0);
  if (r >= SBRK_ERR_FLOOR) {
    sbrkErr = r;
    return NULL;
  }
  sbrkErr = 0;
  return (void *)r;
}

unsigned long sbrk_last_error(void) { return sbrkErr; }
