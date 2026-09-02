/* core/tests/conformance/plat-rel/nodyn.c
 *
 * PLAT.ELF without PT_DYNAMIC — the ADR-0126 path still works.
 * Derived write is compile-time XOR, not a reloc. ADR-0127.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1

#define SIG 0xA1270000C0DE0002UL
#define MIX 0x0000000000000127UL

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call nodynMain\n"
    "1:\n"
    "  pause\n"
    "  jmp 1b\n"
    ".size _start, . - _start\n");

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

__attribute__((section(".interp"), used))
const char interp_path[] = "LD.SO";

const char msgStart[] = "NOD START";

char out[64];

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

void nodynMain(void) {
  unsigned long n;
  unsigned long v;
  unsigned long j;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  v = SIG ^ MIX;
  out[0] = 'N';
  out[1] = 'O';
  out[2] = 'D';
  out[3] = ' ';
  out[4] = 'L';
  out[5] = 'I';
  out[6] = 'N';
  out[7] = 'E';
  out[8] = ' ';
  n = 9;
  for (j = 0; j < 16; j++) {
    out[n + j] = hex(v >> (60 - 4 * j));
  }
  sys(SYS_WRITE, (unsigned long)out, 25);

  sys(SYS_EXIT, 0xA1270001UL, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
