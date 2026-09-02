#!/usr/bin/env python3
"""Host-side expected numbers for plat-need (ADR-0157).

LINE1 = MARK_C ^ MIX1 after write through LIBC.SO.
LINE2 = MARK_M ^ MIX2 after need_fn through LIBM.SO.
Missing LIBM.SO is NotFound and cannot invent LINE2.
ASK.ELF of the same bytes is REFUSED 11 (PT_DYNAMIC).
"""

MARK_C = 0xA1520000C0DE0001
MIX1 = 0x00C10E0000001520
MARK_M = 0xA1570000C0DE0001
MIX2 = 0x00C10E0000001570
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9


def main():
    line1 = (MARK_C ^ MIX1) & ((1 << 64) - 1)
    line2 = (MARK_M ^ MIX2) & ((1 << 64) - 1)
    print("mark_c=%016X" % MARK_C)
    print("mix1=%016X" % MIX1)
    print("mark_m=%016X" % MARK_M)
    print("mix2=%016X" % MIX2)
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=NEED START")
    print("msg_via_c=VIA LIBC")
    print("msg_via_m=VIA LIBM")
    print("line1=LINE1 %016X" % line1)
    print("line2=LINE2 %016X" % line2)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_two=NEED 0000000000000002")
    print("need_one=NEED 0000000000000001")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    print("satisfied=2")
    print("remain=30")
    print("cef_needed=32")


if __name__ == "__main__":
    main()
