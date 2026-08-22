/* core/tests/conformance/m12-heap/prog.c
 *
 * THE FIRST PROGRAM ON THIS MACHINE THAT ASKS THE KERNEL FOR MEMORY.
 *
 * ONE SOURCE, COMPILED TWICE, AND THAT IS THE WHOLE ISOLATION ARGUMENT
 * ---------------------------------------------------------------------------
 * `build-progs.sh` builds this file into progH.elf and progP.elf with nothing
 * different but two `-D` constants that land in `.rodata`. The two binaries
 * therefore have BYTE-IDENTICAL SEGMENT GEOMETRY -- same p_vaddr, same
 * p_filesz, same p_memsz -- which means the kernel gives both processes a heap
 * that STARTS AT THE SAME VIRTUAL ADDRESS. `build-progs.sh` asserts that
 * equality out of the two ELF files rather than assuming it.
 *
 * That is the point. Two processes writing different patterns to THE SAME
 * ADDRESS and each reading back its own is a statement about page tables that
 * no amount of "they were given different addresses" could make. If the heaps
 * were shared, whichever process wrote last would win and the other would
 * report the wrong signature -- loudly, by name, in the serial capture.
 *
 * The compile-time IDs are `volatile const` and live in `.rodata`, so clang
 * cannot fold either branch away and both binaries contain all of the code.
 * A `#if` would have produced two programs of different sizes, two different
 * heap bases, and no shared address to argue about.
 *
 * WHAT THIS PROGRAM PROVES
 * ---------------------------------------------------------------------------
 *   1. `sbrk` returns real memory. Every page it is handed is read (it must be
 *      all zeroes -- the kernel zeroes a frame before it maps it, and this is
 *      the one place a leak of a dead process's data would show), written with
 *      a per-page signature derived from `progSig`, and read back.
 *   2. The memory SURVIVES. Every page is re-verified after later `sbrk` calls,
 *      after a context switch to the other process, and again at the end.
 *   3. The kernel's own pointer validator agrees the heap is user memory: the
 *      program copies a message ONTO ITS HEAP and passes that heap pointer to
 *      `write`. `elfOwns` walks the live page tables and refuses a pointer whose
 *      page is not present and user-accessible, so a `USER WRITE` of text that
 *      lives on the heap is the kernel confirming the mapping from its side.
 *   4. IT CAN BE TOLD NO, THREE DIFFERENT WAYS, AND KEEP RUNNING. A "negative"
 *      increment, an oversized one, and a heap grown until the address space
 *      runs out -- each returns a distinct error, none of them faults, and the
 *      program runs on afterwards and exits normally.
 *
 * Nothing here may assume anything about the kernel except the five syscall
 * numbers and the three error values below, which are core/kernel/user.dart's
 * and core/kernel/heap.dart's.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_WHO 2
#define SYS_YIELD 3
#define SYS_SBRK 4

/* core/kernel/heap.dart's `heapRet*`. Anything above ERR_FLOOR is a refusal
 * rather than an address; the window ends at 258MiB so no legal break comes
 * anywhere near. */
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_NOMEM 0xFFFFFFFFFFFFFFFCUL
#define E_NOSPACE 0xFFFFFFFFFFFFFFFDUL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define PAGE 4096UL
#define WORDS_PER_PAGE 512UL

/* How many pages the scripted phase takes: 1 + 3 + 1 (the last from an
 * increment of ONE byte, which must still round up to a whole page). */
#define SCRIPT_PAGES 5

/* The growth loop's increment: 64 pages at a time, so a ~500-page window is
 * exhausted in eight calls rather than five hundred lines of serial output. */
#define GROW_PAGES 64

/* Every page this program is ever handed, so the final sweep can re-verify all
 * of them. The window is 512 pages, so 512 entries can never overflow. */
#define MAX_PAGES 576

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

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

/* THE TWO PATCH POINTS.
 *
 * `make-image.py` writes `EB FE` (`jmp .`) over the first two bytes of ONE of
 * these to build a variant that stops at a chosen moment with its address space
 * intact, so the harness can read the page tables out of guest RAM while the
 * process is still alive. m10-elf and m11-proc patched `e_entry` for the same
 * reason; a heap needs the stop to be AFTER the allocations (or, for the
 * before-picture, after the program is running but before the first one), and
 * neither of those moments is the entry point.
 *
 * `nop; nop` is exactly two bytes, so the patch replaces instructions rather
 * than splitting one.
 *
 * THEY ARE WRITTEN AS RAW ASSEMBLY RATHER THAN AS C FUNCTIONS, and the first
 * attempt is why: an `__attribute__((noinline)) void f(void) { asm("nop"); }`
 * compiled to `55 48 89 e5 ...` -- clang emitted a frame-pointer prologue at
 * -O2 on this target, so the two bytes at the symbol were `push %rbp` and half
 * of a `mov`, and patching them would have run something nobody wrote.
 * build-progs.sh caught it, and the check stays because a compiler flag could
 * put the prologue back. */
__asm__(
    ".text\n"
    ".globl heapHoldEarly\n"
    ".type heapHoldEarly, @function\n"
    "heapHoldEarly:\n"
    "  nop\n"
    "  nop\n"
    "  ret\n"
    ".size heapHoldEarly, . - heapHoldEarly\n"
    ".globl heapHoldLate\n"
    ".type heapHoldLate, @function\n"
    "heapHoldLate:\n"
    "  nop\n"
    "  nop\n"
    "  ret\n"
    ".size heapHoldLate, . - heapHoldLate\n");
void heapHoldEarly(void);
void heapHoldLate(void);

/* The two words that differ between the two builds, in `.rodata` and `volatile`
 * so that neither the branch below nor the signature can be constant-folded --
 * which is what keeps the two binaries the same size. derive.py reads both out
 * of the ELF, so every expectation about this program comes from the binary. */
volatile const unsigned long progId = PROG_ID;
volatile const unsigned long progSig = PROG_SIG;

/* The exit status's fixed part, also read out of the file by derive.py. */
volatile const unsigned long exitBase = 0x000C0DE000000000UL;

/* `.data` WITH FILE CONTENT BEHIND IT, and it is here for the loader rather
 * than for this program: a PT_LOAD whose p_filesz is 0 is a segment the kernel
 * zeroes without reading a sector, and this milestone must not quietly stop
 * exercising the read-and-then-zero path M10 built. It is added into the exit
 * status so it cannot be optimised out of existence. */
volatile unsigned long dataWord = 0x0D0A0D0A0D0A0D0AUL;

const char msgStart[] = "HEAP START";
const char msgHeapText[] = "THIS LINE WAS READ BY THE KERNEL OUT OF MY HEAP";

char out[128];
unsigned long pageAddr[MAX_PAGES];
unsigned long pageCount;

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

/* 16 hex digits of [v] into [dst]. Returns the next free index. */
static unsigned long put64(unsigned long at, unsigned long v) {
  unsigned long j;
  for (j = 0; j < 16; j++) {
    out[at + j] = hex(v >> (60 - 4 * j));
  }
  return at + 16;
}

static unsigned long put8(unsigned long at, unsigned long v) {
  unsigned long j;
  for (j = 0; j < 8; j++) {
    out[at + j] = hex(v >> (28 - 4 * j));
  }
  return at + 8;
}

static unsigned long putstr(unsigned long at, const char *s) {
  while (*s) {
    out[at++] = *s++;
  }
  return at;
}

/* The signature this program writes into word [w] of the page at index [i].
 *
 * `progSig` is per-build and lives in the file; the page index and the word
 * index are added in, so a page written to the wrong place, a page written
 * twice, and a page whose contents came from the OTHER process are all three
 * distinguishable from each other. derive.py recomputes it. */
static unsigned long mark(unsigned long i, unsigned long w) {
  return progSig + (i << 20) + w;
}

/* Records a page and returns 1 if anything about it was wrong.
 *
 * ZERO-CHECKED BEFORE IT IS WRITTEN. `allocFrame()` hands back whatever the
 * frame last held, and this kernel recycles frames between processes, so a
 * heap page arriving non-zero is a leak of somebody else's memory into the one
 * place a program is guaranteed to look. Checking after writing would prove
 * nothing. */
static unsigned long takePage(unsigned long va, unsigned long deep) {
  volatile unsigned long *p = (volatile unsigned long *)va;
  unsigned long w, bad = 0;
  unsigned long last = deep ? WORDS_PER_PAGE : 1;

  for (w = 0; w < last; w++) {
    if (p[w] != 0) {
      bad++;
    }
  }
  if (!deep && p[WORDS_PER_PAGE - 1] != 0) {
    bad++;
  }

  for (w = 0; w < last; w++) {
    p[w] = mark(pageCount, w);
  }
  if (!deep) {
    p[WORDS_PER_PAGE - 1] = mark(pageCount, WORDS_PER_PAGE - 1);
  }

  pageAddr[pageCount] = va;
  pageCount++;
  return bad;
}

/* Re-reads every page taken so far. Returns the number of wrong words. */
static unsigned long verifyAll(void) {
  unsigned long i, bad = 0;
  for (i = 0; i < pageCount; i++) {
    volatile unsigned long *p = (volatile unsigned long *)pageAddr[i];
    if (p[0] != mark(i, 0)) {
      bad++;
    }
    if (p[WORDS_PER_PAGE - 1] != mark(i, WORDS_PER_PAGE - 1)) {
      bad++;
    }
  }
  return bad;
}

/* `H<id> <tag> <64-bit value>` */
static void say(const char *tag, unsigned long v) {
  unsigned long n = 0;
  out[n++] = 'H';
  out[n++] = hex(progId);
  out[n++] = ' ';
  n = putstr(n, tag);
  out[n++] = ' ';
  n = put64(n, v);
  sys(SYS_WRITE, (unsigned long)out, n);
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long b0, p1, p2, p3, e1, e2, e3, b1, g, chunk;
  unsigned long bad = 0, zbad = 0, n, i, grew = 0, lastErr = 0;

  (void)probe;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);
  sys(SYS_WHO, 0, 0);

  /* THE BREAK BEFORE ANYTHING IS ALLOCATED. `sbrk(0)` must cost nothing: a
   * malloc that starts by asking where the heap is must not consume a page to
   * find out. The harness compares this against the top of the program's own
   * PT_LOAD segments, read out of the ELF. */
  b0 = sys(SYS_SBRK, 0, 0);
  say("BRK0", b0);

  /* The before-picture patch point: with `EB FE` here the process is alive,
   * running, and has not allocated one byte of heap. The page tables dumped at
   * this moment are what "absent before the allocation" means. */
  heapHoldEarly();

  /* 1. One page, checked to the last byte and written to the last byte. */
  p1 = sys(SYS_SBRK, PAGE, 0);
  say("GOT1", p1);
  if (p1 > ERR_FLOOR) {
    bad += 1000;
  } else {
    if (p1 != b0) {
      bad++;
    }
    zbad += takePage(p1, 1);
  }

  /* 2. Three pages in one call. */
  p2 = sys(SYS_SBRK, 3 * PAGE, 0);
  say("GOT3", p2);
  if (p2 > ERR_FLOOR) {
    bad += 1000;
  } else {
    if (p2 != p1 + PAGE) {
      bad++;
    }
    for (i = 0; i < 3; i++) {
      zbad += takePage(p2 + i * PAGE, 0);
    }
  }

  /* 3. ONE BYTE, which must still round up to a whole page. A kernel that
   *    handed back a byte-granular break would return p2+3*PAGE here and the
   *    next allocation would overlap this one. */
  p3 = sys(SYS_SBRK, 1, 0);
  say("GOT1B", p3);
  if (p3 > ERR_FLOOR) {
    bad += 1000;
  } else {
    if (p3 != p2 + 3 * PAGE) {
      bad++;
    }
    zbad += takePage(p3, 0);
    if (sys(SYS_SBRK, 0, 0) != p3 + PAGE) {
      bad++;
    }
  }

  if (pageCount != SCRIPT_PAGES) {
    bad++;
  }
  bad += verifyAll();

  /* 4. THE KERNEL READS MY HEAP. `elfOwns` walks the live page tables and
   *    refuses a pointer whose page is not present and user-accessible, so the
   *    text below only reaches the console if the mapping is genuinely there
   *    and genuinely mine. */
  if (pageCount > 0) {
    char *h = (char *)pageAddr[0];
    for (i = 0; i < sizeof(msgHeapText); i++) {
      h[i] = msgHeapText[i];
    }
    if (sys(SYS_WRITE, pageAddr[0], sizeof(msgHeapText) - 1) !=
        sizeof(msgHeapText) - 1) {
      bad++;
    }
    /* ...AND THEN PUT THE WHOLE PAGE BACK. The message is 47 bytes, which is
     * six words, not one -- the first version of this program restored only
     * word 0 and the harness read the message text out of the physical frame
     * where it expected a signature. The check found it, and rewriting the
     * whole page is both the fix and a second full-page write. */
    for (i = 0; i < WORDS_PER_PAGE; i++) {
      ((volatile unsigned long *)pageAddr[0])[i] = mark(0, i);
    }
  }

  /* 5. THE OTHER PROCESS RUNS NOW, and it allocates a heap at exactly these
   *    addresses in its own address space. Everything below the yield is a
   *    statement about isolation. */
  sys(SYS_YIELD, 0, 0);
  bad += verifyAll();
  say("AFTERYIELD", bad);

  /* 6. The refusals. Only process 0 exhausts the window: two processes both
   *    filling ~500 pages would take four times as long and prove the same
   *    thing once. Process 1 still exercises both BADARG paths. */
  e1 = sys(SYS_SBRK, 0xFFFFFFFFFFFFFFFFUL, 0); /* a C program's sbrk(-1) */
  say("ERRNEG", e1);
  if (e1 != E_BADARG) {
    bad++;
  }
  e2 = sys(SYS_SBRK, 0x200001UL, 0); /* one byte past the whole window */
  say("ERRBIG", e2);
  if (e2 != E_BADARG) {
    bad++;
  }
  /* The break must not have moved. */
  if (sys(SYS_SBRK, 0, 0) != p3 + PAGE) {
    bad++;
  }

  if (progId == 0) {
    /* 7. GROW UNTIL EVEN ONE PAGE IS REFUSED. Every page of every successful
     *    call is zero-checked and written, so "the window filled up" is not a
     *    claim about a counter -- it is ~500 pages that were each written and
     *    each read back.
     *
     *    THE CHUNK HALVES ON A REFUSAL, and the first version of this program
     *    is why. It asked for 64 pages until that was refused and then asserted
     *    that a ONE-page request was refused too -- which it was not, because
     *    54 pages of room were still there. The program reported BAD 1 on a
     *    kernel that was behaving perfectly. `NOSPACE` means "not this much",
     *    not "nothing more", and the difference is the whole reason the loop
     *    below has to keep asking for less before it can claim the window is
     *    full. */
    chunk = GROW_PAGES;
    for (;;) {
      if (pageCount + chunk > MAX_PAGES) {
        lastErr = 2;
        break;
      }
      g = sys(SYS_SBRK, chunk * PAGE, 0);
      if (g > ERR_FLOOR) {
        lastErr = g;
        if (chunk < 2) {
          break; /* even a single page is refused: the window really is full */
        }
        chunk >>= 1;
        continue;
      }
      grew++;
      for (i = 0; i < chunk; i++) {
        zbad += takePage(g + i * PAGE, 0);
      }
    }
    say("GREW", grew);
    say("FULL", lastErr);
    if (lastErr != E_NOSPACE) {
      bad++;
    }

    /* 8. STILL REFUSED, AND STILL ALIVE. One more single page, so the refusal
     *    is shown to be a property of the address space rather than a one-shot
     *    latch that a second call could clear. */
    e3 = sys(SYS_SBRK, PAGE, 0);
    say("AGAIN", e3);
    if (e3 != E_NOSPACE) {
      bad++;
    }

    /* 9. The break is still readable and still where the last SUCCESSFUL call
     *    left it -- a refused request must not move it. */
    b1 = sys(SYS_SBRK, 0, 0);
    say("BRK1", b1);

    /* 10. And every page this process was ever given still holds what it
     *     wrote, after ~500 more allocations and a trip through another
     *     address space. */
    bad += verifyAll();
  }

  n = 0;
  n = putstr(n, "H");
  out[n++] = hex(progId);
  n = putstr(n, " SUM PAGES ");
  n = put8(n, pageCount);
  n = putstr(n, " ZBAD ");
  n = put8(n, zbad);
  n = putstr(n, " BAD ");
  n = put8(n, bad);
  n = putstr(n, " BRK ");
  n = put64(n, sys(SYS_SBRK, 0, 0));
  sys(SYS_WRITE, (unsigned long)out, n);

  /* The after-picture patch point: with `EB FE` here the process stops with
   * every page it was ever given still mapped and still written. */
  heapHoldLate();

  /* The status carries the page count and the fault count, so a run that
   * allocated the wrong number of pages or found one wrong word exits with a
   * different number -- and derive.py computes the right one from the ELF. */
  sys(SYS_EXIT, exitBase + dataWord + (pageCount << 16) + zbad + bad, 0);

  for (;;) {
    __asm__ volatile("pause");
  }
}
