#ifndef GUEST_SYS_MMAN_H
#define GUEST_SYS_MMAN_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4
#define MAP_PRIVATE 2
#define MAP_ANON 0x20
#define MAP_ANONYMOUS MAP_ANON
#define MAP_FAILED ((void *)-1)
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long off);
int munmap(void *addr, size_t len);
#ifdef __cplusplus
}
#endif
#endif
