/* plat-need5/libnp.c — OUR tiny LIBNP.SO. Not the CEF original.
 * DT_NEEDED stand-in. Exports np_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0165.
 */

#define SYS_WRITE 1
#define MARK 0xA1620000C0DE0003UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long np_fn(unsigned long buf, unsigned long len) {
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
