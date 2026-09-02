/* oscortex libdrm port — shim header: <assert.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_ASSERT_H
#define _SHIM_ASSERT_H
void __oscortex_assert_fail(const char *, const char *, unsigned, const char *);
#ifdef NDEBUG
#define assert(e) ((void)0)
#else
#define assert(e) ((e) ? (void)0 : __oscortex_assert_fail(#e, __FILE__, __LINE__, __func__))
#endif
#endif
