#!/usr/bin/env python3
"""Host-side expected numbers for plat-clone.

CHILD is SIG ^ MIX. A kernel that returned a fake tid without
entering child_start cannot write CHILD LINE or that hex. First
PROC KILL FREED must be 0 — the survivor still walks the tables.
The last free equals ASK.ELF's single free of the same bytes.
"""

SIG = 0xA1300000C0DE0001
MIX = 0x00C10E0000001300
E_BADARG = 0xFFFFFFFFFFFFFFFE
PLAT_CAP = 0x1000000
APP_CAP = 0x200000


def main():
    child = (SIG ^ MIX) & ((1 << 64) - 1)
    print("sig=%016X" % SIG)
    print("mix=%016X" % MIX)
    print("child=%016X" % child)
    print("badarg=%016X" % E_BADARG)
    print("plat_cap=%08X" % PLAT_CAP)
    print("app_cap=%08X" % APP_CAP)
    print("msg_start=PLAT START")
    print("msg_child=CHILD LINE")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("child_line=CHILD %016X" % child)
    print("clone_err=ERR FFFFFFFFFFFFFFFE")


if __name__ == "__main__":
    main()
