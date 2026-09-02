#!/usr/bin/env python3
"""core/tests/conformance/files-ico/derive.py

Host-side picture for FILES icons: surface origin, band colour, icon
foreground, and one set bit inside osgfx_icon_doc. Nothing is baked.

    derive.py geometry <files.c> <osxui.h> <osgfx_glyph.c> <names>
"""

import re
import sys


def die(msg):
    print("derive: %s" % msg, file=sys.stderr)
    raise SystemExit(1)


def define_u(src, name):
    m = re.search(r"#define\s+%s\s+(0x[0-9A-Fa-f]+|\d+)UL?" % name, src)
    if not m:
        die("no #define %s" % name)
    return int(m.group(1), 0)


def enum_u(src, name):
    m = re.search(r"%s\s*=\s*(0x[0-9A-Fa-f]+|\d+)" % name, src)
    if not m:
        die("no enum %s" % name)
    return int(m.group(1), 0)


def icon_rows(glyph_c):
    m = re.search(
        r"osgfx_icon_doc\[16\]\s*=\s*\{([^}]+)\}", glyph_c, re.S
    )
    if not m:
        die("no osgfx_icon_doc")
    vals = [int(x, 0) for x in re.findall(r"0x[0-9A-Fa-f]+|\d+", m.group(1))]
    if len(vals) != 16:
        die("osgfx_icon_doc has %d bytes" % len(vals))
    return vals


def first_set(rows):
    for r, byte in enumerate(rows):
        for c in range(8):
            if (byte >> (7 - c)) & 1:
                return r, c
    die("icon has no set bits")


def main():
    if len(sys.argv) != 6 or sys.argv[1] != "geometry":
        die("usage: derive.py geometry <files.c> <osxui.h> <osgfx_glyph.c> <names>")
    files_c = open(sys.argv[2], encoding="utf-8").read()
    ui_h = open(sys.argv[3], encoding="utf-8").read()
    glyph_c = open(sys.argv[4], encoding="utf-8").read()
    names = int(sys.argv[5])
    if names < 1:
        die("names must be >= 1")

    surf_x = define_u(files_c, "SURF_X")
    surf_y = define_u(files_c, "SURF_Y")
    win_w = define_u(files_c, "WIN_W")
    win_h = define_u(files_c, "WIN_H")
    title_h = define_u(files_c, "TITLE_H")
    band0 = define_u(files_c, "SURF_BAND0")
    icon_pad = define_u(files_c, "ICON_PAD_X")
    icon_fg = define_u(files_c, "ICON_FG")
    ui_pad = enum_u(ui_h, "OSXUI_ICON_PAD_X")
    ui_fg = enum_u(ui_h, "OSXUI_ICON_FG")
    if icon_pad != ui_pad:
        die("ICON_PAD_X %d != OSXUI_ICON_PAD_X %d" % (icon_pad, ui_pad))
    if icon_fg != ui_fg:
        die("ICON_FG %06X != OSXUI_ICON_FG %06X" % (icon_fg, ui_fg))

    rows = icon_rows(glyph_c)
    br, bc = first_set(rows)
    body_h = win_h - title_h
    if body_h < 1:
        die("TITLE_H %d leaves no list body in %d-tall window" % (title_h, win_h))
    band_h = body_h // names if names > 1 else body_h
    if band_h < 1:
        band_h = 1
    # ADR-0195: list rows start under the CSD caption (TITLE_H).
    ix = icon_pad + bc
    iy = title_h + br
    sx = surf_x + ix
    sy = surf_y + iy
    # A band-only pixel next to the icon (same row, clear of glyph).
    band_x = surf_x + icon_pad + 8 + 2
    band_y = surf_y + title_h + 2

    print("names=%d" % names)
    print("band_h=%d" % band_h)
    print("surf_x=%d" % surf_x)
    print("surf_y=%d" % surf_y)
    print("title_h=%d" % title_h)
    print("win_w=%d" % win_w)
    print("win_h=%d" % win_h)
    print("band0=%06X" % (band0 & 0xFFFFFF))
    print("icon_fg=%06X" % (icon_fg & 0xFFFFFF))
    print("icon_pad=%d" % icon_pad)
    print("bit_r=%d" % br)
    print("bit_c=%d" % bc)
    print("icon_sx=%d" % sx)
    print("icon_sy=%d" % sy)
    print("band_sx=%d" % band_x)
    print("band_sy=%d" % band_y)
    print("host_ix=%d" % (40 + ui_pad + bc))
    print("host_iy=%d" % (48 + br))
    print("host_band_x=%d" % (40 + ui_pad + 10))
    print("host_band_y=%d" % (48 + 2))


if __name__ == "__main__":
    main()
