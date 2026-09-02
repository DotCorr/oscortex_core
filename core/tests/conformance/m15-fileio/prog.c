/* core/tests/conformance/m15-fileio/prog.c
 *
 * A C PROGRAM THAT READS A FILE OFF THIS OPERATING SYSTEM'S FILESYSTEM.
 *
 * M14 put a filesystem under the kernel and M13 put a C library over the
 * syscalls, and until M15 the two did not touch: the kernel could read a file
 * and a *program* could not. This program is M15's exit criterion. It opens
 * files by name, reads them IN PIECES, seeks inside them, keeps four
 * descriptors open at once, computes a position-sensitive hash of everything it
 * read, and exits with a status derived from the bytes on the disk.
 *
 * EVERY NUMBER IT PRINTS IS DERIVED INDEPENDENTLY BY derive.py, out of the very
 * files make-image.py wrote onto the volume. Nothing here is compared against
 * itself.
 *
 * WHY THE HASH IS FNV-1a AND NOT A SUM. A sum is INVARIANT UNDER A PERMUTATION
 * of the input, and a permutation of 1KiB slabs is exactly what a filesystem
 * driver that ignored the cluster chain would deliver. DATA.BIN's twenty
 * clusters are deliberately scattered and NOT in increasing order, so a reader
 * that walked forward from the first cluster gets the volume's background
 * pattern in the wrong places -- and derive.py computes what such a reader would
 * hash, and run.sh requires that number NOT to appear in the transcript.
 *
 * THE CHUNK SIZE IS 173 AND IT IS NOT A ROUND NUMBER ON PURPOSE. It divides
 * neither 512 (a sector) nor 1024 (a cluster on this volume) nor 20000 (the
 * file), so almost every read starts and ends in the middle of a sector, many
 * of them cross a sector boundary, some cross a CLUSTER boundary -- which is
 * where the chain has to be followed mid-read -- and the last one is short.
 *
 * THE NEGATIVE CONTROL IS ONE `#if`. `-DPROG_NEG=1` builds a program that
 * IGNORES the byte count `read` returns and hashes the whole 173-byte chunk
 * every time. That is the single most common way to get this wrong, it is only
 * visible on the last read of the file, and derive.py computes exactly what it
 * produces. run.sh requires the control to print that number, to NOT print the
 * true one, and to exit with a different status.
 *
 * NO `malloc`, AND THAT IS NOT AN OVERSIGHT. `sbrk` is refused unless a PROCESS
 * is live (core/kernel/user.dart) and `run <name>` -- the command that loads a
 * program off the filesystem -- does not create one. Everything here is on the
 * stack or in .bss, which is why the buffered layer in core/user/libc/rfile.c
 * has a fixed array of RFILEs rather than allocating them.
 */

#include "oslibc.h"

extern char __ro_start[];
extern char __ro_end[];
extern char __rw_end[];

#ifndef PROG_NEG
#define PROG_NEG 0
#endif

/* Read sizes. All three are deliberately not divisors of 512 or 1024. */
#define CHUNK 173  /* phase 1: the whole of DATA.BIN, in pieces */
#define ALT 100    /* phase 3: alternating between two open files */
#define ALTN 12    /* how many times round the alternation */
#define PEEK 16    /* phase 4: a small read at a chosen offset */

#define FNV_INIT 0x811C9DC5UL
#define FNV_PRIME 16777619UL

/* The eight-byte markers make-image.py puts at the head and the tail of
 * DATA.BIN, so that "the first bytes are the first bytes" is a check the
 * PROGRAM makes rather than only the harness. */
static const char headMagic[8] = {'M', '1', '5', 'D', 'A', 'T', 'A', '\n'};
static const char tailMagic[8] = {'E', 'N', 'D', 'D', 'A', 'T', 'A', '\n'};

static unsigned char buf[READ_MAX + 8];
static unsigned char peekA[PEEK];
static unsigned char peekB[PEEK];
static char line[96];

static unsigned long fnvUpdate(unsigned long h, const unsigned char *p,
                               unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    h ^= (unsigned long)p[i];
    h = (h * FNV_PRIME) & 0xFFFFFFFFUL;
  }
  return h;
}

static unsigned long fnv1a(const unsigned char *p, unsigned long n) {
  return fnvUpdate(FNV_INIT, p, n);
}

static int same(const unsigned char *a, const char *b, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (a[i] != (unsigned char)b[i]) {
      return 0;
    }
  }
  return 1;
}

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

void progMain(void);

void progMain(void) {
  const unsigned char *ro = (const unsigned char *)__ro_start;
  unsigned long roBytes = (unsigned long)(__ro_end - __ro_start);
  unsigned long selfBefore = fnv1a(ro, roBytes);
  unsigned long selfAfter;
  unsigned long fd, fd2, fd3, fd4;
  unsigned long total = 0, reads = 0, got, h, hA, hB, k;
  unsigned long rNoSlot, rNotFound, rIsDir, rBadName, rBadLen, rOpenPtr, rEmpty;
  unsigned long rRoPtr, rKernPtr, rLongLen, rBadFd, rBadClose, rBadSeek;
  unsigned long rStraddle;
  unsigned char *edge;
  unsigned long rEofRead, rAtEnd;
  int headOk, tailOk;
  unsigned long rfHash, rfBytes, rfLines, rfChars;
  RFILE *rf;

  printf("M15 PROG NEG %d SELF BYTES %x FNV %x\n", (int)PROG_NEG, (int)roBytes,
         (int)selfBefore);

  /* ---- phase 1: the whole of DATA.BIN, CHUNK bytes at a time ---------- */
  fd = open("DATA.BIN");
  if (fd >= FILE_ERR_FLOOR) {
    printf("M15 OPEN DATA REFUSED %x\n", (int)fd);
    exit(0xE1UL);
  }
  h = FNV_INIT;
  for (;;) {
    memset(buf, 0, CHUNK);
    got = read(fd, buf, CHUNK);
    if (got >= FILE_ERR_FLOOR) {
      printf("M15 READ DATA REFUSED %x\n", (int)got);
      exit(0xE2UL);
    }
    if (got == 0) {
      break;
    }
    reads++;
    total += got;
#if PROG_NEG
    /* THE NEGATIVE CONTROL: the returned count is thrown away and the whole
     * chunk is hashed, zero padding included. Correct on every read but the
     * last one, which is exactly what makes it a good control. */
    h = fnvUpdate(h, buf, CHUNK);
#else
    h = fnvUpdate(h, buf, got);
#endif
  }
  printf("M15 DATA BYTES %x READS %x FNV %x\n", (int)total, (int)reads, (int)h);

  /* ---- phase 2: seek, and the two markers at the ends ----------------- */
  seek(fd, 0);
  memset(buf, 0, 8);
  got = read(fd, buf, 8);
  headOk = (got == 8 && same(buf, headMagic, 8)) ? 1 : 0;
  seek(fd, total - 8);
  memset(buf, 0, 8);
  got = read(fd, buf, 8);
  tailOk = (got == 8 && same(buf, tailMagic, 8)) ? 1 : 0;
  rAtEnd = seek(fd, total);
  rEofRead = read(fd, buf, 8);
  rBadSeek = seek(fd, total + 1);
  printf("M15 SEEK HEAD %d TAIL %d END %x EOFREAD %x PAST %x\n", headOk, tailOk,
         (int)rAtEnd, (int)rEofRead, (int)rBadSeek);

  /* ---- phase 3: two files open at once, alternating -------------------
   * This is the phase that forces the kernel to rebuild a cluster chain on
   * every single read, because `fat.dart` holds ONE chain and these two files
   * are not the same file. `FILE ... CHAINS` in the kernel's own exit line is
   * the count, and run.sh requires it to be at least this loop's length. */
  fd2 = open("OTHER.BIN");
  if (fd2 >= FILE_ERR_FLOOR) {
    printf("M15 OPEN OTHER REFUSED %x\n", (int)fd2);
    exit(0xE3UL);
  }
  seek(fd, 0);
  hA = FNV_INIT;
  hB = FNV_INIT;
  for (k = 0; k < ALTN; k++) {
    got = read(fd, buf, ALT);
    hA = fnvUpdate(hA, buf, got);
    got = read(fd2, buf, ALT);
    hB = fnvUpdate(hB, buf, got);
  }
  printf("M15 ALT %x FNVA %x FNVB %x\n", (int)(ALTN * ALT), (int)hA, (int)hB);

  /* ---- phase 4: the SAME file open twice, with independent offsets ---- */
  fd3 = open("DATA.BIN");
  if (fd3 >= FILE_ERR_FLOOR) {
    printf("M15 OPEN DATA2 REFUSED %x\n", (int)fd3);
    exit(0xE4UL);
  }
  seek(fd3, 5000);
  read(fd3, peekA, PEEK);
  read(fd, peekB, PEEK); /* fd is at ALTN*ALT, untouched by fd3's seek */
  printf("M15 TWOFD AT5000 %x ATALT %x\n", (int)fnv1a(peekA, PEEK),
         (int)fnv1a(peekB, PEEK));

  /* ---- phase 5: the fourth descriptor, and then the fifth ------------- */
  fd4 = open("SMALL.TXT");
  rNoSlot = open("SMALL.TXT");
  printf("M15 FDS %x %x %x %x FIFTH %x\n", (int)fd, (int)fd2, (int)fd3,
         (int)fd4, (int)rNoSlot);

  /* ---- phase 6: every refusal, observed from ring 3 ------------------- */
  close(fd4);
  rNotFound = open("NOSUCH.BIN");
  rIsDir = open("SUB");
  rBadName = open("A..B");
  rBadLen = open("TOOLONGNAME.BIN");
  printf("M15 REFUSE OPEN %x %x %x %x\n", (int)rNotFound, (int)rIsDir,
         (int)rBadName, (int)rBadLen);

  /* open() validates its NAME pointer too, and this is the only way to make it
   * refuse one: the library's open() takes a C string and calls strlen on it,
   * so a kernel address would fault in RING 3 before the syscall happened. The
   * raw syscall is used here on purpose -- the kernel must not trust a pointer
   * just because the wrapper usually produces a good one. And EMPTY.TXT is a
   * real, legal, zero-length FAT file, which this kernel refuses to open rather
   * than handing back a descriptor every read of which would return 0. */
  rOpenPtr = sys_call(SYS_OPEN, 0x100000UL, 8);
  rEmpty = open("EMPTY.TXT");
  printf("M15 REFUSE OPEN2 %x %x\n", (int)rOpenPtr, (int)rEmpty);

  /* The W^X one. `__ro_start` is user-accessible and NOT writable, so it passes
   * the kernel's read-side validator and must fail its write-side one. If this
   * came back as a byte count the file would have been written into the
   * program's own instructions -- which `selfAfter` below would then show. */
  rRoPtr = read(fd, (void *)__ro_start, 64);
  rKernPtr = read(fd, (void *)0x100000UL, 64);
  rLongLen = read(fd, buf, READ_MAX + 1);
  rBadFd = read(9, buf, 16);
  rBadClose = close(9);
  printf("M15 REFUSE READ %x %x %x %x CLOSE %x\n", (int)rRoPtr, (int)rKernPtr,
         (int)rLongLen, (int)rBadFd, (int)rBadClose);

  /* THE RANGE THAT STRADDLES THE END OF THE MAPPED IMAGE. `__rw_end` is the
   * last byte of .bss; the kernel maps whole pages, so the page it is on is
   * mapped and the next one is not (the stack is at 0x101FF000, far above).
   * A range that starts 8 bytes below that page boundary and runs 64 bytes
   * therefore has a FIRST page that is user and writable and a SECOND page that
   * is nothing at all. A validator that checked only the first page would accept
   * it and the kernel would then page-fault copying into unmapped memory --
   * which is precisely the failure a range check exists to prevent. */
  edge = (unsigned char *)(((((unsigned long)__rw_end) + 4095UL) & ~4095UL) - 8UL);
  rStraddle = read(fd, edge, 64);
  printf("M15 REFUSE STRADDLE %x\n", (int)rStraddle);

  selfAfter = fnv1a(ro, roBytes);
  printf("M15 SELF AGAIN %x SAME %d\n", (int)selfAfter,
         selfAfter == selfBefore ? 1 : 0);

  close(fd);
  close(fd2);
  /* fd3 IS DELIBERATELY LEFT OPEN. A program that always tidies up cannot show
   * that the kernel tidies up after one that does not, and the teardown path is
   * shared with the FAULT path -- so `FILE ORPHANS 01` in the transcript is the
   * evidence that a program which dies with files open leaks nothing. */

  /* ---- phase 7: the buffered layer, cross-checking phase 1 ------------
   * rfread never asks the kernel for 173 bytes -- it asks for RFILE_BUFSZ and
   * hands out 173 at a time -- so the same hash coming out of a completely
   * different sequence of syscalls is a statement about the FILE rather than
   * about either loop. */
  rfHash = FNV_INIT;
  rfBytes = 0;
  rf = rfopen("DATA.BIN");
  if (rf == NULL) {
    printf("M15 RFOPEN REFUSED %x\n", (int)rf_last_error());
    exit(0xE5UL);
  }
  for (;;) {
    unsigned long n = rfread(buf, CHUNK, rf);
    if (n == 0) {
      break;
    }
    rfHash = fnvUpdate(rfHash, buf, n);
    rfBytes += n;
  }
  printf("M15 RFILE BYTES %x FNV %x EOF %d\n", (int)rfBytes, (int)rfHash,
         rfeof(rf));
  rfclose(rf);

  /* rfgets over the text file, so the line-oriented path is exercised by
   * something whose answer is a count the harness can derive. */
  rfLines = 0;
  rfChars = 0;
  rf = rfopen("SMALL.TXT");
  if (rf == NULL) {
    printf("M15 RFOPEN SMALL REFUSED %x\n", (int)rf_last_error());
    exit(0xE6UL);
  }
  while (rfgets(line, sizeof line, rf) != NULL) {
    rfLines++;
    rfChars += strlen(line);
  }
  printf("M15 RFGETS LINES %x CHARS %x\n", (int)rfLines, (int)rfChars);
  rfclose(rf);

  /* One line straight out of a file, written through the kernel's own ring-3
   * pointer validator, so the bytes appear in the transcript as `USER WRITE`
   * and the harness can compare them against the file it wrote. */
  rf = rfopen("SMALL.TXT");
  if (rf != NULL) {
    if (rfgets(line, sizeof line, rf) != NULL) {
      unsigned long n = strlen(line);
      if (n > 0 && line[n - 1] == '\n') {
        n--;
      }
      write(line, n);
    }
    rfclose(rf);
  }

  /* The exit status is a function of the file's contents and of nothing else.
   * A kernel that delivered the wrong bytes exits with a different number, and
   * derive.py computes it from DATA.BIN and OTHER.BIN on the host. */
  exit((h ^ hB) & 0xFFUL);
}
