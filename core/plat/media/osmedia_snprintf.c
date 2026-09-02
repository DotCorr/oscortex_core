/* Real snprintf for FFmpeg. Guest CRT's snprintf is a stub. */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

static void putc_buf(char *s, size_t n, size_t *i, char c) {
  if (*i + 1 < n) {
    s[*i] = c;
  }
  *i = *i + 1;
}

static void put_str(char *s, size_t n, size_t *i, const char *t) {
  if (t == 0) {
    t = "(null)";
  }
  while (*t) {
    putc_buf(s, n, i, *t);
    t = t + 1;
  }
}

static void put_uint(char *s, size_t n, size_t *i, uint64_t v, int base,
                     int upper, int width, int zpad) {
  char tmp[32];
  int k;
  const char *dig;
  dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  k = 0;
  if (v == 0) {
    tmp[k] = '0';
    k = k + 1;
  }
  while (v > 0 && k < 32) {
    tmp[k] = dig[v % (uint64_t)base];
    k = k + 1;
    v = v / (uint64_t)base;
  }
  while (width > k) {
    putc_buf(s, n, i, zpad ? '0' : ' ');
    width = width - 1;
  }
  while (k > 0) {
    k = k - 1;
    putc_buf(s, n, i, tmp[k]);
  }
}

int osmedia_vsnprintf(char *s, size_t n, const char *fmt, va_list ap) {
  size_t i;
  if (s == 0) {
    n = 0;
  }
  i = 0;
  if (fmt == 0) {
    if (n > 0) {
      s[0] = 0;
    }
    return 0;
  }
  while (*fmt) {
    if (*fmt != '%') {
      putc_buf(s, n, &i, *fmt);
      fmt = fmt + 1;
      continue;
    }
    fmt = fmt + 1;
    {
      int zpad;
      int width;
      int lng;
      zpad = 0;
      width = 0;
      lng = 0;
      if (*fmt == '0') {
        zpad = 1;
        fmt = fmt + 1;
      }
      while (*fmt >= '0' && *fmt <= '9') {
        width = width * 10 + (*fmt - '0');
        fmt = fmt + 1;
      }
      while (*fmt == 'l' || *fmt == 'z' || *fmt == 't' || *fmt == 'h') {
        if (*fmt == 'l') {
          lng = lng + 1;
        }
        fmt = fmt + 1;
      }
      if (*fmt == '%') {
        putc_buf(s, n, &i, '%');
      } else if (*fmt == 's') {
        put_str(s, n, &i, va_arg(ap, const char *));
      } else if (*fmt == 'c') {
        putc_buf(s, n, &i, (char)va_arg(ap, int));
      } else if (*fmt == 'd' || *fmt == 'i') {
        int64_t v;
        if (lng >= 2) {
          v = va_arg(ap, int64_t);
        } else if (lng == 1) {
          v = (int64_t)va_arg(ap, long);
        } else {
          v = (int64_t)va_arg(ap, int);
        }
        if (v < 0) {
          putc_buf(s, n, &i, '-');
          put_uint(s, n, &i, (uint64_t)(-v), 10, 0, width, zpad);
        } else {
          put_uint(s, n, &i, (uint64_t)v, 10, 0, width, zpad);
        }
      } else if (*fmt == 'u') {
        uint64_t v;
        if (lng >= 2) {
          v = va_arg(ap, uint64_t);
        } else if (lng == 1) {
          v = (uint64_t)va_arg(ap, unsigned long);
        } else {
          v = (uint64_t)va_arg(ap, unsigned);
        }
        put_uint(s, n, &i, v, 10, 0, width, zpad);
      } else if (*fmt == 'x' || *fmt == 'X') {
        uint64_t v;
        if (lng >= 2) {
          v = va_arg(ap, uint64_t);
        } else if (lng == 1) {
          v = (uint64_t)va_arg(ap, unsigned long);
        } else {
          v = (uint64_t)va_arg(ap, unsigned);
        }
        put_uint(s, n, &i, v, 16, *fmt == 'X', width, zpad);
      } else if (*fmt == 'p') {
        put_str(s, n, &i, "0x");
        put_uint(s, n, &i, (uint64_t)(uintptr_t)va_arg(ap, void *), 16, 0, 0, 0);
      } else if (*fmt == 'f' || *fmt == 'g' || *fmt == 'e' || *fmt == 'F' ||
                 *fmt == 'G') {
        (void)va_arg(ap, double);
        put_str(s, n, &i, "0");
      } else if (*fmt != 0) {
        putc_buf(s, n, &i, *fmt);
      }
      if (*fmt != 0) {
        fmt = fmt + 1;
      }
    }
  }
  if (n > 0) {
    if (i < n) {
      s[i] = 0;
    } else {
      s[n - 1] = 0;
    }
  }
  return (int)i;
}

size_t strftime(char *s, size_t n, const char *fmt, const struct tm *tm) {
  (void)fmt;
  (void)tm;
  if (s != 0 && n > 0) {
    s[0] = 0;
  }
  return 0;
}

double scalbn(double x, int n) { return __builtin_scalbn(x, n); }
float scalbnf(float x, int n) { return __builtin_scalbnf(x, n); }
double log10(double x) { return __builtin_log10(x); }
float log10f(float x) { return __builtin_log10f(x); }
/* Weak: osgfx_cxxrt.cpp defines these when Skia is linked. */
__attribute__((weak)) double sinh(double x) { return __builtin_sinh(x); }
__attribute__((weak)) double cosh(double x) { return __builtin_cosh(x); }
__attribute__((weak)) double tanh(double x) { return __builtin_tanh(x); }

long long strtoll(const char *s, char **end, int base) {
  unsigned long long u;
  int neg;
  if (s == 0) {
    return 0;
  }
  neg = 0;
  while (*s == ' ' || *s == '\t') {
    s = s + 1;
  }
  if (*s == '-') {
    neg = 1;
    s = s + 1;
  } else if (*s == '+') {
    s = s + 1;
  }
  u = strtoull(s, end, base);
  if (neg) {
    return -(long long)u;
  }
  return (long long)u;
}

clock_t clock(void) { return 0; }
time_t mktime(struct tm *tm) {
  (void)tm;
  return 0;
}
unsigned long long gethrtime(void) { return 0; }
int setvbuf(void *stream, char *buf, int mode, size_t size) {
  (void)stream;
  (void)buf;
  (void)mode;
  (void)size;
  return 0;
}
int usleep(unsigned usec) {
  (void)usec;
  return 0;
}
int access(const char *path, int mode) {
  (void)path;
  (void)mode;
  return -1;
}
int isatty(int fd) {
  (void)fd;
  return 0;
}
int fputs(const char *s, void *stream) {
  (void)s;
  (void)stream;
  return 0;
}
int fcntl(int fd, int cmd, ...) {
  (void)fd;
  (void)cmd;
  return 0;
}
int fstat(int fd, void *st) {
  (void)fd;
  (void)st;
  return -1;
}
int mkstemp(char *tmpl) {
  (void)tmpl;
  return -1;
}
void *fdopen(int fd, const char *mode) {
  (void)fd;
  (void)mode;
  return 0;
}

int strerror_r(int errnum, char *buf, size_t buflen) {
  (void)errnum;
  if (buf != 0 && buflen > 0) {
    buf[0] = 0;
  }
  return 0;
}

static struct tm g_tm;

struct tm *gmtime(const time_t *t) {
  (void)t;
  return &g_tm;
}
struct tm *localtime(const time_t *t) {
  (void)t;
  return &g_tm;
}
struct tm *gmtime_r(const time_t *t, struct tm *out) {
  (void)t;
  if (out == 0) {
    return 0;
  }
  return out;
}
struct tm *localtime_r(const time_t *t, struct tm *out) {
  return gmtime_r(t, out);
}
void ff_aom_uninit_film_grain_params(void *s) { (void)s; }

int sysctl(const int *name, unsigned namelen, void *oldp, unsigned long *oldlenp,
           const void *newp, unsigned long newlen) {
  (void)name;
  (void)namelen;
  (void)oldp;
  (void)oldlenp;
  (void)newp;
  (void)newlen;
  return -1;
}

int osmedia_snprintf(char *s, size_t n, const char *fmt, ...) {
  va_list ap;
  int r;
  va_start(ap, fmt);
  r = osmedia_vsnprintf(s, n, fmt, ap);
  va_end(ap);
  return r;
}
