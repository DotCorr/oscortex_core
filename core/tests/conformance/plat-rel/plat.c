/* core/tests/conformance/plat-rel/plat.c
 *
 * Named PLAT.ELF with PT_INTERP + PT_DYNAMIC. The derived write
 * is hex(reloc_word ^ MIX). reloc_word is 0 in the file; LD.SO
 * applies R_X86_64_64 from RELA. Skip the reloc and the line is
 * MIX alone. ADR-0127.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1

#define MIX 0x0000000000000127UL

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  call platMain\n"
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

__attribute__((section(".relocword"), used))
unsigned long reloc_word = 0;

char out[64];

static char hex(unsigned long v) {
  const char d[] = "0123456789ABCDEF";
  return d[v & 15];
}

void platMain(void) {
  unsigned long n;
  unsigned long v;
  unsigned long j;

  sys(SYS_WRITE, (unsigned long)msgStart, sizeof(msgStart) - 1);

  v = reloc_word ^ MIX;
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

  sys(SYS_EXIT, 0xA1270000UL, 0);
  for (;;) {
    __asm__ volatile("pause");
  }
}
