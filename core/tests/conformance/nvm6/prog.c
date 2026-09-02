/* core/tests/conformance/nvm6/prog.c
 *
 * A named program whose write string and exit code are compiled in at
 * test time (-DMAGIC_HEX=... -DEXIT_CODE=...). nvm6 plants this ELF
 * on a FAT-on-NVMe volume and `run prog.elf` must print those bytes.
 * They are not a kernel constant.
 *
 * Freestanding, no libc. Same syscall ABI as m10-elf. -mgeneral-regs-only
 * is required (GAP-0092): this machine has no OSFXSR.
 */

#ifndef MAGIC_HEX
#define MAGIC_HEX "00000000000000000000000000000000"
#endif
#ifndef EXIT_CODE
#define EXIT_CODE 0
#endif

#define SYS_EXIT 0
#define SYS_WRITE 1

static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

const char msg[] = "NVM6 " MAGIC_HEX;

/* Forces a real RW PT_LOAD. An empty .data/.bss makes ld emit a
 * PT_LOAD at vaddr 0, which elf.dart refuses as incongruent. */
volatile unsigned long keep = 1;

void _start(void) {
  keep = keep + 1;
  sys(SYS_WRITE, (unsigned long)msg, sizeof(msg) - 1);
  sys(SYS_EXIT, (unsigned long)EXIT_CODE, 0);
}
