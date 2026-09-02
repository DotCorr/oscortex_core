/* core/tests/conformance/plat-dyn/dyn.c
 *
 * The dyn program. Planted as PLAT.ELF (platform) and ASK.ELF (same
 * bytes). PT_INTERP names LD.SO. The derived write lives HERE, not
 * in the interp. ADR-0126.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1

#define SIG 0xA1260000C0DE0001UL
#define MIX 0x0000000000000126UL

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call dynMain\n"
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

const char msgStart[] = "DYN START";

char out[64];

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

void dynMain(void) {
  unsigned long n;
  unsigned long v;
  unsigned long j;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  v = SIG ^ MIX;
  out[0] = 'D';
  out[1] = 'Y';
  out[2] = 'N';
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

  sys(SYS_EXIT, 0xA1260000UL, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
