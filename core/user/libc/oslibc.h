/* core/user/libc/oslibc.h — the whole public surface of oscortex's C library.
 *
 * WHAT THIS IS, AND WHAT IT IS NOT
 * ---------------------------------------------------------------------------
 * This is not a port of anything. It is the smallest set of C functions that
 * makes ordinary-looking C source compilable for this operating system, written
 * against the five syscalls this kernel actually has. Everything it offers is
 * listed in this file; there is no second header and nothing is hidden behind a
 * feature macro.
 *
 *   syscalls   sys_exit, sys_write, sys_who, sys_yield, sys_sbrk  (raw)
 *              write(), exit(), yield(), sbrk()                   (checked)
 *   memory     malloc, free                                       (§ malloc.c)
 *   strings    memcpy, memset, strlen, strcmp, strcpy
 *   output     printf, with EXACTLY five conversions
 *
 * THE FIVE CONVERSIONS ARE %s %d %x %c %%, AND THERE IS NO SIXTH.
 * Anything else after a `%` -- a width, a flag, a length modifier, `%f`, `%p`,
 * `%u`, `%ld`, or a `%` at the very end of the format -- emits the two
 * characters `%!` and the offending character is consumed. It is deliberately
 * LOUD: a printf that silently drops what it does not understand turns a
 * missing feature into wrong output, and wrong output in a serial capture is
 * what a golden file enshrines. See ADR-0017 §5.
 *
 * ONE printf CALL IS ONE write IS ONE LINE ON THE CONSOLE.
 * There are no file descriptors, no buffering and no `\n` convention here.
 * `userSysWrite` prints `USER WRITE `, the bytes, and a newline of its own, and
 * `elfOwns` REFUSES a length above `userWriteMax` (128) -- so a formatted string
 * longer than [PRINTF_MAX] is not a thing this OS can print, and printf reports
 * that rather than truncating quietly. See §4 below.
 *
 * NOTHING HERE MAY ASSUME ANYTHING ABOUT THE KERNEL except the five syscall
 * numbers and the refusal values below, which are core/kernel/user.dart's,
 * core/kernel/proc.dart's and core/kernel/heap.dart's. The m13-libc harness
 * reads every one of them back out of those files and compares.
 */

#ifndef OSLIBC_H
#define OSLIBC_H

typedef unsigned long size_t;
typedef unsigned long uintptr_t;

#ifndef NULL
#define NULL ((void *)0)
#endif

/* ---------------------------------------------------------------------------
 * 1. The syscall numbers. core/kernel/user.dart's `userSys*No`, core/kernel/
 *    proc.dart's `procSysYieldNo` and core/kernel/heap.dart's `heapSysSbrkNo`.
 * ------------------------------------------------------------------------- */
#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_WHO 2
#define SYS_YIELD 3
#define SYS_SBRK 4

/* core/kernel/user.dart's `userRefused`: what a refused syscall returns. */
#define SYS_REFUSED 0xFFFFFFFFFFFFFFFFUL

/* core/kernel/heap.dart's `heapRet*`. Anything at or above SBRK_ERR_FLOOR is a
 * refusal rather than an address -- one comparison, which is the whole reason
 * ADR-0016 chose a floor instead of a signed -1. */
#define SBRK_ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define SBRK_ENOMEM 0xFFFFFFFFFFFFFFFCUL
#define SBRK_ENOSPACE 0xFFFFFFFFFFFFFFFDUL
#define SBRK_EBADARG 0xFFFFFFFFFFFFFFFEUL

/* core/kernel/user.dart's `userWriteMax`. The kernel's pointer validator
 * refuses a longer write, so this is a property of the OS and not a taste. */
#define WRITE_MAX 128UL

/* The largest string one printf can produce. Below WRITE_MAX so the trailing
 * overflow marker still fits inside one legal write. */
#define PRINTF_MAX 120UL

/* ---------------------------------------------------------------------------
 * 2. Raw syscalls. `int $0x80`, number in RAX, arguments in RDI and RSI.
 * ------------------------------------------------------------------------- */
unsigned long sys_call(unsigned long n, unsigned long a, unsigned long b);

/* ---------------------------------------------------------------------------
 * 3. The checked wrappers.
 * ------------------------------------------------------------------------- */

/* Writes [len] bytes at [buf]. Returns the number of bytes the kernel says it
 * wrote, or SYS_REFUSED. Does NOT loop: a length above WRITE_MAX is refused by
 * the kernel and this returns that refusal unchanged. */
unsigned long write(const void *buf, size_t len);

/* Never returns. */
void exit(unsigned long status);

/* Runs the other process, if there is one. */
void yield(void);

/* Moves the program break by [inc] bytes and returns the OLD break, or NULL on
 * any of heap.dart's three refusals. The raw refusal value of the last call is
 * available through sbrk_last_error(). */
void *sbrk(size_t inc);
unsigned long sbrk_last_error(void);

/* Which process am I? Prints a line from the kernel; returns the slot. */
unsigned long who(void);

/* ---------------------------------------------------------------------------
 * 4. printf. Returns the number of bytes written, or -1 if the formatted string
 *    did not fit in PRINTF_MAX -- in which case the output ends in the marker
 *    `%!OVF` and IS still printed, so the failure is visible on the console
 *    rather than only in a return value nobody checks.
 * ------------------------------------------------------------------------- */
int printf(const char *fmt, ...);

/* ---------------------------------------------------------------------------
 * 5. Strings. memcpy and memset are here because clang -O2 EMITS CALLS TO THEM
 *    from ordinary C -- a struct assignment, an array initialiser -- so a
 *    freestanding program that does not define them does not link. That is
 *    measured by the harness, not assumed: it requires a `call <memcpy>` that
 *    the compiler put there to exist in the disassembly of the test program.
 * ------------------------------------------------------------------------- */
void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
char *strcpy(char *dst, const char *src);

/* ---------------------------------------------------------------------------
 * 6. malloc/free. A FIRST-FIT FREE LIST over sbrk, with splitting and with
 *    coalescing of adjacent free blocks. It reuses memory: freeing a block and
 *    asking for one that fits gives the same address back, and that is asserted
 *    by the test program at runtime rather than described here. ADR-0017 §6.
 *
 *    malloc(0) returns NULL. free(NULL) does nothing. There is no realloc and
 *    no calloc.
 * ------------------------------------------------------------------------- */
void *malloc(size_t n);
void free(void *p);

/* Bookkeeping the test program and the harness read. Not part of any standard;
 * exported because a claim about an allocator that cannot be counted is not a
 * claim. */
unsigned long malloc_bytes_from_kernel(void); /* total sbrk'd, in bytes */
unsigned long malloc_free_blocks(void);       /* blocks on the free list now */

/* Read out of the ELF by derive.py, so the harness's arithmetic about where
 * blocks land comes from the binary rather than from a number typed twice. */
extern volatile const unsigned long mallocHdrBytes;
extern volatile const unsigned long mallocAlign;
extern volatile const unsigned long mallocMinSplit;
extern volatile const unsigned long printfMax;
extern volatile const unsigned long libcWriteMax;

/* 1 in a normal build; 0 in the NEGATIVE-CONTROL build, in which free() returns
 * immediately and every reuse assertion in the test program must fail. It is a
 * `volatile const` word rather than a `#ifdef` so that both builds have
 * byte-identical segment geometry -- m12-heap/build-progs.sh's reason, kept. */
extern volatile const unsigned long libcFreeEnabled;

#endif /* OSLIBC_H */
