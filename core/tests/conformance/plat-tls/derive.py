#!/usr/bin/env python3
"""Host-side expected numbers for plat-tls.

TLS is SIG ^ MIX after setfs + %fs:0 store/load. A kernel that
returned success without writing IA32_FS_BASE faults at VA 0
and never prints the derived line.
"""

SIG = 0xA1480000C0DE0001
MIX = 0x00F10E0000001480
E_BADARG = 0xFFFFFFFFFFFFFFFE
PLAT_CAP = 0x1000000
APP_CAP = 0x200000


def main():
    tls = (SIG ^ MIX) & ((1 << 64) - 1)
    print("sig=%016X" % SIG)
    print("mix=%016X" % MIX)
    print("tls=%016X" % tls)
    print("badarg=%016X" % E_BADARG)
    print("plat_cap=%08X" % PLAT_CAP)
    print("app_cap=%08X" % APP_CAP)
    print("msg_start=PLAT START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_ok=ASKED 0000000000000000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("tls_line=TLS %016X" % tls)
    print("setfs_err=ERR FFFFFFFFFFFFFFFE")
    print("zero_mix=TLS %016X" % (MIX & ((1 << 64) - 1)))


if __name__ == "__main__":
    main()
