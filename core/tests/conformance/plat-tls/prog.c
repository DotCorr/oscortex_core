/* core/tests/conformance/plat-tls/prog.c
 *
 * ONE SOURCE, TWO FAT NAMES. Planted as PLAT.ELF and ASK.ELF.
 * The bytes are identical. Only the 8.3 name may setfs.
 *
 *   PLAT.ELF  — named platform process: setfs(tls_block), store
 *               SIG at %fs:0, load it back, write TLS with
 *               SIG ^ MIX. Without the MSR write the store
 *               faults at VA 0 and the derived line is missing.
 *   ASK.ELF   — same binary, no platform flag: setfs is
 *               setfsRetBadArg.
 *
 * Not glibc. Not CEF OnPaint. Not futex. Syscall 33. 11 stays fdwait.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_SETFS 33

#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL
#define E_BADARG 0xFFFFFFFFFFFFFFFEUL

#define SIG 0xA1480000C0DE0001UL
#define MIX 0x00F10E0000001480UL

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

static unsigned long sys1(unsigned long n, unsigned long a) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a) : "memory");
  return r;
}

static unsigned long sys2(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

static void fs_store(unsigned long v) {
  __asm__ volatile("movq %0, %%fs:0" : : "r"(v) : "memory");
}

static unsigned long fs_load(void) {
  unsigned long v;
  __asm__ volatile("movq %%fs:0, %0" : "=r"(v));
  return v;
}

const char msgStart[] = "PLAT START";

char out[128];
unsigned long tls_block __attribute__((aligned(8)));

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

void progMain(unsigned long probe);

void progMain(unsigned long probe) {
  unsigned long st;
  unsigned long got;
  unsigned long bad;

  (void)probe;
  bad = 0;
  tls_block = 0;

  sys2(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  st = sys1(SYS_SETFS, (unsigned long)&tls_block);
  say("ASKED", st);

  if (st > ERR_FLOOR) {
    if (st != E_BADARG) {
      bad++;
    }
    say("CAP", 0x200000UL);
  } else {
    if (st != 0UL) {
      bad++;
    }
    /* Real TLS door: store and load through %fs. A kernel that
     * returned success without writing IA32_FS_BASE faults here
     * (FS.base still 0 → VA 0) and never prints TLS. */
    fs_store(SIG);
    got = fs_load();
    if (got != SIG) {
      bad++;
    }
    if (tls_block != SIG) {
      bad++;
    }
    say("TLS", got ^ MIX);
    say("CAP", 0x1000000UL);
  }

  say("BAD", bad);
  sys2(SYS_EXIT, 0xA1480000UL + bad, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
