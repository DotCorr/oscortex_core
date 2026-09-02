#ifndef GUEST_TIME_H
#define GUEST_TIME_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef long time_t;
typedef long clock_t;
struct timespec { time_t tv_sec; long tv_nsec; };
struct timeval { time_t tv_sec; long tv_usec; };
#define CLOCK_MONOTONIC 1
#define CLOCK_REALTIME 0
time_t time(time_t *t);
int clock_gettime(int clk, struct timespec *ts);
int gettimeofday(struct timeval *tv, void *tz);
#ifdef __cplusplus
}
#endif
#endif
