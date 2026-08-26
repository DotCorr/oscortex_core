/* core/tests/conformance/drm-abi/neg-shim/sys/ioccom.h
 *
 * THE NEGATIVE CONTROL, AND IT IS ONE FILE.
 *
 * `include/drm/drm.h` takes its "one of the BSDs" branch on any target where
 * `__linux__` is not defined, and x86_64-unknown-none-elf is such a target.
 * That branch reaches for `<sys/ioccom.h>` and uses whatever `_IOWR` it finds.
 * SO THE ENCODING IS OURS TO CHOOSE AND CHOOSING WRONG IS SILENT: the headers
 * compile, the structs are identical, and 29 of 121 request numbers are
 * different from the ones Linux serves.
 *
 * This file is BSD's real encoding, put ahead of
 * core/user/ports/libdrm/shim/sys/ioccom.h on the include path for the control
 * build. Everything else about the two builds is the same file compiled the
 * same way. The control must produce the SAME count and a DIFFERENT hash, and
 * run.sh requires the 29 differing entries to be exactly the ones this comment
 * names -- otherwise the control is controlling for something other than what
 * it says.
 *
 * The differences, measured (ADR-0031 §3):
 *   _IOWR and _IO-with-payload  identical, all 92 of them
 *   _IOR / _IOW                 the direction bits are SWAPPED: BSD IOC_OUT is
 *                               0x40000000 where Linux _IOC_READ is 0x80000000
 *   _IO (no payload)            BSD stamps IOC_VOID (0x20000000); Linux stamps
 *                               zero. DRM_IOCTL_SET_MASTER and DROP_MASTER are
 *                               these, and they are not legacy
 *   the size field              13 bits on BSD, 14 on Linux -- no DRM struct is
 *                               big enough for that to show
 */
#ifndef _OSCORTEX_NEG_SYS_IOCCOM_H
#define _OSCORTEX_NEG_SYS_IOCCOM_H

#define IOCPARM_SHIFT 13
#define IOCPARM_MASK ((1 << IOCPARM_SHIFT) - 1)
#define IOC_VOID 0x20000000
#define IOC_OUT 0x40000000
#define IOC_IN 0x80000000
#define IOC_INOUT (IOC_IN | IOC_OUT)

#define _IOC(inout, group, num, len)                                           \
  ((unsigned long)((inout) | (((len) & IOCPARM_MASK) << 16) | ((group) << 8) | \
                   (num)))
#define _IO(g, n) _IOC(IOC_VOID, (g), (n), 0)
#define _IOR(g, n, t) _IOC(IOC_OUT, (g), (n), sizeof(t))
#define _IOW(g, n, t) _IOC(IOC_IN, (g), (n), sizeof(t))
#define _IOWR(g, n, t) _IOC(IOC_INOUT, (g), (n), sizeof(t))

/* prog.c decodes request numbers with Linux's field extractors, in both
 * builds, deliberately: the control exists to show that a BSD-ENCODED number
 * READ BY A LINUX-SHAPED KERNEL comes apart wrong. Transcribed from
 * include/uapi/asm-generic/ioctl.h and identical to the ones in
 * core/user/ports/libdrm/shim/asm/ioctl.h. */
#define _IOC_NRBITS 8
#define _IOC_TYPEBITS 8
#define _IOC_SIZEBITS 14
#define _IOC_DIRBITS 2
#define _IOC_NRMASK ((1 << _IOC_NRBITS) - 1)
#define _IOC_TYPEMASK ((1 << _IOC_TYPEBITS) - 1)
#define _IOC_SIZEMASK ((1 << _IOC_SIZEBITS) - 1)
#define _IOC_DIRMASK ((1 << _IOC_DIRBITS) - 1)
#define _IOC_NRSHIFT 0
#define _IOC_TYPESHIFT (_IOC_NRSHIFT + _IOC_NRBITS)
#define _IOC_SIZESHIFT (_IOC_TYPESHIFT + _IOC_TYPEBITS)
#define _IOC_DIRSHIFT (_IOC_SIZESHIFT + _IOC_SIZEBITS)
#define _IOC_DIR(nr) (((nr) >> _IOC_DIRSHIFT) & _IOC_DIRMASK)
#define _IOC_TYPE(nr) (((nr) >> _IOC_TYPESHIFT) & _IOC_TYPEMASK)
#define _IOC_NR(nr) (((nr) >> _IOC_NRSHIFT) & _IOC_NRMASK)
#define _IOC_SIZE(nr) (((nr) >> _IOC_SIZESHIFT) & _IOC_SIZEMASK)

#endif
