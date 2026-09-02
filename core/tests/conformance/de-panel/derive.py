#!/usr/bin/env python3
"""core/tests/conformance/de-panel/derive.py

Host model for reflection-panel hex pids. Reads pad / colour / panel
origin from wmde / wmchrome / fb and the 8x16 font from fb.dart.
Never imports the kernel.

    derive.py geometry <wmde.dart> <wmchrome.dart> <fb.dart> [osxui.h]
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
    m = re.search(r"\b%s\s*=\s*(0x[0-9A-Fa-f]+|\d+)\b" % re.escape(name), text)
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


def emit_geometry(ded, chd, fbd, uih=None):
    pad_x = dartconst(ded, "wmPanelPadX")
    pad_y = dartconst(ded, "wmPanelPadY")
    fg = dartconst(ded, "wmPanelFg")
    stem_n = dartconst(ded, "wmPanelStemN")
    panel_w = dartconst(ded, "wmPanelW")
    panel_h = dartconst(ded, "wmPanelH")
    panel_color = dartconst(ded, "wmPanelColor")
    panel_row0 = dartconst(ded, "wmPanelRow0")
    note_w = dartconst(ded, "wmNoteW")
    launch_row_h = dartconst(ded, "wmLaunchRowH")
    chrome_h = dartconst(chd, "wmChromeH")
    desk = 0x00184060
    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")
    font = load_font(fbd)
    host = "DEADBEEF"
    expect = set_bits(font, host)
    wrong = set_bits(font, "WXYZ"[:len(host)])
    if stem_n != 8:
        raise SystemExit("derive: wmPanelStemN is %d, want 8" % stem_n)
    if expect < 16:
        raise SystemExit("derive: DEADBEEF has too few set bits")
    if expect == wrong:
        raise SystemExit("derive: DEADBEEF and WXYZ have the same bit count")
    if fg == panel_row0 or fg == panel_color or fg == desk:
        raise SystemExit("derive: panel fg equals a fill")
    if pad_y + 16 > launch_row_h + 4:
        raise SystemExit("derive: glyph taller than the panel row")

    panel_x = fb_w - panel_w
    panel_y = fb_h - chrome_h - panel_h
    glyph_x = panel_x + pad_x
    glyph_y = panel_y + pad_y
    glyph_w = stem_n * 8
    probe_x = panel_x + 10
    probe_y = panel_y + 4 + launch_row_h // 2
    note_x = fb_w - note_w // 2
    note_y = fb_h - chrome_h // 2

    if glyph_x <= probe_x < glyph_x + glyph_w and glyph_y <= probe_y < glyph_y + 16:
        raise SystemExit("derive: hex glyphs cover the de-chrome row probe")
    if glyph_x + glyph_w > panel_x + panel_w:
        raise SystemExit("derive: hex glyphs overflow the panel")

    if uih:
        if cenum(uih, "OSXUI_REFL_PAD_X") != pad_x:
            raise SystemExit("derive: OSXUI_REFL_PAD_X moved")
        if cenum(uih, "OSXUI_REFL_PAD_Y") != pad_y:
            raise SystemExit("derive: OSXUI_REFL_PAD_Y moved")
        if cenum(uih, "OSXUI_REFL_FG") != fg:
            raise SystemExit("derive: OSXUI_REFL_FG moved")
        if cenum(uih, "OSXUI_REFL") != panel_row0:
            raise SystemExit("derive: OSXUI_REFL is not wmPanelRow0")
        if cenum(uih, "OSXUI_REFL_BG") != panel_color:
            raise SystemExit("derive: OSXUI_REFL_BG is not wmPanelColor")

    rels = fmt_rels(steps_to(note_x, note_y))
    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("host=%s" % host)
    print("fg=%06X" % (fg & 0xFFFFFF))
    print("row=%06X" % (panel_row0 & 0xFFFFFF))
    print("panel=%06X" % (panel_color & 0xFFFFFF))
    print("desk=%06X" % (desk & 0xFFFFFF))
    print("glyph_x=%d" % glyph_x)
    print("glyph_y=%d" % glyph_y)
    print("probe_x=%d" % probe_x)
    print("probe_y=%d" % probe_y)
    print("host_x=%d" % (panel_x + pad_x))
    print("host_y=%d" % (panel_y + pad_y))
    print("expect_bits=%d" % expect)
    print("wrong_bits=%d" % wrong)
    print("pad_x=%d" % pad_x)
    print("pad_y=%d" % pad_y)
    print("rels_note=%s" % ",".join([rels, "btn:left:down,wait:80,btn:left:up"]))
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
        if len(sys.argv) not in (5, 6):
            raise SystemExit(
                "usage: derive.py geometry <wmde> <wmchrome> <fb> [osxui.h]")
        uih = sys.argv[5] if len(sys.argv) == 6 else None
        return emit_geometry(sys.argv[2], sys.argv[3], sys.argv[4], uih)
    if kind == "font":
        return emit_font(sys.argv[2])
    raise SystemExit("derive: kind")


if __name__ == "__main__":
    sys.exit(main())
