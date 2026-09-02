/* plat-need5/libca.c — OUR tiny LIBCA.SO. Not libcairo.so.2.
 * DT_NEEDED stand-in. Exports ca_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0165.
 */

#define SYS_WRITE 1
#define MARK 0xA1650000C0DE000AUL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long ca_fn(unsigned long buf, unsigned long len) {
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
