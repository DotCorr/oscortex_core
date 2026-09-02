/* oscortex: sys/ioccom.h — LINUX's _IOC encoding, deliberately. */
#ifndef _OSCORTEX_SYS_IOCCOM_H
#define _OSCORTEX_SYS_IOCCOM_H
#include <asm/ioctl.h>
/* xf86drm.h's non-__linux__ branch spells the direction bits with BSD's names.
 * Map them onto Linux's, with BSD's OUT/IN sense preserved:
 *   IOC_OUT = the kernel writes the payload out to userspace = _IOC_READ
 *   IOC_IN  = userspace writes the payload in to the kernel  = _IOC_WRITE */
#define IOC_VOID  _IOC_NONE
#define IOC_OUT   _IOC_READ
#define IOC_IN    _IOC_WRITE
#define IOC_INOUT (_IOC_READ | _IOC_WRITE)
#endif
