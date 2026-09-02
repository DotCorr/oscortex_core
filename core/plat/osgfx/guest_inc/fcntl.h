#ifndef GUEST_FCNTL_H
#define GUEST_FCNTL_H
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 0x40
#ifdef __cplusplus
extern "C" {
#endif
int open(const char *path, int flags, ...);
#ifdef __cplusplus
}
#endif
#endif
