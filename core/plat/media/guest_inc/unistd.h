#ifndef OSMEDIA_GUEST_UNISTD_H
#define OSMEDIA_GUEST_UNISTD_H
#include_next <unistd.h>
#ifndef off_t
typedef long off_t;
#endif
#ifdef __cplusplus
extern "C" {
#endif
int mkstemp(char *tmpl);
int isatty(int fd);
int usleep(unsigned usec);
int access(const char *path, int mode);
#ifdef __cplusplus
}
#endif
#endif
