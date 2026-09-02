/* cef-plt/libc.c — OUR tiny LIBC.SO. Not glibc.
 *
 * ADR-0169: memset@plt. ADR-0170: same door also binds
 * memcpy/memmove/strlen/memcmp (cef-und/). Bodies land in an RX
 * face slab; PLT stubs get 12-byte trampolines.
 */

void *memset(void *dst, int c, unsigned long n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  unsigned char v = (unsigned char)c;
  unsigned long i;
  for (i = 0; i < n; i++) {
    d[i] = v;
  }
  return dst;
}

void *memcpy(void *dst, const void *src, unsigned long n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  const volatile unsigned char *s = (const volatile unsigned char *)src;
  unsigned long i;
  for (i = 0; i < n; i++) {
    d[i] = s[i];
  }
  return dst;
}

void *memmove(void *dst, const void *src, unsigned long n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  const volatile unsigned char *s = (const volatile unsigned char *)src;
  unsigned long i;
  if ((unsigned long)d < (unsigned long)s) {
    for (i = 0; i < n; i++) {
      d[i] = s[i];
    }
  } else {
    i = n;
    while (i > 0) {
      i--;
      d[i] = s[i];
    }
  }
  return dst;
}

unsigned long strlen(const char *s) {
  unsigned long n = 0;
  while (s[n]) {
    n++;
  }
  return n;
}

int memcmp(const void *a, const void *b, unsigned long n) {
  const unsigned char *x = (const unsigned char *)a;
  const unsigned char *y = (const unsigned char *)b;
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (x[i] != y[i]) {
      return (int)x[i] - (int)y[i];
    }
  }
  return 0;
}
