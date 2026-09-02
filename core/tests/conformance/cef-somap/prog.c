/* core/tests/conformance/cef-somap/prog.c
 *
 * ADR-0176: named PLAT.ELF carries DT_NEEDED of all 32 official CEF
 * Linux sonames (libdl.so.2 … ld-linux-x86-64.so.2). Walks
 * DT_NEEDED / DT_STRTAB, dlopens each real string, and calls through
 * OUR plat-need5 faces planted as FAT LIB*.SO. Kernel resolves via
 * planted SOMAP.TXT. Missing one alias refuses that name.
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

#define MARK_C 0xA1520000C0DE0001UL
#define MIX_C 0x00C10E0000001520UL
#define MARK_M 0xA1570000C0DE0001UL
#define MIX_M 0x00C10E0000001570UL
#define MARK_D 0xA1600000C0DE0001UL
#define MIX_D 0x00C10E0000001600UL
#define MARK_P 0xA1600000C0DE0002UL
#define MIX_P 0x00C10E0000001601UL
#define MARK_GB 0xA1620000C0DE0001UL
#define MIX_GB 0x00C10E0000001620UL
#define MARK_GO 0xA1620000C0DE0002UL
#define MIX_GO 0x00C10E0000001621UL
#define MARK_NP 0xA1620000C0DE0003UL
#define MIX_NP 0x00C10E0000001622UL
#define MARK_NS 0xA1620000C0DE0004UL
#define MIX_NS 0x00C10E0000001623UL
#define MARK_NU 0xA1630000C0DE0001UL
#define MIX_NU 0x00C10E0000001630UL
#define MARK_SM 0xA1630000C0DE0002UL
#define MIX_SM 0x00C10E0000001631UL
#define MARK_DB 0xA1630000C0DE0003UL
#define MIX_DB 0x00C10E0000001632UL
#define MARK_GI 0xA1630000C0DE0004UL
#define MIX_GI 0x00C10E0000001633UL
#define MARK_AT 0xA1630000C0DE0005UL
#define MIX_AT 0x00C10E0000001634UL
#define MARK_AB 0xA1630000C0DE0006UL
#define MIX_AB 0x00C10E0000001635UL
#define MARK_CU 0xA1630000C0DE0007UL
#define MIX_CU 0x00C10E0000001636UL
#define MARK_X1 0xA1630000C0DE0008UL
#define MIX_X1 0x00C10E0000001637UL
#define MARK_XC 0xA1650000C0DE0001UL
#define MIX_XC 0x00C10E0000001650UL
#define MARK_XD 0xA1650000C0DE0002UL
#define MIX_XD 0x00C10E0000001651UL
#define MARK_XE 0xA1650000C0DE0003UL
#define MIX_XE 0x00C10E0000001652UL
#define MARK_XF 0xA1650000C0DE0004UL
#define MIX_XF 0x00C10E0000001653UL
#define MARK_XR 0xA1650000C0DE0005UL
#define MIX_XR 0x00C10E0000001654UL
#define MARK_GM 0xA1650000C0DE0006UL
#define MIX_GM 0x00C10E0000001655UL
#define MARK_EX 0xA1650000C0DE0007UL
#define MIX_EX 0x00C10E0000001656UL
#define MARK_XB 0xA1650000C0DE0008UL
#define MIX_XB 0x00C10E0000001657UL
#define MARK_XK 0xA1650000C0DE0009UL
#define MIX_XK 0x00C10E0000001658UL
#define MARK_CA 0xA1650000C0DE000AUL
#define MIX_CA 0x00C10E0000001659UL
#define MARK_PG 0xA1650000C0DE000BUL
#define MIX_PG 0x00C10E000000165AUL
#define MARK_UD 0xA1650000C0DE000CUL
#define MIX_UD 0x00C10E000000165BUL
#define MARK_AS 0xA1650000C0DE000DUL
#define MIX_AS 0x00C10E000000165CUL
#define MARK_AP 0xA1650000C0DE000EUL
#define MIX_AP 0x00C10E000000165DUL
#define MARK_GC 0xA1650000C0DE000FUL
#define MIX_GC 0x00C10E000000165EUL
#define MARK_LD 0xA1650000C0DE0010UL
#define MIX_LD 0x00C10E000000165FUL

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

typedef unsigned long (*write_fn)(const void *buf, unsigned long len);
typedef unsigned long (*face_fn)(unsigned long buf, unsigned long len);

const char msgStart[] = "SOMAP START";
const char msgViaLIBDL[] = "VIA LIBDL";
const char msgViaLIBPT[] = "VIA LIBPT";
const char msgViaLIBGB[] = "VIA LIBGB";
const char msgViaLIBGO[] = "VIA LIBGO";
const char msgViaLIBNP[] = "VIA LIBNP";
const char msgViaLIBNS[] = "VIA LIBNS";
const char msgViaLIBNU[] = "VIA LIBNU";
const char msgViaLIBSM[] = "VIA LIBSM";
const char msgViaLIBDB[] = "VIA LIBDB";
const char msgViaLIBGI[] = "VIA LIBGI";
const char msgViaLIBAT[] = "VIA LIBAT";
const char msgViaLIBAB[] = "VIA LIBAB";
const char msgViaLIBCU[] = "VIA LIBCU";
const char msgViaLIBX1[] = "VIA LIBX1";
const char msgViaLIBXC[] = "VIA LIBXC";
const char msgViaLIBXD[] = "VIA LIBXD";
const char msgViaLIBXE[] = "VIA LIBXE";
const char msgViaLIBXF[] = "VIA LIBXF";
const char msgViaLIBXR[] = "VIA LIBXR";
const char msgViaLIBGM[] = "VIA LIBGM";
const char msgViaLIBEX[] = "VIA LIBEX";
const char msgViaLIBXB[] = "VIA LIBXB";
const char msgViaLIBXK[] = "VIA LIBXK";
const char msgViaLIBCA[] = "VIA LIBCA";
const char msgViaLIBPG[] = "VIA LIBPG";
const char msgViaLIBUD[] = "VIA LIBUD";
const char msgViaLIBAS[] = "VIA LIBAS";
const char msgViaLIBM[] = "VIA LIBM";
const char msgViaLIBAP[] = "VIA LIBAP";
const char msgViaLIBGC[] = "VIA LIBGC";
const char msgViaLIBC[] = "VIA LIBC";
const char msgViaLIBLD[] = "VIA LIBLD";

/* Official CEF DT_NEEDED order — must match link order / SOMAP. */
const char want0[] = "libdl.so.2";
const char want1[] = "libpthread.so.0";
const char want2[] = "libglib-2.0.so.0";
const char want3[] = "libgobject-2.0.so.0";
const char want4[] = "libnspr4.so";
const char want5[] = "libnss3.so";
const char want6[] = "libnssutil3.so";
const char want7[] = "libsmime3.so";
const char want8[] = "libdbus-1.so.3";
const char want9[] = "libgio-2.0.so.0";
const char want10[] = "libatk-1.0.so.0";
const char want11[] = "libatk-bridge-2.0.so.0";
const char want12[] = "libcups.so.2";
const char want13[] = "libX11.so.6";
const char want14[] = "libXcomposite.so.1";
const char want15[] = "libXdamage.so.1";
const char want16[] = "libXext.so.6";
const char want17[] = "libXfixes.so.3";
const char want18[] = "libXrandr.so.2";
const char want19[] = "libgbm.so.1";
const char want20[] = "libexpat.so.1";
const char want21[] = "libxcb.so.1";
const char want22[] = "libxkbcommon.so.0";
const char want23[] = "libcairo.so.2";
const char want24[] = "libpango-1.0.so.0";
const char want25[] = "libudev.so.1";
const char want26[] = "libasound.so.2";
const char want27[] = "libm.so.6";
const char want28[] = "libatspi.so.0";
const char want29[] = "libgcc_s.so.1";
const char want30[] = "libc.so.6";
const char want31[] = "ld-linux-x86-64.so.2";

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

static unsigned long nameeq(const char *a, const char *b) {
  unsigned long i = 0;
  while (a[i] && b[i]) {
    if (a[i] != b[i]) {
      return 0;
    }
    i = i + 1;
  }
  return (a[i] == 0 && b[i] == 0) ? 1 : 0;
}

static const char *wantAt(unsigned long idx) {
  if (idx == 0) return want0;
  if (idx == 1) return want1;
  if (idx == 2) return want2;
  if (idx == 3) return want3;
  if (idx == 4) return want4;
  if (idx == 5) return want5;
  if (idx == 6) return want6;
  if (idx == 7) return want7;
  if (idx == 8) return want8;
  if (idx == 9) return want9;
  if (idx == 10) return want10;
  if (idx == 11) return want11;
  if (idx == 12) return want12;
  if (idx == 13) return want13;
  if (idx == 14) return want14;
  if (idx == 15) return want15;
  if (idx == 16) return want16;
  if (idx == 17) return want17;
  if (idx == 18) return want18;
  if (idx == 19) return want19;
  if (idx == 20) return want20;
  if (idx == 21) return want21;
  if (idx == 22) return want22;
  if (idx == 23) return want23;
  if (idx == 24) return want24;
  if (idx == 25) return want25;
  if (idx == 26) return want26;
  if (idx == 27) return want27;
  if (idx == 28) return want28;
  if (idx == 29) return want29;
  if (idx == 30) return want30;
  return want31;
}

static void faceVia(unsigned long idx, const char **via, unsigned long *mark,
                    unsigned long *mix, const char **line) {
  /* CEF order → plat-need5 face. idx 30 is write (libc). */
  if (idx == 0) {
    *via = msgViaLIBDL; *mark = MARK_D; *mix = MIX_D; *line = "LINE1";
  } else if (idx == 1) {
    *via = msgViaLIBPT; *mark = MARK_P; *mix = MIX_P; *line = "LINE2";
  } else if (idx == 2) {
    *via = msgViaLIBGB; *mark = MARK_GB; *mix = MIX_GB; *line = "LINE3";
  } else if (idx == 3) {
    *via = msgViaLIBGO; *mark = MARK_GO; *mix = MIX_GO; *line = "LINE4";
  } else if (idx == 4) {
    *via = msgViaLIBNP; *mark = MARK_NP; *mix = MIX_NP; *line = "LINE5";
  } else if (idx == 5) {
    *via = msgViaLIBNS; *mark = MARK_NS; *mix = MIX_NS; *line = "LINE6";
  } else if (idx == 6) {
    *via = msgViaLIBNU; *mark = MARK_NU; *mix = MIX_NU; *line = "LINE7";
  } else if (idx == 7) {
    *via = msgViaLIBSM; *mark = MARK_SM; *mix = MIX_SM; *line = "LINE8";
  } else if (idx == 8) {
    *via = msgViaLIBDB; *mark = MARK_DB; *mix = MIX_DB; *line = "LINE9";
  } else if (idx == 9) {
    *via = msgViaLIBGI; *mark = MARK_GI; *mix = MIX_GI; *line = "LINE10";
  } else if (idx == 10) {
    *via = msgViaLIBAT; *mark = MARK_AT; *mix = MIX_AT; *line = "LINE11";
  } else if (idx == 11) {
    *via = msgViaLIBAB; *mark = MARK_AB; *mix = MIX_AB; *line = "LINE12";
  } else if (idx == 12) {
    *via = msgViaLIBCU; *mark = MARK_CU; *mix = MIX_CU; *line = "LINE13";
  } else if (idx == 13) {
    *via = msgViaLIBX1; *mark = MARK_X1; *mix = MIX_X1; *line = "LINE14";
  } else if (idx == 14) {
    *via = msgViaLIBXC; *mark = MARK_XC; *mix = MIX_XC; *line = "LINE15";
  } else if (idx == 15) {
    *via = msgViaLIBXD; *mark = MARK_XD; *mix = MIX_XD; *line = "LINE16";
  } else if (idx == 16) {
    *via = msgViaLIBXE; *mark = MARK_XE; *mix = MIX_XE; *line = "LINE17";
  } else if (idx == 17) {
    *via = msgViaLIBXF; *mark = MARK_XF; *mix = MIX_XF; *line = "LINE18";
  } else if (idx == 18) {
    *via = msgViaLIBXR; *mark = MARK_XR; *mix = MIX_XR; *line = "LINE19";
  } else if (idx == 19) {
    *via = msgViaLIBGM; *mark = MARK_GM; *mix = MIX_GM; *line = "LINE20";
  } else if (idx == 20) {
    *via = msgViaLIBEX; *mark = MARK_EX; *mix = MIX_EX; *line = "LINE21";
  } else if (idx == 21) {
    *via = msgViaLIBXB; *mark = MARK_XB; *mix = MIX_XB; *line = "LINE22";
  } else if (idx == 22) {
    *via = msgViaLIBXK; *mark = MARK_XK; *mix = MIX_XK; *line = "LINE23";
  } else if (idx == 23) {
    *via = msgViaLIBCA; *mark = MARK_CA; *mix = MIX_CA; *line = "LINE24";
  } else if (idx == 24) {
    *via = msgViaLIBPG; *mark = MARK_PG; *mix = MIX_PG; *line = "LINE25";
  } else if (idx == 25) {
    *via = msgViaLIBUD; *mark = MARK_UD; *mix = MIX_UD; *line = "LINE26";
  } else if (idx == 26) {
    *via = msgViaLIBAS; *mark = MARK_AS; *mix = MIX_AS; *line = "LINE27";
  } else if (idx == 27) {
    *via = msgViaLIBM; *mark = MARK_M; *mix = MIX_M; *line = "LINE28";
  } else if (idx == 28) {
    *via = msgViaLIBAP; *mark = MARK_AP; *mix = MIX_AP; *line = "LINE29";
  } else if (idx == 29) {
    *via = msgViaLIBGC; *mark = MARK_GC; *mix = MIX_GC; *line = "LINE30";
  } else if (idx == 30) {
    *via = msgViaLIBC; *mark = MARK_C; *mix = MIX_C; *line = "LINE31";
  } else {
    *via = msgViaLIBLD; *mark = MARK_LD; *mix = MIX_LD; *line = "LINE32";
  }
}

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
  const char *want;
  const char *via;
  const char *line;
  unsigned long mark;
  unsigned long mix;

  bad = 0;
  dyn = _DYNAMIC;
  strtab = 0;
  i = 0;
  while (i < 96) {
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
  while (i < 96) {
    tag = dyn[i * 2];
    val = dyn[i * 2 + 1];
    if (tag == DT_NULL) {
      break;
    }
    if (tag == DT_NEEDED) {
      name = (const char *)(strtab + val);
      want = wantAt(idx);
      if (nameeq(name, want) < 1) {
        say("BADN", idx);
        return 1;
      }
      va = sys(SYS_DLOPEN, (unsigned long)name, namelen(name));
      say("ASKED", va);
      if (va > ERR_FLOOR) {
        say("NEED", idx);
        say("MISS", va);
        if (va != E_NOTFOUND) {
          bad = bad + 1;
        }
        return bad;
      }
      faceVia(idx, &via, &mark, &mix, &line);
      if (idx == 30) {
        w = (write_fn)va;
        got = w(via, namelen(via));
      } else {
        f = (face_fn)va;
        got = f((unsigned long)via, namelen(via));
      }
      if (got != mark) {
        bad = bad + 1;
      }
      say(line, got ^ mix);
      idx = idx + 1;
    }
    i = i + 1;
  }
  say("NEED", idx);
  if (idx < 32) {
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
  sys(SYS_EXIT, 0xA1760000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
