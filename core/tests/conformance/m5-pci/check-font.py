#!/usr/bin/env python3
"""Validate oscortex_core's 8x16 bitmap font, read out of the object file.

Usage: check-font.py <rodata.bin> <byte offset of fbFont8x16>

A separate file rather than a heredoc inside run.sh for the same reason
qmp-drive.py is: run.sh already nests a heredoc inside a `if ! python3 - ...`
construct several times, and a second level of that is where a shell script
stops being readable.

What this catches that a size check alone would not is in run.sh's own comment
at check 2e; the short version is that a font is data the renderer indexes by
arithmetic, so a malformed one draws garbage on a screen with nothing failing.

Exit status: 0 if the font is well-formed, 1 otherwise.
"""
import sys

GLYPHS = 96   # 0x20..0x7E, plus the fallback at index 95
HEIGHT = 16   # rows per glyph, one byte each

# The glyphs are authored 5 pixels wide and placed in columns 1..5 of the
# 8-pixel cell, i.e. bits 6..2. Bit 7 and bits 1:0 must therefore be clear in
# every byte of every glyph.
EDGE_BITS = 0x83


def main():
    if len(sys.argv) != 3:
        print("usage: check-font.py <rodata.bin> <offset>", file=sys.stderr)
        return 2
    blob = open(sys.argv[1], "rb").read()
    off = int(sys.argv[2])
    tbl = blob[off:off + GLYPHS * HEIGHT]

    fails = []
    if len(tbl) != GLYPHS * HEIGHT:
        fails.append("only %d bytes of font available in .rodata at offset %d, "
                     "need %d" % (len(tbl), off, GLYPHS * HEIGHT))
    else:
        space = tbl[0:HEIGHT]
        if any(space):
            fails.append("glyph 0 (space, 0x20) is not blank: %r" % (space,))

        fallback = tbl[(GLYPHS - 1) * HEIGHT:GLYPHS * HEIGHT]
        if not any(fallback):
            fails.append(
                "the fallback glyph (index %d) is BLANK -- a byte this font "
                "cannot represent would draw nothing, which is exactly what "
                "the fallback exists to prevent" % (GLYPHS - 1))

        blanks = [g for g in range(GLYPHS)
                  if not any(tbl[g * HEIGHT:(g + 1) * HEIGHT])]
        if blanks != [0]:
            fails.append(
                "expected exactly one blank glyph (0, the space); found %d: %r "
                "-- an unauthored glyph is sixteen zero bytes and renders as "
                "nothing at all" % (len(blanks), blanks))

        stray = [i for i, b in enumerate(tbl) if b & EDGE_BITS]
        if stray:
            i = stray[0]
            fails.append(
                "%d font byte(s) set bit 7 or bits 1:0, which the 5-wide "
                "placement in columns 1..5 must leave clear; first at byte %d "
                "(glyph %d, row %d, value 0x%02X)"
                % (len(stray), i, i // HEIGHT, i % HEIGHT, tbl[i]))

    if fails:
        print("check-font: FAILED", file=sys.stderr)
        for f in fails:
            print("    - " + f, file=sys.stderr)
        return 1
    print("    (%d glyphs, exactly one blank, a non-blank fallback, no stray "
          "edge bits)" % GLYPHS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
