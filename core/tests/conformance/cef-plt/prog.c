/* core/tests/conformance/cef-plt/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 *
 *   PLAT.ELF — dlopen("CEF.SO") maps official LOADs; kernel opens
 *              LIBC.SO, plants its memset over official memset@plt.
 *              Call through that PLT address; derived LINE from the
 *              filled buffer. Unbound PLT → #PF → no LINE.
 *   ASK.ELF  — same bytes; dlopen is BadArg.
 *
 * Not OnPaint. Not the rest of 1,336 UND. Syscall 29. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define MIX 0x0000000000000169UL
#define CEF_INIT_VA 0x2CE7700UL
#define MEMSET_PLT_VA 0xDCFB1E0UL
#define FILL 0xA5UL
#define FILL_N 64UL

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

typedef void *(*memset_plt_fn)(void *dst, int c, unsigned long n);

const char msgStart[] = "CEFPLT START";
const char nameCef[] = "CEF.SO";

char out[160];
unsigned char buf[64];

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
  unsigned long cef, bad, bias, plt, i, sig, got;
  memset_plt_fn mp;

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
    plt = bias + MEMSET_PLT_VA;
    say("PLT", plt);

    i = 0;
    while (i < FILL_N) {
      buf[i] = 0;
      i++;
    }
    /* Call through the official CEF memset@plt address. Unbound → #PF. */
    mp = (memset_plt_fn)plt;
    got = (unsigned long)mp(buf, (int)FILL, FILL_N);
    if (got != (unsigned long)buf) {
      bad++;
    }
    sig = 0;
    i = 0;
    while (i < FILL_N) {
      if (buf[i] != (unsigned char)FILL) {
        bad++;
      }
      sig = (sig << 1) ^ (unsigned long)buf[i];
      i++;
    }
    say("LINE", sig ^ MIX);
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1690000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
