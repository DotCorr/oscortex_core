/* oscortex libdrm port — shim header: <ctype.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_CTYPE_H
#define _SHIM_CTYPE_H
int isspace(int);
int isdigit(int);
int isalpha(int);
int isalnum(int);
int isupper(int);
int islower(int);
int isprint(int);
int isxdigit(int);
int toupper(int);
int tolower(int);
#endif
