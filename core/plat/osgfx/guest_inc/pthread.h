#ifndef GUEST_PTHREAD_H
#define GUEST_PTHREAD_H
#ifdef __cplusplus
extern "C" {
#endif
typedef int pthread_mutex_t;
typedef int pthread_once_t;
typedef int pthread_t;
typedef int pthread_key_t;
typedef int pthread_cond_t;
typedef int pthread_mutexattr_t;
#define PTHREAD_MUTEX_INITIALIZER 0
#define PTHREAD_ONCE_INIT 0
#define PTHREAD_COND_INITIALIZER 0
int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a);
int pthread_mutex_destroy(pthread_mutex_t *m);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_unlock(pthread_mutex_t *m);
int pthread_once(pthread_once_t *o, void (*fn)(void));
int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m);
int pthread_cond_signal(pthread_cond_t *c);
int sched_yield(void);
pthread_t pthread_self(void);
#ifdef __cplusplus
}
#endif
#endif
