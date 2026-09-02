#!/usr/bin/env python3
"""Host-side expected numbers for plat-huge (ADR-0155).

189 MiB plant: every page marked, XOR of page[0] marks, write() of
a string on the mapped VA, and FREED delta = 111 plat tables +
48384 mapped pages. A no-op return of heap base fails the delta.
ASK.ELF of the same bytes is refused. Old 128 MiB PMM / 112 MiB
window cannot satisfy the structural floor.
"""

SIG = 0xA1550000C0DE0001
WANT_PAGES = 48384
PLAT_BASE = 0x10400000
PLAT_TABLES = 111
PLAT_CAP = 0xBD00000
APP_CAP = 0x200000
WANT = 0xBD00000
E_BADARG = 0xFFFFFFFFFFFFFFFE


def mark(i, w):
    return (SIG + (i << 12) + w) & ((1 << 64) - 1)


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
    print("want=%07X" % WANT)
    print("want_pages=%d" % WANT_PAGES)
    print("plat_tables=%d" % PLAT_TABLES)
    print("freed_delta=%d" % (PLAT_TABLES + WANT_PAGES))
    print("xor=%016X" % x)
    print("badarg=%016X" % E_BADARG)
    print("msg_start=PLAT START")
    print("msg_map=PLAT HUGE PAGE")
    print("cap_plat=CAP 000000000BD00000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("asked_ok=ASKED 0000000010400000")
    print("map_va=VA 0000000010400000")
    print("map_pages=PAGES 0000BD00")
    print("map_err=ERR FFFFFFFFFFFFFFFE")
    print("win=PROC PLAT 00 WIN 000000000DCFC000")


if __name__ == "__main__":
    main()
