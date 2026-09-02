#ifndef OSMEDIA_GUEST_SYS_TIME_H
#define OSMEDIA_GUEST_SYS_TIME_H
#include <time.h>
#ifdef __cplusplus
extern "C" {
#endif
int gettimeofday(struct timeval *tv, void *tz);
#ifdef __cplusplus
}
#endif
#endif
