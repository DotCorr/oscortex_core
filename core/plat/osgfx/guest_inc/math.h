#ifndef GUEST_MATH_H
#define GUEST_MATH_H
#ifdef __cplusplus
extern "C" {
#endif
#define NAN __builtin_nanf("")
#define INFINITY __builtin_inff()
#define HUGE_VAL __builtin_huge_val()
#define HUGE_VALF __builtin_huge_valf()
#define M_PI 3.14159265358979323846
#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4
float sqrtf(float x);
double sqrt(double x);
float floorf(float x);
double floor(double x);
float ceilf(float x);
double ceil(double x);
float fabsf(float x);
double fabs(double x);
float powf(float x, float y);
double pow(double x, double y);
float logf(float x);
double log(double x);
float log2f(float x);
double log2(double x);
float expf(float x);
double exp(double x);
float sinf(float x);
double sin(double x);
float cosf(float x);
double cos(double x);
float tanf(float x);
double tan(double x);
float asinf(float x);
double asin(double x);
float acosf(float x);
double acos(double x);
float atanf(float x);
double atan(double x);
float atan2f(float y, float x);
double atan2(double y, double x);
float fmodf(float x, float y);
double fmod(double x, double y);
float ldexpf(float x, int e);
double ldexp(double x, int e);
float frexpf(float x, int *e);
double frexp(double x, int *e);
float copysignf(float x, float y);
double copysign(double x, double y);
float hypotf(float x, float y);
double hypot(double x, double y);
float truncf(float x);
double trunc(double x);
float roundf(float x);
double round(double x);
float nextafterf(float x, float y);
double nextafter(double x, double y);
float fminf(float a, float b);
double fmin(double a, double b);
float fmaxf(float a, float b);
double fmax(double a, double b);
float fmaf(float x, float y, float z);
double fma(double x, double y, double z);
float lrintf(float x);
double lrint(double x);
float cbrtf(float x);
double cbrt(double x);
#ifdef __cplusplus
}
#endif
#ifndef signbit
#define signbit(x) __builtin_signbit(x)
#endif
#endif
