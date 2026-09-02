#ifndef OSMEDIA_GUEST_TIME_H
#define OSMEDIA_GUEST_TIME_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef long time_t;
typedef long clock_t;
struct timespec { time_t tv_sec; long tv_nsec; };
struct timeval { time_t tv_sec; long tv_usec; };
struct tm {
  int tm_sec;
  int tm_min;
  int tm_hour;
  int tm_mday;
  int tm_mon;
  int tm_year;
  int tm_wday;
  int tm_yday;
  int tm_isdst;
};
#define CLOCK_MONOTONIC 1
#define CLOCK_REALTIME 0
#define CLOCKS_PER_SEC 1000000
time_t time(time_t *t);
clock_t clock(void);
time_t mktime(struct tm *tm);
int clock_gettime(int clk, struct timespec *ts);
int gettimeofday(struct timeval *tv, void *tz);
unsigned long long gethrtime(void);
size_t strftime(char *s, size_t n, const char *fmt, const struct tm *tm);
struct tm *gmtime(const time_t *t);
struct tm *localtime(const time_t *t);
struct tm *gmtime_r(const time_t *t, struct tm *out);
struct tm *localtime_r(const time_t *t, struct tm *out);
#ifdef __cplusplus
}
#endif
#endif
