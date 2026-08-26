/* core/user/libc/posix.h — THE POSIX FACE, AND IT IS OPT-IN.
 *
 * ===========================================================================
 * WHAT THIS IS, AND WHY IT IS NOT IN oslibc.h
 * ===========================================================================
 *
 * ADR-0031 §9 left one question open by name:
 *
 *     "Whether the libc grows a POSIX face or libdrm gets an oscortex face.
 *      §2.1's four clashing symbols can be resolved either by giving
 *      core/user/libc a `posix_open`-shaped second surface or by keeping the
 *      clash and refusing to link the two together. GAP-0170 states the
 *      problem and takes no position."
 *
 * ADR-0033 §2 takes the position. **THE LIBC GROWS A POSIX FACE, IT IS A
 * SEPARATE TRANSLATION UNIT, AND A PROGRAM OPTS IN BY LINKING IT.** Three
 * properties follow and each one is the reason for the shape of this file:
 *
 *   1. **A NATIVE OSCORTEX PROGRAM NEVER LINKS THIS AND IS UNAFFECTED.** The
 *      refusal-floor discipline -- ADR-0016's, ADR-0019's, and this kernel's
 *      everywhere -- is untouched. `os_open` still returns FILE_ENOTFOUND and
 *      not -1, and nothing in core/kernel/ learned the word `errno`.
 *
 *   2. **A PORT LINKS THIS AND GETS EXACTLY ONE POSIX SURFACE**, in one file,
 *      that a reader can hold in their head. Every `-1` on this operating
 *      system is produced between these braces.
 *
 *   3. **THE TWO CANNOT BE CONFUSED, BECAUSE THE SYMBOLS DIFFER.** oslibc.h
 *      exports `os_open`; this exports `open`. Linking both is fine and
 *      intended -- posix.c is written on top of the os_* calls. Linking
 *      NEITHER, which is what a port did before ADR-0033, is now an undefined
 *      reference instead of a clean link to the wrong function (GAP-0170).
 *
 * ===========================================================================
 * `errno` — THE DECISION, WHICH IS THE HARD HALF
 * ===========================================================================
 *
 * GAP-0113 decided this OS has no `errno`, deliberately, and gave the reason:
 * **"the refusal IS the return value."** That is a good decision. It is also
 * one that `drmIoctl` -- the retry loop at the very centre of the DRM ABI --
 * is written in terms of:
 *
 *     do { ret = ioctl(fd, request, arg); }
 *     while (ret == -1 && (errno == EINTR || errno == EAGAIN));
 *
 * **BOTH ARE KEPT. `errno` EXISTS ONLY HERE.** It is one `int` in this
 * translation unit's `.bss`, reached through `__errno_location()`, written by
 * exactly one function ([posixFail]), and derived from the kernel's refusal
 * value by a single visible mapping ([posix_errno_for]). The kernel does not
 * have one, oslibc.h does not have one, and no os_* call can set one.
 *
 * **AND THE RETRY LOOP IS MADE PROVABLY ONE-SHOT RATHER THAN EMULATED.**
 * This is the part worth reading twice. Nothing on this operating system can
 * return EINTR: there are no signals (there is no signal delivery mechanism at
 * all). Nothing can return EAGAIN: no descriptor is non-blocking, because no
 * syscall here blocks. So [posix_errno_for] maps NO oscortex refusal onto
 * either value, and it never will while those two facts hold -- which means
 * `drmIoctl`'s `while` condition is false on the first evaluation, always, and
 * the loop executes its body exactly once. That is not a workaround; it is the
 * loop doing precisely what it was written to do on a platform where the
 * conditions it retries on cannot arise. **If this OS ever grows signals or
 * non-blocking descriptors, this comment becomes false and GAP-0179 is where
 * that is recorded**, because a retry loop that silently starts spinning is
 * worse than one that never did.
 *
 * ===========================================================================
 * WHAT WAS REJECTED
 * ===========================================================================
 *
 *   A. **MAKE THE KERNEL RETURN -1 AND CARRY AN errno.** Rejected, and
 *      ADR-0031 §4.1 rejects it by name: "this kernel's whole refusal
 *      discipline is that a refusal is a distinct value carrying a reason."
 *      Eleven `ioctl` refusals and fourteen file refusals would collapse to
 *      one number, and every existing harness that reads a specific refusal
 *      out of a transcript would be reading -1.
 *
 *   B. **GIVE oslibc.h A POSIX-SHAPED SECOND SURFACE UNDER SECOND NAMES**
 *      (`posix_open`, `posix_read`). Rejected: it does not solve the problem.
 *      Ported C calls `open`, not `posix_open`, so the clashing symbol would
 *      still be `open` and would still bind to the wrong function. A fix that
 *      requires editing the port is not a fix for a port we compile
 *      unmodified.
 *
 *   C. **KEEP THE CLASH AND REFUSE TO LINK THE TWO TOGETHER.** Rejected as
 *      insufficient rather than wrong. It is half of what ADR-0033 does -- the
 *      symbols now differ, so the bad link is impossible -- but on its own it
 *      leaves the port dead with no path forward and closes GAP-0170 by
 *      abandoning the thing that opened it.
 *
 *   D. **AN `__asm__("os_open")` LABEL ON THE DECLARATION**, keeping the
 *      source spelling and changing the emitted symbol invisibly. Rejected on
 *      this repo's own precedent: M16 named a function `fdwrite` rather than
 *      overloading `write`, because "two functions called `write`
 *      distinguished only by how many arguments they have would be the kind of
 *      thing that compiles and then does the wrong one." An assembler label
 *      that renames a symbol with no trace at the call site is that same
 *      invisibility, pointed at the linker instead of the compiler.
 *
 * ===========================================================================
 * WHAT THIS FILE DOES NOT CLAIM
 * ===========================================================================
 *
 * It is not POSIX. It is the smallest POSIX-SHAPED surface that lets a port
 * compiled against <fcntl.h>/<unistd.h> link and behave correctly on the paths
 * this OS can actually serve. Everything it cannot serve REFUSES LOUDLY --
 * see [POSIX_STUB] below -- and never returns a plausible-looking success.
 * GAP-0180 is the list of what is stubbed.
 */

#ifndef OSLIBC_POSIX_H
#define OSLIBC_POSIX_H

#include "oslibc.h"

/* oslibc.h defines `open`/`read`/`close`/`printf`/`write` as the short spellings of
 * the os_* symbols. THIS FILE IS THE ONE PLACE THAT MUST NOT HAVE THEM: the
 * whole point is to declare and define the POSIX `open`, under that name, as a
 * different function. So the four aliases are undefined here, immediately
 * after the include that created them, and nothing below this line can reach
 * an os_* call by its short spelling. */
#undef open
#undef read
#undef close
#undef printf
#undef write

typedef long ssize_t;
typedef long off_t;

/* --------------------------------------------------------------------------
 * errno. One int, one accessor, and the accessor is the symbol libdrm needs.
 *
 * `__errno_location` is in ADR-0031's missing 43 and design/libdrm-port.md §2
 * tiers it as MUST WORK. It is the glibc spelling and it is what libdrm's
 * <errno.h> shim resolves `errno` to.
 * ----------------------------------------------------------------------- */
int *__errno_location(void);
#define errno (*__errno_location())

/* The errno values this OS can actually produce. There is no <errno.h> here
 * and this is not a copy of one: it is the CLOSED SET that [posix_errno_for]
 * can return, and every value in it is reachable. The numbers are Linux's,
 * because the shim headers a port compiles against are Linux-shaped and a port
 * that compares `errno == ENOENT` must get the number its own header gave it.
 *
 * NOTE WHAT IS ABSENT AND WHY IT IS ABSENT: there is no EINTR and no EAGAIN.
 * Not "not yet" -- they cannot be produced, because this OS has no signals and
 * no non-blocking descriptor. See the `drmIoctl` note in this file's header. */
#define EPERM 1
#define ENOENT 2
#define EIO 5
#define EBADF 9
#define ENOMEM 12
#define EACCES 13
#define EFAULT 14
#define EBUSY 16
#define EEXIST 17
#define ENOTDIR 20
#define EISDIR 21
#define EINVAL 22
#define ENFILE 23
#define EMFILE 24
#define ENOTTY 25
#define EFBIG 27
#define ENOSPC 28
#define EROFS 30
#define ENAMETOOLONG 36
#define ENOSYS 38
#define EOVERFLOW 75

/* The <fcntl.h> flags a port passes. Only the access mode is honoured; see
 * posix.c's `open`. */
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 0100
#define O_TRUNC 01000
#define O_APPEND 02000
#define O_NONBLOCK 04000
#define O_CLOEXEC 02000000

/* Maps one oscortex refusal (at or above FILE_ERR_FLOOR / IOCTL_ERR_FLOOR) to
 * the closest errno. EXPOSED rather than static so that a harness can call it
 * and so that the mapping is testable without booting. Returns EINVAL for a
 * value that is not a refusal at all, which is a caller bug. */
int posix_errno_for(unsigned long refusal);

/* The POSIX-shaped surface. Each returns -1 and sets errno on failure. */
int open(const char *path, int flags, ...);
ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
int close(int fd);
int ioctl(int fd, unsigned long request, ...);
off_t lseek(int fd, off_t off, int whence);

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

/* port.c's formatter, declared here because posix.c's `printf` is built on it
 * and because a port that includes <stdio.h> from the shim gets the same
 * signatures. */
int vsnprintf(char *buf, size_t cap, const char *fmt, __builtin_va_list ap);
int snprintf(char *buf, size_t cap, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int printf(const char *fmt, ...);

/* getpagesize() — tier 1. libdrm's atomic request grows by a page's worth of
 * items at a time, and `drmMap` uses it. core/kernel/vm.dart's `vmPageBytes`. */
int getpagesize(void);

/* strerror() — tier 1, reached from every libdrm diagnostic. Returns a static
 * string; never NULL. */
char *strerror(int e);

/* How many times a POSIX_STUB refused, and which one refused last. Exported so
 * that "nothing on the R0-R3 path called a stub" is a claim a program can
 * CHECK rather than a claim this header makes. */
unsigned long posix_stub_calls(void);
const char *posix_stub_last(void);

#endif /* OSLIBC_POSIX_H */
