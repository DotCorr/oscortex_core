#!/usr/bin/env python3
"""Assert a framebuffer region holds ANTIALIASED PROPORTIONAL OUTLINE text.

The properties checked here are the ones an 8x16 bitmap font cannot have,
which is the whole point: "there is dark ink in the caption band" was
already true of the stamped glyphs the owner rejected.

  1. AA ramp        -- many distinct ink shades, not one flat ink colour.
  2. Fringe mass    -- a large share of the ink sits at intermediate
                       coverage between the ink core and the background.
  3. Off-grid metrics -- the ink bounding box height is not the 16px cell
                       height, and the ink does not start/stop on 8px
                       column boundaries for every glyph.

Usage: caption.py FB PITCH X0 Y0 X1 Y1 [--min-ink N]
Exit:  0 pass, 1 fail, 2 usage.
"""
import sys

CELL_W = 8
CELL_H = 16


def luma(c):
    return (((c >> 16) & 255) * 299 + ((c >> 8) & 255) * 587 +
            (c & 255) * 114) // 1000


def main():
    if len(sys.argv) < 7:
        sys.stderr.write(__doc__)
        return 2
    fb = sys.argv[1]
    pitch = int(sys.argv[2])
    x0, y0, x1, y1 = (int(v) for v in sys.argv[3:7])
    min_ink = 40
    if "--min-ink" in sys.argv:
        min_ink = int(sys.argv[sys.argv.index("--min-ink") + 1])
    data = open(fb, "rb").read()

    def px(x, y):
        off = y * pitch + x * 4
        if off + 4 > len(data):
            return 0
        return int.from_bytes(data[off:off + 4], "little") & 0xFFFFFF

    # Background = most common colour in the band (the title fill).
    hist = {}
    for y in range(y0, y1):
        for x in range(x0, x1):
            c = px(x, y)
            hist[c] = hist.get(c, 0) + 1
    bg = max(hist, key=hist.get)
    bg_l = luma(bg)

    # Ink may be darker than the fill (title caption) or lighter than it
    # (white label on the Start pill), so polarity is measured, not assumed.
    ink = []
    for y in range(y0, y1):
        for x in range(x0, x1):
            c = px(x, y)
            if abs(luma(c) - bg_l) > 20:
                ink.append((x, y, c))

    if len(ink) < min_ink:
        print("caption: only %d ink pixels (need %d) over bg %06X"
              % (len(ink), min_ink, bg))
        return 1

    shades = {c for (_x, _y, c) in ink}
    lumas = sorted(luma(c) for (_x, _y, c) in ink)
    dark = bg_l - lumas[0] >= lumas[-1] - bg_l
    core_l = lumas[0] if dark else lumas[-1]
    lo = min(core_l, bg_l) + 8
    hi = max(core_l, bg_l) - 8
    fringe = sum(1 for l in lumas if lo < l < hi)
    xs = [p[0] for p in ink]
    ys = [p[1] for p in ink]
    box_h = max(ys) - min(ys) + 1
    box_w = max(xs) - min(xs) + 1

    ok = True
    if len(shades) < 12:
        print("caption: only %d distinct ink shades — flat stamps, no AA ramp"
              % len(shades))
        ok = False
    if fringe * 4 < len(ink):
        print("caption: only %d/%d ink pixels at intermediate coverage — "
              "binary coverage, not antialiasing" % (fringe, len(ink)))
        ok = False
    if box_h == CELL_H or box_h == 0:
        print("caption: ink box height %d is the 8x16 cell height — "
              "still a bitmap cell" % box_h)
        ok = False
    if box_w % CELL_W == 0 and len(set(xs)) % CELL_W == 0:
        print("caption: ink width %d lands exactly on the %dpx cell grid"
              % (box_w, CELL_W))
        ok = False

    if not ok:
        return 1
    print("caption: pass  %d ink px, %d shades, %d fringe px, box %dx%d "
          "(off the %dx%d cell), bg %06X"
          % (len(ink), len(shades), fringe, box_w, box_h, CELL_W, CELL_H, bg))
    return 0


if __name__ == "__main__":
    sys.exit(main())
