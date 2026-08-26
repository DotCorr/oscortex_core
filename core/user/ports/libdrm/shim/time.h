/* oscortex libdrm port — shim header: <time.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_TIME_H
#define _SHIM_TIME_H
#include <sys/types.h>
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
struct timespec { time_t tv_sec; long tv_nsec; };
int clock_gettime(int, struct timespec *);
int nanosleep(const struct timespec *, struct timespec *);
time_t time(time_t *);
#endif
