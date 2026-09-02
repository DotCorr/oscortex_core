/* plat-need5/libgm.c — OUR tiny LIBGM.SO. Not libgbm.so.1.
 * DT_NEEDED stand-in. Exports gm_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0165.
 */

#define SYS_WRITE 1
#define MARK 0xA1650000C0DE0006UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long gm_fn(unsigned long buf, unsigned long len) {
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
