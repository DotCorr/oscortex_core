#ifndef GUEST_ERRNO_H
#define GUEST_ERRNO_H
#define errno (*osgfx_errno())
#ifdef __cplusplus
extern "C" {
#endif
int *osgfx_errno(void);
#ifdef __cplusplus
}
#endif
#define ENOMEM 12
#define EINVAL 22
#endif
