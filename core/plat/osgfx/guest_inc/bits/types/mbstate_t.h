#ifndef GUEST_MBSTATE_T_H
#define GUEST_MBSTATE_T_H
struct __mbstate { int __st; unsigned __w; };
typedef struct __mbstate mbstate_t;
#endif
