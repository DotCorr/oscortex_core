/* plat-need5/libcu.c — OUR tiny LIBCU.SO. Not the CEF original.
 * DT_NEEDED stand-in. Exports cu_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0165.
 */

#define SYS_WRITE 1
#define MARK 0xA1630000C0DE0007UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long cu_fn(unsigned long buf, unsigned long len) {
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
