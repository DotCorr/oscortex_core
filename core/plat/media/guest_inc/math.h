#ifndef OSMEDIA_GUEST_MATH_H
#define OSMEDIA_GUEST_MATH_H
#include_next <math.h>
#ifndef fpclassify
#define fpclassify(x) \
  __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, (x))
#endif
#ifdef __cplusplus
extern "C" {
#endif
double scalbn(double x, int n);
float scalbnf(float x, int n);
double log10(double x);
float log10f(float x);
double sinh(double x);
double cosh(double x);
double tanh(double x);
#ifdef __cplusplus
}
#endif
#endif
