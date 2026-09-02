#!/usr/bin/env python3
"""Host-side expected numbers for plat-map.

Checksum of the 3 MiB platform fill, recomputed from the same
formula prog.c writes. A kernel that returned the heap base
without mapping pages cannot make write() of a plat-map string
succeed, cannot match XOR, and cannot free WANT_PAGES extra
frames on teardown.
"""

import re

SIG = 0xA1280000C0DE0001
WANT_PAGES = 768
PLAT_BASE = 0x10400000


def _dartconst(name):
    """vm.dart is the only place the plat window is described."""
    src = open(__file__.rsplit("/tests/", 1)[0] + "/kernel/vm.dart").read()
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % name, src, re.M)
    if not m:
        raise SystemExit("derive: no const int %s in vm.dart" % name)
    return int(m.group(1), 0)


# Was typed as 95, which stopped being true when ADR-0168 grew the plat window
# to the RO+RX LOAD span of the measured official libcef. It is not an
# independent number: it is how many 2MiB page-directory entries the window
# needs.
PLAT_TABLES = _dartconst("vmPlatPdCount")
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
    print("plat_tables=%d" % PLAT_TABLES)
    print("freed_delta=%d" % (PLAT_TABLES + WANT_PAGES))
    print("xor=%016X" % x)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=PLAT START")
    print("msg_map=PLAT MAP PAGE")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("asked_ok=ASKED 0000000010400000")
    print("map_va=VA 0000000010400000")
    print("map_pages=PAGES 00000300")
    print("map_err=ERR FFFFFFFFFFFFFFFE")


if __name__ == "__main__":
    main()
