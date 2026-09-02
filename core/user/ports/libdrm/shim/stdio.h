/* oscortex libdrm port — shim header: <stdio.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_STDIO_H
#define _SHIM_STDIO_H
#include <stddef.h>
#include <stdarg.h>
#include <sys/types.h>
typedef struct _SHIM_FILE FILE;
extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;
#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
int sprintf(char *, const char *, ...);
int printf(const char *, ...);
int fprintf(FILE *, const char *, ...);
int snprintf(char *, size_t, const char *, ...);
int asprintf(char **, const char *, ...);
int vasprintf(char **, const char *, va_list);
int vsnprintf(char *, size_t, const char *, va_list);
int sscanf(const char *, const char *, ...);
int fscanf(FILE *, const char *, ...);
int vfprintf(FILE *, const char *, va_list);
FILE *fopen(const char *, const char *);
FILE *fdopen(int, const char *);
FILE *open_memstream(char **, size_t *);
int fclose(FILE *);
int fflush(FILE *);
char *fgets(char *, int, FILE *);
size_t fread(void *, size_t, size_t, FILE *);
size_t fwrite(const void *, size_t, size_t, FILE *);
int fseek(FILE *, long, int);
long ftell(FILE *);
int fputc(int, FILE *);
int getchar(void);
int putchar(int);
int fputs(const char *, FILE *);
int remove(const char *);
int rename(const char *, const char *);
#endif
