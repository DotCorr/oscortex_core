#ifndef GUEST_SIGNAL_H
#define GUEST_SIGNAL_H
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*sighandler_t)(int);
#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIGABRT 6
sighandler_t signal(int sig, sighandler_t h);
#ifdef __cplusplus
}
#endif
#endif
