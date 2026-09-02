/* core/tests/conformance/plat-need5/prog.c
 *
 * Named PLAT.ELF with PT_DYNAMIC and thirty-two DT_NEEDED (LIBC.SO
 * .. LIBLD.SO). Walks DT_NEEDED / DT_STRTAB, dlopens each FAT name,
 * and calls through the mapped face. LINE1..LINE32 are MARK ^ MIX.
 * ASK.ELF is the same bytes and is REFUSED 11. Missing LIBLD.SO
 * cannot invent LINE32. ADR-0165. Satisfies 32 of 32 CEF DT_NEEDED
 * stand-ins. Not glibc. Not CEF OnPaint.
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
#define MARK_NU 0xA1630000C0DE0001UL
#define MIX9 0x00C10E0000001630UL
#define MARK_SM 0xA1630000C0DE0002UL
#define MIX10 0x00C10E0000001631UL
#define MARK_DB 0xA1630000C0DE0003UL
#define MIX11 0x00C10E0000001632UL
#define MARK_GI 0xA1630000C0DE0004UL
#define MIX12 0x00C10E0000001633UL
#define MARK_AT 0xA1630000C0DE0005UL
#define MIX13 0x00C10E0000001634UL
#define MARK_AB 0xA1630000C0DE0006UL
#define MIX14 0x00C10E0000001635UL
#define MARK_CU 0xA1630000C0DE0007UL
#define MIX15 0x00C10E0000001636UL
#define MARK_X1 0xA1630000C0DE0008UL
#define MIX16 0x00C10E0000001637UL
#define MARK_XC 0xA1650000C0DE0001UL
#define MIX17 0x00C10E0000001650UL
#define MARK_XD 0xA1650000C0DE0002UL
#define MIX18 0x00C10E0000001651UL
#define MARK_XE 0xA1650000C0DE0003UL
#define MIX19 0x00C10E0000001652UL
#define MARK_XF 0xA1650000C0DE0004UL
#define MIX20 0x00C10E0000001653UL
#define MARK_XR 0xA1650000C0DE0005UL
#define MIX21 0x00C10E0000001654UL
#define MARK_GM 0xA1650000C0DE0006UL
#define MIX22 0x00C10E0000001655UL
#define MARK_EX 0xA1650000C0DE0007UL
#define MIX23 0x00C10E0000001656UL
#define MARK_XB 0xA1650000C0DE0008UL
#define MIX24 0x00C10E0000001657UL
#define MARK_XK 0xA1650000C0DE0009UL
#define MIX25 0x00C10E0000001658UL
#define MARK_CA 0xA1650000C0DE000AUL
#define MIX26 0x00C10E0000001659UL
#define MARK_PG 0xA1650000C0DE000BUL
#define MIX27 0x00C10E000000165AUL
#define MARK_UD 0xA1650000C0DE000CUL
#define MIX28 0x00C10E000000165BUL
#define MARK_AS 0xA1650000C0DE000DUL
#define MIX29 0x00C10E000000165CUL
#define MARK_AP 0xA1650000C0DE000EUL
#define MIX30 0x00C10E000000165DUL
#define MARK_GC 0xA1650000C0DE000FUL
#define MIX31 0x00C10E000000165EUL
#define MARK_LD 0xA1650000C0DE0010UL
#define MIX32 0x00C10E000000165FUL

#define DT_NULL 0
#define DT_NEEDED 1
#define DT_STRTAB 5

/* ld provides _DYNAMIC for ET_EXEC with PT_DYNAMIC. The ELF file
 * header is not in a LOAD (page-aligned first segment), so walking
 * SELF_BASE phdrs would read garbage. ADR-0165. */
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

const char msgStart[] = "NEED5 START";
const char msgViaLIBC[] = "VIA LIBC";
const char msgViaLIBM[] = "VIA LIBM";
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
const char msgViaLIBAP[] = "VIA LIBAP";
const char msgViaLIBGC[] = "VIA LIBGC";
const char msgViaLIBLD[] = "VIA LIBLD";

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
    *via = msgViaLIBM; *mark = MARK_M; *mix = MIX2; *line = "LINE2";
  } else if (idx == 2) {
    *via = msgViaLIBDL; *mark = MARK_D; *mix = MIX3; *line = "LINE3";
  } else if (idx == 3) {
    *via = msgViaLIBPT; *mark = MARK_P; *mix = MIX4; *line = "LINE4";
  } else if (idx == 4) {
    *via = msgViaLIBGB; *mark = MARK_GB; *mix = MIX5; *line = "LINE5";
  } else if (idx == 5) {
    *via = msgViaLIBGO; *mark = MARK_GO; *mix = MIX6; *line = "LINE6";
  } else if (idx == 6) {
    *via = msgViaLIBNP; *mark = MARK_NP; *mix = MIX7; *line = "LINE7";
  } else if (idx == 7) {
    *via = msgViaLIBNS; *mark = MARK_NS; *mix = MIX8; *line = "LINE8";
  } else if (idx == 8) {
    *via = msgViaLIBNU; *mark = MARK_NU; *mix = MIX9; *line = "LINE9";
  } else if (idx == 9) {
    *via = msgViaLIBSM; *mark = MARK_SM; *mix = MIX10; *line = "LINE10";
  } else if (idx == 10) {
    *via = msgViaLIBDB; *mark = MARK_DB; *mix = MIX11; *line = "LINE11";
  } else if (idx == 11) {
    *via = msgViaLIBGI; *mark = MARK_GI; *mix = MIX12; *line = "LINE12";
  } else if (idx == 12) {
    *via = msgViaLIBAT; *mark = MARK_AT; *mix = MIX13; *line = "LINE13";
  } else if (idx == 13) {
    *via = msgViaLIBAB; *mark = MARK_AB; *mix = MIX14; *line = "LINE14";
  } else if (idx == 14) {
    *via = msgViaLIBCU; *mark = MARK_CU; *mix = MIX15; *line = "LINE15";
  } else if (idx == 15) {
    *via = msgViaLIBX1; *mark = MARK_X1; *mix = MIX16; *line = "LINE16";
  } else if (idx == 16) {
    *via = msgViaLIBXC; *mark = MARK_XC; *mix = MIX17; *line = "LINE17";
  } else if (idx == 17) {
    *via = msgViaLIBXD; *mark = MARK_XD; *mix = MIX18; *line = "LINE18";
  } else if (idx == 18) {
    *via = msgViaLIBXE; *mark = MARK_XE; *mix = MIX19; *line = "LINE19";
  } else if (idx == 19) {
    *via = msgViaLIBXF; *mark = MARK_XF; *mix = MIX20; *line = "LINE20";
  } else if (idx == 20) {
    *via = msgViaLIBXR; *mark = MARK_XR; *mix = MIX21; *line = "LINE21";
  } else if (idx == 21) {
    *via = msgViaLIBGM; *mark = MARK_GM; *mix = MIX22; *line = "LINE22";
  } else if (idx == 22) {
    *via = msgViaLIBEX; *mark = MARK_EX; *mix = MIX23; *line = "LINE23";
  } else if (idx == 23) {
    *via = msgViaLIBXB; *mark = MARK_XB; *mix = MIX24; *line = "LINE24";
  } else if (idx == 24) {
    *via = msgViaLIBXK; *mark = MARK_XK; *mix = MIX25; *line = "LINE25";
  } else if (idx == 25) {
    *via = msgViaLIBCA; *mark = MARK_CA; *mix = MIX26; *line = "LINE26";
  } else if (idx == 26) {
    *via = msgViaLIBPG; *mark = MARK_PG; *mix = MIX27; *line = "LINE27";
  } else if (idx == 27) {
    *via = msgViaLIBUD; *mark = MARK_UD; *mix = MIX28; *line = "LINE28";
  } else if (idx == 28) {
    *via = msgViaLIBAS; *mark = MARK_AS; *mix = MIX29; *line = "LINE29";
  } else if (idx == 29) {
    *via = msgViaLIBAP; *mark = MARK_AP; *mix = MIX30; *line = "LINE30";
  } else if (idx == 30) {
    *via = msgViaLIBGC; *mark = MARK_GC; *mix = MIX31; *line = "LINE31";
  } else if (idx == 31) {
    *via = msgViaLIBLD; *mark = MARK_LD; *mix = MIX32; *line = "LINE32";
  } else {
    *via = msgViaLIBLD; *mark = MARK_LD; *mix = MIX32; *line = "LINE32";
  }
}

/* Walk _DYNAMIC. Names come from DT_NEEDED / DT_STRTAB —
 * inventing LINE32 without the thirty-second FAT file must fail. */
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
        got = w(msgViaLIBC, sizeof(msgViaLIBC) - 1);
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
  sys(SYS_EXIT, 0xA1650000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
