#ifndef GUEST_UNISTD_H
#define GUEST_UNISTD_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef long ssize_t;
#define _SC_PAGESIZE 30
#define _SC_NPROCESSORS_ONLN 84
long sysconf(int name);
int getpagesize(void);
int close(int fd);
ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
#ifdef __cplusplus
}
#endif
#endif
