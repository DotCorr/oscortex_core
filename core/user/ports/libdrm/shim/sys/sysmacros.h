/* oscortex libdrm port — shim header: <sys/sysmacros.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_SYS_SYSMACROS_H
#define _SHIM_SYS_SYSMACROS_H
unsigned int major(unsigned long);
unsigned int minor(unsigned long);
unsigned long makedev(unsigned int, unsigned int);
#endif
