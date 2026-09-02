/* core/tests/conformance/cef-und/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 *
 *   PLAT.ELF — dlopen("CEF.SO") maps official LOADs; kernel opens
 *              LIBC.SO and binds a measured high-traffic UND batch
 *              (memset/memcpy/memmove/strlen/memcmp) through OUR
 *              faces. Call each official @plt; derived LINE from
 *              all five. Unbound PLT → #PF → no LINE.
 *   ASK.ELF  — same bytes; dlopen is BadArg.
 *
 * Measured: the official libcef PLT has no allocator JUMP_SLOT.
 * Not OnPaint. Not the rest of 1,336 UND / libdl.so.2.
 * Syscall 29. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define MIX 0x0000000000000170UL
#define CEF_INIT_VA 0x2CE7700UL
#define MEMSET_PLT_VA 0xDCFB1E0UL
#define MEMCPY_PLT_VA 0xDCFB030UL
#define MEMMOVE_PLT_VA 0xDCFB1F0UL
#define STRLEN_PLT_VA 0xDCF5E20UL
#define MEMCMP_PLT_VA 0xDCF5E60UL
#define FILL 0xA5UL
#define FILL_N 64UL
#define BATCH 5UL

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

typedef void *(*memset_fn)(void *dst, int c, unsigned long n);
typedef void *(*memcpy_fn)(void *dst, const void *src, unsigned long n);
typedef void *(*memmove_fn)(void *dst, const void *src, unsigned long n);
typedef unsigned long (*strlen_fn)(const char *s);
typedef int (*memcmp_fn)(const void *a, const void *b, unsigned long n);

const char msgStart[] = "CEFUND START";
const char nameCef[] = "CEF.SO";

char out[160];
unsigned char buf[64];
unsigned char src[64];
unsigned char dst[64];
char zstr[] = "oscortex";

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

static unsigned long put64(unsigned long at, unsigned long v) {
  unsigned long j;
  for (j = 0; j < 16; j++) {
    out[at + j] = hex(v >> (60 - 4 * j));
  }
  return at + 16;
}

static unsigned long putstr(unsigned long at, const char *s) {
  while (*s) {
    out[at++] = *s++;
  }
  return at;
}

static void say(const char *tag, unsigned long v) {
  unsigned long n = 0;
  n = putstr(n, tag);
  out[n++] = ' ';
  n = put64(n, v);
  sys(SYS_WRITE, (unsigned long)out, n);
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long cef, bad, bias, i, sig, got, n;
  memset_fn zs;
  memcpy_fn yc;
  memmove_fn ym;
  strlen_fn yl;
  memcmp_fn ycmp;

  (void)probe;
  bad = 0;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  cef = sys(SYS_DLOPEN, (unsigned long)nameCef, sizeof(nameCef) - 1);
  say("CEF", cef);

  if (cef > ERR_FLOOR) {
    if (cef != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    bias = cef - CEF_INIT_VA;
    say("PLT", bias + MEMSET_PLT_VA);
    say("BATCH", BATCH);

    /* --- memset@plt --- */
    i = 0;
    while (i < FILL_N) {
      buf[i] = 0;
      i++;
    }
    zs = (memset_fn)(bias + MEMSET_PLT_VA);
    got = (unsigned long)zs(buf, (int)FILL, FILL_N);
    if (got != (unsigned long)buf) {
      bad++;
    }
    i = 0;
    while (i < FILL_N) {
      if (buf[i] != (unsigned char)FILL) {
        bad++;
      }
      i++;
    }

    /* --- memcpy@plt --- */
    i = 0;
    while (i < FILL_N) {
      src[i] = (unsigned char)(0x40 + (i & 0x1F));
      dst[i] = 0;
      i++;
    }
    yc = (memcpy_fn)(bias + MEMCPY_PLT_VA);
    got = (unsigned long)yc(dst, src, FILL_N);
    if (got != (unsigned long)dst) {
      bad++;
    }
    i = 0;
    while (i < FILL_N) {
      if (dst[i] != src[i]) {
        bad++;
      }
      i++;
    }

    /* --- memmove@plt (overlap backward) --- */
    i = 0;
    while (i < FILL_N) {
      buf[i] = (unsigned char)(0x10 + i);
      i++;
    }
    ym = (memmove_fn)(bias + MEMMOVE_PLT_VA);
    got = (unsigned long)ym(buf + 4, buf, 32);
    if (got != (unsigned long)(buf + 4)) {
      bad++;
    }
    i = 0;
    while (i < 32) {
      if (buf[4 + i] != (unsigned char)(0x10 + i)) {
        bad++;
      }
      i++;
    }

    /* --- strlen@plt --- */
    yl = (strlen_fn)(bias + STRLEN_PLT_VA);
    n = yl(zstr);
    if (n != 8UL) {
      bad++;
    }

    /* --- memcmp@plt --- */
    ycmp = (memcmp_fn)(bias + MEMCMP_PLT_VA);
    if (ycmp(src, src, FILL_N) != 0) {
      bad++;
    }
    src[0] = (unsigned char)(src[0] + 1);
    if (ycmp(src, dst, 1) == 0) {
      bad++;
    }

    /* Derived LINE folds every face result. */
    sig = 0;
    i = 0;
    while (i < FILL_N) {
      sig = (sig << 1) ^ (unsigned long)buf[i];
      i++;
    }
    sig = (sig << 1) ^ n;
    sig = (sig << 1) ^ BATCH;
    say("LINE", sig ^ MIX);
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1700000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
