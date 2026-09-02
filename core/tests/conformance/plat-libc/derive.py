#!/usr/bin/env python3
"""Host-side expected numbers for plat-libc.

LINE is MARK ^ MIX after calling write through mapped LIBC.SO.
A kernel that invents a VA without mapping (or leaves NX on the
X LOAD) cannot print LINE. Missing MISS.SO is NotFound.
ASK.ELF of the same bytes is BadArg.
"""

MARK = 0xA1520000C0DE0001
MIX = 0x00C10E0000001520
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
    print("msg_via=VIA LIBC")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("line_line=LINE %016X" % derived)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")


if __name__ == "__main__":
    main()
