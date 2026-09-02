#!/usr/bin/env python3
"""Host-side expected numbers for plat-need2 (ADR-0160).

LINE1..LINE4 = MARK ^ MIX after faces through LIBC/LIBM/LIBDL/LIBPT.
Missing LIBPT.SO is NotFound and cannot invent LINE4.
ASK.ELF of the same bytes is REFUSED 11 (PT_DYNAMIC).
Satisfies 4 of 32 CEF DT_NEEDED stand-ins; 28 remain.
"""

MARK_C = 0xA1520000C0DE0001
MIX1 = 0x00C10E0000001520
MARK_M = 0xA1570000C0DE0001
MIX2 = 0x00C10E0000001570
MARK_D = 0xA1600000C0DE0001
MIX3 = 0x00C10E0000001600
MARK_P = 0xA1600000C0DE0002
MIX4 = 0x00C10E0000001601
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9

# CEF's 32 DT_NEEDED (ADR-0123). Stand-ins satisfied this rung:
# libc.so.6→LIBC.SO, libm.so.6→LIBM.SO, libdl.so.2→LIBDL.SO,
# libpthread.so.0→LIBPT.SO.
CEF_NEEDED = [
    "libdl.so.2",
    "libpthread.so.0",
    "libglib-2.0.so.0",
    "libgobject-2.0.so.0",
    "libnspr4.so",
    "libnss3.so",
    "libnssutil3.so",
    "libsmime3.so",
    "libdbus-1.so.3",
    "libgio-2.0.so.0",
    "libatk-1.0.so.0",
    "libatk-bridge-2.0.so.0",
    "libcups.so.2",
    "libX11.so.6",
    "libXcomposite.so.1",
    "libXdamage.so.1",
    "libXext.so.6",
    "libXfixes.so.3",
    "libXrandr.so.2",
    "libgbm.so.1",
    "libexpat.so.1",
    "libxcb.so.1",
    "libxkbcommon.so.0",
    "libcairo.so.2",
    "libpango-1.0.so.0",
    "libudev.so.1",
    "libasound.so.2",
    "libm.so.6",
    "libatspi.so.0",
    "libgcc_s.so.1",
    "libc.so.6",
    "ld-linux-x86-64.so.2",
]
SATISFIED_CEF = {
    "libc.so.6",
    "libm.so.6",
    "libdl.so.2",
    "libpthread.so.0",
}


def main():
    line1 = (MARK_C ^ MIX1) & ((1 << 64) - 1)
    line2 = (MARK_M ^ MIX2) & ((1 << 64) - 1)
    line3 = (MARK_D ^ MIX3) & ((1 << 64) - 1)
    line4 = (MARK_P ^ MIX4) & ((1 << 64) - 1)
    print("mark_c=%016X" % MARK_C)
    print("mix1=%016X" % MIX1)
    print("mark_m=%016X" % MARK_M)
    print("mix2=%016X" % MIX2)
    print("mark_d=%016X" % MARK_D)
    print("mix3=%016X" % MIX3)
    print("mark_p=%016X" % MARK_P)
    print("mix4=%016X" % MIX4)
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=NEED2 START")
    print("msg_via_c=VIA LIBC")
    print("msg_via_m=VIA LIBM")
    print("msg_via_d=VIA LIBDL")
    print("msg_via_p=VIA LIBPT")
    print("line1=LINE1 %016X" % line1)
    print("line2=LINE2 %016X" % line2)
    print("line3=LINE3 %016X" % line3)
    print("line4=LINE4 %016X" % line4)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_four=NEED 0000000000000004")
    print("need_three=NEED 0000000000000003")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    print("satisfied=4")
    print("remain=28")
    print("cef_needed=32")
    remaining = [n for n in CEF_NEEDED if n not in SATISFIED_CEF]
    print("remaining=%s" % ",".join(remaining))
    print("satisfied_names=LIBC.SO,LIBM.SO,LIBDL.SO,LIBPT.SO")


if __name__ == "__main__":
    main()
