/* plat-need2/libm.c — OUR tiny LIBM.SO. Not libm.so.6.
 * Second DT_NEEDED stand-in. Exports need_fn. ADR-0160.
 */

#define SYS_WRITE 1
#define MARK 0xA1570000C0DE0001UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long need_fn(unsigned long buf, unsigned long len) {
  unsigned long r;
  __asm__ volatile("int $0x80"
                   : "=a"(r)
                   : "a"((unsigned long)SYS_WRITE), "D"(buf), "S"(len)
                   : "memory");
  if (r > ERR_FLOOR) {
    return r;
  }
  return MARK;
}
