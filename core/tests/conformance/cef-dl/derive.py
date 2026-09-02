#!/usr/bin/env python3
"""Host-side expected numbers for cef-dl (ADR-0174).

Real DT_NEEDED soname libdl.so.2 → planted SOMAP.TXT → FAT LIBDL.SO.
LINE = MARK_D ^ MIX. Missing SOMAP is NotFound and cannot invent LINE.
"""

MARK_D = 0xA1740000C0DE0001
MIX = 0x00C10E0000001740
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9

# One of 32 CEF DT_NEEDED faces under its real Linux soname.
CEF_SONAME = "libdl.so.2"
FAT_FACE = "LIBDL.SO"


def main():
    line = (MARK_D ^ MIX) & ((1 << 64) - 1)
    print("mark_d=%016X" % MARK_D)
    print("mix=%016X" % MIX)
    print("notfound=%016X" % E_NOTFOUND)
    print("msg_start=CEFDL START")
    print("msg_via=VIA LIBDL.SO.2")
    print("soname=%s" % CEF_SONAME)
    print("fat_face=%s" % FAT_FACE)
    print("somap_line=%s=%s" % (CEF_SONAME, FAT_FACE))
    print("line=LINE %016X" % line)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("need_one=NEED 0000000000000001")
    print("refuse=ELF REFUSED 11 PT_INTERP or PT_DYNAMIC: this loader does not link")
    print("alias_tag=PROC DLOPEN ALIAS")
    print("satisfied_named=1")
    print("und_remain=1286")
    print("und_bound=50")
    print("leftover=rest of UND / other 31 DT_NEEDED sonames / OnPaint")


if __name__ == "__main__":
    main()
