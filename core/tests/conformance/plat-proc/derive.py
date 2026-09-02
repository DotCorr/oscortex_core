#!/usr/bin/env python3
"""Host-side expected numbers for plat-proc.

Checksum of the 3 MiB platform fill, recomputed from the same
formula prog.c writes. A kernel that returned addresses without
mapping pages cannot make write() of a plat-heap string succeed,
and cannot match XOR.
"""

SIG = 0xA1240000C0DE0001
WANT_PAGES = 768
PLAT_BASE = 0x10400000
PLAT_CAP = 0x1000000
APP_CAP = 0x200000
WANT = 0x300000
E_BADARG = 0xFFFFFFFFFFFFFFFE


def mark(i, w):
    return (SIG + (i << 20) + w) & ((1 << 64) - 1)


def plat_xor():
    x = 0
    for i in range(WANT_PAGES):
        x ^= mark(i, 0)
    return x


def main():
    x = plat_xor()
    print("plat_base=%08X" % PLAT_BASE)
    print("plat_cap=%08X" % PLAT_CAP)
    print("app_cap=%08X" % APP_CAP)
    print("want=%06X" % WANT)
    print("want_pages=%d" % WANT_PAGES)
    print("xor=%016X" % x)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=PLAT START")
    print("msg_heap=PLAT HEAP PAGE")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("brk0_plat=BRK0 0000000010400000")


if __name__ == "__main__":
    main()
