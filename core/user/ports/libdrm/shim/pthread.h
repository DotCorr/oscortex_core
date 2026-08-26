/* oscortex libdrm port — shim header: <pthread.h>
 *
 * THIS IS NOT A LIBC HEADER AND IT IMPLEMENTS NOTHING. It exists so that
 * unmodified libdrm source can be COMPILED for x86_64-unknown-none-elf. Every
 * function declared here is either backed by core/user/libc (ten of them are)
 * or DELIBERATELY LEFT UNDEFINED, so that it appears in `nm --undefined-only`
 * and is counted by core/user/ports/libdrm/build.sh.
 *
 * A declaration here is a MEASUREMENT, not a promise. See ../README.md.
 */
#ifndef _SHIM_PTHREAD_H
#define _SHIM_PTHREAD_H
#include <stddef.h>
typedef unsigned long pthread_t;
typedef struct { unsigned long o[8]; } pthread_mutex_t;
typedef struct { unsigned long o[8]; } pthread_cond_t;
typedef struct { unsigned long o[8]; } pthread_attr_t;
typedef struct { unsigned long o[8]; } pthread_mutexattr_t;
typedef struct { unsigned long o[8]; } pthread_condattr_t;
#define PTHREAD_MUTEX_INITIALIZER {{0,0,0,0,0,0,0,0}}
#define PTHREAD_COND_INITIALIZER  {{0,0,0,0,0,0,0,0}}
int pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
int pthread_join(pthread_t, void **);
int pthread_detach(pthread_t);
int pthread_cancel(pthread_t);
int pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int pthread_mutex_destroy(pthread_mutex_t *);
int pthread_mutex_lock(pthread_mutex_t *);
int pthread_mutex_unlock(pthread_mutex_t *);
int pthread_cond_init(pthread_cond_t *, const pthread_condattr_t *);
int pthread_cond_destroy(pthread_cond_t *);
int pthread_cond_wait(pthread_cond_t *, pthread_mutex_t *);
int pthread_cond_signal(pthread_cond_t *);
int pthread_cond_broadcast(pthread_cond_t *);
#endif
