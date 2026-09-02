#ifndef GUEST_WCHAR_H
#define GUEST_WCHAR_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#include <bits/types/mbstate_t.h>
#ifndef __cplusplus
#ifndef _WCHAR_T_DEFINED
typedef unsigned wchar_t;
#define _WCHAR_T_DEFINED
#endif
#endif
typedef unsigned wint_t;
#define WEOF ((wint_t)-1)
wchar_t *wcschr(const wchar_t *s, wchar_t c);
wchar_t *wcsrchr(const wchar_t *s, wchar_t c);
wchar_t *wcspbrk(const wchar_t *s, const wchar_t *a);
wchar_t *wcsstr(const wchar_t *s, const wchar_t *n);
wchar_t *wmemchr(const wchar_t *s, wchar_t c, size_t n);
size_t wcslen(const wchar_t *s);
int wcscmp(const wchar_t *a, const wchar_t *b);
int wcsncmp(const wchar_t *a, const wchar_t *b, size_t n);
wchar_t *wcscpy(wchar_t *d, const wchar_t *s);
wchar_t *wcsncpy(wchar_t *d, const wchar_t *s, size_t n);
wchar_t *wmemcpy(wchar_t *d, const wchar_t *s, size_t n);
wchar_t *wmemmove(wchar_t *d, const wchar_t *s, size_t n);
wchar_t *wmemset(wchar_t *d, wchar_t c, size_t n);
int wmemcmp(const wchar_t *a, const wchar_t *b, size_t n);
#ifdef __cplusplus
}
#endif
#endif
