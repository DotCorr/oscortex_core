/* cef-dl/libdl.c — OUR tiny libdl face. Planted on FAT as LIBDL.SO.
 * Real DT_NEEDED soname is libdl.so.2 (ADR-0174 / SOMAP.TXT).
 * Exports dl_fn(buf, len): writes the caller buffer, returns MARK.
 * Not glibc. Not OnPaint.
 */

#define SYS_WRITE 1
#define MARK 0xA1740000C0DE0001UL
#define ERR_FLOOR 0xFFFFFFFFFFFFF000UL

unsigned long dl_fn(unsigned long buf, unsigned long len) {
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
