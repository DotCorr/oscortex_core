#ifndef GUEST_STDIO_H
#define GUEST_STDIO_H
#include <stddef.h>
#include <stdarg.h>
#ifdef __cplusplus
extern "C" {
#endif
struct _IO_FILE { int unused; };
typedef struct _IO_FILE FILE;
extern FILE *stderr;
extern FILE *stdout;
extern FILE *stdin;
#define EOF (-1)
int fprintf(FILE *f, const char *fmt, ...);
int vfprintf(FILE *f, const char *fmt, va_list ap);
int printf(const char *fmt, ...);
int snprintf(char *s, size_t n, const char *fmt, ...);
int vsnprintf(char *s, size_t n, const char *fmt, va_list ap);
int sscanf(const char *s, const char *fmt, ...);
int remove(const char *path);
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
int fflush(FILE *f);
size_t fread(void *p, size_t sz, size_t n, FILE *f);
size_t fwrite(const void *p, size_t sz, size_t n, FILE *f);
long ftell(FILE *f);
int fseek(FILE *f, long off, int whence);
void perror(const char *s);
#ifdef __cplusplus
}
#endif
#endif
