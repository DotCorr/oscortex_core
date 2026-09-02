/* oscortex libdrm port — shim header: <math.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_MATH_H
#define _SHIM_MATH_H
#define M_PI 3.14159265358979323846
double fabs(double);
float roundf(float);
double round(double);
float fabsf(float);
double sqrt(double);
double pow(double, double);
double floor(double);
double ceil(double);
#endif
