/* plat-need5/libap.c — OUR tiny LIBAP.SO. Not libatspi.so.0.
 * DT_NEEDED stand-in. Exports ap_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0165.
 */

#define SYS_WRITE 1
#define MARK 0xA1650000C0DE000EUL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long ap_fn(unsigned long buf, unsigned long len) {
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
