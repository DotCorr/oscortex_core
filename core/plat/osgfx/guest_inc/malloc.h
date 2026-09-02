#ifndef GUEST_MALLOC_H
#define GUEST_MALLOC_H
#include <stdlib.h>
#ifdef __cplusplus
extern "C" {
#endif
size_t malloc_usable_size(void *p);
#ifdef __cplusplus
}
#endif
#endif

