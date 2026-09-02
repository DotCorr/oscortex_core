/* core/tests/conformance/cef-dl/prog.c
 *
 * ADR-0174: named PLAT.ELF carries DT_NEEDED of the real Linux
 * soname `libdl.so.2` (not LIBDL.SO). Walks DT_NEEDED / DT_STRTAB,
 * dlopens that string, and calls dl_fn through OUR face planted as
 * FAT LIBDL.SO. Kernel resolves via planted SOMAP.TXT
 * (`libdl.so.2=LIBDL.SO`). Missing SOMAP cannot invent LINE.
 * ASK.ELF of the same bytes is REFUSED 11.
 *
 * Not glibc. Not OnPaint. Not the rest of UND. Syscall 29.
 * 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_NOTFOUND 0xFFFFFFFFFFFFFFF9UL

#define MARK_D 0xA1740000C0DE0001UL
#define MIX 0x00C10E0000001740UL

#define DT_NULL 0
#define DT_NEEDED 1
#define DT_STRTAB 5

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

typedef unsigned long (*face_fn)(unsigned long buf, unsigned long len);

const char msgStart[] = "CEFDL START";
const char msgVia[] = "VIA LIBDL.SO.2";
const char wantName[] = "libdl.so.2";

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

static unsigned long nameeq(const char *a, const char *b, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (a[i] != b[i]) {
      return 0;
    }
  }
  return a[n] == 0 ? 1 : 0;
}

/* Walk _DYNAMIC. The NEEDED string must be libdl.so.2 — inventing
 * LINE from a hardcoded LIBDL.SO dlopen fails the harness. */
static unsigned long loadNeeded(void) {
  unsigned long *dyn;
  unsigned long strtab;
  unsigned long i;
  unsigned long tag;
  unsigned long val;
  unsigned long bad;
  unsigned long va;
  unsigned long got;
  face_fn f;
  const char *name;
  unsigned long nlen;

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
  i = 0;
  while (i < 64) {
    tag = dyn[i * 2];
    val = dyn[i * 2 + 1];
    if (tag == DT_NULL) {
      break;
    }
    if (tag == DT_NEEDED) {
      name = (const char *)(strtab + val);
      nlen = namelen(name);
      say("NEED", 1);
      if (nameeq(name, wantName, sizeof(wantName) - 1) < 1) {
        say("BADN", nlen);
        return 1;
      }
      va = sys(SYS_DLOPEN, (unsigned long)name, nlen);
      say("ASKED", va);
      if (va > ERR_FLOOR) {
        say("MISS", va);
        if (va != E_NOTFOUND) {
          bad = bad + 1;
        }
        return bad;
      }
      f = (face_fn)va;
      got = f((unsigned long)msgVia, sizeof(msgVia) - 1);
      if (got != MARK_D) {
        bad = bad + 1;
      }
      say("LINE", got ^ MIX);
      return bad;
    }
    i = i + 1;
  }
  return 1;
}

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long bad;

  (void)probe;
  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);
  bad = loadNeeded();
  say("BAD", bad);
  sys(SYS_EXIT, 0xA1740000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
