/* plat-need3/libns.c — OUR tiny LIBNS.SO. Not libnss3.so.
 * Eighth DT_NEEDED stand-in. Exports ns_fn(buf, len): writes the
 * caller buffer, then returns MARK. ADR-0162.
 */

#define SYS_WRITE 1
#define MARK 0xA1620000C0DE0004UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long ns_fn(unsigned long buf, unsigned long len) {
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
