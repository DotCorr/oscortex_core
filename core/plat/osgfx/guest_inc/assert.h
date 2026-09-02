#ifndef GUEST_ASSERT_H
#define GUEST_ASSERT_H
#ifdef __cplusplus
extern "C" void abort(void);
#else
void abort(void);
#endif
#define assert(x) ((x) ? (void)0 : abort())
#endif
