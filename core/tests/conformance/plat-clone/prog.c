/* core/tests/conformance/plat-clone/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 * The bytes are identical. Only the 8.3 name may clone.
 *
 *   PLAT.ELF  — named platform process: clone(child, stack)
 *               starts a sibling on the same page tables. The
 *               child writes the derived CHILD line.
 *   ASK.ELF   — same binary, no platform flag: clone is
 *               cloneRetBadArg.
 *
 * This is not glibc and not CEF OnPaint. It is the door a later
 * Content thread needs (ADR-0130). Syscall 28. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_CLONE 28

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define SIG 0xA1300000C0DE0001UL
#define MIX 0x00C10E0000001300UL

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
    ".size _start, . - _start\n"
    ".globl child_start\n"
    ".type child_start, @function\n"
    "child_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call childMain\n"
    "2:\n"
    "  pause\n"
    "  jmp 2b\n"
    ".size child_start, . - child_start\n");

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

extern void child_start(void);

const char msgStart[] = "PLAT START";
const char msgChild[] = "CHILD LINE";

char out[128];
char child_stack[4096] __attribute__((aligned(16)));

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

void childMain(void);
void progMain(unsigned long probe);

void childMain(void) {
  sys(SYS_WRITE, (unsigned long)msgChild, sizeof(msgChild) - 1);
  say("CHILD", SIG ^ MIX);
  sys(SYS_EXIT, 0xA1300001UL, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}

void progMain(unsigned long probe) {
  unsigned long tid;
  unsigned long bad;
  unsigned long stack;

  (void)probe;
  bad = 0;
  stack = (unsigned long)(child_stack + sizeof(child_stack));

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  tid = sys(SYS_CLONE, (unsigned long)child_start, stack);
  say("ASKED", tid);

  if (tid > ERR_FLOOR) {
    if (tid != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    if (tid > 3UL) {
      bad++;
    }
    say("PARENT", tid);
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys(SYS_EXIT, 0xA1300000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
