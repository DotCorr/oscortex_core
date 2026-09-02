#!/usr/bin/env python3
"""Host-side expected numbers for cef-wire (ADR-0167).

PIXEL / RELOC are (first 8 official cef_initialize bytes) ^ MIX.
NEED is 32. NHASH folds the official DT_NEEDED name bytes.
A handwritten stub cannot match PIXEL. Missing CEF.SO cannot
print NEED. ASK.ELF of the same bytes is BadArg.
"""

MIX = 0x0000000000000167
PIXEL_RAW = 0x22840FFF8548C031
E_BADARG = 0xFFFFFFFFFFFFFFFE
E_NOTFOUND = 0xFFFFFFFFFFFFFFF9
PLAT_CAP = 0x1000000
APP_CAP = 0x200000

NEEDED_PIN = [
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


def nhash_fold(names):
    h = 0
    for n in names:
        for c in n.encode("ascii"):
            h = ((h * 131) + c) & ((1 << 64) - 1)
    return h


def main():
    derived = (PIXEL_RAW ^ MIX) & ((1 << 64) - 1)
    nh = nhash_fold(NEEDED_PIN)
    print("mix=%016X" % MIX)
    print("pixel_raw=%016X" % PIXEL_RAW)
    print("derived=%016X" % derived)
    print("needed=0000000000000020")
    print("nhash=%016X" % nh)
    print("badarg=%016X" % E_BADARG)
    print("notfound=%016X" % E_NOTFOUND)
    print("plat_cap=%08X" % PLAT_CAP)
    print("app_cap=%08X" % APP_CAP)
    print("msg_start=CEF START")
    print("cap_plat=CAP 0000000001000000")
    print("cap_app=CAP 0000000000200000")
    print("asked_bad=ASKED FFFFFFFFFFFFFFFE")
    print("pixel_line=PIXEL %016X" % derived)
    print("need_line=NEED 0000000000000020")
    print("nhash_line=NHASH %016X" % nh)
    print("reloc_line=RELOC %016X" % derived)
    print("miss_line=MISS FFFFFFFFFFFFFFF9")
    print("dlopen_err=ERR FFFFFFFFFFFFFFFE")
    print("extract_sha1=82f0dac25f8ab79701da064984d3c49ef2bedf0b")
    print("needed_blob_sha1=36d038b5f1f23f37d15968965cb33cf4097416e1")


if __name__ == "__main__":
    main()
