/* core/tests/conformance/plat-rel/ld.c
 *
 * Tiny FAT interp. OUR code, not glibc. The kernel maps this at
 * 0x10100000, puts the dyn e_entry in RDI, and enters here.
 * We write INTERP MAP, walk the dyn PT_DYNAMIC, apply RELA, jump.
 * ADR-0127.
 */

#define SYS_WRITE 1

#define DYN_BASE 0x10000000UL
#define PT_DYNAMIC 2
#define DT_NULL 0
#define DT_SYMTAB 6
#define DT_RELA 7
#define DT_RELASZ 8
#define DT_RELAENT 9
#define R_X86_64_64 1
#define R_X86_64_GLOB_DAT 6
#define R_X86_64_RELATIVE 8

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  movq %rdi, %r12\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call ldMain\n"
    "  jmp *%r12\n"
    ".size _start, . - _start\n");

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

static unsigned long ru16(unsigned long p) {
  return (unsigned long)*(const unsigned short *)p;
}

static unsigned long ru32(unsigned long p) {
  return (unsigned long)*(const unsigned int *)p;
}

static unsigned long ru64(unsigned long p) {
  return *(const unsigned long *)p;
}

static void wu64(unsigned long p, unsigned long v) {
  *(unsigned long *)p = v;
}

const char msgMap[] = "INTERP MAP";
const char msgRela[] = "RELA OK";

static unsigned long ldApplyRela(void) {
  unsigned long phoff;
  unsigned long phnum;
  unsigned long phentsize;
  unsigned long i;
  unsigned long dyn;
  unsigned long dynsz;
  unsigned long rela;
  unsigned long relasz;
  unsigned long relaent;
  unsigned long symtab;
  unsigned long applied;
  unsigned long t;
  unsigned long tag;
  unsigned long val;

  if (ru32(DYN_BASE) != 0x464C457FU) {
    return 0;
  }
  phoff = ru64(DYN_BASE + 32);
  phentsize = ru16(DYN_BASE + 54);
  phnum = ru16(DYN_BASE + 56);
  if (phentsize != 56) {
    return 0;
  }
  if (phnum == 0 || phnum > 16) {
    return 0;
  }
  dyn = 0;
  dynsz = 0;
  i = 0;
  while (i < phnum) {
    unsigned long ph = DYN_BASE + phoff + (i * phentsize);
    if (ru32(ph) == PT_DYNAMIC) {
      dyn = ru64(ph + 16);
      dynsz = ru64(ph + 32);
    }
    i = i + 1;
  }
  if (dyn < DYN_BASE) {
    return 0;
  }
  if (dynsz < 16 || dynsz > 512) {
    return 0;
  }
  rela = 0;
  relasz = 0;
  relaent = 24;
  symtab = 0;
  t = 0;
  while (t + 16 <= dynsz) {
    tag = ru64(dyn + t);
    val = ru64(dyn + t + 8);
    if (tag == DT_NULL) {
      break;
    }
    if (tag == DT_RELA) {
      rela = val;
    }
    if (tag == DT_RELASZ) {
      relasz = val;
    }
    if (tag == DT_RELAENT) {
      relaent = val;
    }
    if (tag == DT_SYMTAB) {
      symtab = val;
    }
    t = t + 16;
  }
  if (rela < DYN_BASE) {
    return 0;
  }
  if (relaent != 24) {
    return 0;
  }
  if (relasz < 24 || relasz > 384) {
    return 0;
  }
  applied = 0;
  t = 0;
  while (t + 24 <= relasz) {
    unsigned long off = ru64(rela + t);
    unsigned long info = ru64(rela + t + 8);
    unsigned long addend = ru64(rela + t + 16);
    unsigned long type = info & 0xFFFFFFFFUL;
    unsigned long sym = info >> 32;
    unsigned long loc;
    unsigned long sv;

    if (off < DYN_BASE || off >= 0x10200000UL) {
      return applied;
    }
    loc = off;
    if (type == R_X86_64_RELATIVE) {
      wu64(loc, addend);
      applied = applied + 1;
    } else if (type == R_X86_64_64 || type == R_X86_64_GLOB_DAT) {
      if (symtab < DYN_BASE) {
        return applied;
      }
      if (sym > 8) {
        return applied;
      }
      sv = ru64(symtab + (sym * 24) + 8);
      wu64(loc, sv + addend);
      applied = applied + 1;
    }
    t = t + 24;
  }
  return applied;
}

void ldMain(void) {
  unsigned long n;

  sys(SYS_WRITE, (unsigned long)msgMap, sizeof(msgMap) - 1);
  n = ldApplyRela();
  if (n > 0) {
    sys(SYS_WRITE, (unsigned long)msgRela, sizeof(msgRela) - 1);
  }
}
