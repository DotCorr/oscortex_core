/* oscortex libdrm port — shim header: <inttypes.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_INTTYPES_H
#define _SHIM_INTTYPES_H
#include <stdint.h>
#define SCNu64 "lu"
#define SCNx64 "lx"
#define SCNd64 "ld"
#define PRIu64 "lu"
#define PRIx64 "lx"
#define PRId64 "ld"
#define PRIu32 "u"
#define PRIx32 "x"
#define PRId32 "d"
#endif
