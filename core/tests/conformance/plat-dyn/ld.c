/* core/tests/conformance/plat-dyn/ld.c
 *
 * Tiny FAT interp. OUR code, not glibc. The kernel maps this at
 * 0x10100000, puts the dyn e_entry in RDI, and enters here.
 * We write INTERP MAP and jump to that entry. ADR-0126.
 */

#define SYS_WRITE 1

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

const char msgMap[] = "INTERP MAP";

void ldMain(void) {
  sys(SYS_WRITE, (unsigned long)msgMap, sizeof(msgMap) - 1);
}
