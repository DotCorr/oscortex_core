/* core/tests/conformance/m16-filewrite/prog.c
 *
 * A C PROGRAM THAT PUTS BYTES ON A DISK AND THEN PROVES THEY ARE THERE.
 *
 * M15 gave a ring-3 program `open`, `read`, `close` and `seek`, and GAP-0122
 * item 1 said in capitals that there were no writes at any layer. This program
 * is M16's exit criterion: it creates a file that was not on the volume, writes
 * it in pieces, closes it, reopens it and reads back what it wrote — and every
 * number it prints is computed independently by derive.py from the same
 * generators, then checked a third time by macOS's own `msdos` driver reading
 * the image the guest left behind.
 *
 * ONE SOURCE, THREE BUILDS
 * ---------------------------------------------------------------------------
 *   PROG_NEG=0 PROG_VERIFY=0   PROG.ELF    the real thing
 *   PROG_NEG=1 PROG_VERIFY=0   PROGN.ELF   THE NEGATIVE CONTROL: it adds the
 *                                          LENGTH IT ASKED FOR to its running
 *                                          total instead of the count fdwrite
 *                                          RETURNED. That is right on every
 *                                          write that succeeds in full and
 *                                          wrong on a short one, so it is
 *                                          indistinguishable from PROG.ELF
 *                                          until the volume fills up — which is
 *                                          why the harness runs it on the
 *                                          `full` variant, where it reports a
 *                                          byte count the disk does not have
 *                                          and the host proves it wrong.
 *   PROG_VERIFY=1              VERIFY.ELF  reads only. It is what BOOT 4 runs
 *                                          against the image BOOT 1 wrote, on a
 *                                          machine that has been switched off
 *                                          and on in between.
 *
 * THE THINGS THIS PROGRAM CHECKS THAT NOTHING BEFORE IT COULD
 * ---------------------------------------------------------------------------
 *   * A FILE THAT WAS NOT THERE IS THERE. NEW.BIN does not exist on the volume
 *     make-image.py writes.
 *   * A FILE THAT WAS THERE IS REPLACED. SEED.TXT arrives with 5000 bytes on
 *     five scattered clusters; it leaves with SEED_NEW bytes on two, and not
 *     one of the old bytes is readable through it.
 *   * A ZERO-LENGTH FILE IS A REAL FILE, BOTH WAYS. EMPTY2.TX is created and
 *     closed without a byte being written, and opening it for READING is
 *     FILE_EEMPTY — the refusal M15 could only produce from a file the image
 *     generator had planted. EMPTY.TXT is the reverse: a zero-length file that
 *     was already on the volume, opened for writing and given contents.
 *   * A WRITE STRAIGHT OUT OF `.rodata` SUCCEEDS. This is the pointer-safety
 *     property M16 adds to M15's. `read` demands the USER *and* WRITABLE bits
 *     of the destination page; `fdwrite` demands only USER of the SOURCE, and a
 *     validator that demanded WRITABLE would refuse the most ordinary call
 *     there is. SCRATCH.BIN gets the first 64 bytes of this program's own
 *     read-only segment and the harness compares them against the ELF.
 *   * THE PROGRAM'S OWN IMAGE IS UNCHANGED. It hashes its R+X segment before
 *     and after everything above, exactly as m15-fileio's does.
 *
 * Every refusal below is OBSERVED FROM RING 3 AS A RETURN VALUE and printed as
 * its low sixteen bits. There is no errno on this OS and there is not going to
 * be one.
 */

#include "oslibc.h"

#ifndef PROG_NEG
#define PROG_NEG 0
#endif
#ifndef PROG_VERIFY
#define PROG_VERIFY 0
#endif

/* core/tests/conformance/m16-filewrite/prog.ld puts these round the R+X
 * segment. run.sh reads both out of the linked ELF and derive.py hashes exactly
 * that range. */
extern char __ro_start[];
extern char __ro_end[];

/* The end of `.bss`, and therefore of everything the kernel mapped for this
 * program apart from the stack page far above it. m15-fileio added this symbol
 * for the READ-side straddling check and M16 needs it for the write side, for
 * the same reason: it is the only way to name a range whose FIRST page is
 * mapped and whose SECOND is not. */
extern char __rw_end[];

/* ---------------------------------------------------------------------------
 * THE FOUR NUMBERS THIS WHOLE HARNESS IS BUILT ON. derive.py reads every one of
 * them back OUT OF THIS FILE and refuses to run if they disagree with what it
 * was going to assume.
 *
 * CHUNK IS 173 AND IT DIVIDES NOTHING. Not a sector (512), not a cluster
 * (1024), not NEW_BYTES and not SEED_NEW. So writes start mid-sector, end
 * mid-sector, cross sector boundaries and cross CLUSTER boundaries, and the
 * last write of every file is short. A driver that only ever wrote whole
 * sectors would pass a test with a round chunk size and fail this one.
 *
 * NEW_BYTES IS 21801 BECAUSE THAT IS TWENTY-TWO CLUSTERS AND THE FREE BAND HOLDS
 * TWENTY. The allocator runs off the end of the band and wraps to the low free
 * run, so NEW.BIN's chain contains a link that goes BACKWARDS by nearly three
 * thousand clusters — and the host has to follow it.
 * ------------------------------------------------------------------------- */
#define CHUNK 173UL
#define NEW_BYTES 21801UL
#define SEED_NEW 2000UL
#define ZERO_NEW 40UL
#define RO_BYTES 64UL

#define NEW_NAME "NEW.BIN"
#define SEED_NAME "SEED.TXT"
#define EMPTY_NEW "EMPTY2.TX"
#define EMPTY_OLD "EMPTY.TXT"
#define SCRATCH_NAME "SCRATCH.BIN"

#if !PROG_VERIFY
static unsigned char chunk[CHUNK];
#endif
static unsigned char rbuf[CHUNK];

#if !PROG_VERIFY
/* The three payload generators. derive.py carries the same three, and run.sh
 * requires the two files to agree about every constant in them. Every byte
 * depends on its OFFSET, so a permutation of clusters — which is exactly what a
 * wrong allocator or a wrong chain produces — is visible in an FNV-1a hash. */
static unsigned char newByte(unsigned long i) {
  return (unsigned char)(((i * 181UL) ^ (i >> 3) ^ ((i * i) >> 5) ^ 0x7EUL) & 0xFFUL);
}

static unsigned char seedByte(unsigned long i) {
  return (unsigned char)(((i * 211UL) + (i >> 1) + 0x2DUL) & 0xFFUL);
}

static unsigned char zeroByte(unsigned long i) {
  return (unsigned char)(0x61UL + (i % 26UL));
}

#endif /* !PROG_VERIFY */

static unsigned long fnvUpdate(unsigned long h, const unsigned char *p,
                               unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    h ^= (unsigned long)p[i];
    h = (h * 16777619UL) & 0xFFFFFFFFUL;
  }
  return h;
}

#if !PROG_VERIFY
static unsigned long fnv1a(const unsigned char *p, unsigned long n) {
  return fnvUpdate(2166136261UL, p, n);
}
#endif

/* Fills `chunk` with `n` bytes of the file `which` starting at offset `off`. */
#if !PROG_VERIFY
static void fillChunk(int which, unsigned long off, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (which == 0) {
      chunk[i] = newByte(off + i);
    } else if (which == 1) {
      chunk[i] = seedByte(off + i);
    } else {
      chunk[i] = zeroByte(off + i);
    }
  }
}

#endif /* !PROG_VERIFY */

/* Reads all of `name` and returns its FNV-1a, leaving the byte count in *got.
 * A refusal is reported and returns 0 with *got set to the refusal. */
static unsigned long hashFile(const char *name, unsigned long *got) {
  unsigned long fd = open(name);
  unsigned long h = 2166136261UL;
  unsigned long n, total = 0;
  if (fd >= FILE_ERR_FLOOR) {
    *got = fd;
    return 0;
  }
  for (;;) {
    n = read(fd, rbuf, CHUNK);
    if (n >= FILE_ERR_FLOOR) {
      close(fd);
      *got = n;
      return 0;
    }
    if (n == 0) {
      break;
    }
    h = fnvUpdate(h, rbuf, n);
    total += n;
  }
  close(fd);
  *got = total;
  return h;
}

#if !PROG_VERIFY
/* Writes `bytes` bytes of generator `which` to `fd` in CHUNK-byte pieces.
 * Returns the number of bytes the KERNEL said it wrote — except in the negative
 * control, where it returns the number this program ASKED it to write. Leaves
 * the refusal, if there was one, in *refusal. */
static unsigned long writeAll(unsigned long fd, int which, unsigned long bytes,
                              unsigned long *refusal) {
  unsigned long off = 0, total = 0, want, n;
  *refusal = 0;
  while (off < bytes) {
    want = bytes - off;
    if (want > CHUNK) {
      want = CHUNK;
    }
    fillChunk(which, off, want);
    n = fdwrite(fd, chunk, want);
    if (n >= FILE_ERR_FLOOR) {
      *refusal = n;
      return total;
    }
#if PROG_NEG
    /* THE BUG, ON PURPOSE. `want` is what was asked for; `n` is what happened.
     * They differ only when the volume ran out part way through a write. */
    total += want;
#else
    total += n;
#endif
    off += n;
    if (n == 0) {
      /* A zero-length success is not a thing this kernel returns, and a loop
       * that did not check would spin forever. */
      *refusal = FILE_EIO;
      return total;
    }
  }
  return total;
}
#endif /* !PROG_VERIFY */

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

#if PROG_VERIFY

/* VERIFY.ELF — BOOT 4. The machine has been switched off and on since the bytes
 * were written. Nothing here writes. */
void progMain(void) {
  unsigned long got, h, status;
  unsigned long newH, seedH, zeroH;

  newH = hashFile(NEW_NAME, &got);
  printf("V NEW %d H %x\n", (int)got, (int)newH);
  status = newH & 0xFFUL;

  seedH = hashFile(SEED_NAME, &got);
  printf("V SEED %d H %x\n", (int)got, (int)seedH);

  zeroH = hashFile(EMPTY_OLD, &got);
  printf("V ZERO %d H %x\n", (int)got, (int)zeroH);

  h = hashFile(SCRATCH_NAME, &got);
  printf("V SCRATCH %d H %x\n", (int)got, (int)h);

  /* The file created and closed without a byte: a real zero-length FAT file,
   * which this kernel refuses to open for reading. */
  h = hashFile(EMPTY_NEW, &got);
  printf("V EMPTY %x\n", (int)(got & 0xFFFFUL));

  exit(status);
}

#else

void progMain(void) {
  const unsigned char *ro = (const unsigned char *)__ro_start;
  unsigned long roBytes = (unsigned long)(__ro_end - __ro_start);
  unsigned long selfBefore = fnv1a(ro, roBytes);
  unsigned long selfAfter;
  unsigned long fd, wfd, rfd, got, h, n, wrote, refusal, status;
  unsigned long rBadModeW, rBadModeR, rBadModeS, rBadModeO;
  unsigned long rBadPtr, rBadLen0, rBadLenB, rBadFd, rClosed;
  unsigned long rIsDir, rBadName, rRodata, rHole, rStraddle;
  const unsigned char *edge;

  printf("SELF %x %d\n", (int)selfBefore, (int)roBytes);

  /* ----------------------------------------------------------------------
   * Phase 1 — REPLACE A FILE THAT IS ALREADY THERE.
   *
   * SEED.TXT arrives with 5000 bytes on five scattered clusters. `create`
   * truncates it, which frees all five, and the rewrite then allocates from the
   * first of them. That ordering is why the harness can predict every cluster.
   * -------------------------------------------------------------------- */
  fd = create(SEED_NAME);
  if (fd >= FILE_ERR_FLOOR) {
    printf("SEED CREATE %x\n", (int)(fd & 0xFFFFUL));
    exit(0x11);
  }
  wrote = writeAll(fd, 1, SEED_NEW, &refusal);
  n = close(fd);
  printf("SEED WROTE %d REF %x CLOSE %x\n", (int)wrote,
         (int)(refusal & 0xFFFFUL), (int)(n & 0xFFFFUL));
  h = hashFile(SEED_NAME, &got);
  printf("SEED BACK %d H %x\n", (int)got, (int)h);

  /* ----------------------------------------------------------------------
   * Phase 2 — CREATE A FILE THAT WAS NOT THERE, AND FILL IT.
   * -------------------------------------------------------------------- */
  fd = create(NEW_NAME);
  if (fd >= FILE_ERR_FLOOR) {
    printf("NEW CREATE %x\n", (int)(fd & 0xFFFFUL));
    exit(0x12);
  }
  wrote = writeAll(fd, 0, NEW_BYTES, &refusal);
  n = close(fd);
  printf("NEW WROTE %d REF %x CLOSE %x\n", (int)wrote,
         (int)(refusal & 0xFFFFUL), (int)(n & 0xFFFFUL));
  h = hashFile(NEW_NAME, &got);
  printf("NEW BACK %d H %x\n", (int)got, (int)h);
  status = h & 0xFFUL;

  /* ----------------------------------------------------------------------
   * Phase 3 — A FILE OF NO BYTES AT ALL, created and closed.
   * -------------------------------------------------------------------- */
  fd = create(EMPTY_NEW);
  if (fd >= FILE_ERR_FLOOR) {
    printf("EMPTY CREATE %x\n", (int)(fd & 0xFFFFUL));
    exit(0x13);
  }
  n = close(fd);
  h = hashFile(EMPTY_NEW, &got);
  printf("EMPTY CLOSE %x OPEN %x\n", (int)(n & 0xFFFFUL),
         (int)(got & 0xFFFFUL));

  /* ----------------------------------------------------------------------
   * Phase 4 — THE OTHER DIRECTION: a zero-length file that was already on the
   * volume, opened for writing and given contents. Its directory entry has
   * first cluster 0, so this is the path where a chain is built from nothing at
   * all rather than from a chain that was freed.
   * -------------------------------------------------------------------- */
  fd = create(EMPTY_OLD);
  if (fd >= FILE_ERR_FLOOR) {
    printf("ZERO CREATE %x\n", (int)(fd & 0xFFFFUL));
    exit(0x14);
  }
  wrote = writeAll(fd, 2, ZERO_NEW, &refusal);
  n = close(fd);
  h = hashFile(EMPTY_OLD, &got);
  printf("ZERO WROTE %d BACK %d H %x\n", (int)wrote, (int)got, (int)h);

  /* ----------------------------------------------------------------------
   * Phase 5 — THE REFUSALS, every one of them a return value from ring 3.
   *
   * SCRATCH.BIN is open for writing and NEW.BIN is open for reading for the
   * whole of this phase, so "wrong mode" is tested in both directions against
   * two descriptors that are both perfectly valid.
   * -------------------------------------------------------------------- */
  wfd = create(SCRATCH_NAME);
  if (wfd >= FILE_ERR_FLOOR) {
    printf("SCRATCH CREATE %x\n", (int)(wfd & 0xFFFFUL));
    exit(0x15);
  }
  rfd = open(NEW_NAME);
  if (rfd >= FILE_ERR_FLOOR) {
    printf("SCRATCH OPEN %x\n", (int)(rfd & 0xFFFFUL));
    exit(0x16);
  }

  rBadModeW = fdwrite(rfd, chunk, 16);
  rBadModeR = read(wfd, rbuf, 16);
  rBadModeS = seek(wfd, 0);
  rBadModeO = openmode(NEW_NAME, 7);
  rBadPtr = fdwrite(wfd, (const void *)1UL, 16);
  /* A PAGE INSIDE THE PROGRAM'S OWN WINDOW THAT IS NOT MAPPED. The image sits
   * at 0x10000000 and the stack at 0x101FF000, so this address passes both
   * bounds and is nothing at all. A validator that checked the range against
   * vmProgBase/vmProgEnd and then stopped would accept it. */
  rHole = fdwrite(wfd, (const void *)0x10100000UL, 16);
  /* A RANGE THAT STRADDLES THE END OF THE MAPPED IMAGE. Its FIRST page is user
   * and present; its SECOND page is not mapped. A validator that looked at the
   * first page only would accept it and the kernel would then fault reading
   * from unmapped memory INSIDE A SYSCALL -- which is precisely the failure a
   * page-by-page walk exists to prevent, and which is the mutant that survived
   * m15-fileio's first round until it grew this check. */
  edge = (const unsigned char *)(((((unsigned long)__rw_end) + 4095UL)
                                  & ~4095UL) - 8UL);
  rStraddle = fdwrite(wfd, edge, 64);
  rBadLen0 = fdwrite(wfd, chunk, 0);
  rBadLenB = fdwrite(wfd, chunk, WRITE_FILE_MAX + 1);
  rBadFd = fdwrite(FILE_MAX_FDS + 5, chunk, 16);
  rIsDir = create("SUB");
  rBadName = create("BAD*NAME.X");

  /* THE ONE THAT MUST SUCCEED. `__ro_start` is present, user-accessible and NOT
   * writable — the exact page M15's `read` validator refuses. This is a source,
   * not a destination, so it goes through. */
  rRodata = fdwrite(wfd, __ro_start, RO_BYTES);

  close(rfd);
  n = close(wfd);
  rClosed = fdwrite(wfd, chunk, 16);

  printf("R MODEW %x MODER %x MODES %x MODEO %x\n",
         (int)(rBadModeW & 0xFFFFUL), (int)(rBadModeR & 0xFFFFUL),
         (int)(rBadModeS & 0xFFFFUL), (int)(rBadModeO & 0xFFFFUL));
  printf("R PTR %x LEN0 %x LENB %x FD %x CLOSED %x\n",
         (int)(rBadPtr & 0xFFFFUL), (int)(rBadLen0 & 0xFFFFUL),
         (int)(rBadLenB & 0xFFFFUL), (int)(rBadFd & 0xFFFFUL),
         (int)(rClosed & 0xFFFFUL));
  printf("R HOLE %x STRADDLE %x\n", (int)(rHole & 0xFFFFUL),
         (int)(rStraddle & 0xFFFFUL));
  printf("R ISDIR %x BADNAME %x RODATA %d CLOSE %x\n",
         (int)(rIsDir & 0xFFFFUL), (int)(rBadName & 0xFFFFUL),
         (int)rRodata, (int)(n & 0xFFFFUL));

  h = hashFile(SCRATCH_NAME, &got);
  printf("SCRATCH BACK %d H %x\n", (int)got, (int)h);

  /* ----------------------------------------------------------------------
   * The program's own image, again. Nothing above may have changed one byte of
   * it: the only pointer the kernel dereferenced on this program's behalf that
   * pointed INTO the R+X segment was the SOURCE of a write.
   * -------------------------------------------------------------------- */
  selfAfter = fnv1a(ro, roBytes);
  printf("SELF %x %d\n", (int)selfAfter, (int)roBytes);
  if (selfAfter != selfBefore) {
    exit(0x17);
  }
  exit(status);
}

#endif
