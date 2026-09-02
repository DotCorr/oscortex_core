/* core/tests/conformance/m13-libc/prog.c
 *
 * THE FIRST PROGRAM ON THIS MACHINE THAT IS WRITTEN LIKE ORDINARY C.
 *
 * Every program before this one -- m10's, m11's, m12's -- hand-rolled its own
 * `int $0x80` stub, its own hex formatter and its own byte loops, because there
 * was no library and there was no `malloc`. This one calls `malloc`, `free`,
 * `strcpy`, `strcmp`, `strlen`, `memset`, `memcpy` and `printf` from
 * core/user/libc, and there is not one line of assembly in it except the
 * `_start` that ordinary C cannot express.
 *
 * ONE SOURCE, COMPILED TWICE, AND THE SECOND BUILD IS THE NEGATIVE CONTROL
 * ---------------------------------------------------------------------------
 * `build-progs.sh` builds this file into progL.elf and progN.elf with nothing
 * different but `-DLIBC_FREE_ENABLED=0` for the second, which makes the
 * library's `free()` return immediately (core/user/libc/malloc.c). It is a
 * `volatile const` word rather than an `#ifdef`, so the two binaries have
 * BYTE-IDENTICAL SEGMENT GEOMETRY and the same heap base -- m12-heap's argument,
 * kept -- and every difference between their two serial transcripts is
 * attributable to `free` and to nothing else.
 *
 * So this program does NOT assert that memory is reused. It MEASURES whether it
 * is and says which, in the output and in its exit status. progL must report
 * REUSE 1 / COALESCE 1 / ROUND2 1 and progN must report 0 / 0 / 0, and the
 * harness requires both. A check that only ever sees the passing side is the
 * failure mode this whole file is arranged around.
 *
 * WHAT IT PROVES
 * ---------------------------------------------------------------------------
 *  1. `malloc` returns real, distinct, 16-aligned memory that packs the way the
 *     allocator says it does -- derive.py recomputes all six addresses from the
 *     header size, the alignment and the request sizes, ALL THREE READ OUT OF
 *     THE ELF, and requires the program to have printed exactly those.
 *  2. The memory is writable and holds what was written, across later `malloc`
 *     calls and across a context switch into the other address space.
 *  3. `free` returns a block to the allocator: freeing one and asking for the
 *     same size gives THE SAME ADDRESS back (REUSE).
 *  4. Adjacent free blocks merge: two neighbours freed and then a request too
 *     big for either alone comes back at the lower address (COALESCE).
 *  5. After everything is freed, six fresh allocations land on the SAME SIX
 *     ADDRESSES and the program has taken NOT ONE MORE BYTE from the kernel
 *     (ROUND2). That is the strongest form of "it reuses memory" available
 *     without reading the allocator's internals.
 *  6. `printf` formats %s %d %x %c %% correctly and marks everything else `%!`,
 *     visibly, including a string too long for this kernel's 128-byte write.
 *  7. The kernel's own pointer validator accepts a MALLOC'd pointer: the program
 *     copies a message into heap memory `malloc` gave it and passes that pointer
 *     to `write`, and `elfOwns` walks the live page tables before believing it.
 *  8. Failure propagates instead of being invented: a `malloc` far larger than
 *     the whole 2MiB window returns NULL, and `sbrk` refuses a "negative"
 *     increment with heap.dart's own value, and the program keeps running.
 */

#include "oslibc.h"

/* The six allocations, in .rodata so derive.py reads the sizes out of the file
 * rather than having them typed a second time in Python. Deliberately awkward:
 * 17 and 5 are not multiples of the alignment and 4096 is bigger than the first
 * page the allocator ever asks the kernel for. */
#define NBLK 6
volatile const unsigned long reqSize[NBLK] = {32, 1000, 17, 4096, 5, 64};

/* The block the coalescing test asks for: larger than either of the two
 * neighbours it frees, so only a merge can satisfy it without growing. */
volatile const unsigned long coalReq = 1024;

volatile const unsigned long progId = PROG_ID;
volatile const unsigned long exitBase = 0x000C0DE100000000UL;

/* `.data` with file content behind it, for the loader rather than for this
 * program: m10 built a read-a-sector-then-zero-the-tail path and a milestone
 * must not quietly stop exercising it. Folded into the exit status so it cannot
 * be optimised away. */
volatile unsigned long dataWord = 0x0D0A0D0A0D0A0D0AUL;

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

/* A struct big enough that clang -O2 copies it with a CALL to memcpy rather
 * than with inline moves. That call is the point: build-progs.sh requires it to
 * be in the disassembly, which is how "clang emits calls to memcpy from source
 * that never names it" stays a measured fact. */
struct Record {
  unsigned long id;
  char name[40];
  unsigned long score;
  /* THE SIZE IS THE POINT. At 56 bytes clang copied this struct with inline
   * moves and emitted no call at all, and the first version of this file
   * claimed a compiler-emitted `memcpy` that was not there -- build-progs.sh's
   * check caught it. Past a few hundred bytes clang stops unrolling and calls
   * the library, which is the behaviour the libc has to survive. */
  char note[240];
};

static char *blk[NBLK];
static unsigned long round1[NBLK];
static unsigned long fails;

static void checkFail(const char *what) {
  fails++;
  printf("L%d CHECKFAIL %s", (int)progId, what);
}

#define EXPECT(c, tag)      \
  do {                      \
    if (!(c)) {             \
      checkFail(tag);       \
    }                       \
  } while (0)

/* Fills block [i] with a byte pattern derived from its index. */
static void fill(unsigned long i) { memset(blk[i], (int)(0x41 + i), reqSize[i]); }

/* Returns the number of bytes in block [i] that are not what fill() wrote. */
static unsigned long checkFill(unsigned long i) {
  unsigned long j, bad = 0;
  for (j = 0; j < reqSize[i]; j++) {
    if ((unsigned char)blk[i][j] != (unsigned char)(0x41 + i)) {
      bad++;
    }
  }
  return bad;
}

void progMain(void);

void progMain(void) {
  int id = (int)progId;
  unsigned long i;
  unsigned long base = (unsigned long)sbrk(0);

  printf("L%d START BASE %x", id, (unsigned)base);
  printf("L%d WHO %x FREE %d", id, (unsigned)who(), (int)libcFreeEnabled);

  /* --- 1. six allocations of six different sizes ------------------------ */
  for (i = 0; i < NBLK; i++) {
    blk[i] = (char *)malloc(reqSize[i]);
    if (!blk[i]) {
      checkFail("MALLOC");
    }
    round1[i] = (unsigned long)blk[i] - base;
    if (((unsigned long)blk[i] & 15) != 0) {
      checkFail("ALIGN");
    }
  }
  printf("L%d BLK %x %x %x", id, (unsigned)round1[0], (unsigned)round1[1],
         (unsigned)round1[2]);
  printf("L%d BLK %x %x %x", id, (unsigned)round1[3], (unsigned)round1[4],
         (unsigned)round1[5]);
  printf("L%d KERNB %x BRK %x", id, (unsigned)malloc_bytes_from_kernel(),
         (unsigned)((unsigned long)sbrk(0) - base));

  /* --- 2. write to all of them, then read them all back ----------------- */
  for (i = 0; i < NBLK; i++) {
    fill(i);
  }
  for (i = 0; i < NBLK; i++) {
    if (checkFill(i)) {
      checkFail("PATTERN");
    }
  }

  /* --- 3. a struct assignment, which is where clang emits its own memcpy - */
  {
    struct Record r;
    struct Record *slot = (struct Record *)blk[3];
    /* A large local zero-initialiser: clang -O2 emits `call memset` for this,
     * from source that does not name memset. Together with the struct
     * assignment below it is why core/user/libc/string.c is not optional. */
    char zeros[512] = {0};
    r.id = 0x5A;
    r.score = 99;
    strcpy(r.name, "ada lovelace");
    strcpy(r.note, "the note field exists so that this struct is big enough "
                   "that clang calls memcpy instead of unrolling the copy");
    /* Read back at runtime, through our own memcpy, so that "the compiler's
     * memset zeroed 512 bytes" is counted rather than assumed. `base` is
     * page-aligned so the index is 0, but clang cannot know that. */
    zeros[(unsigned long)(base & 511)] = 'z';
    memcpy(blk[3], zeros, sizeof(zeros));
    {
      unsigned long nz = 0, k;
      for (k = 0; k < sizeof(zeros); k++) {
        if (blk[3][k]) {
          nz++;
        }
      }
      EXPECT(nz == 1, "ZEROS");
    }
    *slot = r; /* clang -O2: call memcpy */
    EXPECT(slot->id == 0x5A, "STRUCTID");
    EXPECT(slot->score == 99, "STRUCTSCORE");
    EXPECT(strcmp(slot->name, "ada lovelace") == 0, "STRUCTNAME");
    EXPECT(strlen(slot->name) == 12, "STRLEN");
    EXPECT(strcmp(slot->name, "ada lovelacf") < 0, "STRCMPLT");
    /* strcmp compares as UNSIGNED char. `char` is signed on this target, so an
     * implementation that subtracted plain `char`s would call "\x80" less than
     * "\x01" and get the sign of the answer backwards for every byte above
     * 127. Cheap to check, invisible otherwise. */
    EXPECT(strcmp("\x80", "\x01") > 0, "STRCMPSIGN");
    EXPECT(strlen(slot->note) == 109, "NOTELEN");
    printf("L%d REC %s %d %x", id, slot->name, (int)slot->score,
           (unsigned)slot->id);
    fill(3); /* put the pattern back */
  }

  /* --- 4. the kernel reads a string out of memory malloc gave me -------- */
  strcpy(blk[5], "THIS LINE WAS READ BY THE KERNEL OUT OF MY MALLOC");
  EXPECT(write(blk[5], strlen(blk[5])) == strlen(blk[5]), "HEAPWRITE");
  fill(5);

  /* --- 5. the other process runs here, in its own address space, and takes
   *        its own heap at these same virtual addresses. What this program
   *        checks afterwards is that ITS OWN blocks still hold what it wrote:
   *        that the heap SURVIVES a context switch. It does not re-prove
   *        isolation -- m12-heap walks both processes' live page tables out of
   *        guest RAM for that, and repeating it here at a quarter of the rigour
   *        would be worse than not repeating it. ---------------------------- */
  yield();
  for (i = 0; i < NBLK; i++) {
    if (checkFill(i)) {
      checkFail("AFTERYIELD");
    }
  }

  /* --- 6. REUSE: free one block, ask for the same size ------------------ */
  free(blk[1]);
  {
    char *again = (char *)malloc(reqSize[1]);
    unsigned long reuse = (again == blk[1]);
    if (reuse) {
      printf("L%d REUSE 1 AT %x", id, (unsigned)((unsigned long)again - base));
    } else {
      printf("L%d REUSE 0 AT %x -- free() did not give this block back",
             id, (unsigned)((unsigned long)again - base));
    }

    /* --- 7. COALESCE: free two neighbours, ask for more than either ---- */
    free(blk[0]);
    free(again);
    char *big = (char *)malloc(coalReq);
    unsigned long coal = (big == blk[0]);
    if (coal) {
      printf("L%d COALESCE 1 AT %x", id, (unsigned)((unsigned long)big - base));
    } else {
      printf("L%d COALESCE 0 AT %x -- the two free neighbours did not merge",
             id, (unsigned)((unsigned long)big - base));
    }

    /* the blocks that were NOT freed must still hold their patterns */
    for (i = 2; i < NBLK; i++) {
      if (checkFill(i)) {
        checkFail("SURVIVE");
      }
    }

    /* --- 8. free everything, then allocate the same six again --------- */
    free(big);
    for (i = 2; i < NBLK; i++) {
      free(blk[i]);
    }
    printf("L%d FREEBLOCKS %d", id, (int)malloc_free_blocks());

    unsigned long before = malloc_bytes_from_kernel();
    unsigned long same = 1;
    for (i = 0; i < NBLK; i++) {
      blk[i] = (char *)malloc(reqSize[i]);
      if (!blk[i] || (unsigned long)blk[i] - base != round1[i]) {
        same = 0;
      }
    }
    unsigned long round2 = same && (malloc_bytes_from_kernel() == before);
    printf("L%d ROUND2 %d KERNB %x", id, (int)round2,
           (unsigned)malloc_bytes_from_kernel());

    /* --- 9. printf's five conversions, and the sixth ------------------ */
    EXPECT(printf("L%d FMT [%s] [%d] [%x] [%c] [%%]", id, "abc", -12345,
                  0xBEEFu, 0x51) == 36,
           "FMTRET");
    /* Through a function pointer so that clang's -Wformat does not reject the
     * deliberately bad format at compile time. The badness is the test. */
    {
      int (*pf)(const char *, ...) = printf;
      /* Four unsupported conversions in one line, each of which must show up
       * as `%!`: an unknown letter, a length-modified one, a width, and a
       * TRAILING `%` with nothing after it at all -- which is its own branch in
       * printf.c and would otherwise be untested. */
      pf("L%d BAD [%q] [%u] [%5d] %", id);
    }
    {
      int r = printf("L%d OVF %s", id,
                     "0123456789012345678901234567890123456789012345678901234567890"
                     "12345678901234567890123456789012345678901234567890123456789");
      printf("L%d OVFRET %d", id, r);
      EXPECT(r == -1, "OVFRET");
    }

    /* --- 10. failure propagates -------------------------------------- */
    EXPECT(malloc(0) == NULL, "MALLOC0");
    /* The largest size_t there is. Without the overflow guard in malloc(), the
     * round-up to the alignment wraps to ZERO and the first block on the free
     * list is handed out for a request of sixteen exabytes. That is a real bug
     * with a two-character fix, and it is the one an allocator is most likely
     * to ship with, so it gets a check of its own. */
    EXPECT(malloc((size_t)-1) == NULL, "MALLOCMAX");
    void *huge = malloc(4UL * 1024 * 1024);
    printf("L%d HUGE %d SBRKERR %x", id, huge == NULL,
           (unsigned)(sbrk_last_error() & 0xFFFFFFFFUL));
    EXPECT(huge == NULL, "HUGE");
    EXPECT(sbrk((size_t)-1) == NULL, "SBRKNEG");
    EXPECT(sbrk_last_error() == SBRK_EBADARG, "SBRKNEGVAL");

    printf("L%d SUM REUSE %d COAL %d R2 %d FAILS %d", id, (int)reuse, (int)coal,
           (int)round2, (int)fails);

    exit(exitBase + dataWord + (reuse << 20) + (coal << 16) + (round2 << 12) +
         fails);
  }
}
