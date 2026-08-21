#!/usr/bin/env python3
"""Check the LINEAR FRAMEBUFFER's actual pixels against the kernel's own font.

Usage:
  check-pixels.py <monitor-capture> <rodata.bin> <font offset> <text> <fg> <bg>

`<monitor-capture>` is qmp-drive.py's dump file: `=== <command> ===` headers
followed by the monitor's `xp` output. This looks for the framebuffer dumps
(the `xp` commands), in order, one per scanline.

WHY THIS EXISTS RATHER THAN A SCREENSHOT
------------------------------------------------------------------------
A PNG proves QEMU rendered something. It does not prove the kernel wrote it,
does not prove the kernel found the right address, and cannot fail in a way
that names what went wrong. This reads the bytes back out of GUEST PHYSICAL
MEMORY at the address the kernel itself reported, and compares them against the
bitmap re-rendered here from the SAME `@rodata` font table the kernel blitted
from -- read out of `kmain.o`, not copied into this file.

So the expected image is not a golden anybody typed. If the font changes, this
check follows it; if the BLIT is wrong -- wrong bit order, wrong row stride,
wrong colour, an off-by-one in the glyph index, a background that was never
painted -- the pixels disagree and the failure names the exact pixel.

Exit status: 0 if every pixel matches, 1 otherwise.
"""
import re
import sys

GLYPH_W, GLYPH_H, GLYPH_BYTES = 8, 16, 16
FONT_FIRST, FONT_LAST = 0x20, 0x7E
FONT_FALLBACK = 95


def parse_dumps(path):
    """Returns the list of `xp` outputs, in order, as lists of ints."""
    rows = []
    cur = None
    for line in open(path, "r", encoding="utf-8", errors="replace"):
        if line.startswith("=== "):
            if cur is not None:
                rows.append(cur)
            cur = [] if " xp/" in line or line.startswith("=== xp") else None
            continue
        if cur is None:
            continue
        if ":" not in line:
            continue
        for tok in line.split(":", 1)[1].split():
            if tok.startswith("0x"):
                cur.append(int(tok, 16))
    if cur is not None:
        rows.append(cur)
    return rows


def glyph_index(ch):
    code = ord(ch)
    if FONT_FIRST <= code <= FONT_LAST:
        return code - FONT_FIRST
    return FONT_FALLBACK


def main():
    if len(sys.argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2
    dump_path, rodata_path, font_off, text, fg, bg = sys.argv[1:]
    font_off = int(font_off)
    fg = int(fg, 0)
    bg = int(bg, 0)

    blob = open(rodata_path, "rb").read()
    font = blob[font_off:font_off + 96 * GLYPH_BYTES]
    if len(font) != 96 * GLYPH_BYTES:
        print("check-pixels: could not read the font out of .rodata",
              file=sys.stderr)
        return 1

    rows = parse_dumps(dump_path)
    if not rows:
        print("check-pixels: the monitor capture contains no `xp` dumps -- "
              "nothing was read back out of guest memory", file=sys.stderr)
        return 1
    if len(rows) != GLYPH_H:
        print("check-pixels: expected %d scanline dumps (one per glyph row), "
              "found %d" % (GLYPH_H, len(rows)), file=sys.stderr)
        return 1

    width = len(text) * GLYPH_W
    for r in rows:
        if len(r) != width:
            print("check-pixels: a scanline dump has %d pixels, expected %d "
                  "(%d characters x %d)" % (len(r), width, len(text), GLYPH_W),
                  file=sys.stderr)
            return 1

    fails = []
    lit = 0
    for row in range(GLYPH_H):
        for col, ch in enumerate(text):
            bits = font[glyph_index(ch) * GLYPH_BYTES + row]
            for px in range(GLYPH_W):
                want = fg if (bits >> (7 - px)) & 1 else bg
                if want == fg:
                    lit += 1
                got = rows[row][col * GLYPH_W + px] & 0x00FFFFFF
                if got != want:
                    if len(fails) < 12:
                        fails.append(
                            "pixel (x=%d, y=%d) inside %r of %r: framebuffer "
                            "has 0x%06X, the font says it should be 0x%06X"
                            % (col * GLYPH_W + px, row, ch, text, got, want))
    if lit == 0:
        fails.append("the expected image has NO foreground pixels at all -- "
                     "this check would have passed against a blank screen")

    if fails:
        print("check-pixels: FAILED", file=sys.stderr)
        for f in fails:
            print("    - " + f, file=sys.stderr)
        return 1
    total = GLYPH_H * width
    print("    (%d pixels compared, %d of them foreground, all matching the "
          "font in kmain.o)" % (total, lit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
