#!/usr/bin/env python3
"""Host-side expected numbers for plat-futex.

SYNC is SIG ^ MIX after the child stores SIG and wakes. A
kernel that returned from wait without blocking (and without
the child running) leaves gate 0 and prints MIX alone.
"""

SIG = 0xA1460000C0DE0001
MIX = 0x00F10E0000001460
E_BADARG = 0xFFFFFFFFFFFFFFFE
PLAT_CAP = 0x1000000
APP_CAP = 0x200000


def main():
    sync = (SIG ^ MIX) & ((1 << 64) - 1)
    child = sync
    print("sig=%016X" % SIG)
    print("mix=%016X" % MIX)
    print("sync=%016X" % sync)
    print("child=%016X" % child)
    print("badarg=%016X" % E_BADARG)
    print("plat_cap=%08X" % PLAT_CAP)
    print("app_cap=%08X" % APP_CAP)
    print("msg_start=PLAT START")
    print("msg_child=CHILD LINE")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("fask_bad=FASK FFFFFFFFFFFFFFFE")
    print("sync_line=SYNC %016X" % sync)
    print("child_line=CHILD %016X" % child)
    print("futex_err=ERR FFFFFFFFFFFFFFFE")
    print("zero_mix=SYNC %016X" % (MIX & ((1 << 64) - 1)))


if __name__ == "__main__":
    main()
