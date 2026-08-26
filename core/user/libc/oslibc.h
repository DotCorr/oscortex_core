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
 *   syscalls   sys_call, sys_call3                               (raw)
 *              write(), exit(), yield(), sbrk(), who()            (checked)
 *   files      open(), read(), close(), seek()                    (§ M15, raw)
 *              openmode(), create(), fdwrite()                     (§ M16, raw)
 *              RFILE, rfopen/rfread/rfgets/rfseek/rfclose         (§ rfile.c)
 *   memory     malloc, free                                       (§ malloc.c)
 *   argv       ARGS_MAX_COUNT, ARGS_MAX_BYTES                  (§ M19)
 *              `_start` in start.c calls main(argc, argv) and exits with
 *              what it returns; the kernel builds the SysV initial stack.
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
 * THERE IS STILL NO INPUT. There is no `stdin` and no console-input syscall.
 * M16 ADDED WRITING: a program can create a file, put bytes in it and close it,
 * and the bytes are on the volume after the machine has been switched off and
 * on again. What it cannot do is write at an arbitrary offset, keep what was
 * already in a file it opens, delete one, or rename one — the kernel's
 * GAP-0127 is the accounting.
 *
 * NOTHING HERE MAY ASSUME ANYTHING ABOUT THE KERNEL except the syscall numbers
 * and the refusal values below, which are core/kernel/user.dart's,
 * core/kernel/proc.dart's, core/kernel/heap.dart's and core/kernel/file.dart's.
 * The m13-libc, m15-fileio and m16-filewrite harnesses read every one of them
 * back out of those files and compare.
 */

#ifndef OSLIBC_H
#define OSLIBC_H

/* ---------------------------------------------------------------------------
 * 0. THE SYMBOLS ARE `os_*`. THE SPELLINGS ARE THE SHORT ONES.
 *    This is the fix for GAP-0170 and it is not a convenience alias.
 *    docs/decisions/0033-*.md §2 argues it; this is the mechanism.
 *
 * THE HAZARD IT CLOSES. `libdrm` needs `open`, `read`, `close` and `printf`.
 * This library used to DEFINE all four, under those exact names, with
 * DIFFERENT SIGNATURES AND A DIFFERENT ERROR CONVENTION:
 *
 *   ours: unsigned long open(const char *name)      -- ONE argument, an 8.3
 *         name in a FAT16 ROOT DIRECTORY, refusal at or above FILE_ERR_FLOOR
 *   theirs: int open(const char *path, int flags, ...) -- a PATH, two or three
 *         arguments, -1 on failure with `errno` set
 *
 * `x86_64-elf-ld` resolved all four without a word. THE LINK WAS CLEAN AND THE
 * PROGRAM WOULD HAVE BEEN WRONG -- and the near-miss is what would have made it
 * hard to find: our refusals are 0xFFFFFFFFFFFFFFF9 and friends, which AS AN
 * `int` are small negative numbers, so libdrm's `if (fd < 0)` would appear to
 * work. What would not work is everything after it. A successful open returns
 * 0..3, the O_RDWR argument is silently discarded, and
 * drmOpenDevice("/dev/dri/card0", ...) would try to open a FAT16 file whose
 * name is a path.
 *
 * THE FIX, AND WHY IT IS A `#define` AND NOT A RENAME OF THE SPELLING.
 * The four functions now EXPORT the symbols `os_open`, `os_read`, `os_close`
 * and `os_printf`. The short spellings are preserved for callers by the four
 * `#define`s below, so no program that includes this header changed by one
 * character. The direction is the whole point:
 *
 *   * a program that INCLUDES THIS HEADER gets oscortex's `open`, exactly as
 *     before, at the same source spelling;
 *   * a PORT THAT DOES NOT INCLUDE THIS HEADER -- which is every port, because
 *     ported C includes <fcntl.h> and <unistd.h> -- now gets an UNDEFINED
 *     REFERENCE to `open` and CANNOT LINK.
 *
 * A mismatch that used to link silently is now a link error. That is the
 * entire requirement, and it is checked: tests/conformance/drm-abi/run.sh
 * CHECK 2 requires all four to come out UNDEFINED when libdrm's objects are
 * linked against this library, and fails if any of them ever binds again.
 *
 * WHAT A PORT LINKS INSTEAD: core/user/libc/posix.h and posix.c, a SEPARATE
 * and OPT-IN translation unit that implements the POSIX-shaped surface --
 * `open(path, flags, ...)`, `read`, `close`, `ioctl`, and an `errno` -- on top
 * of the `os_*` calls. It is not part of this header and a native oscortex
 * program never links it. ADR-0033 §2 states what was rejected and why.
 *
 * `write` IS A FIFTH, AND THE COMPILER PROVED IT RATHER THAN A REVIEWER
 * GUESSING IT. GAP-0170 named four. When posix.c tried to define POSIX's
 * `ssize_t write(int, const void *, size_t)`, clang refused it outright --
 * "conflicting types for 'write'", against oscortex's two-argument
 * `unsigned long write(const void *, size_t)` in this header. So the clash was
 * not merely latent, it BLOCKED THE ADAPTER, and `write` is aliased here for
 * the same reason and by the same mechanism as the four. It is `os_write`.
 *
 * TWO MORE NAMES COLLIDE AND ARE DELIBERATELY LEFT ALONE, NAMED RATHER THAN
 * SILENTLY FIXED: `exit` (ours takes unsigned long, POSIX's takes int -- a
 * port's `exit(1)` converts and behaves correctly), and `sbrk` (ours returns
 * NULL where POSIX returns (void *)-1, so a port testing `== (void *)-1`
 * would miss an out-of-memory). Neither is reached by libdrm and neither
 * blocks posix.c, so both are MEASURED in GAP-0178 rather than changed by a
 * unit that was not asked to. That is the boundary this unit drew, and it is
 * drawn where the evidence stops rather than where the work got tiring.
 * ------------------------------------------------------------------------- */
#define open os_open
#define read os_read
#define close os_close
#define printf os_printf
#define write os_write

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

/* M15. core/kernel/file.dart's `fileSys*No`. */
#define SYS_OPEN 5
#define SYS_READ 6
#define SYS_CLOSE 7
#define SYS_SEEK 8

/* M16. `fileSysWriteNo`. It is NOT called SYS_WRITE: syscall 1 has been that
 * since M9 and it prints on the console. See fdwrite() below. */
#define SYS_FDWRITE 9

/* S0 (ADR-0033). `core/kernel/ioctl.dart`'s `ioctlSysNo`.
 *
 * TWELVE, AND ELEVEN IS SKIPPED ON PURPOSE. `fdwait` was named as syscall 11
 * by three separate design documents before `ioctl` existed, so `ioctl` took
 * the next number. docs/syscall-registry.md is the allocator and
 * core/scripts/verify-syscall-registry.sh fails if this line and that table
 * and core/kernel/ioctl.dart ever disagree. */
#define SYS_IOCTL 12

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
 * 1b. M15's and M16's file I/O: the five bounds and the thirteen refusal
 *     values, all of them core/kernel/file.dart's own. `m15-fileio/run.sh` reads every one of
 *     them back out of that file and compares, exactly as m13-libc does for the
 *     eleven numbers above -- a library that disagreed with the kernel about
 *     what a refusal LOOKS LIKE would treat one as a byte count.
 * ------------------------------------------------------------------------- */

/* core/kernel/file.dart's `fileReadMax`: the largest single read() the kernel
 * will perform. NOT a bound on a file -- a program reads a bigger file by
 * calling read() again, because the offset lives in the descriptor. */
#define READ_MAX 512UL

/* `fileMaxFds`: descriptors per program. A fifth open() is FILE_ENOSLOT. */
#define FILE_MAX_FDS 4UL

/* `fileNameMax`: `12345678.123` is twelve characters and there is no thirteenth
 * 8.3 name. */
#define FILE_NAME_MAX 12UL

/* `fileRetFloor`. ONE comparison separates a result from a refusal, exactly as
 * SBRK_ERR_FLOOR does: a byte count, a descriptor number and a file offset are
 * all far below this, and SYS_REFUSED -- what a kernel WITHOUT these syscalls
 * hands back -- is above it, so a program built against an older kernel sees a
 * refusal rather than a length. */
#define FILE_ERR_FLOOR 0xFFFFFFFFFFFFFF00UL

#define FILE_EBADFD 0xFFFFFFFFFFFFFFFEUL    /* no such open descriptor */
#define FILE_EBADPTR 0xFFFFFFFFFFFFFFFDUL   /* buffer not yours, or not writable */
#define FILE_EBADLEN 0xFFFFFFFFFFFFFFFCUL   /* zero, or above READ_MAX/NAME_MAX */
#define FILE_ENOSLOT 0xFFFFFFFFFFFFFFFBUL   /* all FILE_MAX_FDS in use */
#define FILE_EBADNAME 0xFFFFFFFFFFFFFFFAUL  /* not an 8.3 name */
#define FILE_ENOTFOUND 0xFFFFFFFFFFFFFFF9UL /* no such entry in the root dir */
#define FILE_EISDIR 0xFFFFFFFFFFFFFFF8UL    /* it is a subdirectory */
#define FILE_EEMPTY 0xFFFFFFFFFFFFFFF7UL    /* the entry has no clusters */
#define FILE_EIO 0xFFFFFFFFFFFFFFF6UL       /* the volume, chain or drive refused */
#define FILE_EBADSEEK 0xFFFFFFFFFFFFFFF5UL  /* past the end of the file */
#define FILE_ENOOWNER 0xFFFFFFFFFFFFFFF4UL  /* nothing that owns descriptors is running */

/* M16. `fileRetBadMode` and `fileRetNoSpace`. */
#define FILE_EBADMODE 0xFFFFFFFFFFFFFFF3UL  /* wrong mode for this descriptor */
#define FILE_ENOSPACE 0xFFFFFFFFFFFFFFF2UL  /* the volume, or the root dir, is full */

/* GAP-0152. `fileRetReadOnly`. The volume marks the file read-only, so
 * open(name, O_WRITE) is refused AND THE FILE STILL HAS ITS BYTES. Before this
 * existed the same call truncated it. */
#define FILE_EREADONLY 0xFFFFFFFFFFFFFFF1UL /* the file is marked read-only */

/* M16. The two values open()'s mode may take. Anything else is FILE_EBADMODE.
 * `core/kernel/file.dart`'s `fileOpenRead` and `fileOpenWrite`.
 *
 * O_WRITE IS CREATE + TRUNCATE + APPEND-ONLY, all three, and there is no way to
 * ask for fewer: the file is made to exist and made empty by open() itself, and
 * the descriptor's offset only ever moves forward. There is no O_APPEND that
 * keeps what a file already had, no O_EXCL, no O_RDWR and no mode bits — see
 * the kernel's GAP-0127 for the whole list. */
#define O_READ 0UL
#define O_WRITE 1UL

/* `fileWriteMax`: the largest single fdwrite() the kernel will perform. */
#define WRITE_FILE_MAX 512UL

/* ---------------------------------------------------------------------------
 * 1c. S0 — `ioctl`, and the eleven refusals core/kernel/ioctl.dart can give.
 *
 *     THE REFUSALS OCCUPY A BAND OF THEIR OWN, 0xE0..0xEF, BELOW file.dart's
 *     0xF1..0xFE. That is ADR-0031 §4.3 rule 7 made mechanical: an `ioctl`
 *     refusal and a file refusal can never be the same number, so a program
 *     cannot mistake IOCTL_EBADFD for FILE_EBADFD and `ioctl` on a FAT16 file
 *     is a DISTINCT answer rather than a reused one. The floor is the same
 *     floor -- one comparison still separates a result from a refusal.
 *
 *     `tests/conformance/drm-abi/run.sh` reads every one of these back out of
 *     core/kernel/ioctl.dart and compares, exactly as m15-fileio does for
 *     file.dart's fourteen.
 * ------------------------------------------------------------------------- */

/* `ioctlRetFloor`. Same value as FILE_ERR_FLOOR and the same discipline. */
#define IOCTL_ERR_FLOOR 0xFFFFFFFFFFFFFF00UL

#define IOCTL_EBADFD 0xFFFFFFFFFFFFFFEFUL   /* no such open descriptor */
#define IOCTL_ENOTDEV 0xFFFFFFFFFFFFFFEEUL  /* it is a FAT16 file, not a device
                                             * -- ENOTTY's equivalent */
#define IOCTL_EBADTYPE 0xFFFFFFFFFFFFFFEDUL /* _IOC_TYPE is not one we serve */
#define IOCTL_EBADSIZE 0xFFFFFFFFFFFFFFECUL /* _IOC_SIZE is zero, or above
                                             * IOCTL_MAX_PAYLOAD. REFUSED,
                                             * never truncated */
#define IOCTL_EBADDIR 0xFFFFFFFFFFFFFFEBUL  /* _IOC_DIR is not the direction
                                             * this request is served with */
#define IOCTL_EBADPTR 0xFFFFFFFFFFFFFFEAUL  /* argp is not yours, or not
                                             * writable when the kernel is
                                             * about to write it */
#define IOCTL_EBADNR 0xFFFFFFFFFFFFFFE9UL   /* no descriptor for (type, nr) */
#define IOCTL_ESIZESKEW 0xFFFFFFFFFFFFFFE8UL /* the request IS served and the
                                              * size is not one this kernel
                                              * accepts for it -- the two sides
                                              * disagree about the struct.
                                              * REFUSED, never zero-extended */
#define IOCTL_ENOOWNER 0xFFFFFFFFFFFFFFE7UL /* nothing that owns descriptors is
                                             * running */
#define IOCTL_ENODEV 0xFFFFFFFFFFFFFFE6UL   /* the descriptor names no device */

/* `ioctlMaxPayload` and `ioctlEncMaxSize`. The first is the bound that DOES
 * the work; the second is the `_IOC` encoding's own 14-bit ceiling, which this
 * kernel records and reports and deliberately does NOT rely on. The measured
 * largest DRM payload across all 121 requests is 248 bytes. */
#define IOCTL_MAX_PAYLOAD 256UL
#define IOCTL_ENC_MAX_SIZE 16383UL

/* Issues [request] against [fd] with the payload at [argp]. Returns 0, or one
 * of the eleven refusals above.
 *
 * IT IS NOT CALLED ioctl() AND THE NAME IS THE INTERFACE -- fdwrite()'s
 * argument (§3b-M16) applied to the case that made it urgent. POSIX's
 * `ioctl` returns -1 and sets errno; this returns the kernel's refusal
 * unchanged, because a wrapper that collapsed eleven distinct refusals to -1
 * would be throwing away the only diagnostic there is. A port that needs the
 * POSIX face links posix.c, which builds it here rather than in the kernel --
 * ADR-0031 §4.1 forbids the kernel returning -1 by name.
 *
 * [argp] may be NULL only for a request whose _IOC_DIR is _IOC_NONE. */
unsigned long os_ioctl(unsigned long fd, unsigned long request, void *argp);

/* ---------------------------------------------------------------------------
 * 2. Raw syscalls. `int $0x80`, number in RAX, arguments in RDI and RSI.
 * ------------------------------------------------------------------------- */
unsigned long sys_call(unsigned long n, unsigned long a, unsigned long b);

/* Three arguments, for `read`. THE ONLY `int $0x80` IN THE LIBRARY IS IN HERE
 * and `sys_call` is a C call to it with a zero third argument -- m13-libc
 * requires exactly one of that instruction in the whole library and M15 did not
 * get to add a second. */
unsigned long sys_call3(unsigned long n, unsigned long a, unsigned long b,
                        unsigned long c);

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
 * 3b. M15 — RAW FILE I/O. Four calls, no buffering, no struct. Every one of
 *     them returns a value that is either a result or, at or above
 *     FILE_ERR_FLOOR, one of the eleven refusals. There is no errno (GAP-0113
 *     said why and that has not changed): the refusal IS the return value.
 *
 *     M16 ADDED A WRITE PATH AND IT IS NARROW ON PURPOSE. open() grew a mode,
 *     fdwrite() appends, close() flushes the directory entry, and that is all:
 *     no writing at an offset, no unlink, no rename, no mkdir. GAP-0127 is the
 *     accounting and GAP-0122 is what M15 left, narrowed item by item.
 * ------------------------------------------------------------------------- */

/* Opens [name] -- an 8.3 name in the volume's ROOT DIRECTORY, at most
 * FILE_NAME_MAX characters, no path and no directory component. Returns a
 * descriptor 0..FILE_MAX_FDS-1, or a refusal.
 *
 * The name is NOT case-folded here; the kernel upper-cases it, because a FAT
 * directory stores upper case. `data.bin` and `DATA.BIN` open the same file. */
unsigned long open(const char *name);

/* Reads at most [len] bytes into [buf] from the descriptor's current offset,
 * and ADVANCES that offset by however many it delivered.
 *
 * RETURNS FEWER THAN [len] AT THE END OF THE FILE, AND 0 WHEN THERE IS NOTHING
 * LEFT. A caller that assumes it got [len] bytes back is wrong on the last
 * read of every file whose size is not a multiple of [len] -- which is most of
 * them -- and m15-fileio builds a program that makes exactly that mistake, on
 * purpose, as its negative control.
 *
 * [len] above READ_MAX is FILE_EBADLEN and is NOT split into several reads:
 * the library does not loop where the kernel refused, for `write`'s reason. */
unsigned long read(unsigned long fd, void *buf, size_t len);

/* Closes [fd]. Returns 0, or FILE_EBADFD -- including for a second close of the
 * same descriptor, which is a bug in the caller and is reported as one. */
unsigned long close(unsigned long fd);

/* Sets the descriptor's offset to [off] ABSOLUTELY and returns it. There is no
 * `whence`: SEEK_CUR is the offset the descriptor already keeps and SEEK_END
 * needs a size this interface cannot ask for (GAP-0122 item 4). An [off] past
 * the end of the file is FILE_EBADSEEK; exactly AT the end is legal and is
 * where a program that has read everything already is. */
unsigned long seek(unsigned long fd, unsigned long off);

/* ---------------------------------------------------------------------------
 * 3b-M16 — WRITING. Three calls, and the third one is the milestone.
 * ------------------------------------------------------------------------- */

/* Opens [name] with an explicit mode. open() and create() are the two ways to
 * spell it and this is the one that shows the argument. */
unsigned long openmode(const char *name, unsigned long mode);

/* Creates [name] in the root directory, or empties it if it is already there,
 * and returns a descriptor open for writing. Equivalent to
 * openmode(name, O_WRITE).
 *
 * WHEN THIS RETURNS, THE VOLUME HAS ALREADY CHANGED: the directory entry
 * exists and the file is zero bytes long. A program that creates a file and
 * writes nothing to it leaves a real, legal, zero-length file behind. */
unsigned long create(const char *name);

/* Writes at most [len] bytes from [buf] at the descriptor's current offset and
 * advances it. [fd] must have been opened with O_WRITE.
 *
 * IT IS NOT CALLED write() AND THE NAME IS THE INTERFACE. write() has printed
 * on the console since M13 and takes no descriptor; this takes one and puts
 * bytes on a disk. Two functions called `write` distinguished only by how many
 * arguments they have would be the kind of thing that compiles and then does
 * the wrong one.
 *
 * RETURNS FEWER THAN [len] WHEN THE VOLUME FILLS UP, and the bytes it reports
 * are really on the drive. Calling again then returns FILE_ENOSPACE. A caller
 * that assumes it got [len] back is wrong exactly when the disk is full, and
 * m16-filewrite builds a program that makes that mistake on purpose as its
 * negative control.
 *
 * [len] above WRITE_FILE_MAX is FILE_EBADLEN and is NOT split into several
 * writes: the library does not loop where the kernel refused. */
unsigned long fdwrite(unsigned long fd, const void *buf, size_t len);

/* ---------------------------------------------------------------------------
 * 3c. M15 — RFILE: a BUFFERED read-only file.
 *
 *     IT IS NOT CALLED `FILE` AND THAT IS DELIBERATE. C's `FILE` reads and
 *     writes, has three of itself open before `main` runs, carries an error and
 *     an EOF flag that `ferror`/`feof` report separately, flushes, and can be
 *     re-pointed with `freopen`. This does exactly one of those things. Calling
 *     it `FILE` and its opener `fopen` would make ordinary C compile against it
 *     and then behave differently, which is the failure mode ADR-0017 §5 built
 *     the loud `%!` marker to avoid. `RFILE` is a read-only file, `rfopen`
 *     opens one, and nothing about the name suggests more than there is.
 *
 *     THE BUFFERING IS REAL AND IS THE POINT: one RFILE_BUFSZ-byte buffer per
 *     open file, filled by one read() syscall, drained by rfgets() a line at a
 *     time and by rfread() a request at a time. A 20 KiB file read by rfgets()
 *     costs 40 syscalls rather than one per line.
 *
 *     THERE IS NO malloc HERE, on purpose: `sbrk` is refused unless a PROCESS is
 *     live (core/kernel/user.dart) and `run <name>` -- the command that loads a
 *     program off the filesystem -- does not create one. So the RFILEs are a
 *     fixed array in .bss, RFILE_MAX of them, and rfopen() returns NULL when
 *     they are all taken.
 * ------------------------------------------------------------------------- */
#define RFILE_BUFSZ 512
#define RFILE_MAX 2

typedef struct RFILE {
  unsigned long fd;   /* the kernel descriptor */
  unsigned long base; /* file offset of buf[0] */
  unsigned long n;    /* valid bytes in buf */
  unsigned long i;    /* next byte of buf to hand out */
  unsigned long used; /* 1 while this slot is an open file */
  unsigned long eof;  /* 1 once a read() has returned 0 */
  unsigned char buf[RFILE_BUFSZ];
} RFILE;

/* Opens [name] buffered. NULL if open() refused or all RFILE_MAX slots are
 * taken; rf_last_error() then carries the kernel's own refusal value, or 0 when
 * the slots were the problem. */
RFILE *rfopen(const char *name);

/* Copies up to [n] bytes into [dst] out of the buffer, refilling as needed.
 * Returns how many -- fewer than [n] only at end of file. */
size_t rfread(void *dst, size_t n, RFILE *f);

/* Reads up to [n]-1 bytes or one line, whichever is shorter, NUL-terminates,
 * and KEEPS the newline exactly as C's fgets does. NULL at end of file with
 * nothing read. */
char *rfgets(char *dst, size_t n, RFILE *f);

/* The absolute offset the next byte will come from. */
unsigned long rftell(RFILE *f);

/* Sets the absolute offset and DISCARDS the buffer. Returns the offset, or the
 * kernel's refusal. */
unsigned long rfseek(RFILE *f, unsigned long off);

/* 1 once a read has come back empty. */
int rfeof(RFILE *f);

/* Closes and releases the slot. Returns 0, or the kernel's refusal. */
unsigned long rfclose(RFILE *f);

/* The raw refusal value of the last rfopen/rfseek/rfclose that failed. Same
 * argument as sbrk_last_error(): eleven distinct refusals collapsed to NULL
 * would be eleven diagnostics thrown away. */
unsigned long rf_last_error(void);

/* ---------------------------------------------------------------------------
 * 3d. M19 — argc, argv, and the two bounds the kernel enforces on them.
 *
 *     A program does not have to know these to run: `main(argc, argv)` is
 *     handed whatever the kernel built. They are here so that a program CAN
 *     know them -- so that a `wc` given nine file names can say "this shell
 *     passes at most eight" instead of being refused by the shell with no way
 *     to have predicted it. core/kernel/args.dart's `argsMaxCount` and
 *     `argsMaxBytes`, read back out of that file by m19-argv/derive.py.
 *
 *     THERE IS NO envp AND NO getenv. The kernel puts a NULL where `envp[0]`
 *     goes and there is no environment on this operating system at all --
 *     docs/known-gaps.md GAP-0146. `main` takes two parameters here; a third
 *     one would be a pointer to a vector of length zero.
 * ------------------------------------------------------------------------- */

/* The most arguments one command line may carry, argv[0] INCLUDED. A ninth is
 * refused by the shell, before the program is loaded. */
#define ARGS_MAX_COUNT 8

/* The most argument TEXT one command line may carry, in bytes, INCLUDING one
 * NUL terminator per argument. */
#define ARGS_MAX_BYTES 128

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

/* S0 (ADR-0033). The USABLE payload of a live block -- what `realloc` must
 * know to copy the old contents without reading past the end of the old
 * allocation. May be more than was asked for, because the allocator rounds up
 * to `mallocAlign` and only splits when the remainder is at least
 * `mallocMinSplit`. Reading it is the ONLY way port.c's realloc learns
 * anything about a block, which is what keeps malloc.c's header layout
 * private to malloc.c. */
size_t malloc_usable(void *p);
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
