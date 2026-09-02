/* plat-need/libc.c — OUR tiny LIBC.SO. Not glibc.
 * Stand-in for CEF DT_NEEDED libc.so.6. Exports write. ADR-0157.
 */

#define SYS_WRITE 1
#define MARK 0xA1520000C0DE0001UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long write(const void *buf, unsigned long len) {
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
