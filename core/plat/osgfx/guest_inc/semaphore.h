#ifndef GUEST_SEMAPHORE_H
#define GUEST_SEMAPHORE_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { int v; } sem_t;
int sem_init(sem_t *s, int pshared, unsigned value);
int sem_destroy(sem_t *s);
int sem_wait(sem_t *s);
int sem_post(sem_t *s);
int sem_trywait(sem_t *s);
#ifdef __cplusplus
}
#endif
#endif
