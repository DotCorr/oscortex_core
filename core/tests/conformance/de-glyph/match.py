#!/usr/bin/env python3
"""Match 8x16 glyphs in a framebuffer dump or P6 PPM.

    match.py fb <fb.bin> <pitch> <x> <y> <fg-hex> <font-file> <text>
    match.py ppm <ppm> 0 <x> <y> <fg-hex> <font-file> <text>

font-file is derive.py font output (font_hex=...). Exit 0 if the
planted text matches the real font (count) and a wrong font does not.
"""

import sys


def glyph_rows(font, ch):
    if ch < 0x20 or ch > 0x7E:
        off = 95 * 16
    else:
        off = (ch - 0x20) * 16
    return font[off:off + 16]


def expected_on(font, text):
    pts = []
    for i, ch in enumerate(text.encode("ascii")):
        rows = glyph_rows(font, ch)
        for r, bits in enumerate(rows):
            for c in range(8):
                if (bits >> (7 - c)) & 1:
                    pts.append((i * 8 + c, r))
    return pts


def wrong_font(font):
    return bytes((b ^ 0xFF) & 0x7C for b in font)


def load_fb(path, pitch):
    blob = open(path, "rb").read()

    def at(x, y):
        off = y * pitch + x * 4
        if off + 4 > len(blob):
            return None
        return int.from_bytes(blob[off:off + 4], "little") & 0x00FFFFFF

    return at


def load_ppm(path):
    with open(path, "rb") as f:
        if f.readline() != b"P6\n":
            raise SystemExit("not P6")
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = [int(x) for x in line.split()]
        if f.readline().strip() != b"255":
            raise SystemExit("maxval")
        data = f.read()
    if len(data) != w * h * 3:
        raise SystemExit("short ppm")

    def at(x, y):
        if x < 0 or y < 0 or x >= w or y >= h:
            return None
        i = (y * w + x) * 3
        return (data[i] << 16) | (data[i + 1] << 8) | data[i + 2]

    return at


def near(c, expect, slop):
    if c is None:
        return False
    dr = abs(((c >> 16) & 0xFF) - ((expect >> 16) & 0xFF))
    dg = abs(((c >> 8) & 0xFF) - ((expect >> 8) & 0xFF))
    db = abs((c & 0xFF) - (expect & 0xFF))
    return dr <= slop and dg <= slop and db <= slop


def count_match(at, ox, oy, fg, pts, slop=8):
    n = 0
    for dx, dy in pts:
        if near(at(ox + dx, oy + dy), fg, slop):
            n += 1
    return n


def main():
    if len(sys.argv) != 9:
        raise SystemExit(
            "usage: match.py fb|ppm <src> <pitch-or-0> <x> <y> <fg-hex> "
            "<font-file> <text>")
    kind, src, pitch_s, xs, ys, fgs, fontp, text = sys.argv[1:9]
    pitch = int(pitch_s)
    x, y = int(xs), int(ys)
    fg = int(fgs, 16) & 0xFFFFFF
    hexpart = None
    for line in open(fontp):
        if line.startswith("font_hex="):
            hexpart = line.split("=", 1)[1].strip()
    if hexpart is None:
        raise SystemExit("no font_hex in %s" % fontp)
    font = bytes.fromhex(hexpart)
    if len(font) != 1536:
        raise SystemExit("font %d" % len(font))
    if kind == "fb":
        at = load_fb(src, pitch)
    elif kind == "ppm":
        at = load_ppm(src)
    else:
        raise SystemExit("kind")

    pts = expected_on(font, text)
    wpts = expected_on(wrong_font(font), text)
    alt_text = "WXYZ" if text.upper() != "WXYZ" else "ABCD"
    alt = expected_on(font, alt_text[:len(text)])
    got = count_match(at, x, y, fg, pts)
    got_wrong = count_match(at, x, y, fg, wpts)
    got_alt = count_match(at, x, y, fg, alt)
    need = max(16, len(pts) // 2)
    print("EXPECT %d" % len(pts))
    print("MATCH %d" % got)
    print("WRONG %d" % got_wrong)
    print("ALT %d" % got_alt)
    if got < need:
        raise SystemExit("MATCH %d < %d — colour tile or missing glyphs" %
                         (got, need))
    if got_wrong >= got:
        raise SystemExit("wrong font matched as well as the real font")
    if got_alt >= got:
        raise SystemExit("alternate name matched as well as the planted name")
    print("GLYPH_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
