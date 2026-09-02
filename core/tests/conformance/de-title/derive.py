#!/usr/bin/env python3
"""core/tests/conformance/de-title/derive.py

Host model for title-bar PID glyphs. Reads pad / colour / window
origin from wmde / wmchrome / fb / win.c and the 8x16 font from
fb.dart. Never imports the kernel.

    derive.py geometry <wmde.dart> <wmchrome.dart> <fb.dart> <win.c>
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


def cdefine(path, name):
    text = open(path).read()
    m = re.search(r"^#define %s\s+(0x[0-9A-Fa-f]+|\d+)UL\s*$" % re.escape(name),
                  text, re.M)
    if not m:
        raise SystemExit("derive: no #define %s in %s" % (name, path))
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


def dartstr(path, name):
    """The ASCII of a @rodata u8 table, e.g. wmStrTitlePid -> 'App'."""
    text = open(path).read()
    m = re.search(r"final List<u8> %s = const \[(.*?)\];" % re.escape(name),
                  text, re.S)
    if not m:
        raise SystemExit("derive: no List<u8> %s in %s" % (name, path))
    b = bytes(int(x, 16) for x in re.findall(r"u8\(0x([0-9A-Fa-f]{2})\)",
                                             m.group(1)))
    return b.decode("ascii")


def emit_geometry(ded, chd, fbd, winc):
    # READ the title stem out of wmde.dart. It was typed as "PID", which is
    # what wmStrTitlePid said before the chrome-text work renamed it to "App";
    # a harness that types the string it expects on screen cannot tell "the
    # compositor renamed the caption" from "the compositor painted nothing",
    # and this one reported MATCH 17/42 for a caption that was fully painted.
    stem = dartstr(ded, "wmStrTitlePid")
    if not stem or not stem.isprintable():
        raise SystemExit("derive: wmStrTitlePid is not printable ASCII")
    pad_x = dartconst(ded, "wmTitlePadX")
    pad_y = dartconst(ded, "wmTitlePadY")
    fg = dartconst(ded, "wmTitleFg")
    stem_n = dartconst(ded, "wmTitleStemN")
    btn_s = dartconst(ded, "wmBtnS")
    btn_gap = dartconst(ded, "wmBtnGap")
    title_h = dartconst(chd, "wmTitleH")
    title_color = dartconst(chd, "wmTitleColor")
    desk = 0x00184060
    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")
    a_x = cdefine(winc, "A_X")
    a_y = cdefine(winc, "A_Y")
    win_w = cdefine(winc, "WIN_W")
    font = load_font(fbd)
    expect = set_bits(font, stem)
    wrong_text = "".join("W" if c != "W" else "M" for c in stem)
    wrong = set_bits(font, wrong_text)
    if stem_n != len(stem):
        raise SystemExit("derive: wmTitleStemN is %d, want %d" % (stem_n, len(stem)))
    if expect < 16:
        raise SystemExit("derive: %s has too few set bits" % stem)
    if expect == wrong:
        raise SystemExit("derive: %s and %s have the same bit count"
                         % (stem, wrong_text))
    if fg == title_color or fg == desk:
        raise SystemExit("derive: title fg equals the fill")
    if pad_y + 16 > title_h:
        raise SystemExit("derive: glyph taller than the title")

    glyph_x = a_x + pad_x
    glyph_y = a_y + pad_y
    glyph_w = stem_n * 8
    sit_x = a_x + 20
    sit_y = a_y + 4
    grab_x = a_x + 40
    grab_y = a_y + title_h // 2
    min_x = a_x + win_w - btn_gap - btn_s - btn_gap - btn_s
    if glyph_x <= sit_x < glyph_x + glyph_w and glyph_y <= sit_y < glyph_y + 16:
        raise SystemExit("derive: %s glyphs cover the sit-in title probe" % stem)
    if glyph_x <= grab_x < glyph_x + glyph_w and glyph_y <= grab_y < glyph_y + 16:
        raise SystemExit("derive: %s glyphs cover the de-wm grab probe" % stem)
    if glyph_x + glyph_w >= min_x:
        raise SystemExit("derive: %s glyphs reach close/min" % stem)

    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("stem=%s" % stem)
    print("wrong_text=%s" % wrong_text)
    print("fg=%06X" % (fg & 0xFFFFFF))
    print("title=%06X" % (title_color & 0xFFFFFF))
    print("desk=%06X" % (desk & 0xFFFFFF))
    print("glyph_x=%d" % glyph_x)
    print("glyph_y=%d" % glyph_y)
    print("sit_x=%d" % sit_x)
    print("sit_y=%d" % sit_y)
    print("grab_x=%d" % grab_x)
    print("grab_y=%d" % grab_y)
    print("expect_bits=%d" % expect)
    print("wrong_bits=%d" % wrong)
    print("pad_x=%d" % pad_x)
    print("pad_y=%d" % pad_y)
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
                "usage: derive.py geometry <wmde> <wmchrome> <fb> <win.c>")
        return emit_geometry(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    if kind == "font":
        return emit_font(sys.argv[2])
    raise SystemExit("derive: kind")


if __name__ == "__main__":
    sys.exit(main())
