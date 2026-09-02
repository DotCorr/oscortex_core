/* plat-libc/libc.c — OUR tiny LIBC.SO. Not glibc.
 *
 * Exports POSIX-shaped write(buf, len) backed by syscall 1.
 * Success returns MARK so the caller can print MARK ^ MIX.
 * A volume without this file cannot invent that line (ADR-0152).
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
