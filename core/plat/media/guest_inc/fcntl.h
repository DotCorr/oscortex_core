#ifndef OSMEDIA_GUEST_FCNTL_H
#define OSMEDIA_GUEST_FCNTL_H
#include_next <fcntl.h>
#define O_TRUNC 0x200
#define O_APPEND 0x400
#define F_SETFD 2
#define FD_CLOEXEC 1
#ifdef __cplusplus
extern "C" {
#endif
int fcntl(int fd, int cmd, ...);
#ifdef __cplusplus
}
#endif
#endif
