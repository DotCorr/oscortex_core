#!/usr/bin/env python3
"""Host-side expected numbers for plat-need5 (ADR-0165).

LINE1..LINE32 = MARK ^ MIX after faces through thirty-two FAT stand-ins.
Missing LIBLD.SO is NotFound and cannot invent LINE32.
ASK.ELF of the same bytes is REFUSED 11 (PT_DYNAMIC).
Satisfies 32 of 32 CEF DT_NEEDED stand-ins; OnPaint leftover.
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
MARK_XC = 0xA1650000C0DE0001
MIX17 = 0x00C10E0000001650
MARK_XD = 0xA1650000C0DE0002
MIX18 = 0x00C10E0000001651
MARK_XE = 0xA1650000C0DE0003
MIX19 = 0x00C10E0000001652
MARK_XF = 0xA1650000C0DE0004
MIX20 = 0x00C10E0000001653
MARK_XR = 0xA1650000C0DE0005
MIX21 = 0x00C10E0000001654
MARK_GM = 0xA1650000C0DE0006
MIX22 = 0x00C10E0000001655
MARK_EX = 0xA1650000C0DE0007
MIX23 = 0x00C10E0000001656
MARK_XB = 0xA1650000C0DE0008
MIX24 = 0x00C10E0000001657
MARK_XK = 0xA1650000C0DE0009
MIX25 = 0x00C10E0000001658
MARK_CA = 0xA1650000C0DE000A
MIX26 = 0x00C10E0000001659
MARK_PG = 0xA1650000C0DE000B
MIX27 = 0x00C10E000000165A
MARK_UD = 0xA1650000C0DE000C
MIX28 = 0x00C10E000000165B
MARK_AS = 0xA1650000C0DE000D
MIX29 = 0x00C10E000000165C
MARK_AP = 0xA1650000C0DE000E
MIX30 = 0x00C10E000000165D
MARK_GC = 0xA1650000C0DE000F
MIX31 = 0x00C10E000000165E
MARK_LD = 0xA1650000C0DE0010
MIX32 = 0x00C10E000000165F
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9

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
SATISFIED_CEF = set(CEF_NEEDED)


def main():
    mask = (1 << 64) - 1
    marks = [
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
        ("line17", MARK_XC, MIX17),
        ("line18", MARK_XD, MIX18),
        ("line19", MARK_XE, MIX19),
        ("line20", MARK_XF, MIX20),
        ("line21", MARK_XR, MIX21),
        ("line22", MARK_GM, MIX22),
        ("line23", MARK_EX, MIX23),
        ("line24", MARK_XB, MIX24),
        ("line25", MARK_XK, MIX25),
        ("line26", MARK_CA, MIX26),
        ("line27", MARK_PG, MIX27),
        ("line28", MARK_UD, MIX28),
        ("line29", MARK_AS, MIX29),
        ("line30", MARK_AP, MIX30),
        ("line31", MARK_GC, MIX31),
        ("line32", MARK_LD, MIX32),
    ]
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=NEED5 START")
    for i, (key, mark, mix) in enumerate(marks, 1):
        print("%s=LINE%d %016X" % (key, i, (mark ^ mix) & mask))
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_thirtytwo=NEED 0000000000000020")
    print("need_thirtyone=NEED 000000000000001F")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    print("satisfied=32")
    print("remain=0")
    print("cef_needed=32")
    remaining = [n for n in CEF_NEEDED if n not in SATISFIED_CEF]
    print("remaining=%s" % ",".join(remaining))
    print(
        "satisfied_names=LIBC.SO,LIBM.SO,LIBDL.SO,LIBPT.SO,LIBGB.SO,LIBGO.SO,"
        "LIBNP.SO,LIBNS.SO,LIBNU.SO,LIBSM.SO,LIBDB.SO,LIBGI.SO,LIBAT.SO,"
        "LIBAB.SO,LIBCU.SO,LIBX1.SO,LIBXC.SO,LIBXD.SO,LIBXE.SO,LIBXF.SO,"
        "LIBXR.SO,LIBGM.SO,LIBEX.SO,LIBXB.SO,LIBXK.SO,LIBCA.SO,LIBPG.SO,"
        "LIBUD.SO,LIBAS.SO,LIBAP.SO,LIBGC.SO,LIBLD.SO"
    )


if __name__ == "__main__":
    main()
