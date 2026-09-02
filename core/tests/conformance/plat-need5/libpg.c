/* plat-need5/libpg.c — OUR tiny LIBPG.SO. Not libpango-1.0.so.0.
 * DT_NEEDED stand-in. Exports pg_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0165.
 */

#define SYS_WRITE 1
#define MARK 0xA1650000C0DE000BUL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long pg_fn(unsigned long buf, unsigned long len) {
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
