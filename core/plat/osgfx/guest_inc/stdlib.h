#ifndef GUEST_STDLIB_H
#define GUEST_STDLIB_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { int quot; int rem; } div_t;
typedef struct { long quot; long rem; } ldiv_t;
typedef struct { long long quot; long long rem; } lldiv_t;
div_t div(int n, int d);
ldiv_t ldiv(long n, long d);
lldiv_t lldiv(long long n, long long d);
int abs(int x);
long labs(long x);
long long llabs(long long x);
void *malloc(size_t n);
void free(void *p);
void *calloc(size_t n, size_t sz);
void *realloc(void *p, size_t n);
int posix_memalign(void **p, size_t align, size_t n);
void abort(void);
int atexit(void (*fn)(void));
void qsort(void *base, size_t n, size_t sz, int (*cmp)(const void *, const void *));
void *bsearch(const void *key, const void *base, size_t n, size_t sz,
              int (*cmp)(const void *, const void *));
int atoi(const char *s);
long atol(const char *s);
double atof(const char *s);
long strtol(const char *s, char **end, int base);
unsigned long strtoul(const char *s, char **end, int base);
unsigned long long strtoull(const char *s, char **end, int base);
double strtod(const char *s, char **end);
#ifdef __cplusplus
}
#endif
#endif
