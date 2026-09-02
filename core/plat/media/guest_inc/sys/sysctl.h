#ifndef OSMEDIA_GUEST_SYSCTL_H
#define OSMEDIA_GUEST_SYSCTL_H
#ifdef __cplusplus
extern "C" {
#endif
int sysctl(const int *name, unsigned namelen, void *oldp, unsigned long *oldlenp,
           const void *newp, unsigned long newlen);
#ifdef __cplusplus
}
#endif
#endif
