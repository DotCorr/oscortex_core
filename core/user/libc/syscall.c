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

unsigned long sys_call3(unsigned long n, unsigned long a, unsigned long b,
                        unsigned long c) {
  unsigned long r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c)
                   : "memory");
  return r;
}

/* M15 made the three-argument form the real one and this the wrapper, rather
 * than adding a second stub: m13-libc requires EXACTLY ONE `int $0x80` in the
 * whole library and it was right to. RDX is a caller-saved register in the
 * System V AMD64 ABI and `isr_common` saves all fifteen general-purpose
 * registers regardless, so a syscall that ignores its third argument is
 * unaffected by one being passed. */
unsigned long sys_call(unsigned long n, unsigned long a, unsigned long b) {
  return sys_call3(n, a, b, 0);
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

/* ---------------------------------------------------------------------------
 * M15 — the four file syscalls.
 *
 * Each is one line, and each returns the kernel's value UNCHANGED, refusals
 * included. That is the whole convention: FILE_ERR_FLOOR separates an answer
 * from a refusal with one comparison, so a wrapper that turned eleven distinct
 * refusals into -1 would be throwing away the only diagnostic there is.
 *
 * `open` computes the length with strlen rather than taking one, because a C
 * caller has a NUL-terminated string and a length argument it had to compute
 * itself is a length argument it can get wrong. The kernel takes a pointer AND
 * a length -- it must, it cannot trust a terminator it would have to go looking
 * for through a ring-3 pointer -- so this is where the two conventions meet.
 * ------------------------------------------------------------------------- */

unsigned long open(const char *name) { return openmode(name, O_READ); }

unsigned long read(unsigned long fd, void *buf, size_t len) {
  return sys_call3(SYS_READ, fd, (unsigned long)buf, len);
}

unsigned long close(unsigned long fd) { return sys_call(SYS_CLOSE, fd, 0); }

unsigned long seek(unsigned long fd, unsigned long off) {
  return sys_call(SYS_SEEK, fd, off);
}

/* ---------------------------------------------------------------------------
 * M16 — the mode argument and the write.
 *
 * `open` is now `openmode(name, O_READ)` and is kept as a name because a
 * read-only open is what most callers want and because every program written
 * against M15 still compiles. The kernel takes the mode in RDX and a
 * two-argument `sys_call` passes zero there, which is O_READ — so the
 * compatibility is a property of the ABI rather than a special case in the
 * kernel.
 * ------------------------------------------------------------------------- */

unsigned long openmode(const char *name, unsigned long mode) {
  return sys_call3(SYS_OPEN, (unsigned long)name, strlen(name), mode);
}

unsigned long create(const char *name) { return openmode(name, O_WRITE); }

unsigned long fdwrite(unsigned long fd, const void *buf, size_t len) {
  return sys_call3(SYS_FDWRITE, fd, (unsigned long)buf, len);
}
