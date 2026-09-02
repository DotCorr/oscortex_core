/* core/tests/conformance/plat-need3/prog.c
 *
 * Named PLAT.ELF with PT_DYNAMIC and eight DT_NEEDED (LIBC.SO,
 * LIBM.SO, LIBDL.SO, LIBPT.SO, LIBGB.SO, LIBGO.SO, LIBNP.SO,
 * LIBNS.SO). Walks DT_NEEDED / DT_STRTAB, dlopens each FAT name,
 * and calls through the mapped face. LINE1..LINE8 are MARK ^ MIX
 * from write / need_fn / dl_fn / pt_fn / gb_fn / go_fn / np_fn /
 * ns_fn. ASK.ELF is the same bytes and is REFUSED 11. Missing
 * LIBNS.SO cannot invent LINE8. ADR-0162. Satisfies 8 of 32
 * CEF DT_NEEDED stand-ins. Not glibc. Not CEF OnPaint.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_NOTFOUND 0xFFFFFFFFFFFFFFF9UL

#define MARK_C 0xA1520000C0DE0001UL
#define MIX1 0x00C10E0000001520UL
#define MARK_M 0xA1570000C0DE0001UL
#define MIX2 0x00C10E0000001570UL
#define MARK_D 0xA1600000C0DE0001UL
#define MIX3 0x00C10E0000001600UL
#define MARK_P 0xA1600000C0DE0002UL
#define MIX4 0x00C10E0000001601UL
#define MARK_GB 0xA1620000C0DE0001UL
#define MIX5 0x00C10E0000001620UL
#define MARK_GO 0xA1620000C0DE0002UL
#define MIX6 0x00C10E0000001621UL
#define MARK_NP 0xA1620000C0DE0003UL
#define MIX7 0x00C10E0000001622UL
#define MARK_NS 0xA1620000C0DE0004UL
#define MIX8 0x00C10E0000001623UL

#define DT_NULL 0
#define DT_NEEDED 1
#define DT_STRTAB 5

/* ld provides _DYNAMIC for ET_EXEC with PT_DYNAMIC. The ELF file
 * header is not in a LOAD (page-aligned first segment), so walking
 * SELF_BASE phdrs would read garbage. ADR-0162. */
extern unsigned long _DYNAMIC[];

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

typedef unsigned long (*write_fn)(const void *buf, unsigned long len);
typedef unsigned long (*face_fn)(unsigned long buf, unsigned long len);

const char msgStart[] = "NEED3 START";
const char msgViaC[] = "VIA LIBC";
const char msgViaM[] = "VIA LIBM";
const char msgViaD[] = "VIA LIBDL";
const char msgViaP[] = "VIA LIBPT";
const char msgViaGB[] = "VIA LIBGB";
const char msgViaGO[] = "VIA LIBGO";
const char msgViaNP[] = "VIA LIBNP";
const char msgViaNS[] = "VIA LIBNS";

char out[128];

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

static unsigned long namelen(const char *s) {
  unsigned long n = 0;
  while (s[n]) {
    n = n + 1;
  }
  return n;
}

static void faceVia(unsigned long idx, const char **via, unsigned long *mark,
                    unsigned long *mix, const char **line) {
  if (idx == 1) {
    *via = msgViaM;
    *mark = MARK_M;
    *mix = MIX2;
    *line = "LINE2";
  } else if (idx == 2) {
    *via = msgViaD;
    *mark = MARK_D;
    *mix = MIX3;
    *line = "LINE3";
  } else if (idx == 3) {
    *via = msgViaP;
    *mark = MARK_P;
    *mix = MIX4;
    *line = "LINE4";
  } else if (idx == 4) {
    *via = msgViaGB;
    *mark = MARK_GB;
    *mix = MIX5;
    *line = "LINE5";
  } else if (idx == 5) {
    *via = msgViaGO;
    *mark = MARK_GO;
    *mix = MIX6;
    *line = "LINE6";
  } else if (idx == 6) {
    *via = msgViaNP;
    *mark = MARK_NP;
    *mix = MIX7;
    *line = "LINE7";
  } else {
    *via = msgViaNS;
    *mark = MARK_NS;
    *mix = MIX8;
    *line = "LINE8";
  }
}

/* Walk _DYNAMIC. Names come from DT_NEEDED / DT_STRTAB —
 * inventing LINE8 without the eighth FAT file must fail. */
static unsigned long loadNeeded(void) {
  unsigned long *dyn;
  unsigned long strtab;
  unsigned long i;
  unsigned long tag;
  unsigned long val;
  unsigned long idx;
  unsigned long bad;
  unsigned long va;
  unsigned long got;
  write_fn w;
  face_fn f;
  const char *name;
  const char *via;
  const char *line;
  unsigned long mark;
  unsigned long mix;

  bad = 0;
  dyn = _DYNAMIC;
  strtab = 0;
  i = 0;
  while (i < 64) {
    tag = dyn[i * 2];
    val = dyn[i * 2 + 1];
    if (tag == DT_NULL) {
      break;
    }
    if (tag == DT_STRTAB) {
      strtab = val;
    }
    i = i + 1;
  }
  if (strtab < 0x10000000UL || strtab >= 0x10200000UL) {
    return 1;
  }
  idx = 0;
  i = 0;
  while (i < 64) {
    tag = dyn[i * 2];
    val = dyn[i * 2 + 1];
    if (tag == DT_NULL) {
      break;
    }
    if (tag == DT_NEEDED) {
      name = (const char *)(strtab + val);
      va = sys(SYS_DLOPEN, (unsigned long)name, namelen(name));
      say("ASKED", va);
      if (va > ERR_FLOOR) {
        say("NEED", idx);
        say("MISS", va);
        if (va != E_NOTFOUND) {
          bad = bad + 1;
        }
        /* Missing later NEEDED: no derived line for that slot. */
        return bad;
      }
      if (idx == 0) {
        w = (write_fn)va;
        got = w(msgViaC, sizeof(msgViaC) - 1);
        if (got != MARK_C) {
          bad = bad + 1;
        }
        say("LINE1", got ^ MIX1);
      } else {
        faceVia(idx, &via, &mark, &mix, &line);
        f = (face_fn)va;
        got = f((unsigned long)via, namelen(via));
        if (got != mark) {
          bad = bad + 1;
        }
        say(line, got ^ mix);
      }
      idx = idx + 1;
    }
    i = i + 1;
  }
  say("NEED", idx);
  if (idx < 8) {
    bad = bad + 1;
  }
  return bad;
}

void progMain(void);

void progMain(void) {
  unsigned long bad;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);
  bad = loadNeeded();
  say("BAD", bad);
  sys(SYS_EXIT, 0xA1620000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
