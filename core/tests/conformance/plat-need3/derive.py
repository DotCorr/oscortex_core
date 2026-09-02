#!/usr/bin/env python3
"""Host-side expected numbers for plat-need3 (ADR-0162).

LINE1..LINE8 = MARK ^ MIX after faces through eight FAT stand-ins.
Missing LIBNS.SO is NotFound and cannot invent LINE8.
ASK.ELF of the same bytes is REFUSED 11 (PT_DYNAMIC).
Satisfies 8 of 32 CEF DT_NEEDED stand-ins; 24 remain.
"""

MARK_C = 0xA1520000C0DE0001
MIX1 = 0x00C10E0000001520
MARK_M = 0xA1570000C0DE0001
MIX2 = 0x00C10E0000001570
MARK_D = 0xA1600000C0DE0001
MIX3 = 0x00C10E0000001600
MARK_P = 0xA1600000C0DE0002
MIX4 = 0x00C10E0000001601
MARK_GB = 0xA1620000C0DE0001
MIX5 = 0x00C10E0000001620
MARK_GO = 0xA1620000C0DE0002
MIX6 = 0x00C10E0000001621
MARK_NP = 0xA1620000C0DE0003
MIX7 = 0x00C10E0000001622
MARK_NS = 0xA1620000C0DE0004
MIX8 = 0x00C10E0000001623
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9

# CEF's 32 DT_NEEDED (ADR-0123). Stand-ins satisfied this rung:
# libc.so.6→LIBC.SO, libm.so.6→LIBM.SO, libdl.so.2→LIBDL.SO,
# libpthread.so.0→LIBPT.SO, libglib-2.0.so.0→LIBGB.SO,
# libgobject-2.0.so.0→LIBGO.SO, libnspr4.so→LIBNP.SO,
# libnss3.so→LIBNS.SO.
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
    "libglib-2.0.so.0",
    "libgobject-2.0.so.0",
    "libnspr4.so",
    "libnss3.so",
}


def main():
    mask = (1 << 64) - 1
    line1 = (MARK_C ^ MIX1) & mask
    line2 = (MARK_M ^ MIX2) & mask
    line3 = (MARK_D ^ MIX3) & mask
    line4 = (MARK_P ^ MIX4) & mask
    line5 = (MARK_GB ^ MIX5) & mask
    line6 = (MARK_GO ^ MIX6) & mask
    line7 = (MARK_NP ^ MIX7) & mask
    line8 = (MARK_NS ^ MIX8) & mask
    print("mark_c=%016X" % MARK_C)
    print("mix1=%016X" % MIX1)
    print("mark_m=%016X" % MARK_M)
    print("mix2=%016X" % MIX2)
    print("mark_d=%016X" % MARK_D)
    print("mix3=%016X" % MIX3)
    print("mark_p=%016X" % MARK_P)
    print("mix4=%016X" % MIX4)
    print("mark_gb=%016X" % MARK_GB)
    print("mix5=%016X" % MIX5)
    print("mark_go=%016X" % MARK_GO)
    print("mix6=%016X" % MIX6)
    print("mark_np=%016X" % MARK_NP)
    print("mix7=%016X" % MIX7)
    print("mark_ns=%016X" % MARK_NS)
    print("mix8=%016X" % MIX8)
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=NEED3 START")
    print("line1=LINE1 %016X" % line1)
    print("line2=LINE2 %016X" % line2)
    print("line3=LINE3 %016X" % line3)
    print("line4=LINE4 %016X" % line4)
    print("line5=LINE5 %016X" % line5)
    print("line6=LINE6 %016X" % line6)
    print("line7=LINE7 %016X" % line7)
    print("line8=LINE8 %016X" % line8)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_eight=NEED 0000000000000008")
    print("need_seven=NEED 0000000000000007")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    print("satisfied=8")
    print("remain=24")
    print("cef_needed=32")
    remaining = [n for n in CEF_NEEDED if n not in SATISFIED_CEF]
    print("remaining=%s" % ",".join(remaining))
    print("satisfied_names=LIBC.SO,LIBM.SO,LIBDL.SO,LIBPT.SO,LIBGB.SO,LIBGO.SO,LIBNP.SO,LIBNS.SO")


if __name__ == "__main__":
    main()
