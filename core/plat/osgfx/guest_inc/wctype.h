#ifndef GUEST_WCTYPE_H
#define GUEST_WCTYPE_H
#ifdef __cplusplus
extern "C" {
#endif
typedef unsigned wint_t;
typedef unsigned wctype_t;
int iswspace(wint_t c);
#ifdef __cplusplus
}
#endif
#endif
