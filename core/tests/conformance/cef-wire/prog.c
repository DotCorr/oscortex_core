/* core/tests/conformance/cef-wire/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 *
 *   PLAT.ELF — dlopen("CEF.SO") maps the measured official slice
 *              (ADR-0167). Resolves cef_initialize. Walks the
 *              official DT_NEEDED list (must be 32). Applies the
 *              one R_X86_64_64 whose addend is the first 8 official
 *              text bytes. Derived PIXEL / NEED / RELOC lines.
 *   ASK.ELF  — same bytes; dlopen is BadArg.
 *
 * Anti-vacuity: MISS.SO is NotFound; a handwritten xor-eax stub
 * cannot match PIXEL. Not OnPaint. Not full 1.5 GiB libcef.
 * Syscall 29. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL
#define E_NOTFOUND 0xFFFFFFFFFFFFFFF9UL

#define MIX 0x0000000000000167UL
#define CEF_TEXT_VA 0x1000UL
#define R_X86_64_64 1UL

#define DT_NULL 0UL
#define DT_NEEDED 1UL
#define DT_STRTAB 5UL
#define DT_RELA 7UL
#define DT_RELASZ 8UL
#define DT_RELAENT 9UL

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

const char msgStart[] = "CEF START";
const char nameCef[] = "CEF.SO";
const char nameMiss[] = "MISS.SO";

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

static void store64(unsigned long p, unsigned long v) {
  *(volatile unsigned long *)p = v;
}

static unsigned long u8at(unsigned long p) {
  return (unsigned long)(*(volatile unsigned char *)p);
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long va, miss, bad, bias, i;
  unsigned long phoff, phnum, dyn, dynsz;
  unsigned long strtab, rela, relasz, relaent;
  unsigned long needed, nhash, word, pixel, addend;
  unsigned long t, tag, val, off, info;

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
    /* cef_initialize is at SO VA 0x1000; bias recovers the map base. */
    bias = va - CEF_TEXT_VA;

    /* Official first 8 text bytes — handwritten stub cannot match. */
    pixel = load64(va);
    say("PIXEL", pixel ^ MIX);

    /* Walk PT_DYNAMIC on the mapped slice. */
    phoff = load64(bias + 32);
    phnum = load64(bias + 56) & 0xffffUL;
    dyn = 0;
    dynsz = 0;
    i = 0;
    while (i < phnum) {
      unsigned long ph = bias + phoff + i * 56UL;
      if ((load64(ph) & 0xffffffffUL) == 2UL) {
        dyn = bias + load64(ph + 16);
        dynsz = load64(ph + 32);
      }
      i++;
    }
    if (dyn < bias || dynsz < 16UL) {
      bad++;
    }

    strtab = 0;
    rela = 0;
    relasz = 0;
    relaent = 24;
    needed = 0;
    nhash = 0;
    t = 0;
    while (t + 16UL <= dynsz) {
      tag = load64(dyn + t);
      val = load64(dyn + t + 8);
      if (tag == DT_NULL) {
        break;
      }
      if (tag == DT_NEEDED) {
        needed++;
        /* Fold official name bytes into nhash (FNV-ish). */
        off = strtab ? strtab + val : 0;
        if (strtab) {
          unsigned long p = strtab + val;
          unsigned long c;
          while ((c = u8at(p)) != 0) {
            nhash = (nhash * 131UL) + c;
            p++;
          }
        }
      }
      if (tag == DT_STRTAB) {
        strtab = bias + val;
        /* Second pass would be needed for names before STRTAB —
         * re-walk after we know strtab. */
      }
      if (tag == DT_RELA) {
        rela = bias + val;
      }
      if (tag == DT_RELASZ) {
        relasz = val;
      }
      if (tag == DT_RELAENT) {
        relaent = val;
      }
      t += 16UL;
    }

    /* Re-walk NEEDED now that strtab is known. */
    needed = 0;
    nhash = 0;
    t = 0;
    while (t + 16UL <= dynsz) {
      tag = load64(dyn + t);
      val = load64(dyn + t + 8);
      if (tag == DT_NULL) {
        break;
      }
      if (tag == DT_NEEDED) {
        needed++;
        if (strtab) {
          unsigned long p = strtab + val;
          unsigned long c;
          while ((c = u8at(p)) != 0) {
            nhash = (nhash * 131UL) + c;
            p++;
          }
        }
      }
      t += 16UL;
    }
    say("NEED", needed);
    say("NHASH", nhash);
    if (needed != 32UL) {
      bad++;
    }

    /* Apply the one official-addend R_X86_64_64. */
    word = 0;
    if (rela && relasz >= 24UL && relaent >= 24UL) {
      off = load64(rela + 0);
      info = load64(rela + 8);
      addend = load64(rela + 16);
      if ((info & 0xffffffffUL) == R_X86_64_64) {
        store64(bias + off, addend);
        word = load64(bias + off);
        if (word != pixel) {
          bad++;
        }
      } else {
        bad++;
      }
    } else {
      bad++;
    }
    say("RELOC", word ^ MIX);

    miss = sys(SYS_DLOPEN, (unsigned long)nameMiss, sizeof(nameMiss) - 1);
    say("MISS", miss);
    if (miss != E_NOTFOUND) {
      bad++;
    }
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1670000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
