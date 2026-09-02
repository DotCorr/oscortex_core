/* core/tests/conformance/plat-futex/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 * The bytes are identical. Only the 8.3 name may futex.
 *
 *   PLAT.ELF  — named platform process: clone a sibling, then
 *               futex-wait on a shared gate. The child stores
 *               SIG and wakes. The parent writes SYNC with
 *               gate ^ MIX — a no-op wait that never blocks
 *               leaves gate 0 and prints the zero mix.
 *   ASK.ELF   — same binary, no platform flag: futex is
 *               futexRetBadArg.
 *
 * Not glibc. Not CEF OnPaint. Not TLS. Syscall 30. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_CLONE 28
#define SYS_FUTEX 30

#define FUTEX_WAIT 0
#define FUTEX_WAKE 1

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define SIG 0xA1460000C0DE0001UL
#define MIX 0x00F10E0000001460UL

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

static unsigned long sys2(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

static unsigned long sys3(unsigned long n, unsigned long a, unsigned long b,
                          unsigned long c) {
  unsigned long r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"(n), "D"(a), "S"(b), "d"(c)
                   : "memory");
  return r;
}

extern void child_start(void);

const char msgStart[] = "PLAT START";
const char msgChild[] = "CHILD LINE";

char out[128];
char child_stack[4096] __attribute__((aligned(16)));
volatile unsigned long gate;

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
  sys2(SYS_WRITE, (unsigned long)out, n);
}

void childMain(void);
void progMain(unsigned long probe);

void childMain(void) {
  sys2(SYS_WRITE, (unsigned long)msgChild, sizeof(msgChild) - 1);
  gate = SIG;
  sys3(SYS_FUTEX, FUTEX_WAKE, (unsigned long)&gate, 1UL);
  say("CHILD", SIG ^ MIX);
  sys2(SYS_EXIT, 0xA1460001UL, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}

void progMain(unsigned long probe) {
  unsigned long tid;
  unsigned long wait;
  unsigned long bad;
  unsigned long stack;

  (void)probe;
  bad = 0;
  gate = 0;
  stack = (unsigned long)(child_stack + sizeof(child_stack));

  sys2(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  tid = sys2(SYS_CLONE, (unsigned long)child_start, stack);
  say("ASKED", tid);

  if (tid > ERR_FLOOR) {
    if (tid != E_BADARG) {
      bad++;
    }
    /* ASK: probe futex itself — same BadArg. */
    wait = sys3(SYS_FUTEX, FUTEX_WAIT, (unsigned long)&gate, 0UL);
    say("FASK", wait);
    if (wait != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    if (tid > 3UL) {
      bad++;
    }
    wait = sys3(SYS_FUTEX, FUTEX_WAIT, (unsigned long)&gate, 0UL);
    say("WAIT", wait);
    if (wait > ERR_FLOOR) {
      bad++;
    }
    if (gate != SIG) {
      bad++;
    }
    say("SYNC", gate ^ MIX);
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys2(SYS_EXIT, 0xA1460000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
