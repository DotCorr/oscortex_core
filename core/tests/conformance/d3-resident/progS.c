/* core/tests/conformance/d3-resident/progS.c
 *
 * THE RESIDENT SPINNER. No syscalls. D3's positive case: spawn it, type
 * `ticks` at the shell while it is still live, and its per-slot preempt
 * counter must be strictly greater afterwards.
 *
 * The loop is the same two instructions m18-preempt/progC uses, for the same
 * reason: a C loop at -O2 disappears, and a program that can `exit` cannot
 * prove it outlived the command that started it.
 */

volatile unsigned long spinData = 0x0D30000000000001UL;
volatile unsigned long spinBss[512];
const char msgS[] = "D3 SPIN: NEVER YIELDS, NEVER EXITS";

__asm__(
    ".text\n"
    ".globl _start\n"
    ".type _start, @function\n"
    "_start:\n"
    "  andq $-16, %rsp\n"
    "  xorl %ebp, %ebp\n"
    "  xorl %r15d, %r15d\n"
    "spinLoop:\n"
    "  incq %r15\n"
    "  jmp spinLoop\n"
    ".size _start, . - _start\n");

unsigned long progSTouch(void);
unsigned long progSTouch(void) {
  return spinData + spinBss[0] + (unsigned long)msgS[0];
}
