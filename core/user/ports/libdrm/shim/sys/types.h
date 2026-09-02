/* oscortex libdrm port — shim header: <sys/types.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_SYS_TYPES_H
#define _SHIM_SYS_TYPES_H
#include <stdint.h>
#include <stddef.h>
typedef long ssize_t;
typedef long off_t;
typedef unsigned int mode_t;
typedef unsigned long dev_t;
typedef unsigned long ino_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned long nlink_t;
typedef long time_t;
typedef long blksize_t;
typedef long blkcnt_t;
typedef int pid_t;
#endif
