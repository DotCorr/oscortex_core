/* oscortex libdrm port — shim header: <poll.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_POLL_H
#define _SHIM_POLL_H
struct pollfd { int fd; short events; short revents; };
typedef unsigned long nfds_t;
#define POLLIN 1
#define POLLPRI 2
#define POLLERR 8
#define POLLHUP 16
#define POLLNVAL 32
#define POLLOUT 4
int poll(struct pollfd *, nfds_t, int);
#endif
