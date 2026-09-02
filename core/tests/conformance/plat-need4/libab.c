/* plat-need4/libab.c — OUR tiny LIBAB.SO. Not libatk-bridge-2.0.so.0.
 * DT_NEEDED stand-in. Exports ab_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0163.
 */

#define SYS_WRITE 1
#define MARK 0xA1630000C0DE0006UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long ab_fn(unsigned long buf, unsigned long len) {
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
