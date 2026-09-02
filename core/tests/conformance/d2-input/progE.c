/* core/tests/conformance/d2-input/progE.c
 *
 * The other half of `proc run`. Exits on its first instruction so the
 * reader is the lone process on the CPU. Two readers would split the
 * queue and the sequence assertion would fail for a reason that is not
 * the queue.
 */

volatile unsigned long exitData = 0x0D20000000000000UL;
volatile unsigned long exitBss[8];
const char msgE[] = "D2 EXIT";

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  xorl %eax, %eax\n"
    "  int $0x80\n"
    ".size _start, . - _start\n");

unsigned long progETouch(void);
unsigned long progETouch(void) {
  return exitData + exitBss[0] + (unsigned long)msgE[0];
}
