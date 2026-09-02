/* core/user/libc/posix.c — the POSIX face. See posix.h for the decision and
 * for what was rejected; this file is the implementation and nothing more.
 *
 * **EVERY `-1` ON THIS OPERATING SYSTEM IS PRODUCED IN THIS FILE.** That is
 * the property posix.h's separation exists to give, and it is worth being able
 * to check mechanically: `grep -c 'return -1' core/user/libc/` (all .c) is nonzero
 * only here.
 */

#include "posix.h"

#include <stdarg.h>

/* --------------------------------------------------------------------------
 * errno.
 * ----------------------------------------------------------------------- */

/* THE ONE `errno` ON THIS OPERATING SYSTEM. Not extern, not in a header, and
 * not reachable except through the accessor below. */
static int posixErrno;

int *__errno_location(void) { return &posixErrno; }

/* --------------------------------------------------------------------------
 * The mapping, which is the whole of the translation and is deliberately one
 * visible function rather than a `default:` scattered through five call sites.
 *
 * IT IS A CHAIN OF `if`s AND NOT A SWITCH, for the reason the kernel's
 * equivalents are (GAP-0088 in the kernel, taste here): a reader checking
 * whether a refusal is covered can read it top to bottom, and an uncovered
 * refusal falls out of the bottom as EIO rather than as a value nobody chose.
 *
 * **NOTHING HERE RETURNS EINTR OR EAGAIN.** posix.h's header explains why that
 * is a property of the platform rather than an omission, and why `drmIoctl`'s
 * retry loop is therefore provably one-shot.
 * ----------------------------------------------------------------------- */
int posix_errno_for(unsigned long r) {
  if (r < FILE_ERR_FLOOR) {
    /* Not a refusal at all. A caller that got here has already mistaken a
     * result for an error, so the honest answer is "your argument was
     * wrong", not a guess about a file. */
    return EINVAL;
  }

  /* core/kernel/ioctl.dart's eleven, 0xE0..0xEF. Checked FIRST because they
   * are numerically lower than file.dart's and a `>=` chain written the other
   * way round would swallow them. */
  if (r == IOCTL_EBADFD) return EBADF;
  if (r == IOCTL_ENOTDEV) return ENOTTY;
  if (r == IOCTL_EBADTYPE) return ENOTTY;
  if (r == IOCTL_EBADSIZE) return EINVAL;
  if (r == IOCTL_EBADDIR) return EINVAL;
  if (r == IOCTL_EBADPTR) return EFAULT;
  if (r == IOCTL_EBADNR) return ENOTTY;
  /* A struct-size disagreement between the two sides of the ABI. EINVAL is
   * what Linux gives for an unrecognised request size and it is what libdrm
   * expects to see when it asks for a uAPI its kernel does not have. */
  if (r == IOCTL_ESIZESKEW) return EINVAL;
  if (r == IOCTL_ENOOWNER) return EBADF;
  if (r == IOCTL_ENODEV) return ENOTTY;

  /* core/kernel/file.dart's fourteen, 0xF1..0xFE. */
  if (r == FILE_EBADFD) return EBADF;
  if (r == FILE_EBADPTR) return EFAULT;
  if (r == FILE_EBADLEN) return EINVAL;
  if (r == FILE_ENOSLOT) return EMFILE;
  if (r == FILE_EBADNAME) return ENAMETOOLONG;
  if (r == FILE_ENOTFOUND) return ENOENT;
  if (r == FILE_EISDIR) return EISDIR;
  if (r == FILE_EEMPTY) return ENOENT;
  if (r == FILE_EIO) return EIO;
  if (r == FILE_EBADSEEK) return EINVAL;
  if (r == FILE_ENOOWNER) return EBADF;
  if (r == FILE_EBADMODE) return EINVAL;
  if (r == FILE_ENOSPACE) return ENOSPC;
  if (r == FILE_EREADONLY) return EROFS;

  /* SYS_REFUSED -- what a kernel WITHOUT the syscall hands back. A program
   * built against a newer libc than its kernel lands here, and ENOSYS is
   * exactly what that means. */
  if (r == SYS_REFUSED) return ENOSYS;

  return EIO;
}

/* Sets errno from an oscortex refusal and returns -1. The one place a `-1`
 * and an errno are produced together. */
static int posixFail(unsigned long refusal) {
  posixErrno = posix_errno_for(refusal);
  return -1;
}

/* --------------------------------------------------------------------------
 * The loud stubs.
 *
 * design/libdrm-port.md §2 tiers twenty of the missing symbols as MUST LINK
 * and says they "may abort". They do not abort here -- aborting takes the
 * whole program down and this OS has no way to say why -- but they must
 * **NEVER RETURN A PLAUSIBLE-LOOKING SUCCESS**, which is the actual
 * requirement and the one a lazy stub gets wrong.
 *
 * So a stub does three things, in this order: it COUNTS itself, it RECORDS ITS
 * OWN NAME, and it returns the failure its caller's contract defines with an
 * errno of ENOSYS. The counter and the name are exported (`posix_stub_calls`,
 * `posix_stub_last`) so that "nothing on the R0-R3 path called a stub" is
 * something a test program can ASSERT rather than something this file claims.
 * A stub that returned 0 for success would be indistinguishable from a working
 * implementation until something downstream used the result.
 * ----------------------------------------------------------------------- */

static unsigned long posixStubCalls;
static const char *posixStubLast = "";

unsigned long posix_stub_calls(void) { return posixStubCalls; }
const char *posix_stub_last(void) { return posixStubLast; }

/* Records one refusal by a stub and sets errno. Returns -1 so that a stub can
 * be one line. */
static int posixStub(const char *who) {
  posixStubCalls = posixStubCalls + 1;
  posixStubLast = who;
  posixErrno = ENOSYS;
  return -1;
}

/* --------------------------------------------------------------------------
 * open/read/write/close/lseek.
 * ----------------------------------------------------------------------- */

/* POSIX `open`. TWO OR THREE ARGUMENTS, a path, and -1 on failure -- which is
 * the signature GAP-0170 is about, and it is now a DIFFERENT SYMBOL from
 * oscortex's one-argument `os_open`.
 *
 * **THE ACCESS MODE IS HONOURED AND EVERY OTHER FLAG IS DELIBERATELY IGNORED,
 * WHICH IS ONLY SAFE BECAUSE OF WHICH ONES THEY ARE.** Stated rather than
 * assumed:
 *
 *   O_RDONLY  -> O_READ. Exact.
 *   O_WRONLY  -> O_WRITE. Exact, given that O_WRITE here means create +
 *                truncate + append-only (ADR-0020 §0) -- see the note below.
 *   O_RDWR    -> O_READ **for a device**, and REFUSED with EINVAL for a file.
 *                libdrm opens `/dev/dri/card0` with O_RDWR|O_CLOEXEC and every
 *                byte it then moves goes through `ioctl`, not through `read`
 *                or `write`. So O_RDWR on a device is honest: the descriptor
 *                really can be both read and written, through the only
 *                interface a device has. O_RDWR on a FAT16 FILE is NOT
 *                serveable -- GAP-0127 item 2 says there is no read-write mode
 *                -- and is refused rather than silently downgraded to one
 *                direction, because a program that asked to write and got a
 *                read-only descriptor finds out at the first write.
 *   O_CLOEXEC -> ignored, correctly: there is no exec on this OS, so there is
 *                no descriptor to leak across one. GAP-0181.
 *   O_NONBLOCK-> ignored, correctly: nothing here blocks.
 *   O_CREAT/O_TRUNC/O_APPEND -> subsumed. O_WRITE already means all three, so
 *                a caller asking for them gets them and a caller NOT asking
 *                for them gets them anyway -- which is a real difference from
 *                POSIX and is GAP-0127's, not this file's. Recorded again in
 *                GAP-0180 so a port author reads it here.
 */
int open(const char *path, int flags, ...) {
  unsigned long mode;
  unsigned long r;
  int acc = flags & 3;

  if (acc == O_RDONLY) {
    mode = O_READ;
  } else if (acc == O_WRONLY) {
    mode = O_WRITE;
  } else if (acc == O_RDWR) {
    /* Try it as a device first: a device is opened O_READ and `ioctl` is the
     * write path. If the name is not a device the kernel says ENOTFOUND, and
     * a FAT16 file genuinely cannot be opened read-write here. */
    mode = O_READ;
  } else {
    posixErrno = EINVAL;
    return -1;
  }

  r = openmode(path, mode);
  if (r >= FILE_ERR_FLOOR) {
    return posixFail(r);
  }
  return (int)r;
}

ssize_t read(int fd, void *buf, size_t n) {
  unsigned long r;
  if (fd < 0) {
    posixErrno = EBADF;
    return -1;
  }
  /* READ_MAX is 512 and the kernel REFUSES a longer read rather than
   * shortening it. POSIX `read` is allowed to return fewer bytes than asked
   * for, so this clamps rather than refusing -- which is the one place in this
   * file where a POSIX contract is MORE permissive than oscortex's and the
   * adapter is allowed to bridge it. A short read is a legal POSIX answer; a
   * refusal would not have been. */
  if (n > READ_MAX) {
    n = READ_MAX;
  }
  if (n == 0) {
    return 0;
  }
  r = os_read((unsigned long)fd, buf, n);
  if (r >= FILE_ERR_FLOOR) {
    return posixFail(r);
  }
  return (ssize_t)r;
}

ssize_t write(int fd, const void *buf, size_t n) {
  unsigned long r;
  if (fd < 0) {
    posixErrno = EBADF;
    return -1;
  }
  if (n > WRITE_FILE_MAX) {
    n = WRITE_FILE_MAX;
  }
  if (n == 0) {
    return 0;
  }
  r = fdwrite((unsigned long)fd, buf, n);
  if (r >= FILE_ERR_FLOOR) {
    return posixFail(r);
  }
  return (ssize_t)r;
}

int close(int fd) {
  unsigned long r;
  if (fd < 0) {
    posixErrno = EBADF;
    return -1;
  }
  r = os_close((unsigned long)fd);
  if (r >= FILE_ERR_FLOOR) {
    return posixFail(r);
  }
  return 0;
}

/* POSIX `ioctl`. **THE FUNCTION THIS WHOLE UNIT EXISTS TO MAKE CALLABLE.**
 *
 * Variadic, because that is how <sys/ioctl.h> declares it and how libdrm calls
 * it. The third argument is fetched only when there is one to fetch -- a
 * request whose _IOC_DIR is _IOC_NONE legitimately has none, and four of the
 * 121 DRM requests are exactly that. Reading a va_arg that the caller did not
 * pass is undefined behaviour, so the direction is decoded HERE, in userland,
 * from the request word, before va_arg is touched.
 *
 * The decode below is a SECOND reading of the same encoding the kernel reads,
 * and that is worth naming because it is normally a smell. It is not a second
 * IMPLEMENTATION of the ABI: the kernel does not trust this one for anything.
 * All this decides is whether to call va_arg, and if it decided wrongly the
 * kernel would refuse the resulting pointer rather than act on it. */
int ioctl(int fd, unsigned long request, ...) {
  va_list ap;
  void *argp = 0;
  unsigned long r;
  unsigned long dir = (request >> 30) & 3;

  if (fd < 0) {
    posixErrno = EBADF;
    return -1;
  }
  if (dir != 0) {
    va_start(ap, request);
    argp = va_arg(ap, void *);
    va_end(ap);
  }
  r = os_ioctl((unsigned long)fd, request, argp);
  if (r >= IOCTL_ERR_FLOOR) {
    return posixFail(r);
  }
  return (int)r;
}

/* POSIX `lseek`. SEEK_SET only, and the other two are REFUSED rather than
 * approximated: `seek` on this OS is absolute (GAP-0122 item 4), SEEK_CUR
 * needs an offset this interface cannot read back and SEEK_END needs a size it
 * cannot ask for. Returning a wrong offset for either would be worse than
 * EINVAL, because a caller checks lseek's return and would believe it. */
off_t lseek(int fd, off_t off, int whence) {
  unsigned long r;
  if (fd < 0) {
    posixErrno = EBADF;
    return -1;
  }
  if (whence != SEEK_SET) {
    posixErrno = EINVAL;
    return -1;
  }
  if (off < 0) {
    posixErrno = EINVAL;
    return -1;
  }
  r = seek((unsigned long)fd, (unsigned long)off);
  if (r >= FILE_ERR_FLOOR) {
    return posixFail(r);
  }
  return (off_t)r;
}

/* --------------------------------------------------------------------------
 * Tier 1, the ones that are one line here rather than in a file of their own.
 * ----------------------------------------------------------------------- */

/* core/kernel/vm.dart's `vmPageBytes`. Not a guess and not 4096 typed twice:
 * tests/conformance/drm-abi/run.sh reads that constant out of vm.dart and
 * requires it to equal what this returns. */
int getpagesize(void) { return 4096; }

/* strerror. Reached from every libdrm diagnostic (`drmError`, `drmGetVersion`,
 * `drmWaitVBlank`).
 *
 * **IT NAMES THE errno, NOT THE REFUSAL, AND THAT LOSES INFORMATION ON
 * PURPOSE.** By the time a value reaches here the eleven ioctl refusals have
 * already been folded into five errnos by [posix_errno_for]. A `strerror` that
 * tried to un-fold them would be inventing a mapping that does not exist. A
 * program that wants the real refusal calls the os_* surface and reads it. */
char *strerror(int e) {
  if (e == EPERM) return "operation not permitted";
  if (e == ENOENT) return "no such file or directory";
  if (e == EIO) return "input/output error";
  if (e == EBADF) return "bad file descriptor";
  if (e == ENOMEM) return "cannot allocate memory";
  if (e == EACCES) return "permission denied";
  if (e == EFAULT) return "bad address";
  if (e == EBUSY) return "device or resource busy";
  if (e == EEXIST) return "file exists";
  if (e == ENOTDIR) return "not a directory";
  if (e == EISDIR) return "is a directory";
  if (e == EINVAL) return "invalid argument";
  if (e == ENFILE) return "too many open files in system";
  if (e == EMFILE) return "too many open files";
  if (e == ENOTTY) return "inappropriate ioctl for device";
  if (e == EFBIG) return "file too large";
  if (e == ENOSPC) return "no space left on device";
  if (e == EROFS) return "read-only file system";
  if (e == ENAMETOOLONG) return "file name too long";
  if (e == ENOSYS) return "function not implemented";
  if (e == EOVERFLOW) return "value too large for defined data type";
  return "unknown error";
}

/* --------------------------------------------------------------------------
 * TIER 2 — MUST LINK, NEVER REACHED ON A RENDER OR KMS PATH, AND EVERY ONE OF
 * THEM REFUSES LOUDLY.
 *
 * design/libdrm-port.md §2's twenty. They are here rather than spread across
 * five files so that the whole set of things this OS cannot do is one screen,
 * and so that deleting one when it becomes real is a single edit.
 *
 * The ones libdrm reaches them from are named, because "who calls this" is the
 * thing a reader needs when one of them starts refusing in a transcript.
 * ----------------------------------------------------------------------- */

/* `drmOpenDevice`, `chown_check_return` — the X-SERVER path, where libdrm
 * creates /dev/dri and the node itself if it is root. oscortex will never take
 * it: the device namespace is served by the kernel (ADR-0033) and there is
 * nothing to create. */
int mknod(const char *p, unsigned int m, unsigned long d) {
  (void)p; (void)m; (void)d; return posixStub("mknod");
}
int chmod(const char *p, unsigned int m) {
  (void)p; (void)m; return posixStub("chmod");
}
int chown(const char *p, unsigned int u, unsigned int g) {
  (void)p; (void)u; (void)g; return posixStub("chown");
}
int mkdir(const char *p, unsigned int m) {
  (void)p; (void)m; return posixStub("mkdir");
}
int remove(const char *p) { (void)p; return posixStub("remove"); }
int access(const char *p, int m) {
  (void)p; (void)m; return posixStub("access");
}

/* geteuid is the ONE tier-2 symbol that must NOT fail, and getting that
 * backwards would be subtle. libdrm calls it to decide whether it is root and
 * therefore whether to try to CREATE the device node -- so a `geteuid` that
 * refused, or that returned 0, would send it down the mknod path. Returning a
 * non-zero uid is both true (there are no users on this OS, so nobody is root)
 * and the answer that keeps libdrm on the path that works. */
unsigned int geteuid(void) { return 1; }

/* Device-number arithmetic. A `dev_t` scheme this OS does not have.
 *
 * These three are NOT stubs and they are not implementable-as-refusals: they
 * are pure arithmetic with no failure return, and libdrm uses them to compare
 * against DRM_MAJOR 226 in `drmNodeIsDRM`. They compute Linux's encoding
 * correctly on whatever they are given. What has no answer here is `stat`,
 * which is what would have PRODUCED a dev_t -- see GAP-0180. */
unsigned int major(unsigned long dev) {
  return (unsigned int)(((dev >> 8) & 0xfff) | ((dev >> 32) & ~0xfffUL));
}
unsigned int minor(unsigned long dev) {
  return (unsigned int)((dev & 0xff) | ((dev >> 12) & ~0xffUL));
}
unsigned long makedev(unsigned int ma, unsigned int mi) {
  return ((unsigned long)(mi & 0xff)) | (((unsigned long)(ma & 0xfff)) << 8) |
         (((unsigned long)(mi & ~0xffU)) << 12) |
         (((unsigned long)(ma & ~0xfffU)) << 32);
}

/* Directory enumeration of /dev/dri and of sysfs. **ALREADY DEAD ON THIS
 * PLATFORM FOR A SECOND, INDEPENDENT REASON** — design/libdrm-port.md §6:
 * `drmGetDevices2` is built on eight `drmParse*` functions that are `#warning`
 * stubs returning -EINVAL on any platform libdrm does not know, so it fails
 * before it ever gets here. GAP-0171. */
void *opendir(const char *p) { (void)p; posixStub("opendir"); return 0; }
void *readdir(void *d) { (void)d; posixStub("readdir"); return 0; }
int closedir(void *d) { (void)d; return posixStub("closedir"); }

/* sysfs parsing, and libdrm's whole diagnostic channel.
 *
 * `drmMsg` is `vfprintf(stderr, ...)`. core/user/libc has no streams at all --
 * GAP-0113 kept RFILE read-only and deliberately did not call it FILE -- so
 * there is no `stderr` to point at. A DIAGNOSTIC THAT SILENTLY VANISHES IS
 * WORSE THAN ONE THAT REFUSES, so these count themselves like every other stub
 * and the count is readable. GAP-0180. */
void *fopen(const char *p, const char *m) {
  (void)p; (void)m; posixStub("fopen"); return 0;
}
int fclose(void *f) { (void)f; return posixStub("fclose"); }
int sscanf(const char *s, const char *f, ...) {
  (void)s; (void)f; return posixStub("sscanf");
}
/* getenv returns NULL, and that is CORRECT rather than a stub: GAP-0146 says
 * there is no environment on this operating system, so every variable is
 * genuinely unset and NULL is the true answer. It does not count itself,
 * because nothing went wrong. */
char *getenv(const char *n) { (void)n; return 0; }

int fprintf(void *f, const char *fmt, ...) {
  (void)f; (void)fmt; return posixStub("fprintf");
}
int vfprintf(void *f, const char *fmt, void *ap) {
  (void)f; (void)fmt; (void)ap; return posixStub("vfprintf");
}
/* `stderr` is a symbol libdrm dereferences as a FILE*. It is NULL, and the
 * functions that would use it refuse above. */
void *stderr = 0;

/* `drmGetFormatModifierName*` — pretty-printing a modifier's name. A FILE*
 * that writes into a growing heap buffer, which design/libdrm-port.md §2 calls
 * "the single most awkward thing on the list to implement, and it is used only
 * by a diagnostic". */
void *open_memstream(char **b, size_t *n) {
  (void)b; (void)n; posixStub("open_memstream"); return 0;
}
int asprintf(char **s, const char *f, ...) {
  (void)s; (void)f; return posixStub("asprintf");
}

/* `drmMatchBusID`. */
int strcasecmp(const char *a, const char *b) {
  (void)a; (void)b; return posixStub("strcasecmp");
}
int strncasecmp(const char *a, const char *b, size_t n) {
  (void)a; (void)b; (void)n; return posixStub("strncasecmp");
}

/* **THE LEGACY DRM MAP PATH, NOT GEM.** `drmMap`/`drmUnmap`/`drmMapBufs`.
 *
 * design/libdrm-port.md §2 is careful about this one and so is this comment: a
 * GEM buffer is mapped by the CLIENT calling mmap on the DRM fd at the offset
 * MAP_DUMB returned -- libdrm does not do it for you. So `mmap` is tier 2 FOR
 * LIBDRM and tier 1 for anything that uses a buffer object. GAP-0159 is the
 * real entry and it is hard-gated on refcounted frames.
 *
 * MAP_FAILED is (void *)-1, not NULL, and returning NULL here would be a stub
 * that lies: a caller checks `== MAP_FAILED`. */
void *mmap(void *a, size_t l, int p, int f, int fd, long off) {
  (void)a; (void)l; (void)p; (void)f; (void)fd; (void)off;
  posixStub("mmap");
  return (void *)-1L;
}
int munmap(void *a, size_t l) {
  (void)a; (void)l; return posixStub("munmap");
}

/* `drmGetNodeTypeFromFd` needs the device's major/minor to know whether it
 * holds a primary or a render node. **TIER 1, AND IT IS STUBBED ANYWAY, WHICH
 * IS THE ONE PLACE THIS FILE FAILS TO MEET design/libdrm-port.md §2's BAR.**
 *
 * It is stubbed rather than faked because there is no `stat` syscall on this
 * kernel and no dev_t to report: inventing 226:0 here would make
 * `drmGetNodeTypeFromFd` return DRM_NODE_PRIMARY on the strength of a number
 * this OS made up, and the first thing that number would do is be believed.
 * GAP-0180 carries it as an open tier-1 item with the kernel work it needs. */
int stat(const char *p, void *st) {
  (void)p; (void)st; return posixStub("stat");
}
int fstat(int fd, void *st) {
  (void)fd; (void)st; return posixStub("fstat");
}

/* `drmWaitVBlank`'s fence and vblank timeouts. There is no time source
 * reachable from ring 3 on this OS -- `tick_count` is the kernel's and there
 * is no syscall that reads it. GAP-0164, GAP-0180. */
int clock_gettime(int clk, void *ts) {
  (void)clk; (void)ts; return posixStub("clock_gettime");
}

/* --------------------------------------------------------------------------
 * POSIX `printf`.
 *
 * **libdrm NEVER CALLS THIS DIRECTLY** -- design/libdrm-port.md §3 measured
 * that, and libdrm's real diagnostic path is `vfprintf(stderr, ...)`, which is
 * a loud stub above. `printf` is pulled into the link transitively, and before
 * ADR-0033 it bound to oscortex's five-conversion, 120-byte-capped one. That
 * was one of GAP-0170's four.
 *
 * So this exists to be the RIGHT function under that name: C's conversions
 * (port.c's vsnprintf set), C's return value, and no 120-byte cap -- the
 * output is chunked across as many `write` syscalls as it takes.
 *
 * **ONE printf IS STILL NOT ONE LINE, AND THAT IS A REAL DIFFERENCE.**
 * `userSysWrite` prints `USER WRITE `, the bytes, and a newline OF ITS OWN, so
 * every chunk becomes its own console line and an embedded `\n` does not do
 * what a POSIX caller expects. There is no way to fix that from userland --
 * it is the kernel's console syscall, not this function's -- and GAP-0183
 * records it rather than this comment implying it is fine.
 * ----------------------------------------------------------------------- */

/* Big enough for libdrm's longest diagnostic and small enough to sit in a
 * one-page user stack alongside the caller's frame. */
#define POSIX_PRINTF_BUF 512

int printf(const char *fmt, ...) {
  char buf[POSIX_PRINTF_BUF];
  __builtin_va_list ap;
  int n;
  int off;

  __builtin_va_start(ap, fmt);
  n = vsnprintf(buf, sizeof buf, fmt, ap);
  __builtin_va_end(ap);
  if (n < 0) {
    return n;
  }

  /* What actually landed in the buffer, which is what there is to write.
   * `n` may be larger -- that is vsnprintf's truncation report and it is
   * returned to the caller unchanged, because that is the value a caller
   * checks. Writing only what we have is the honest half. */
  {
    int have = n;
    if (have > (int)(sizeof buf) - 1) {
      have = (int)(sizeof buf) - 1;
    }
    off = 0;
    while (off < have) {
      int chunk = have - off;
      if (chunk > (int)PRINTF_MAX) {
        chunk = (int)PRINTF_MAX;
      }
      if (os_write(buf + off, (size_t)chunk) >= SBRK_ERR_FLOOR) {
        posixErrno = EIO;
        return -1;
      }
      off = off + chunk;
    }
  }
  return n;
}
