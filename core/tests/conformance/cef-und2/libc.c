/* cef-und2/libc.c — OUR tiny LIBC.SO. Not glibc.
 *
 * ADR-0179: two hundred measured high-traffic UND faces for official
 * libcef PLT binds (100 beyond ADR-0178). Each export is a self-contained
 * leaf body (no cross-calls) so the kernel can copy st_size bytes into
 * the RX face slab. No allocator faces (absent from PLT).
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

int bcmp(const void *a, const void *b, unsigned long n) {
  const unsigned char *x = (const unsigned char *)a;
  const unsigned char *y = (const unsigned char *)b;
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (x[i] != y[i]) {
      return 1;
    }
  }
  return 0;
}

void *memchr(const void *s, int c, unsigned long n) {
  const unsigned char *p = (const unsigned char *)s;
  unsigned char v = (unsigned char)c;
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (p[i] == v) {
      return (void *)(unsigned long)(p + i);
    }
  }
  return (void *)0;
}

int strncmp(const char *a, const char *b, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    unsigned char x = (unsigned char)a[i];
    unsigned char y = (unsigned char)b[i];
    if (x != y) {
      return (int)x - (int)y;
    }
    if (x == 0) {
      return 0;
    }
  }
  return 0;
}

char *strcpy(char *dst, const char *src) {
  unsigned long i = 0;
  for (;;) {
    dst[i] = src[i];
    if (src[i] == 0) {
      break;
    }
    i++;
  }
  return dst;
}

int strcmp(const char *a, const char *b) {
  unsigned long i = 0;
  for (;;) {
    unsigned char x = (unsigned char)a[i];
    unsigned char y = (unsigned char)b[i];
    if (x != y) {
      return (int)x - (int)y;
    }
    if (x == 0) {
      return 0;
    }
    i++;
  }
}

unsigned long strnlen(const char *s, unsigned long n) {
  unsigned long i = 0;
  while (i < n && s[i]) {
    i++;
  }
  return i;
}

char *strncpy(char *dst, const char *src, unsigned long n) {
  volatile unsigned char *d = (volatile unsigned char *)dst;
  unsigned long i = 0;
  while (i < n && src[i]) {
    d[i] = (unsigned char)src[i];
    i++;
  }
  while (i < n) {
    d[i] = 0;
    i++;
  }
  return dst;
}

char *strchr(const char *s, int c) {
  unsigned char v = (unsigned char)c;
  unsigned long i = 0;
  for (;;) {
    if ((unsigned char)s[i] == v) {
      return (char *)(unsigned long)(s + i);
    }
    if (s[i] == 0) {
      return (char *)0;
    }
    i++;
  }
}

char *strrchr(const char *s, int c) {
  unsigned char v = (unsigned char)c;
  char *last = (char *)0;
  unsigned long i = 0;
  for (;;) {
    if ((unsigned char)s[i] == v) {
      last = (char *)(unsigned long)(s + i);
    }
    if (s[i] == 0) {
      return last;
    }
    i++;
  }
}

char *strstr(const char *hay, const char *ndl) {
  unsigned long i;
  unsigned long j;
  if (ndl[0] == 0) {
    return (char *)(unsigned long)hay;
  }
  i = 0;
  while (hay[i]) {
    j = 0;
    while (ndl[j] && hay[i + j] == ndl[j]) {
      j++;
    }
    if (ndl[j] == 0) {
      return (char *)(unsigned long)(hay + i);
    }
    i++;
  }
  return (char *)0;
}

char *strcat(char *dst, const char *src) {
  unsigned long i = 0;
  unsigned long j = 0;
  while (dst[i]) {
    i++;
  }
  for (;;) {
    dst[i] = src[j];
    if (src[j] == 0) {
      break;
    }
    i++;
    j++;
  }
  return dst;
}

unsigned long strspn(const char *s, const char *accept) {
  unsigned long i = 0;
  unsigned long j;
  for (;;) {
    if (s[i] == 0) {
      return i;
    }
    j = 0;
    while (accept[j] && accept[j] != s[i]) {
      j++;
    }
    if (accept[j] == 0) {
      return i;
    }
    i++;
  }
}

unsigned long strcspn(const char *s, const char *reject) {
  unsigned long i = 0;
  unsigned long j;
  for (;;) {
    if (s[i] == 0) {
      return i;
    }
    j = 0;
    while (reject[j]) {
      if (reject[j] == s[i]) {
        return i;
      }
      j++;
    }
    i++;
  }
}

char *strncat(char *dst, const char *src, unsigned long n) {
  unsigned long i = 0;
  unsigned long j = 0;
  while (dst[i]) {
    i++;
  }
  while (j < n && src[j]) {
    dst[i] = src[j];
    i++;
    j++;
  }
  dst[i] = 0;
  return dst;
}

int strcasecmp(const char *a, const char *b) {
  unsigned long i = 0;
  for (;;) {
    unsigned char x = (unsigned char)a[i];
    unsigned char y = (unsigned char)b[i];
    if (x >= 65 && x <= 90) {
      x = (unsigned char)(x + 32);
    }
    if (y >= 65 && y <= 90) {
      y = (unsigned char)(y + 32);
    }
    if (x != y) {
      return (int)x - (int)y;
    }
    if (x == 0) {
      return 0;
    }
    i++;
  }
}

int strncasecmp(const char *a, const char *b, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    unsigned char x = (unsigned char)a[i];
    unsigned char y = (unsigned char)b[i];
    if (x >= 65 && x <= 90) {
      x = (unsigned char)(x + 32);
    }
    if (y >= 65 && y <= 90) {
      y = (unsigned char)(y + 32);
    }
    if (x != y) {
      return (int)x - (int)y;
    }
    if (x == 0) {
      return 0;
    }
  }
  return 0;
}

int wcsncmp(const int *a, const int *b, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (a[i] != b[i]) {
      return (a[i] < b[i]) ? -1 : 1;
    }
    if (a[i] == 0) {
      return 0;
    }
  }
  return 0;
}

unsigned long wcslen(const int *s) {
  unsigned long n = 0;
  while (s[n]) {
    n++;
  }
  return n;
}

int *wmemchr(const int *s, int c, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (s[i] == c) {
      return (int *)(unsigned long)(s + i);
    }
  }
  return (int *)0;
}

int wcscmp(const int *a, const int *b) {
  unsigned long i = 0;
  for (;;) {
    if (a[i] != b[i]) {
      return (a[i] < b[i]) ? -1 : 1;
    }
    if (a[i] == 0) {
      return 0;
    }
    i++;
  }
}

int wmemcmp(const int *a, const int *b, unsigned long n) {
  unsigned long i;
  for (i = 0; i < n; i++) {
    if (a[i] != b[i]) {
      return (a[i] < b[i]) ? -1 : 1;
    }
  }
  return 0;
}

int *wcschr(const int *s, int c) {
  unsigned long i = 0;
  for (;;) {
    if (s[i] == c) {
      return (int *)(unsigned long)(s + i);
    }
    if (s[i] == 0) {
      return (int *)0;
    }
    i++;
  }
}

int iswdigit(int c) {
  return (c >= 48 && c <= 57) ? 1 : 0;
}

int iswalnum(int c) {
  if (c >= 48 && c <= 57) {
    return 1;
  }
  if (c >= 65 && c <= 90) {
    return 1;
  }
  if (c >= 97 && c <= 122) {
    return 1;
  }
  return 0;
}

int *wcspbrk(const int *s, const int *accept) {
  unsigned long i = 0;
  unsigned long j;
  for (;;) {
    if (s[i] == 0) {
      return (int *)0;
    }
    j = 0;
    while (accept[j]) {
      if (accept[j] == s[i]) {
        return (int *)(unsigned long)(s + i);
      }
      j++;
    }
    i++;
  }
}

int *wcscpy(int *dst, const int *src) {
  unsigned long i = 0;
  for (;;) {
    dst[i] = src[i];
    if (src[i] == 0) {
      break;
    }
    i++;
  }
  return dst;
}

int towupper(int c) {
  if (c >= 97 && c <= 122) {
    return c - 32;
  }
  return c;
}

int towlower(int c) {
  if (c >= 65 && c <= 90) {
    return c + 32;
  }
  return c;
}

/* Base-10-only parsers — leaf bodies must stay ≤160 bytes. */
long strtol(const char *s, char **end, int base) {
  unsigned long i = 0;
  int neg = 0;
  unsigned long v = 0;
  (void)base;
  while (s[i] == ' ' || s[i] == '\t') {
    i++;
  }
  if (s[i] == '+' || s[i] == '-') {
    neg = (s[i] == '-');
    i++;
  }
  while (s[i] >= '0' && s[i] <= '9') {
    v = v * 10UL + (unsigned long)(s[i] - '0');
    i++;
  }
  if (end) {
    *end = (char *)(unsigned long)(s + i);
  }
  if (neg) {
    return -(long)v;
  }
  return (long)v;
}

unsigned long strtoul(const char *s, char **end, int base) {
  unsigned long i = 0;
  unsigned long v = 0;
  (void)base;
  while (s[i] == ' ' || s[i] == '\t') {
    i++;
  }
  if (s[i] == '+') {
    i++;
  }
  while (s[i] >= '0' && s[i] <= '9') {
    v = v * 10UL + (unsigned long)(s[i] - '0');
    i++;
  }
  if (end) {
    *end = (char *)(unsigned long)(s + i);
  }
  return v;
}

long long strtoll(const char *s, char **end, int base) {
  unsigned long i = 0;
  int neg = 0;
  unsigned long v = 0;
  (void)base;
  while (s[i] == ' ' || s[i] == '\t') {
    i++;
  }
  if (s[i] == '+' || s[i] == '-') {
    neg = (s[i] == '-');
    i++;
  }
  while (s[i] >= '0' && s[i] <= '9') {
    v = v * 10UL + (unsigned long)(s[i] - '0');
    i++;
  }
  if (end) {
    *end = (char *)(unsigned long)(s + i);
  }
  if (neg) {
    return -(long long)v;
  }
  return (long long)v;
}

unsigned long long strtoull(const char *s, char **end, int base) {
  unsigned long i = 0;
  unsigned long v = 0;
  (void)base;
  while (s[i] == ' ' || s[i] == '\t') {
    i++;
  }
  if (s[i] == '+') {
    i++;
  }
  while (s[i] >= '0' && s[i] <= '9') {
    v = v * 10UL + (unsigned long)(s[i] - '0');
    i++;
  }
  if (end) {
    *end = (char *)(unsigned long)(s + i);
  }
  return (unsigned long long)v;
}

int sched_yield(void) {
  return 0;
}

int getpid(void) {
  return 1;
}

int getpagesize(void) {
  return 4096;
}

float nanf(const char *tag) {
  float f;
  unsigned u;
  (void)tag;
  u = 0x7fc00000u;
  __asm__ volatile("movd %1, %0" : "=x"(f) : "r"(u));
  return f;
}

double nan(const char *tag) {
  double d;
  unsigned long u;
  (void)tag;
  u = 0x7ff8000000000000UL;
  __asm__ volatile("movq %1, %0" : "=x"(d) : "r"(u));
  return d;
}

char *getenv(const char *name) {
  (void)name;
  return (char *)0;
}

unsigned long getauxval(unsigned long type) {
  (void)type;
  return 0;
}

long time(long *t) {
  if (t) {
    *t = 0;
  }
  return 0;
}

int usleep(unsigned int usec) {
  (void)usec;
  return 0;
}

unsigned getuid(void) {
  return 0;
}

int isatty(int fd) {
  (void)fd;
  return 0;
}

int rand(void) {
  return 4;
}

unsigned geteuid(void) {
  return 0;
}

/* ADR-0178 faces 50..99 */
float floorf(float x) {
  return x;
}

float ceilf(float x) {
  return x;
}

float truncf(float x) {
  return x;
}

float roundf(float x) {
  return x;
}

double floor(double x) {
  return x;
}

double ceil(double x) {
  return x;
}

double trunc(double x) {
  return x;
}

double round(double x) {
  return x;
}

int putchar(int c) {
  return c;
}

int puts(const char *s) {
  (void)s;
  return 0;
}

void srand(unsigned seed) {
  (void)seed;
}

int getppid(void) {
  return 1;
}

unsigned sleep(unsigned sec) {
  (void)sec;
  return 0;
}

long write(int fd, const void *buf, unsigned long n) {
  (void)fd;
  (void)buf;
  (void)n;
  return -1;
}

long read(int fd, void *buf, unsigned long n) {
  (void)fd;
  (void)buf;
  (void)n;
  return -1;
}

void abort(void) {
}

void exit(int code) {
  (void)code;
}

void _exit(int code) {
  (void)code;
}

int unlink(const char *p) {
  (void)p;
  return -1;
}

int rename(const char *a, const char *b) {
  (void)a;
  (void)b;
  return -1;
}

int mkdir(const char *p, int m) {
  (void)p;
  (void)m;
  return -1;
}

int rmdir(const char *p) {
  (void)p;
  return -1;
}

int access(const char *p, int m) {
  (void)p;
  (void)m;
  return -1;
}

int chmod(const char *p, int m) {
  (void)p;
  (void)m;
  return -1;
}

int fileno(void *fp) {
  (void)fp;
  return 0;
}

int feof(void *fp) {
  (void)fp;
  return 0;
}

int ferror(void *fp) {
  (void)fp;
  return 0;
}

int fflush(void *fp) {
  (void)fp;
  return 0;
}

int gethostname(char *buf, unsigned long n) {
  (void)buf;
  (void)n;
  return -1;
}

int munmap(void *p, unsigned long n) {
  (void)p;
  (void)n;
  return -1;
}

int mprotect(void *p, unsigned long n, int prot) {
  (void)p;
  (void)n;
  (void)prot;
  return -1;
}

unsigned alarm(unsigned sec) {
  (void)sec;
  return 0;
}

int pause(void) {
  return -1;
}

int kill(int pid, int sig) {
  (void)pid;
  (void)sig;
  return -1;
}

int dup(int fd) {
  (void)fd;
  return -1;
}

int dup2(int a, int b) {
  (void)a;
  (void)b;
  return -1;
}

int pipe(int fd[2]) {
  (void)fd;
  return -1;
}

int getpriority(int which, int who) {
  (void)which;
  (void)who;
  return 0;
}

int setpriority(int which, int who, int prio) {
  (void)which;
  (void)who;
  (void)prio;
  return -1;
}

float sinf(float x) {
  (void)x;
  return 0.0f;
}

float cosf(float x) {
  (void)x;
  return 0.0f;
}

float tanf(float x) {
  (void)x;
  return 0.0f;
}

float expf(float x) {
  (void)x;
  return 0.0f;
}

float logf(float x) {
  (void)x;
  return 0.0f;
}

float powf(float x, float y) {
  (void)x;
  (void)y;
  return 0.0f;
}

float fmodf(float x, float y) {
  (void)x;
  (void)y;
  return 0.0f;
}

int socket(int d, int t, int p) {
  (void)d;
  (void)t;
  (void)p;
  return -1;
}

long sysconf(int name) {
  (void)name;
  return -1;
}

float hypotf(float x, float y) {
  (void)x;
  (void)y;
  return 0.0f;
}

float nearbyintf(float x) {
  return x;
}


/* ADR-0179 faces 100..199 — leaf stubs, tiny bodies. */
double sin(double x) { (void)x; return 0.0; }
double cos(double x) { (void)x; return 0.0; }
double tan(double x) { (void)x; return 0.0; }
double asin(double x) { (void)x; return 0.0; }
double acos(double x) { (void)x; return 0.0; }
double atan(double x) { (void)x; return 0.0; }
double atan2(double x, double y) { (void)x; (void)y; return 0.0; }
double exp(double x) { (void)x; return 0.0; }
double log(double x) { (void)x; return 0.0; }
double exp2(double x) { (void)x; return 0.0; }
double log2(double x) { (void)x; return 0.0; }
double pow(double x, double y) { (void)x; (void)y; return 0.0; }
double hypot(double x, double y) { (void)x; (void)y; return 0.0; }
double sinh(double x) { (void)x; return 0.0; }
double cosh(double x) { (void)x; return 0.0; }
double tanh(double x) { (void)x; return 0.0; }
float asinf(float x) { (void)x; return 0.0f; }
float acosf(float x) { (void)x; return 0.0f; }
float atanf(float x) { (void)x; return 0.0f; }
float atan2f(float x, float y) { (void)x; (void)y; return 0.0f; }
float sinhf(float x) { (void)x; return 0.0f; }
float coshf(float x) { (void)x; return 0.0f; }
float tanhf(float x) { (void)x; return 0.0f; }
float exp2f(float x) { (void)x; return 0.0f; }
float log2f(float x) { (void)x; return 0.0f; }
double log10(double x) { (void)x; return 0.0; }
float log10f(float x) { (void)x; return 0.0f; }
double rint(double x) { (void)x; return 0.0; }
float rintf(float x) { (void)x; return 0.0f; }
double nearbyint(double x) { (void)x; return 0.0; }
double fma(double x, double y, double z) { (void)x; (void)y; (void)z; return 0.0; }
float fmaf(float x, float y, float z) { (void)x; (void)y; (void)z; return 0.0f; }
double modf(double x, double *ip) { if (ip) *ip = 0.0; (void)x; return 0.0; }
float modff(float x, float *ip) { if (ip) *ip = 0.0f; (void)x; return 0.0f; }
double frexp(double x, int *exp) { if (exp) *exp = 0; (void)x; return 0.0; }
float frexpf(float x, int *exp) { if (exp) *exp = 0; (void)x; return 0.0f; }
double ldexp(double x, int exp) { (void)x; (void)exp; return 0.0; }
float ldexpf(float x, int exp) { (void)x; (void)exp; return 0.0f; }
double cbrt(double x) { (void)x; return 0.0; }
float cbrtf(float x) { (void)x; return 0.0f; }
double nextafter(double x, double y) { (void)x; (void)y; return 0.0; }
float nextafterf(float x, float y) { (void)x; (void)y; return 0.0f; }
double acosh(double x) { (void)x; return 0.0; }
float acoshf(float x) { (void)x; return 0.0f; }
double asinh(double x) { (void)x; return 0.0; }
float asinhf(float x) { (void)x; return 0.0f; }
double atanh(double x) { (void)x; return 0.0; }
float atanhf(float x) { (void)x; return 0.0f; }
double scalbn(double x, int n) { (void)x; (void)n; return 0.0; }
double remainder(double x, double y) { (void)x; (void)y; return 0.0; }
int ilogbf(float x) { (void)x; return 0; }
double erf(double x) { (void)x; return 0.0; }
float erff(float x) { (void)x; return 0.0f; }
double log1p(double x) { (void)x; return 0.0; }
float expm1f(float x) { (void)x; return 0.0f; }
unsigned long fread(void *p, unsigned long s, unsigned long n, void *f) { (void)p;(void)s;(void)n;(void)f; return 0; }
unsigned long fwrite(void *p, unsigned long s, unsigned long n, void *f) { (void)p;(void)s;(void)n;(void)f; return 0; }
int fseek(void *f, long off, int whence) { (void)f;(void)off;(void)whence; return -1; }
long ftell(void *f) { (void)f; return -1; }
char *fgets(char *s, int n, void *f) { (void)s;(void)n;(void)f; return (char *)0; }
int fclose(void *f) { (void)f; return -1; }
int fputs(const char *s, void *f) { (void)s;(void)f; return -1; }
int printf(const char *fmt, ...) { (void)fmt; return 0; }
int snprintf(char *s, unsigned long n, const char *fmt, ...) { (void)s;(void)n;(void)fmt; return 0; }
int vsnprintf(char *s, unsigned long n, const char *fmt, void *ap) { (void)s;(void)n;(void)fmt;(void)ap; return 0; }
int fprintf(void *f, const char *fmt, ...) { (void)f;(void)fmt; return 0; }
int sprintf(char *s, const char *fmt, ...) { (void)s;(void)fmt; return 0; }
int fputc(int c, void *f) { (void)c;(void)f; return -1; }
int getc(void *f) { (void)f; return -1; }
int ungetc(int c, void *f) { (void)c;(void)f; return -1; }
int setvbuf(void *f, char *b, int m, unsigned long s) { (void)f;(void)b;(void)m;(void)s; return -1; }
void rewind(void *f) { (void)f; }
void setbuf(void *f, char *b) { (void)f;(void)b; }
int sigaction(int sig, const void *act, void *old) { (void)sig;(void)act;(void)old; return -1; }
int raise(int sig) { (void)sig; return -1; }
int nanosleep(const void *req, void *rem) { (void)req;(void)rem; return -1; }
int clock_gettime(int clk, void *ts) { (void)clk;(void)ts; return -1; }
void *signal(int sig, void *handler) { (void)sig;(void)handler; return (void *)0; }
char *strerror(int err) { (void)err; return (char *)0; }
int strerror_r(int err, char *b, unsigned long n) { (void)err;(void)b;(void)n; return -1; }
int uname(void *buf) { (void)buf; return -1; }
void *opendir(const char *p) { (void)p; return (void *)0; }
int closedir(void *d) { (void)d; return -1; }
int madvise(void *a, unsigned long n, int adv) { (void)a;(void)n;(void)adv; return -1; }
void tzset(void) {}
int fork(void) { return -1; }
int chdir(const char *p) { (void)p; return -1; }
int poll(void *fds, unsigned long n, int t) { (void)fds;(void)n;(void)t; return -1; }
void qsort(void *b, unsigned long n, unsigned long s, void *cmp) { (void)b;(void)n;(void)s;(void)cmp; }
int bind(int fd, const void *a, unsigned len) { (void)fd;(void)a;(void)len; return -1; }
int listen(int fd, int n) { (void)fd;(void)n; return -1; }
int shutdown(int fd, int n) { (void)fd;(void)n; return -1; }
int connect(int fd, const void *a, unsigned len) { (void)fd;(void)a;(void)len; return -1; }
int accept(int fd, void *a, void *l) { (void)fd;(void)a;(void)l; return -1; }
long writev(int fd, const void *iov, int n) { (void)fd;(void)iov;(void)n; return -1; }
int setsockopt(int fd, int l, int n, void *v, void *len) { (void)fd;(void)l;(void)n;(void)v;(void)len; return -1; }
int getsockopt(int fd, int l, int n, void *v, void *len) { (void)fd;(void)l;(void)n;(void)v;(void)len; return -1; }
void *gmtime(const long *t) { (void)t; return (void *)0; }
void *gmtime_r(const long *t, void *tm) { (void)t;(void)tm; return (void *)0; }
long mktime(void *tm) {
  (void)tm;
  return -1;
}

__attribute__((naked)) int select(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int ioctl(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int strdup(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int strtod(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int strftime(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fcntl(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int prctl(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sigemptyset(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sigfillset(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sigaddset(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sigdelset(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sigprocmask(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sigaltstack(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sem_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sem_wait(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sem_post(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sem_destroy(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sem_timedwait(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mmap64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int open64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int openat64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fopen64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fdopen(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int lseek64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pread64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pwrite64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int ftruncate64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fseeko64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int ftello64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mkstemp64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mkostemp64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mkdtemp(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int readdir64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getgrnam(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getgrgid(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getpwuid(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int eventfd(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int timerfd_create(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int timerfd_settime(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sched_setscheduler(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sched_getscheduler(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sched_getparam(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sched_getaffinity(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int newlocale(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int freelocale(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int uselocale(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int strtod_l(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int setlocale(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int localeconv(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int setenv(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int unsetenv(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int setsid(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int readlink(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int setpgid(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int execvp(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int execlp(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int execv(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int system(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int clone(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int vfprintf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fchmod(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int freeaddrinfo(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int socketpair(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getsockname(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int inet_ntop(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sendmsg(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int recvmsg(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int gai_strerror(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getifaddrs(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int freeifaddrs(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mremap(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int ppoll(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int open_memstream(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int epoll_create1(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int epoll_create(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int epoll_ctl(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int epoll_wait(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int msync(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int posix_fallocate64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int posix_fadvise64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fallocate64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int sendfile64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fdatasync(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int utimensat(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int futimens(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getrlimit64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int setrlimit64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int inotify_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int inotify_add_watch(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int inotify_rm_watch(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int tcflush(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int tcdrain(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int syscall(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int remove(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pathconf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fsync(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int link(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int symlink(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int unlinkat(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getcwd(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int realpath(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int gettimeofday(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int difftime(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int timegm(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int wcstol(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int swprintf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int vswprintf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int vasprintf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fmod(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int log1pf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int lround(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int lroundf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int llround(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int llroundf(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int getopt_long(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int waitpid(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int waitid(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pipe2(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int flock(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int lchown(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int umask(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mincore(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int dirfd(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int openlog(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int syslog(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int closelog(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int statvfs64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int statfs64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fstatfs64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fnmatch(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int creat64(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int fdopendir(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int wcrtomb(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int mbrtowc(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int wcsftime(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int strndup(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int rand_r(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int initstate_r(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int random_r(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int longjmp(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int _setjmp(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_self(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_once(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutex_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutex_lock(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutex_unlock(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutex_destroy(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutex_trylock(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutexattr_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_mutexattr_destroy(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_cond_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_cond_wait(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_cond_timedwait(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_cond_signal(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_cond_broadcast(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_cond_destroy(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_condattr_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_condattr_setclock(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_condattr_destroy(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_key_create(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_key_delete(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_getspecific(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_setspecific(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_attr_init(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_attr_destroy(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_attr_setstacksize(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_attr_setdetachstate(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_attr_getstack(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_attr_getstacksize(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_create(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_join(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_detach(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_sigmask(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_getschedparam(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_setname_np(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_getname_np(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_kill(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pthread_getattr_np(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pkey_mprotect(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pkey_alloc(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int pkey_set(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __cxa_finalize(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __cxa_atexit(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __errno_location(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __ctype_b_loc(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __ctype_tolower_loc(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __ctype_toupper_loc(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __xpg_strerror_r(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __ctype_get_mb_cur_max(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __cxa_thread_atexit_impl(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __getdelim(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __longjmp_chk(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __mbrlen(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __register_atfork(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __sched_cpualloc(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __sched_cpucount(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __sched_cpufree(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __stack_chk_fail(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __tls_get_addr(void) { __asm__("mov $-1, %eax\n\tret"); }
__attribute__((naked)) int __udivti3(void) { __asm__("mov $-1, %eax\n\tret"); }

/* Keep the final UND face body inside RX filesz after the kernel's
 * min-8 body bump (ADR-0179). Not exported — not a bind face. */
__attribute__((used, noinline)) static void __os_und_text_pad(void) {
  __asm__ volatile(
      "nop;nop;nop;nop;nop;nop;nop;nop;"
      "nop;nop;nop;nop;nop;nop;nop;nop;"
      "nop;nop;nop;nop;nop;nop;nop;nop;"
      "nop;nop;nop;nop;nop;nop;nop;nop;"
      "nop;nop;nop;nop;nop;nop;nop;nop;"
      "nop;nop;nop;nop;nop;nop;nop;nop;");
}
