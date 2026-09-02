/* core/tests/conformance/d3-resident/progE.c
 *
 * THE NEGATIVE CONTROL. Exits immediately. D3's criterion is sensitive to
 * liveness: spawn this instead of the spinner, type `ticks`, and the
 * preempt counter must NOT advance.
 */

volatile unsigned long exitData = 0x0D30000000000000UL;
volatile unsigned long exitBss[8];
const char msgE[] = "D3 EXIT: RETURNS AT ONCE";

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
