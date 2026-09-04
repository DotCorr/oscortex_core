/* Freestanding CRT for kernel-linked Skia. No host libc. */
#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#ifndef __cplusplus
#ifndef __WCHAR_TYPE__
typedef int wchar_t;
#endif
#endif
long strtol(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
double strtod(const char *s, char **end);

#ifndef CRT_HEAP
/* Host SPIR-V curve path + PIX/RRECT/DESK; keep under vmFineBytes.
 * build-kernel.sh may override via -DCRT_HEAP. free() is a no-op;
 * osgfx_heap_frame_begin reclaims per-tick scratch after the Graphite
 * init watermark. */
#define CRT_HEAP (6 * 1024 * 1024)
#endif

static unsigned char heap[CRT_HEAP];
static size_t heap_used;

size_t osgfx_heap_used(void) { return heap_used; }
size_t osgfx_heap_cap(void) { return (size_t)CRT_HEAP; }

void com1_puts(const char *s);

static size_t heap_watermark;
static size_t heap_chrome_mark;
static size_t heap_high_water;
static int heap_reclaim_armed;

int osgfx_heap_ready(void) { return heap_watermark > 0 ? 1 : 0; }

size_t osgfx_heap_high_water(void) { return heap_high_water; }

static void com1_put_uhex(size_t v) {
  char buf[17];
  int i;
  unsigned d;

  i = 16;
  buf[16] = 0;
  if (v == 0) {
    com1_puts("0");
    return;
  }
  while (v != 0 && i > 0) {
    i = i - 1;
    d = (unsigned)(v & 15u);
    if (d < 10u) {
      buf[i] = (char)('0' + d);
    } else {
      buf[i] = (char)('A' + (d - 10u));
    }
    v = v >> 4;
  }
  com1_puts(buf + i);
}

static void heap_note_hi(void) {
  size_t prev;

  if (heap_used <= heap_high_water) {
    return;
  }
  prev = heap_high_water;
  heap_high_water = heap_used;
  if ((prev >> 16) != (heap_high_water >> 16)) {
    com1_puts("OSGFX HEAP HI ");
    com1_put_uhex(heap_high_water);
    com1_puts("\n");
  }
}

/* After the first chrome flush: durable mark includes g_one + shaders.
 * Client paint may reclaim above this mark only after those unique_ptrs
 * have been reset. Do not fall back to the Graphite watermark — that
 * rewinds through a live chrome canvas. */
void osgfx_heap_chrome_seal(void) {
  heap_chrome_mark = heap_used;
  heap_reclaim_armed = 0;
}

void osgfx_heap_client_begin(void) {
  if (heap_chrome_mark == 0) {
    return;
  }
  if (heap_used > heap_chrome_mark) {
    heap_used = heap_chrome_mark;
  }
  heap_reclaim_armed = 1;
}

void osgfx_heap_scratch_live(void) {
  heap_reclaim_armed = 0;
}

int osgfx_heap_oom_reclaim(void) {
  if (heap_reclaim_armed == 0) {
    return 0;
  }
  if (heap_chrome_mark > 0 && heap_used > heap_chrome_mark) {
    heap_used = heap_chrome_mark;
    return 1;
  }
  return 0;
}

/* Frame scratch reclaim. Graphite MakeVulkan + init proofs stay
 * below the watermark; per-tick surfaces are bump-allocated and
 * discarded here because free() is a no-op. Callers must reset
 * every unique_ptr before this rewind. A full rewind also drops
 * the chrome seal so the next bind(g_one) reseals. */
void osgfx_heap_frame_begin(void) {
  heap_chrome_mark = 0;
  heap_reclaim_armed = 0;
  if (heap_watermark == 0) {
    if (heap_used > 0) {
      heap_watermark = heap_used;
    }
    return;
  }
  if (heap_used > heap_watermark) {
    heap_used = heap_watermark;
  }
}

/* Always set the rewind point to the live bump. Use after MakeVulkan
 * so a prior empty frame_begin cannot rewind the Graphite context
 * (that #GP'd as FAULT 0D OP FF50 on the first chrome miss). */
void osgfx_heap_watermark_seal(void) {
  heap_watermark = heap_used;
  heap_chrome_mark = 0;
  heap_reclaim_armed = 0;
}

void *memcpy(void *dst, const void *src, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  size_t i = 0;
  while (i < n) {
    d[i] = s[i];
    i = i + 1;
  }
  return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  size_t i;
  if (d == s) {
    return dst;
  }
  if (d < s) {
    i = 0;
    while (i < n) {
      d[i] = s[i];
      i = i + 1;
    }
    return dst;
  }
  i = n;
  while (i > 0) {
    i = i - 1;
    d[i] = s[i];
  }
  return dst;
}

void *memset(void *dst, int c, size_t n) {
  unsigned char *d = (unsigned char *)dst;
  size_t i = 0;
  while (i < n) {
    d[i] = (unsigned char)c;
    i = i + 1;
  }
  return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = (const unsigned char *)a;
  const unsigned char *y = (const unsigned char *)b;
  size_t i = 0;
  while (i < n) {
    if (x[i] != y[i]) {
      return (int)x[i] - (int)y[i];
    }
    i = i + 1;
  }
  return 0;
}

void *memchr(const void *s, int c, size_t n) {
  const unsigned char *p = (const unsigned char *)s;
  size_t i = 0;
  while (i < n) {
    if (p[i] == (unsigned char)c) {
      return (void *)(p + i);
    }
    i = i + 1;
  }
  return 0;
}

size_t strlen(const char *s) {
  size_t n = 0;
  while (s[n] != 0) {
    n = n + 1;
  }
  return n;
}

int strcmp(const char *a, const char *b) {
  size_t i = 0;
  while (a[i] != 0) {
    if (a[i] != b[i]) {
      return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
    }
    i = i + 1;
  }
  return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
}

int strncmp(const char *a, const char *b, size_t n) {
  size_t i = 0;
  while (i < n) {
    if (a[i] != b[i] || a[i] == 0) {
      return (int)(unsigned char)a[i] - (int)(unsigned char)b[i];
    }
    i = i + 1;
  }
  return 0;
}

char *strcpy(char *d, const char *s) {
  size_t i = 0;
  while (1) {
    d[i] = s[i];
    if (s[i] == 0) {
      return d;
    }
    i = i + 1;
  }
}

char *strncpy(char *d, const char *s, size_t n) {
  size_t i = 0;
  while (i < n && s[i] != 0) {
    d[i] = s[i];
    i = i + 1;
  }
  while (i < n) {
    d[i] = 0;
    i = i + 1;
  }
  return d;
}

char *strcat(char *d, const char *s) {
  return strcpy(d + strlen(d), s);
}

char *strchr(const char *s, int c) {
  while (*s) {
    if ((unsigned char)*s == (unsigned char)c) {
      return (char *)s;
    }
    s = s + 1;
  }
  if ((unsigned char)c == 0) {
    return (char *)s;
  }
  return 0;
}

char *strrchr(const char *s, int c) {
  const char *last = 0;
  while (*s) {
    if ((unsigned char)*s == (unsigned char)c) {
      last = s;
    }
    s = s + 1;
  }
  if ((unsigned char)c == 0) {
    return (char *)s;
  }
  return (char *)last;
}

char *strstr(const char *h, const char *n) {
  size_t nl;
  if (n[0] == 0) {
    return (char *)h;
  }
  nl = strlen(n);
  while (*h) {
    if (strncmp(h, n, nl) == 0) {
      return (char *)h;
    }
    h = h + 1;
  }
  return 0;
}

void *malloc(size_t n) {
  size_t aligned;
  void *p;
  if (n == 0) {
    n = 1;
  }
  aligned = (n + 15u) & ~15u;
  if (heap_used + aligned > CRT_HEAP) {
    if (osgfx_heap_oom_reclaim() == 0 || heap_used + aligned > CRT_HEAP) {
      com1_puts("OSGFX OOM\n");
      return 0;
    }
  }
  p = heap + heap_used;
  heap_used = heap_used + aligned;
  heap_note_hi();
  return p;
}

void free(void *p) { (void)p; }

void *calloc(size_t n, size_t sz) {
  size_t bytes;
  void *p;
  bytes = n * sz;
  p = malloc(bytes);
  if (p != 0) {
    memset(p, 0, bytes);
  }
  return p;
}

void *realloc(void *p, size_t n) {
  void *q;
  if (p == 0) {
    return malloc(n);
  }
  q = malloc(n);
  if (q == 0) {
    return 0;
  }
  memcpy(q, p, n);
  return q;
}

int posix_memalign(void **p, size_t align, size_t n) {
  uintptr_t base;
  size_t pad;
  void *raw;
  if (p == 0 || align < 16) {
    align = 16;
  }
  raw = malloc(n + align);
  if (raw == 0) {
    return 12;
  }
  base = (uintptr_t)raw;
  pad = (align - (base % align)) % align;
  *p = (void *)(base + pad);
  return 0;
}

static void com1_putc(char c) {
  unsigned tries;
  tries = 0;
  while (tries < 100000u) {
    unsigned char st;
    __asm__ volatile("inb %1, %0" : "=a"(st) : "Nd"((unsigned short)0x3fd));
    if ((st & 0x20u) != 0) {
      break;
    }
    tries = tries + 1;
  }
  __asm__ volatile("outb %0, %1" : : "a"((unsigned char)c), "Nd"((unsigned short)0x3f8));
}

void com1_puts(const char *s) {
  while (s != 0 && *s != 0) {
    com1_putc(*s);
    s = s + 1;
  }
}

void abort(void) {
  com1_puts("OSGFX ABORT\n");
  for (;;) {
  }
}

int atexit(void (*fn)(void)) {
  (void)fn;
  return 0;
}

void __cxa_pure_virtual(void) { abort(); }

int __cxa_atexit(void (*fn)(void *), void *arg, void *dso) {
  (void)fn;
  (void)arg;
  (void)dso;
  return 0;
}

void *__dso_handle;

static int g_errno;
int *osgfx_errno(void) { return &g_errno; }

typedef struct { int unused; } FILE;
FILE *stderr;
FILE *stdout;
FILE *stdin;

int fprintf(FILE *f, const char *fmt, ...) {
  (void)f;
  (void)fmt;
  return 0;
}
int vfprintf(FILE *f, const char *fmt, void *ap) {
  (void)f;
  (void)fmt;
  (void)ap;
  return 0;
}
int printf(const char *fmt, ...) {
  (void)fmt;
  return 0;
}
int snprintf(char *s, size_t n, const char *fmt, ...) {
  (void)fmt;
  if (n > 0) {
    s[0] = 0;
  }
  return 0;
}
int vsnprintf(char *s, size_t n, const char *fmt, void *ap) {
  (void)fmt;
  (void)ap;
  if (n > 0) {
    s[0] = 0;
  }
  return 0;
}
int sscanf(const char *s, const char *fmt, ...) {
  (void)s;
  (void)fmt;
  return 0;
}
int remove(const char *path) {
  (void)path;
  return -1;
}
FILE *fopen(const char *path, const char *mode) {
  (void)path;
  (void)mode;
  return 0;
}
int fclose(FILE *f) {
  (void)f;
  return 0;
}
int fflush(FILE *f) {
  (void)f;
  return 0;
}
size_t fread(void *p, size_t sz, size_t n, FILE *f) {
  (void)p;
  (void)sz;
  (void)n;
  (void)f;
  return 0;
}
size_t fwrite(const void *p, size_t sz, size_t n, FILE *f) {
  (void)p;
  (void)sz;
  (void)n;
  (void)f;
  return 0;
}
long ftell(FILE *f) {
  (void)f;
  return 0;
}
int fseek(FILE *f, long off, int whence) {
  (void)f;
  (void)off;
  (void)whence;
  return -1;
}
void perror(const char *s) { (void)s; }

size_t strspn(const char *s, const char *accept) {
  size_t i = 0;
  while (s[i] && strchr(accept, s[i])) {
    i = i + 1;
  }
  return i;
}
size_t strcspn(const char *s, const char *reject) {
  size_t i = 0;
  while (s[i] && !strchr(reject, s[i])) {
    i = i + 1;
  }
  return i;
}

int pthread_self(void) { return 1; }
unsigned long long strtoull(const char *s, char **end, int base) {
  return (unsigned long long)strtoul(s, end, base);
}
int mkdir(const char *path, int mode) {
  (void)path;
  (void)mode;
  return -1;
}
/* clang __builtin_floor/frexp/ldexp on this triple become call/jmp
 * to the same symbol — a hang. Bit math, no libm. SSE2 sqrt/fabs stay. */
static unsigned long long crt_dbits(double x) {
  union {
    double d;
    unsigned long long u;
  } v;
  v.d = x;
  return v.u;
}
static double crt_bitsd(unsigned long long u) {
  union {
    double d;
    unsigned long long u;
  } v;
  v.u = u;
  return v.d;
}

double floor(double x);
double frexp(double x, int *e);
double ldexp(double x, int e);
double trunc(double x);

float cbrtf(float x) { return x; }
double cbrt(double x) { return x; }

typedef struct { int unused; } DIR;
struct dirent { char d_name[256]; };
DIR *opendir(const char *path) {
  (void)path;
  return 0;
}
struct dirent *readdir(DIR *d) {
  (void)d;
  return 0;
}
int closedir(DIR *d) {
  (void)d;
  return -1;
}
size_t malloc_usable_size(void *p) {
  (void)p;
  return 0;
}

/* SQRTSS/SQRTSD directly, NOT __builtin_sqrtf.
 *
 * This was the whole "Skia curved rrect hangs on qemu64" bug (ADR-0161),
 * and it is not a qemu64 bug at all. `sqrtf` must set errno for a negative
 * argument, and SQRTSS cannot, so without -fno-math-errno clang lowers
 * __builtin_sqrtf to a CALL to sqrtf -- inside sqrtf. The linked image was
 *
 *   sqrtf: push %rbp; mov %rsp,%rbp; pop %rbp; jmp sqrtf
 *
 * an infinite self-tail-call. Any Skia geometry that measured a distance
 * wedged the image forever: SkRRect::MakeRectXY corners are conics, conic
 * subdivision calls SkPoint::Distance, Distance calls sqrtf. Plain rects
 * and square rrects never call it, which is exactly the "only curves hang"
 * signature that got read as an AA/Graphite/CPU-feature problem. AA was
 * never involved; -cpu qemu64 was never involved.
 *
 * SSE2 is baseline on x86-64, so the instruction is always available. */
float sqrtf(float x) {
  float r;
  asm("sqrtss %1, %0" : "=x"(r) : "x"(x));
  return r;
}

double sqrt(double x) {
  double r;
  asm("sqrtsd %1, %0" : "=x"(r) : "x"(x));
  return r;
}
float fabsf(float x) { return __builtin_fabsf(x); }
double fabs(double x) { return __builtin_fabs(x); }
float copysignf(float x, float y) { return __builtin_copysignf(x, y); }
double copysign(double x, double y) { return __builtin_copysign(x, y); }

double floor(double x) {
  unsigned long long u;
  unsigned long long exp;
  unsigned long long sign;
  unsigned long long mask;
  int e;
  u = crt_dbits(x);
  exp = (u >> 52) & 0x7ffULL;
  sign = u & 0x8000000000000000ULL;
  if (exp == 0x7ffULL) {
    return x;
  }
  e = (int)exp - 1023;
  if (e < 0) {
    if (sign == 0) {
      return 0.0;
    }
    if ((u & 0x7fffffffffffffffULL) == 0) {
      return x;
    }
    return -1.0;
  }
  if (e >= 52) {
    return x;
  }
  mask = (1ULL << (52 - e)) - 1ULL;
  if ((u & mask) == 0) {
    return x;
  }
  if (sign) {
    u = u + mask;
  }
  return crt_bitsd(u & ~mask);
}

double ceil(double x) {
  unsigned long long u;
  unsigned long long exp;
  unsigned long long sign;
  unsigned long long mask;
  int e;
  u = crt_dbits(x);
  exp = (u >> 52) & 0x7ffULL;
  sign = u & 0x8000000000000000ULL;
  if (exp == 0x7ffULL) {
    return x;
  }
  e = (int)exp - 1023;
  if (e < 0) {
    if ((u & 0x7fffffffffffffffULL) == 0) {
      return x;
    }
    return sign ? -0.0 : 1.0;
  }
  if (e >= 52) {
    return x;
  }
  mask = (1ULL << (52 - e)) - 1ULL;
  if ((u & mask) == 0) {
    return x;
  }
  if (sign == 0) {
    u = u + mask;
  }
  return crt_bitsd(u & ~mask);
}

double trunc(double x) {
  unsigned long long u;
  unsigned long long exp;
  unsigned long long mask;
  int e;
  u = crt_dbits(x);
  exp = (u >> 52) & 0x7ffULL;
  if (exp == 0x7ffULL) {
    return x;
  }
  e = (int)exp - 1023;
  if (e < 0) {
    return crt_bitsd(u & 0x8000000000000000ULL);
  }
  if (e >= 52) {
    return x;
  }
  mask = (1ULL << (52 - e)) - 1ULL;
  return crt_bitsd(u & ~mask);
}

double round(double x) {
  double t;
  double f;
  t = floor(x);
  f = x - t;
  if (f > 0.5) {
    return t + 1.0;
  }
  if (f < 0.5) {
    return t;
  }
  if (x < 0.0) {
    return t;
  }
  return t + 1.0;
}

double frexp(double x, int *exp_out) {
  unsigned long long u;
  unsigned long long sign;
  unsigned long long exp;
  unsigned long long frac;
  int e;
  u = crt_dbits(x);
  sign = u & 0x8000000000000000ULL;
  exp = (u >> 52) & 0x7ffULL;
  frac = u & 0x000fffffffffffffULL;
  if (exp_out == 0) {
    return x;
  }
  if (exp == 0x7ffULL) {
    *exp_out = 0;
    return x;
  }
  if (exp == 0) {
    if (frac == 0) {
      *exp_out = 0;
      return x;
    }
    e = -1022;
    while ((frac & 0x0010000000000000ULL) == 0) {
      frac = frac << 1;
      e = e - 1;
    }
    frac = frac & 0x000fffffffffffffULL;
    *exp_out = e;
    return crt_bitsd(sign | (0x3feULL << 52) | frac);
  }
  *exp_out = (int)exp - 1022;
  return crt_bitsd(sign | (0x3feULL << 52) | frac);
}

double ldexp(double x, int exp_add) {
  unsigned long long u;
  unsigned long long sign;
  unsigned long long exp;
  unsigned long long frac;
  int e;
  int e0;
  double m;
  u = crt_dbits(x);
  sign = u & 0x8000000000000000ULL;
  exp = (u >> 52) & 0x7ffULL;
  frac = u & 0x000fffffffffffffULL;
  if (exp == 0x7ffULL) {
    return x;
  }
  if (exp == 0 && frac == 0) {
    return x;
  }
  if (exp == 0) {
    m = frexp(x, &e0);
    return ldexp(m, e0 + exp_add);
  }
  e = (int)exp + exp_add;
  if (e >= 0x7ff) {
    return crt_bitsd(sign | (0x7ffULL << 52));
  }
  if (e <= 0) {
    if (e < -52) {
      return crt_bitsd(sign);
    }
    frac = (frac | 0x0010000000000000ULL) >> (1 - e);
    return crt_bitsd(sign | frac);
  }
  return crt_bitsd(sign | (((unsigned long long)e) << 52) | frac);
}

double fmod(double x, double y) {
  double q;
  if (y == 0.0) {
    return crt_bitsd(0x7ff8000000000000ULL);
  }
  q = trunc(x / y);
  return x - q * y;
}

double pow(double x, double y) {
  int n;
  double r;
  if (y == 0.0) {
    return 1.0;
  }
  if (x == 0.0) {
    return 0.0;
  }
  n = (int)y;
  if ((double)n != y || n < 0 || n >= 64) {
    return 0.0;
  }
  r = 1.0;
  while (n) {
    if (n & 1) {
      r = r * x;
    }
    x = x * x;
    n = n >> 1;
  }
  return r;
}

/* qemu64 has x87. Stub sin=0/cos=1/tan=0 collapsed rrect edges so
 * SkScan::FillPath never returned from IRQ0. */
double sin(double x) {
  double r;
  __asm__ volatile("fsin" : "=t"(r) : "0"(x));
  return r;
}
double cos(double x) {
  double r;
  __asm__ volatile("fcos" : "=t"(r) : "0"(x));
  return r;
}
double tan(double x) {
  double r;
  __asm__ volatile("fptan; fstp %%st(0)" : "=t"(r) : "0"(x));
  return r;
}
double atan(double x) {
  double r;
  __asm__ volatile("fld1; fpatan" : "=t"(r) : "0"(x));
  return r;
}
double atan2(double y, double x) {
  double r;
  __asm__ volatile("fpatan" : "=t"(r) : "0"(x), "u"(y) : "st(1)");
  return r;
}
double asin(double x) {
  if (x <= -1.0) {
    return -1.5707963267948966;
  }
  if (x >= 1.0) {
    return 1.5707963267948966;
  }
  return atan2(x, sqrt(1.0 - x * x));
}
double acos(double x) {
  if (x <= -1.0) {
    return 3.141592653589793;
  }
  if (x >= 1.0) {
    return 0.0;
  }
  return atan2(sqrt(1.0 - x * x), x);
}
double log(double x) {
  double r;
  if (x <= 0.0) {
    return crt_bitsd(0xfff8000000000000ULL);
  }
  __asm__ volatile("fldln2; fxch; fyl2x" : "=t"(r) : "0"(x));
  return r;
}
double log2(double x) {
  double r;
  if (x <= 0.0) {
    return crt_bitsd(0xfff8000000000000ULL);
  }
  __asm__ volatile("fld1; fxch; fyl2x" : "=t"(r) : "0"(x));
  return r;
}
double exp(double x) {
  double r;
  __asm__ volatile(
      "fldl2e; fmulp; fld %%st(0); frndint; fsubr %%st(0), %%st(1); "
      "fxch; f2xm1; fld1; faddp; fscale; fstp %%st(1)"
      : "=t"(r)
      : "0"(x));
  return r;
}

float floorf(float x) { return (float)floor((double)x); }
float ceilf(float x) { return (float)ceil((double)x); }
float truncf(float x) { return (float)trunc((double)x); }
float roundf(float x) { return (float)round((double)x); }
float powf(float x, float y) { return (float)pow((double)x, (double)y); }
float logf(float x) { return (float)log((double)x); }
float log2f(float x) { return (float)log2((double)x); }
float expf(float x) { return (float)exp((double)x); }
float erff(float x) { return x < 0.f ? -1.f : (x > 0.f ? 1.f : 0.f); }
float sinf(float x) { return (float)sin((double)x); }
float cosf(float x) { return (float)cos((double)x); }
float tanf(float x) { return (float)tan((double)x); }
float asinf(float x) { return (float)asin((double)x); }
float acosf(float x) { return (float)acos((double)x); }
float atanf(float x) { return (float)atan((double)x); }
float atan2f(float y, float x) { return (float)atan2((double)y, (double)x); }
float fmodf(float x, float y) { return (float)fmod((double)x, (double)y); }
float ldexpf(float x, int e) { return (float)ldexp((double)x, e); }
float frexpf(float x, int *e) { return (float)frexp((double)x, e); }
float hypotf(float x, float y) { return sqrtf(x * x + y * y); }
double hypot(double x, double y) { return sqrt(x * x + y * y); }
float nextafterf(float x, float y) {
  (void)y;
  return x;
}
double nextafter(double x, double y) {
  (void)y;
  return x;
}
float fminf(float a, float b) { return a < b ? a : b; }
double fmin(double a, double b) { return a < b ? a : b; }
float fmaxf(float a, float b) { return a > b ? a : b; }
double fmax(double a, double b) { return a > b ? a : b; }
float fmaf(float x, float y, float z) { return x * y + z; }
double fma(double x, double y, double z) { return x * y + z; }
float lrintf(float x) { return (float)(long)round((double)x); }
double lrint(double x) { return (double)(long)round(x); }

int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }

typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;
div_t div(int n, int d) {
  div_t r;
  r.quot = n / d;
  r.rem = n % d;
  return r;
}
ldiv_t ldiv(long n, long d) {
  ldiv_t r;
  r.quot = n / d;
  r.rem = n % d;
  return r;
}
lldiv_t lldiv(long long n, long long d) {
  lldiv_t r;
  r.quot = n / d;
  r.rem = n % d;
  return r;
}

int isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
int isdigit(int c) { return c >= '0' && c <= '9'; }
int isxdigit(int c) {
  return isdigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
int isalpha(int c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
int isalnum(int c) { return isalpha(c) || isdigit(c); }
int isprint(int c) { return c >= 32 && c < 127; }
int isupper(int c) { return c >= 'A' && c <= 'Z'; }
int islower(int c) { return c >= 'a' && c <= 'z'; }
int toupper(int c) { return islower(c) ? c - 'a' + 'A' : c; }
int tolower(int c) { return isupper(c) ? c - 'A' + 'a' : c; }

static void qsort_swap(unsigned char *a, unsigned char *b, size_t sz) {
  size_t i;
  unsigned char t;
  i = 0;
  while (i < sz) {
    t = a[i];
    a[i] = b[i];
    b[i] = t;
    i = i + 1;
  }
}

void qsort(void *base, size_t n, size_t sz, int (*cmp)(const void *, const void *)) {
  size_t i;
  size_t j;
  unsigned char *b = (unsigned char *)base;
  if (n < 2 || sz == 0) {
    return;
  }
  i = 0;
  while (i < n) {
    j = i + 1;
    while (j < n) {
      if (cmp(b + j * sz, b + i * sz) < 0) {
        qsort_swap(b + i * sz, b + j * sz, sz);
      }
      j = j + 1;
    }
    i = i + 1;
  }
}

void *bsearch(const void *key, const void *base, size_t n, size_t sz,
              int (*cmp)(const void *, const void *)) {
  const unsigned char *b = (const unsigned char *)base;
  size_t lo = 0;
  size_t hi = n;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    int c = cmp(key, b + mid * sz);
    if (c == 0) {
      return (void *)(b + mid * sz);
    }
    if (c < 0) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return 0;
}

int atoi(const char *s) { return (int)strtol(s, 0, 10); }
long atol(const char *s) { return strtol(s, 0, 10); }
double atof(const char *s) { return strtod(s, 0); }

long strtol(const char *s, char **end, int base) {
  long v = 0;
  int sign = 1;
  if (s == 0) {
    return 0;
  }
  while (isspace((unsigned char)*s)) {
    s = s + 1;
  }
  if (*s == '-') {
    sign = -1;
    s = s + 1;
  } else if (*s == '+') {
    s = s + 1;
  }
  if (base == 0) {
    base = 10;
  }
  while (*s) {
    int d;
    if (isdigit((unsigned char)*s)) {
      d = *s - '0';
    } else if (*s >= 'a' && *s <= 'z') {
      d = *s - 'a' + 10;
    } else if (*s >= 'A' && *s <= 'Z') {
      d = *s - 'A' + 10;
    } else {
      break;
    }
    if (d >= base) {
      break;
    }
    v = v * base + d;
    s = s + 1;
  }
  if (end) {
    *end = (char *)s;
  }
  return sign * v;
}

unsigned long strtoul(const char *s, char **end, int base) {
  return (unsigned long)strtol(s, end, base);
}

double strtod(const char *s, char **end) {
  double v = 0;
  double frac = 0.1;
  int sign = 1;
  int seen = 0;
  if (s == 0) {
    return 0;
  }
  while (isspace((unsigned char)*s)) {
    s = s + 1;
  }
  if (*s == '-') {
    sign = -1;
    s = s + 1;
  }
  while (isdigit((unsigned char)*s)) {
    v = v * 10 + (*s - '0');
    s = s + 1;
    seen = 1;
  }
  if (*s == '.') {
    s = s + 1;
    while (isdigit((unsigned char)*s)) {
      v = v + frac * (*s - '0');
      frac = frac * 0.1;
      s = s + 1;
      seen = 1;
    }
  }
  (void)seen;
  if (end) {
    *end = (char *)s;
  }
  return sign * v;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off) {
  (void)addr;
  (void)prot;
  (void)flags;
  (void)fd;
  (void)off;
  return malloc(len);
}
int munmap(void *addr, size_t len) {
  (void)addr;
  (void)len;
  return 0;
}

long sysconf(int name) {
  (void)name;
  return 4096;
}
int getpagesize(void) { return 4096; }
int close(int fd) {
  (void)fd;
  return -1;
}
long read(int fd, void *buf, size_t n) {
  (void)fd;
  (void)buf;
  (void)n;
  return -1;
}
long write(int fd, const void *buf, size_t n) {
  (void)fd;
  (void)buf;
  (void)n;
  return -1;
}

typedef long time_t;
struct timespec { time_t tv_sec; long tv_nsec; };
struct timeval { time_t tv_sec; long tv_usec; };
static unsigned long long crt_now_ns;
static unsigned long long crt_advance(void) {
  crt_now_ns = crt_now_ns + 1000000ull;
  return crt_now_ns;
}
time_t time(time_t *t) {
  time_t s;
  s = (time_t)(crt_advance() / 1000000000ull);
  if (t) {
    *t = s;
  }
  return s;
}
int clock_gettime(int clk, struct timespec *ts) {
  unsigned long long ns;
  (void)clk;
  ns = crt_advance();
  if (ts) {
    ts->tv_sec = (time_t)(ns / 1000000000ull);
    ts->tv_nsec = (long)(ns % 1000000000ull);
  }
  return 0;
}
int gettimeofday(struct timeval *tv, void *tz) {
  unsigned long long ns;
  (void)tz;
  ns = crt_advance();
  if (tv) {
    tv->tv_sec = (time_t)(ns / 1000000000ull);
    tv->tv_usec = (long)((ns / 1000ull) % 1000000ull);
  }
  return 0;
}

int pthread_mutex_init(int *m, const void *a) {
  (void)m;
  (void)a;
  return 0;
}
int pthread_mutex_destroy(int *m) {
  (void)m;
  return 0;
}
int pthread_mutex_lock(int *m) {
  (void)m;
  return 0;
}
int pthread_mutex_unlock(int *m) {
  (void)m;
  return 0;
}
int pthread_once(int *o, void (*fn)(void)) {
  if (o == 0) {
    return 0;
  }
  if (*o != 0) {
    return 0;
  }
  *o = 1;
  fn();
  return 0;
}
int pthread_cond_wait(int *c, int *m) {
  (void)c;
  (void)m;
  return 0;
}
int pthread_cond_signal(int *c) {
  (void)c;
  return 0;
}
int sched_yield(void) { return 0; }

int open(const char *path, int flags, ...) {
  (void)path;
  (void)flags;
  return -1;
}
int stat(const char *path, void *st) {
  (void)path;
  (void)st;
  return -1;
}
char *setlocale(int cat, const char *loc) {
  (void)cat;
  (void)loc;
  return 0;
}

typedef unsigned wint_t;
wchar_t *wcschr(const wchar_t *s, wchar_t c) {
  while (*s) {
    if (*s == c) {
      return (wchar_t *)s;
    }
    s = s + 1;
  }
  return 0;
}
wchar_t *wcsrchr(const wchar_t *s, wchar_t c) {
  const wchar_t *last = 0;
  while (*s) {
    if (*s == c) {
      last = s;
    }
    s = s + 1;
  }
  return (wchar_t *)last;
}
wchar_t *wcspbrk(const wchar_t *s, const wchar_t *a) {
  (void)a;
  (void)s;
  return 0;
}
wchar_t *wcsstr(const wchar_t *s, const wchar_t *n) {
  (void)n;
  (void)s;
  return 0;
}
wchar_t *wmemchr(const wchar_t *s, wchar_t c, size_t n) {
  size_t i = 0;
  while (i < n) {
    if (s[i] == c) {
      return (wchar_t *)(s + i);
    }
    i = i + 1;
  }
  return 0;
}
size_t wcslen(const wchar_t *s) {
  size_t n = 0;
  while (s[n]) {
    n = n + 1;
  }
  return n;
}
int wcscmp(const wchar_t *a, const wchar_t *b) {
  while (*a && *a == *b) {
    a = a + 1;
    b = b + 1;
  }
  return (int)(*a - *b);
}
int wcsncmp(const wchar_t *a, const wchar_t *b, size_t n) {
  size_t i = 0;
  while (i < n) {
    if (a[i] != b[i]) {
      return (int)(a[i] - b[i]);
    }
    if (a[i] == 0) {
      return 0;
    }
    i = i + 1;
  }
  return 0;
}
wchar_t *wcscpy(wchar_t *d, const wchar_t *s) {
  size_t i = 0;
  while (1) {
    d[i] = s[i];
    if (s[i] == 0) {
      return d;
    }
    i = i + 1;
  }
}
wchar_t *wcsncpy(wchar_t *d, const wchar_t *s, size_t n) {
  size_t i = 0;
  while (i < n && s[i] != 0) {
    d[i] = s[i];
    i = i + 1;
  }
  while (i < n) {
    d[i] = 0;
    i = i + 1;
  }
  return d;
}
wchar_t *wmemcpy(wchar_t *d, const wchar_t *s, size_t n) {
  return (wchar_t *)memcpy(d, s, n * sizeof(wchar_t));
}
wchar_t *wmemmove(wchar_t *d, const wchar_t *s, size_t n) {
  return (wchar_t *)memmove(d, s, n * sizeof(wchar_t));
}
wchar_t *wmemset(wchar_t *d, wchar_t c, size_t n) {
  size_t i = 0;
  while (i < n) {
    d[i] = c;
    i = i + 1;
  }
  return d;
}
int wmemcmp(const wchar_t *a, const wchar_t *b, size_t n) {
  size_t i = 0;
  while (i < n) {
    if (a[i] != b[i]) {
      return (int)(a[i] - b[i]);
    }
    i = i + 1;
  }
  return 0;
}

void *_Znwm(size_t n) { return malloc(n); }
void *_Znam(size_t n) { return malloc(n); }
void _ZdlPv(void *p) { free(p); }
void _ZdaPv(void *p) { free(p); }
void _ZdlPvm(void *p, size_t n) {
  (void)n;
  free(p);
}
void _ZdaPvm(void *p, size_t n) {
  (void)n;
  free(p);
}
void *_ZnwmSt11align_val_t(size_t n, size_t a) {
  void *p;
  (void)posix_memalign(&p, a < 16 ? 16 : a, n);
  return p;
}
void _ZdlPvSt11align_val_t(void *p, size_t a) {
  (void)a;
  free(p);
}

void __stack_chk_fail(void) { abort(); }

int __cxa_guard_acquire(uint64_t *guard) {
  unsigned char *b;
  if (guard == 0) {
    return 0;
  }
  b = (unsigned char *)guard;
  if (b[0] != 0) {
    return 0;
  }
  return 1;
}
void __cxa_guard_release(uint64_t *guard) {
  if (guard != 0) {
    ((unsigned char *)guard)[0] = 1;
  }
}
void __cxa_guard_abort(uint64_t *guard) {
  if (guard != 0) {
    ((unsigned char *)guard)[0] = 0;
  }
}

typedef struct { int v; } sem_t;
int sem_init(sem_t *s, int pshared, unsigned value) {
  (void)pshared;
  if (s) {
    s->v = (int)value;
  }
  return 0;
}
int sem_destroy(sem_t *s) {
  (void)s;
  return 0;
}
int sem_wait(sem_t *s) {
  (void)s;
  return 0;
}
int sem_post(sem_t *s) {
  (void)s;
  return 0;
}
int sem_trywait(sem_t *s) {
  (void)s;
  return 0;
}
