#ifndef OSMEDIA_GUEST_STRING_H
#define OSMEDIA_GUEST_STRING_H
#include_next <string.h>
#ifdef __cplusplus
extern "C" {
#endif
int strerror_r(int errnum, char *buf, size_t buflen);
#ifdef __cplusplus
}
#endif
#endif
