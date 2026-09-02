#!/usr/bin/env python3
"""core/tests/conformance/de-glyph/derive.py

Host model for Start / osxui 8.3 glyphs. Reads geometry from wmde /
wmchrome / fb / osxui.h and the 8x16 font from fb.dart. Never imports
the kernel.

    derive.py geometry <wmde.dart> <wmchrome.dart> <fb.dart> NAME
    derive.py font <fb.dart>
"""

import re
import sys


def dartconst(path, name):
    text = open(path).read()
    m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(name),
                  text, re.M)
    if not m:
        raise SystemExit("derive: no const int %s in %s" % (name, path))
    return int(m.group(1), 0)


def cenum(path, name):
    text = open(path).read()
    m = re.search(r"%s = (0x[0-9A-Fa-f]+|\d+)" % re.escape(name), text)
    if not m:
        raise SystemExit("derive: no %s in %s" % (name, path))
    return int(m.group(1), 0)


def load_font(fbd):
    text = open(fbd).read()
    m = re.search(r"final List<u8> fbFont8x16 = const \[(.*?)\];", text, re.S)
    if not m:
        raise SystemExit("derive: no fbFont8x16")
    vals = [int(x, 16) for x in re.findall(r"u8\(0x([0-9A-Fa-f]{2})\)",
                                           m.group(1))]
    if len(vals) != 1536:
        raise SystemExit("derive: font is %d bytes, want 1536" % len(vals))
    return bytes(vals)


def glyph_rows(font, ch):
    if ch < 0x20 or ch > 0x7E:
        off = 95 * 16
    else:
        off = (ch - 0x20) * 16
    return font[off:off + 16]


def set_bits(font, text):
    n = 0
    for ch in text.encode("ascii"):
        for row in glyph_rows(font, ch):
            n += bin(row).count("1")
    return n


def steps_to(dx, dy, cap=120):
    out = []
    x, y = dx, dy
    while x != 0 or y != 0:
        sx = max(-cap, min(cap, x))
        sy = max(-cap, min(cap, y))
        if sx == 0 and sy == 0:
            raise SystemExit("derive: cannot step (%d,%d)" % (dx, dy))
        out.append((sx, sy))
        x -= sx
        y -= sy
    return out


def fmt_rels(steps):
    return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)


def click_script(from_xy, to_xy):
    dx = to_xy[0] - from_xy[0]
    dy = to_xy[1] - from_xy[1]
    rels = fmt_rels(steps_to(dx, dy)) if (dx or dy) else ""
    parts = [rels] if rels else []
    parts.append("btn:left:down,wait:80,btn:left:up")
    return ",".join(parts), to_xy


def emit_geometry(ded, chd, fbd, name):
    name = name.upper()
    if "." in name:
        stem = name.split(".", 1)[0]
    else:
        stem = name
    if len(stem) != 4:
        raise SystemExit("derive: planted stem must be 4 letters, got %r" % stem)

    start_w = dartconst(ded, "wmStartW")
    launch_w = dartconst(ded, "wmLaunchW")
    launch_h = dartconst(ded, "wmLaunchH")
    launch_row_h = dartconst(ded, "wmLaunchRowH")
    launch_row0 = dartconst(ded, "wmLaunchRow0")
    pad_x = dartconst(ded, "wmLabelPadX")
    pad_y = dartconst(ded, "wmLabelPadY")
    fg = dartconst(ded, "wmLabelFg")
    chrome_h = dartconst(chd, "wmChromeH")
    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")
    font = load_font(fbd)
    expect = set_bits(font, stem)
    wrong = set_bits(font, "WXYZ")
    if expect < 16:
        raise SystemExit("derive: planted stem has too few set bits")
    if expect == wrong:
        raise SystemExit("derive: ABCD and WXYZ have the same bit count")

    start_x = start_w // 2
    start_y = fb_h - chrome_h // 2
    launch_y0 = fb_h - chrome_h - launch_h
    glyph_x = pad_x
    glyph_y = launch_y0 + pad_y
    row0_x = launch_w // 2
    row0_y = launch_y0 + 4 + launch_row_h // 2
    if glyph_x + 4 * 8 >= row0_x:
        raise SystemExit("derive: glyphs reach the row-centre colour probe")
    if fg == launch_row0:
        raise SystemExit("derive: label fg equals the launch row")

    origin = (0, 0)
    rels_start, _ = click_script(origin, (start_x, start_y))

    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("stem=%s" % stem)
    print("name=%s" % name)
    print("fg=%06X" % (fg & 0xFFFFFF))
    print("row0=%06X" % (launch_row0 & 0xFFFFFF))
    print("glyph_x=%d" % glyph_x)
    print("glyph_y=%d" % glyph_y)
    print("row0_x=%d" % row0_x)
    print("row0_y=%d" % row0_y)
    print("expect_bits=%d" % expect)
    print("wrong_bits=%d" % wrong)
    print("rels_start=%s" % rels_start)
    return 0


def emit_font(fbd):
    font = load_font(fbd)
    print("font_bytes=%d" % len(font))
    print("font_hex=%s" % font.hex())
    return 0


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: derive.py geometry|font ...")
    kind = sys.argv[1]
    if kind == "geometry":
        if len(sys.argv) != 6:
            raise SystemExit(
                "usage: derive.py geometry <wmde> <wmchrome> <fb> NAME")
        return emit_geometry(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    if kind == "font":
        return emit_font(sys.argv[2])
    raise SystemExit("derive: kind")


if __name__ == "__main__":
    sys.exit(main())
