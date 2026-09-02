#ifndef GUEST_DIRENT_H
#define GUEST_DIRENT_H
#ifdef __cplusplus
extern "C" {
#endif
struct dirent { char d_name[256]; };
typedef struct { int unused; } DIR;
DIR *opendir(const char *path);
struct dirent *readdir(DIR *d);
int closedir(DIR *d);
#ifdef __cplusplus
}
#endif
#endif
