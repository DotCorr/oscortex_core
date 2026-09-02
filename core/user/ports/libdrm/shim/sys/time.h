/* oscortex libdrm port — shim header: <sys/time.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_SYS_TIME_H
#define _SHIM_SYS_TIME_H
#include <sys/types.h>
#include <time.h>
struct timeval { time_t tv_sec; long tv_usec; };
int gettimeofday(struct timeval *, void *);
typedef struct { unsigned long fds_bits[16]; } fd_set;
#define FD_SETSIZE 1024
void FD_ZERO(fd_set *);
void FD_SET(int, fd_set *);
void FD_CLR(int, fd_set *);
int  FD_ISSET(int, fd_set *);
int select(int, fd_set *, fd_set *, fd_set *, struct timeval *);
#endif
