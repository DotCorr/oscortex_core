#!/usr/bin/env python3
"""Host-side expected numbers for cef-somap (ADR-0176).

All 32 official CEF DT_NEEDED Linux sonames → planted SOMAP.TXT →
OUR plat-need5 FAT 8.3 faces. LINE1..LINE32 = MARK ^ MIX in CEF order.
Anti-vacuity: SOMAP missing ld-linux-x86-64.so.2 refuses that name.
Not OnPaint. UND floor 50/1336 held.
"""

E_NOTFOUND = 0xFFFFFFFFFFFFFFF9

# Official CEF DT_NEEDED order (pack-cef-slice / plat-need5 CEF_NEEDED).
# Face / MARK / MIX reused from plat-need5 plants.
FACES = [
    # (soname, fat, mark, mix, via_tag)
    ("libdl.so.2", "LIBDL.SO", 0xA1600000C0DE0001, 0x00C10E0000001600, "LIBDL"),
    ("libpthread.so.0", "LIBPT.SO", 0xA1600000C0DE0002, 0x00C10E0000001601, "LIBPT"),
    ("libglib-2.0.so.0", "LIBGB.SO", 0xA1620000C0DE0001, 0x00C10E0000001620, "LIBGB"),
    ("libgobject-2.0.so.0", "LIBGO.SO", 0xA1620000C0DE0002, 0x00C10E0000001621, "LIBGO"),
    ("libnspr4.so", "LIBNP.SO", 0xA1620000C0DE0003, 0x00C10E0000001622, "LIBNP"),
    ("libnss3.so", "LIBNS.SO", 0xA1620000C0DE0004, 0x00C10E0000001623, "LIBNS"),
    ("libnssutil3.so", "LIBNU.SO", 0xA1630000C0DE0001, 0x00C10E0000001630, "LIBNU"),
    ("libsmime3.so", "LIBSM.SO", 0xA1630000C0DE0002, 0x00C10E0000001631, "LIBSM"),
    ("libdbus-1.so.3", "LIBDB.SO", 0xA1630000C0DE0003, 0x00C10E0000001632, "LIBDB"),
    ("libgio-2.0.so.0", "LIBGI.SO", 0xA1630000C0DE0004, 0x00C10E0000001633, "LIBGI"),
    ("libatk-1.0.so.0", "LIBAT.SO", 0xA1630000C0DE0005, 0x00C10E0000001634, "LIBAT"),
    ("libatk-bridge-2.0.so.0", "LIBAB.SO", 0xA1630000C0DE0006, 0x00C10E0000001635, "LIBAB"),
    ("libcups.so.2", "LIBCU.SO", 0xA1630000C0DE0007, 0x00C10E0000001636, "LIBCU"),
    ("libX11.so.6", "LIBX1.SO", 0xA1630000C0DE0008, 0x00C10E0000001637, "LIBX1"),
    ("libXcomposite.so.1", "LIBXC.SO", 0xA1650000C0DE0001, 0x00C10E0000001650, "LIBXC"),
    ("libXdamage.so.1", "LIBXD.SO", 0xA1650000C0DE0002, 0x00C10E0000001651, "LIBXD"),
    ("libXext.so.6", "LIBXE.SO", 0xA1650000C0DE0003, 0x00C10E0000001652, "LIBXE"),
    ("libXfixes.so.3", "LIBXF.SO", 0xA1650000C0DE0004, 0x00C10E0000001653, "LIBXF"),
    ("libXrandr.so.2", "LIBXR.SO", 0xA1650000C0DE0005, 0x00C10E0000001654, "LIBXR"),
    ("libgbm.so.1", "LIBGM.SO", 0xA1650000C0DE0006, 0x00C10E0000001655, "LIBGM"),
    ("libexpat.so.1", "LIBEX.SO", 0xA1650000C0DE0007, 0x00C10E0000001656, "LIBEX"),
    ("libxcb.so.1", "LIBXB.SO", 0xA1650000C0DE0008, 0x00C10E0000001657, "LIBXB"),
    ("libxkbcommon.so.0", "LIBXK.SO", 0xA1650000C0DE0009, 0x00C10E0000001658, "LIBXK"),
    ("libcairo.so.2", "LIBCA.SO", 0xA1650000C0DE000A, 0x00C10E0000001659, "LIBCA"),
    ("libpango-1.0.so.0", "LIBPG.SO", 0xA1650000C0DE000B, 0x00C10E000000165A, "LIBPG"),
    ("libudev.so.1", "LIBUD.SO", 0xA1650000C0DE000C, 0x00C10E000000165B, "LIBUD"),
    ("libasound.so.2", "LIBAS.SO", 0xA1650000C0DE000D, 0x00C10E000000165C, "LIBAS"),
    ("libm.so.6", "LIBM.SO", 0xA1570000C0DE0001, 0x00C10E0000001570, "LIBM"),
    ("libatspi.so.0", "LIBAP.SO", 0xA1650000C0DE000E, 0x00C10E000000165D, "LIBAP"),
    ("libgcc_s.so.1", "LIBGC.SO", 0xA1650000C0DE000F, 0x00C10E000000165E, "LIBGC"),
    ("libc.so.6", "LIBC.SO", 0xA1520000C0DE0001, 0x00C10E0000001520, "LIBC"),
    ("ld-linux-x86-64.so.2", "LIBLD.SO", 0xA1650000C0DE0010, 0x00C10E000000165F, "LIBLD"),
]


def main():
    mask = (1 << 64) - 1
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=SOMAP START")
    print("alias_tag=PROC DLOPEN ALIAS")
    print("cef_needed=32")
    print("satisfied=32")
    print("remain=0")
    print("und_bound=50")
    print("und_remain=1286")
    print("miss_soname=ld-linux-x86-64.so.2")
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_thirtytwo=NEED 0000000000000020")
    print("need_thirtyone=NEED 000000000000001F")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    for i, (soname, fat, mark, mix, tag) in enumerate(FACES, 1):
        print("soname%d=%s" % (i, soname))
        print("fat%d=%s" % (i, fat))
        print("via%d=VIA %s" % (i, tag))
        print("line%d=LINE%d %016X" % (i, i, (mark ^ mix) & mask))
    print("somap_lines=%d" % len(FACES))
    print(
        "satisfied_names="
        + ",".join("%s=%s" % (s, f) for s, f, _, _, _ in FACES)
    )
    print("leftover=rest of UND / OnPaint")


if __name__ == "__main__":
    main()
