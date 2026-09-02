#!/usr/bin/env python3
"""Host-side expected numbers for plat-need4 (ADR-0163).

LINE1..LINE16 = MARK ^ MIX after faces through sixteen FAT stand-ins.
Missing LIBX1.SO is NotFound and cannot invent LINE16.
ASK.ELF of the same bytes is REFUSED 11 (PT_DYNAMIC).
Satisfies 16 of 32 CEF DT_NEEDED stand-ins; 16 remain.
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
MARK_NU = 0xA1630000C0DE0001
MIX9 = 0x00C10E0000001630
MARK_SM = 0xA1630000C0DE0002
MIX10 = 0x00C10E0000001631
MARK_DB = 0xA1630000C0DE0003
MIX11 = 0x00C10E0000001632
MARK_GI = 0xA1630000C0DE0004
MIX12 = 0x00C10E0000001633
MARK_AT = 0xA1630000C0DE0005
MIX13 = 0x00C10E0000001634
MARK_AB = 0xA1630000C0DE0006
MIX14 = 0x00C10E0000001635
MARK_CU = 0xA1630000C0DE0007
MIX15 = 0x00C10E0000001636
MARK_X1 = 0xA1630000C0DE0008
MIX16 = 0x00C10E0000001637
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9

# CEF's 32 DT_NEEDED (ADR-0123). Stand-ins satisfied this rung:
# libc.so.6→LIBC.SO … libnss3.so→LIBNS.SO (ADR-0162), then
# libnssutil3.so→LIBNU.SO, libsmime3.so→LIBSM.SO,
# libdbus-1.so.3→LIBDB.SO, libgio-2.0.so.0→LIBGI.SO,
# libatk-1.0.so.0→LIBAT.SO, libatk-bridge-2.0.so.0→LIBAB.SO,
# libcups.so.2→LIBCU.SO, libX11.so.6→LIBX1.SO.
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
    "libnssutil3.so",
    "libsmime3.so",
    "libdbus-1.so.3",
    "libgio-2.0.so.0",
    "libatk-1.0.so.0",
    "libatk-bridge-2.0.so.0",
    "libcups.so.2",
    "libX11.so.6",
}


def main():
    mask = (1 << 64) - 1
    lines = [
        ("line1", MARK_C, MIX1),
        ("line2", MARK_M, MIX2),
        ("line3", MARK_D, MIX3),
        ("line4", MARK_P, MIX4),
        ("line5", MARK_GB, MIX5),
        ("line6", MARK_GO, MIX6),
        ("line7", MARK_NP, MIX7),
        ("line8", MARK_NS, MIX8),
        ("line9", MARK_NU, MIX9),
        ("line10", MARK_SM, MIX10),
        ("line11", MARK_DB, MIX11),
        ("line12", MARK_GI, MIX12),
        ("line13", MARK_AT, MIX13),
        ("line14", MARK_AB, MIX14),
        ("line15", MARK_CU, MIX15),
        ("line16", MARK_X1, MIX16),
    ]
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=NEED4 START")
    for i, (key, mark, mix) in enumerate(lines, 1):
        print("%s=LINE%d %016X" % (key, i, (mark ^ mix) & mask))
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_sixteen=NEED 0000000000000010")
    print("need_fifteen=NEED 000000000000000F")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    print("satisfied=16")
    print("remain=16")
    print("cef_needed=32")
    remaining = [n for n in CEF_NEEDED if n not in SATISFIED_CEF]
    print("remaining=%s" % ",".join(remaining))
    print(
        "satisfied_names=LIBC.SO,LIBM.SO,LIBDL.SO,LIBPT.SO,LIBGB.SO,LIBGO.SO,"
        "LIBNP.SO,LIBNS.SO,LIBNU.SO,LIBSM.SO,LIBDB.SO,LIBGI.SO,LIBAT.SO,"
        "LIBAB.SO,LIBCU.SO,LIBX1.SO"
    )


if __name__ == "__main__":
    main()
