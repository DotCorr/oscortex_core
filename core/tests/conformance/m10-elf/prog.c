/* core/tests/conformance/m10-elf/prog.c
 *
 * THE FIRST PROGRAM THIS OPERATING SYSTEM DID NOT COMPILE INTO ITSELF.
 *
 * Freestanding C, no libc, no dynamic linking, compiled and linked by the
 * harness into a static ELF64 executable and written onto the test disk. The
 * kernel reads it off the disk, parses its ELF header and program headers, maps
 * its PT_LOAD segments with the permissions p_flags asks for, and jumps to
 * e_entry in ring 3.
 *
 * The exact build command is in build-prog.sh and in ADR-0014 §2. Nothing here
 * may assume anything about the kernel except the three syscall numbers below,
 * which are core/kernel/user.dart's.
 *
 * WHY -mgeneral-regs-only IS NOT OPTIONAL, and it is a finding rather than a
 * flag: core/boot/boot.S sets exactly one bit of CR4 (PAE). It never sets
 * OSFXSR, so an SSE instruction -- which is what clang emits for an ordinary
 * memcpy, a struct copy or a vectorised loop at -O2 -- raises #UD on this
 * machine, in ring 3, at whatever instruction happened to get one. See
 * docs/known-gaps.md GAP-0092. build-prog.sh asserts the disassembly is free of
 * them rather than trusting the flag.
 */

#define SYS_EXIT 0
#define SYS_WRITE 1
#define SYS_WHO 2

/* The whole ABI: RAX = number, RDI and RSI = arguments, `int $0x80`, RAX back.
 * "memory" because the kernel reads through the pointer this hands it. */
static unsigned long sys(unsigned long n, unsigned long a, unsigned long b) {
  unsigned long r;
  __asm__ volatile("int $0x80" : "=a"(r) : "a"(n), "D"(a), "S"(b) : "memory");
  return r;
}

/* .rodata -> the R+X segment. Read back by the harness OUT OF THE ELF FILE, so
 * the expected output is derived from the binary rather than typed twice. */
const char msg[] = "HELLO FROM AN ELF ON DISK";

/* Also .rodata, and `volatile` so the compiler must LOAD it rather than fold it
 * into an immediate: the exit status then depends on the loader having mapped
 * this segment's contents correctly, not merely on the code having run. */
const volatile unsigned long exit_status = 0x00C0FFEE;

/* .bss. Never written by the program before it is read, so every byte of it is
 * the loader's answer to `p_memsz > p_filesz`. `volatile` for the same reason:
 * LLVM knows a zero-initialised global that nothing writes is zero, and would
 * otherwise fold the whole check away and prove nothing. */
volatile unsigned char bss_probe[64];

/* .data -> the RW segment, WITH file content behind it. The .bss above proves
 * the p_memsz - p_filesz tail is zeroed; this proves the p_filesz part of the
 * same segment was actually copied off the disk, which a loader that zeroed the
 * whole thing would also pass without. */
volatile unsigned long data_word = 0x00DA7A00;

/* .bss as well, but written before it is read: the RW segment has to be
 * writable, and the store below is what says so. */
char out[16];

static char hex(unsigned long v) {
  const char digits[] = "0123456789ABCDEF";
  return digits[v & 15];
}

void _start(void) {
  unsigned long i;
  unsigned long sum;

  /* Who does the CPU think is running? The kernel answers out of the frame it
   * pushed, so this asks rather than reports. */
  sys(SYS_WHO, 0, 0);

  /* The R+X segment's contents, printed by the kernel. */
  sys(SYS_WRITE, (unsigned long)msg, sizeof(msg) - 1);

  /* Every byte of .bss, not just the first: a loader that zeroed one page of a
   * two-page tail would pass a one-byte check. */
  sum = 0;
  for (i = 0; i < sizeof(bss_probe); i++) {
    sum += bss_probe[i];
  }

  out[0] = 'B';
  out[1] = 'S';
  out[2] = 'S';
  out[3] = '[';
  out[4] = hex(bss_probe[0] >> 4);
  out[5] = hex(bss_probe[0]);
  out[6] = ']';
  out[7] = ' ';
  out[8] = 'S';
  out[9] = 'U';
  out[10] = 'M';
  out[11] = '=';
  out[12] = hex(sum >> 4);
  out[13] = hex(sum);
  sys(SYS_WRITE, (unsigned long)out, 14);

  /* The status is the .rodata word PLUS the .data word PLUS what .bss actually
   * held. The harness reads the first two out of the ELF file and adds them, so
   * the expected status is derived from the binary; the last two are zero only
   * if the tail really was zeroed, so a loader that skipped it reports a
   * different number here as well as a different SUM above. */
  sys(SYS_EXIT, exit_status + data_word + sum + bss_probe[0], 0);

  /* Not reached. `pause` rather than an empty loop, which C lets a compiler
   * delete, and rather than `hlt`, which is privileged. */
  for (;;) {
    __asm__ volatile("pause");
  }
}
