/* core/tests/conformance/plat-need/prog.c
 *
 * Named PLAT.ELF with PT_DYNAMIC and two DT_NEEDED (LIBC.SO,
 * LIBM.SO). Walks DT_NEEDED / DT_STRTAB, dlopens each FAT name,
 * and calls through the mapped face. LINE1 is MARK_C ^ MIX1 from
 * write; LINE2 is MARK_M ^ MIX2 from need_fn. ASK.ELF is the same
 * bytes and is REFUSED 11 (PT_DYNAMIC). Missing LIBM.SO cannot
 * invent LINE2. ADR-0157. Not glibc. Not CEF OnPaint.
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

#define DT_NULL 0
#define DT_NEEDED 1
#define DT_STRTAB 5

/* ld provides _DYNAMIC for ET_EXEC with PT_DYNAMIC. The ELF file
 * header is not in a LOAD (page-aligned first segment), so walking
 * SELF_BASE phdrs would read garbage. ADR-0157. */
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
typedef unsigned long (*need_fn)(unsigned long buf, unsigned long len);

const char msgStart[] = "NEED START";
const char msgViaC[] = "VIA LIBC";
const char msgViaM[] = "VIA LIBM";

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

/* Walk _DYNAMIC. Names come from DT_NEEDED / DT_STRTAB —
 * inventing LINE2 without the second FAT file must fail. */
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
  need_fn nf;
  const char *name;

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
        /* Missing second (or later) NEEDED: no derived line. */
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
        nf = (need_fn)va;
        got = nf((unsigned long)msgViaM, sizeof(msgViaM) - 1);
        if (got != MARK_M) {
          bad = bad + 1;
        }
        say("LINE2", got ^ MIX2);
      }
      idx = idx + 1;
    }
    i = i + 1;
  }
  say("NEED", idx);
  if (idx < 2) {
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
  sys(SYS_EXIT, 0xA1570000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
