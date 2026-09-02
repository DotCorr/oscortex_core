#ifndef OSMEDIA_GUEST_STDLIB_H
#define OSMEDIA_GUEST_STDLIB_H
#include_next <stdlib.h>
#ifdef __cplusplus
extern "C" {
#endif
long long strtoll(const char *s, char **end, int base);
#ifdef __cplusplus
}
#endif
#endif
