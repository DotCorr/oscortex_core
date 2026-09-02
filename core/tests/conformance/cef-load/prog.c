/* core/tests/conformance/cef-load/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 *
 *   PLAT.ELF — dlopen("CEF.SO") maps official RO+RX LOADs from the
 *              host plant (ADR-0168). Prints RO / RX filesz pins.
 *              PIXEL from official cef_initialize. ASK refused.
 *   ASK.ELF  — same bytes; dlopen is BadArg.
 *
 * Anti-vacuity: RO/RX must match official readelf sizes; the 12 KiB
 * cef-wire slice cannot satisfy. Not OnPaint. Not glibc UND.
 * Syscall 29. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define MIX 0x0000000000000168UL
#define CEF_INIT_VA 0x2CE7700UL
#define RO_PIN 42593760UL
#define RX_PIN 189117488UL

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

const char msgStart[] = "CEFLOAD START";
const char nameCef[] = "CEF.SO";

char out[160];

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

static unsigned long load64(unsigned long p) {
  return *(volatile unsigned long *)p;
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long va, bad, bias, pixel;
  unsigned long phoff, phnum, i, ph, ptype, flags;
  unsigned long vaddr, filesz, ro, rx;

  (void)probe;
  bad = 0;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  va = sys(SYS_DLOPEN, (unsigned long)nameCef, sizeof(nameCef) - 1);
  say("ASKED", va);

  if (va > ERR_FLOOR) {
    if (va != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    bias = va - CEF_INIT_VA;
    pixel = load64(va);
    say("PIXEL", pixel ^ MIX);

    /* Walk mapped PHDRs for official RO / RX filesz. */
    phoff = load64(bias + 32);
    phnum = load64(bias + 56) & 0xffffUL;
    ro = 0;
    rx = 0;
    i = 0;
    while (i < phnum) {
      ph = bias + phoff + i * 56UL;
      ptype = load64(ph) & 0xffffffffUL;
      flags = (load64(ph) >> 32) & 0xffffffffUL;
      if (ptype == 1UL) {
        vaddr = load64(ph + 16);
        filesz = load64(ph + 32);
        if ((flags & 1UL) != 0) {
          rx = filesz;
          (void)vaddr;
        } else if ((flags & 2UL) == 0) {
          ro = filesz;
        }
      }
      i++;
    }
    say("RO", ro);
    say("RX", rx);
    if (ro != RO_PIN) {
      bad++;
    }
    if (rx != RX_PIN) {
      bad++;
    }
    /* 12 KiB slice cannot match these pins. */
    if (ro <= 12288UL || rx <= 12288UL) {
      bad++;
    }
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1680000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
