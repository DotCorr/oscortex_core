/* core/tests/conformance/plat-dl/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 * The bytes are identical. Only the 8.3 name may dlopen.
 *
 *   PLAT.ELF  — named platform process: dlopen("TINY.SO") maps
 *               our FAT ET_DYN and returns so_mark. write() of
 *               *so_mark is the mapped page. Missing MISS.SO is
 *               NotFound and cannot invent the derived line.
 *   ASK.ELF   — same binary, no platform flag: dlopen is
 *               elfDlopenRetBadArg.
 *
 * Not glibc. Not CEF OnPaint. Syscall 29. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_DLOPEN 29

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL
#define E_NOTFOUND 0xFFFFFFFFFFFFFFF9UL

#define MARK 0xA1440000C0DE0001UL
#define MIX 0x00D10E0000001440UL

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

const char msgStart[] = "PLAT START";
const char nameTiny[] = "TINY.SO";
const char nameMiss[] = "MISS.SO";

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

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long va, miss, bad, got;

  (void)probe;
  bad = 0;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  va = sys(SYS_DLOPEN, (unsigned long)nameTiny, sizeof(nameTiny) - 1);
  say("ASKED", va);

  if (va > ERR_FLOOR) {
    if (va != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    got = *(volatile unsigned long *)va;
    if (got != MARK) {
      bad++;
    }
    say("MARK", got ^ MIX);
    miss = sys(SYS_DLOPEN, (unsigned long)nameMiss, sizeof(nameMiss) - 1);
    say("MISS", miss);
    if (miss != E_NOTFOUND) {
      bad++;
    }
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1440000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
