#ifndef GUEST_SYS_STAT_H
#define GUEST_SYS_STAT_H
#ifdef __cplusplus
extern "C" {
#endif
#define S_IFDIR 0040000
#define S_IFREG 0100000
#define S_IFMT 0170000
struct stat { int st_mode; long st_size; };
int stat(const char *path, struct stat *st);
int mkdir(const char *path, int mode);
#ifdef __cplusplus
}
#endif
#endif
