#ifndef OSMEDIA_GUEST_SYS_STAT_H
#define OSMEDIA_GUEST_SYS_STAT_H
#include_next <sys/stat.h>
#ifdef __cplusplus
extern "C" {
#endif
int fstat(int fd, struct stat *st);
#ifdef __cplusplus
}
#endif
#endif
