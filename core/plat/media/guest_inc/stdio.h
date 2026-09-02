#ifndef OSMEDIA_GUEST_STDIO_H
#define OSMEDIA_GUEST_STDIO_H
#include_next <stdio.h>
#ifndef _IONBF
#define _IONBF 2
#endif
#ifndef _IOLBF
#define _IOLBF 1
#endif
#ifndef _IOFBF
#define _IOFBF 0
#endif
#ifdef __cplusplus
extern "C" {
#endif
FILE *fdopen(int fd, const char *mode);
int fputs(const char *s, FILE *stream);
int setvbuf(FILE *stream, char *buf, int mode, size_t size);
#ifdef __cplusplus
}
#endif
#endif
