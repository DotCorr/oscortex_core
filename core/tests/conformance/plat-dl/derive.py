#!/usr/bin/env python3
"""Host-side expected numbers for plat-dl.

MARK is so_mark in TINY.SO. The printed line is MARK ^ MIX.
A kernel that invents a VA without mapping the file cannot
read so_mark. Missing MISS.SO is NotFound and cannot print MARK.
ASK.ELF of the same bytes is BadArg.
"""

MARK = 0xA1440000C0DE0001
MIX = 0x00D10E0000001440
E_BADARG = 0xFFFFFFFFFFFFFFFE
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9
PLAT_CAP = 0x1000000
APP_CAP = 0x200000


def main():
    derived = (MARK ^ MIX) & ((1 << 64) - 1)
    print("mark=%016X" % MARK)
    print("mix=%016X" % MIX)
    print("derived=%016X" % derived)
    print("badarg=%016X" % E_BADARG)
    print("notfound=%016X" % E_NOTFOUND)
    print("plat_cap=%08X" % PLAT_CAP)
    print("app_cap=%08X" % APP_CAP)
    print("msg_start=PLAT START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("mark_line=MARK %016X" % derived)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")


if __name__ == "__main__":
    main()
