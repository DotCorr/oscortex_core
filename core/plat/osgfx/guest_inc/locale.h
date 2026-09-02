#ifndef GUEST_LOCALE_H
#define GUEST_LOCALE_H
#ifdef __cplusplus
extern "C" {
#endif
#define LC_ALL 0
struct lconv { char dummy; };
char *setlocale(int cat, const char *loc);
struct lconv *localeconv(void);
#ifdef __cplusplus
}
#endif
#endif
