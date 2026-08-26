/* core/tests/conformance/m19-argv/prog.c — M19's test program: a `wc`.
 *
 * WHY A `wc` AND NOT A PROGRAM THAT PRINTS ITS ARGUMENTS
 * ---------------------------------------------------------------------------
 * A program that prints argv proves that argv reached it. It does not prove
 * that argv is USABLE — that the pointers are readable for their whole length,
 * that the strings are NUL-terminated where the vector says they end, that one
 * of them can be handed to open() unchanged. A `wc` does: every one of its
 * answers is a function of a file whose NAME came in on argv and of a MODE that
 * came in on argv, and the harness computes the same answers on the host from
 * the file it wrote.
 *
 * THE CONTRACT THIS FILE IS WRITTEN AGAINST IS C's, NOT THIS OS's.
 * There is no `_start` here. There is `int main(int argc, char **argv)`, and
 * core/user/libc/start.c is what calls it. That is the entire point of M19: a C
 * program written the way C programs are written is a program this operating
 * system runs.
 *
 * THE NEGATIVE CONTROL IS A SECOND BUILD OF THIS SOURCE (-DWC_NEG=1), and it is
 * chosen to control for exactly the thing M19 claims. The control IGNORES argv
 * and counts WC_NEG_FILE instead — which is precisely how every test program on
 * this operating system behaved before M19, with its input compiled into it. So
 * `run WCN.ELF BETA.TXT` prints ALPHA.TXT's counts, derive.py predicts that,
 * and run.sh requires the control to print the WRONG file's answer and a
 * DIFFERENT exit status. A kernel that built a plausible-looking stack that the
 * program could not actually use would produce the control's output from the
 * real build, and this is the check that would see it.
 *
 * MALLOC EVERYWHERE THAT MATTERS, AND THAT IS THE POINT OF M20.
 * ---------------------------------------------------------------------------
 * m19-argv's copy of this program carried the sentence "NO malloc ANYWHERE:
 * `sbrk` is refused unless a PROCESS is live and `run <name>` does not create
 * one". That was true and it was the defect: `run` gave a program argv and no
 * heap, `proc run` gave it a heap and no argv, and no program on this machine
 * could have both. ADR-0027 unifies the two launch paths so that `run` creates
 * a process, and this program is what proves it.
 *
 * THE TWO HALVES ARE NOT TESTED SIDE BY SIDE, THEY ARE TESTED THROUGH EACH
 * OTHER. The read buffer is not a static array any more -- it is `malloc`ed,
 * and it is the buffer every byte of every file is counted through. So the
 * counts this program prints are wrong, or absent, unless BOTH halves worked:
 * the file name came in on argv, and the memory it was read into came from the
 * heap. A kernel that gave argv but refused `sbrk` prints `WC HEAP FAIL` and
 * exits 5; a kernel that gave a heap but no argv cannot find a file to open.
 * Neither can produce the counts derive.py computes on the host.
 */

#include "oslibc.h"

#ifndef WC_NEG
#define WC_NEG 0
#endif

/* The file the negative control uses instead of the one it was told to use.
 * run.sh reads this string back out of THIS SOURCE and requires the control's
 * output to be the counts for it. */
#define WC_NEG_FILE "ALPHA.TXT"

/* Read out of the ELF by derive.py so the harness's arithmetic comes from the
 * binary rather than from a number typed twice, exactly as malloc.c's
 * `mallocHdrBytes` is. */
volatile const unsigned long wcNeg = WC_NEG;
volatile const unsigned long wcChunk = 173;

/* An INITIALISED mutable global, so the R+W PT_LOAD has file bytes as well as
 * .bss. Without it every mutable object here would be .bss, p_filesz would be
 * zero, and the loader's copy path for the data segment would never run --
 * which would make this program a weaker test of elf.dart than m15's. */
volatile unsigned long wcMarker = 0x0C0FFEE0UL;

/* The counting modes, and the flag that selects each. */
#define MODE_ALL 0
#define MODE_LINES 1
#define MODE_WORDS 2
#define MODE_CHARS 3

/* THE READ BUFFER LIVES ON THE HEAP. In m19 this was `static unsigned char
 * buf[512]`. Making it heap memory is what couples the two halves: every byte
 * counted below passes through memory that `malloc` -- and therefore `sbrk`,
 * and therefore a live process slot -- had to provide. */
static unsigned char *buf;

/* What the heap phase found, printed as one line and folded into the exit
 * status so a run that allocated nothing cannot exit like a run that did. */
static unsigned long heapOk;
static unsigned long heapZero;
static unsigned long heapReuse;

static int isSpaceByte(unsigned char c) {
  if (c == ' ') return 1;
  if (c == '\n') return 1;
  if (c == '\t') return 1;
  if (c == '\r') return 1;
  if (c == '\v') return 1;
  if (c == '\f') return 1;
  return 0;
}

/* The derived exit status: a function of all three counts, so a program that
 * got the lines right and the words wrong exits differently from one that got
 * both right. derive.py computes the same expression. */
static unsigned long statusOf(unsigned long l, unsigned long w,
                              unsigned long c) {
  return ((l * 31UL + w) * 31UL + c) & 0xFFUL;
}

int main(int argc, char **argv) {
  int mode = MODE_ALL;
  int first = 1;
  int i;
  unsigned long tl = 0, tw = 0, tc = 0;
  int files = 0;

  /* THE STACK, AS THE PROGRAM SEES IT. Printed so a human reading a serial
   * capture can see it; NOT trusted by run.sh, which reads the same words out
   * of guest physical memory with QEMU's monitor and compares. A program is not
   * a witness to its own stack. */
  printf("WC ARGC %d RSP %x VEC %x\n", argc,
         (int)(unsigned long)((char **)argv - 1), (int)(unsigned long)argv);
  for (i = 0; i < argc; i++) {
    printf("WC ARGV %d %x %d %s\n", i, (int)(unsigned long)argv[i],
           (int)strlen(argv[i]), argv[i]);
  }
  /* argv[argc] must be NULL and envp[0] must be NULL: the two terminators the
   * ABI puts there. Printed as numbers so a non-zero one is visible. */
  printf("WC TERM %x %x\n", (int)(unsigned long)argv[argc],
         (int)(unsigned long)argv[argc + 1]);

  /* -----------------------------------------------------------------------
   * THE HEAP PHASE. This runs BEFORE any file is opened, because the buffer it
   * produces is the one every file is read through -- there is nothing to fall
   * back to and nothing here is optional.
   *
   * `malloc` returning NULL is the pre-M20 kernel's answer: `sbrk` refused
   * because no process was live. That is reported by name, with the kernel's
   * own refusal value, and exits 5 -- a status no successful run can produce.
   * --------------------------------------------------------------------- */
  {
    unsigned long k;
    unsigned char *probe;
    unsigned long firstAddr;

    buf = (unsigned char *)malloc((size_t)wcChunk);
    if (buf == NULL) {
      printf("WC HEAP FAIL SBRK %x\n", (int)sbrk_last_error());
      return 5;
    }
    heapOk = 1;

    /* EVERY BYTE IS WRITTEN AND READ BACK. A pointer that is merely non-NULL
     * proves nothing; memory that holds what was put in it does. */
    for (k = 0; k < wcChunk; k++) {
      buf[k] = (unsigned char)((k * 7UL + 3UL) & 0xFFUL);
    }
    for (k = 0; k < wcChunk; k++) {
      if (buf[k] != (unsigned char)((k * 7UL + 3UL) & 0xFFUL)) {
        heapZero++;
      }
    }

    /* THE ALLOCATOR IS A REAL ALLOCATOR: a block freed and re-requested at the
     * same size comes back at the same address. Measured, not claimed -- and
     * the -DLIBC_FREE_ENABLED=0 control build prints REUSE 0 here. */
    probe = (unsigned char *)malloc((size_t)wcChunk);
    if (probe == NULL) {
      printf("WC HEAP FAIL PROBE %x\n", (int)sbrk_last_error());
      return 5;
    }
    firstAddr = (unsigned long)probe;
    free(probe);
    probe = (unsigned char *)malloc((size_t)wcChunk);
    /* The NULL guard matters: `free(NULL)` is a no-op, so two failed probes
     * would both be 0 and would report REUSE 1 -- a false pass on exactly the
     * kernel this harness exists to catch. */
    if (probe == NULL) {
      printf("WC HEAP FAIL PROBE2 %x\n", (int)sbrk_last_error());
      return 5;
    }
    if ((unsigned long)probe == firstAddr) {
      heapReuse = 1;
    }
    free(probe);

    printf("WC HEAP PTR %x BAD %d REUSE %d KERNB %x BLOCKS %d\n",
           (int)(unsigned long)buf, (int)heapZero, (int)heapReuse,
           (int)malloc_bytes_from_kernel(), (int)malloc_free_blocks());
  }

  if (argc < 2) {
    printf("WC USAGE wc [-l|-w|-c|-a] FILE...\n");
    return 2;
  }

  if (argv[1][0] == '-') {
    if (strcmp(argv[1], "-l") == 0) {
      mode = MODE_LINES;
    } else if (strcmp(argv[1], "-w") == 0) {
      mode = MODE_WORDS;
    } else if (strcmp(argv[1], "-c") == 0) {
      mode = MODE_CHARS;
    } else if (strcmp(argv[1], "-a") == 0) {
      mode = MODE_ALL;
    } else {
      printf("WC BADFLAG %s\n", argv[1]);
      return 3;
    }
    first = 2;
    if (argc < 3) {
      printf("WC USAGE wc [-l|-w|-c|-a] FILE...\n");
      return 2;
    }
  }

  for (i = first; i < argc; i++) {
    const char *name = argv[i];
    RFILE *f;
    unsigned long lines = 0, words = 0, chars = 0;
    int inWord = 0;
    size_t got;

#if WC_NEG
    /* THE NEGATIVE CONTROL: the name it was given is thrown away and the name
     * that was compiled in is used instead. This is pre-M19 behaviour. */
    name = WC_NEG_FILE;
#endif

    f = rfopen(name);
    if (f == NULL) {
      printf("WC OPEN %s REFUSED %x\n", argv[i], (int)rf_last_error());
      return 4;
    }
    for (;;) {
      size_t k;
      got = rfread(buf, (size_t)wcChunk, f);
      if (got == 0) {
        break;
      }
      for (k = 0; k < got; k++) {
        unsigned char c = buf[k];
        chars++;
        if (c == '\n') {
          lines++;
        }
        if (isSpaceByte(c)) {
          inWord = 0;
        } else if (inWord == 0) {
          inWord = 1;
          words++;
        }
      }
    }
    rfclose(f);
    files++;
    tl += lines;
    tw += words;
    tc += chars;

    if (mode == MODE_LINES) {
      printf("WC %d %s\n", (int)lines, argv[i]);
    } else if (mode == MODE_WORDS) {
      printf("WC %d %s\n", (int)words, argv[i]);
    } else if (mode == MODE_CHARS) {
      printf("WC %d %s\n", (int)chars, argv[i]);
    } else {
      printf("WC %d %d %d %s\n", (int)lines, (int)words, (int)chars, argv[i]);
    }
  }

  if (files > 1) {
    printf("WC TOTAL %d %d %d\n", (int)tl, (int)tw, (int)tc);
  }
  printf("WC MODE %d FILES %d STATUS %x\n", mode, files,
         (int)statusOf(tl, tw, tc));
  return (int)statusOf(tl, tw, tc);
}
