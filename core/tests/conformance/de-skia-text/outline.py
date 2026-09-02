#!/usr/bin/env python3
"""Assert osgfx_font_data.c is a proportional QUADRATIC OUTLINE table.

A bitmap font, a fixed-cell font and a coverage-mask cache would all fail
at least one of these:

  1. advances differ per glyph, and the ratio between the widest and the
     narrowest is large (a cell font has ONE advance);
  2. 'i' is much narrower than 'W' specifically (catches a table that
     varies advances but not by glyph shape);
  3. a large share of the verbs are quadratics (verb code 2) -- a table
     built from straight segments only is a traced bitmap, not `glyf`;
  4. point coordinates span thousands of font units, i.e. they are em
     units at a real upem, not pixels in a cell.

Usage: outline.py osgfx_font_data.c
"""
import re
import sys

FIRST = 0x20
VERB_QUAD = 2


def arrays(src, kind, suffix):
    out = {}
    pat = (r'static const %s (\w+)_%s\[\d+\] = \{(.*?)\};'
           % (kind, suffix))
    for m in re.finditer(pat, src, re.S):
        out[m.group(1)] = [int(v) for v in m.group(2).replace("\n", "").split(",")
                           if v.strip()]
    return out


def main():
    src = open(sys.argv[1]).read()
    verbs = arrays(src, r'unsigned char', 'verbs')
    pts = arrays(src, r'short', 'pts')
    glyphs = {}
    for m in re.finditer(r'static const OsgfxGlyphRec (\w+)_glyphs'
                         r'\[\d+\] = \{(.*?)\n\};', src, re.S):
        recs = []
        for r in re.finditer(r'\{\s*(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\}',
                             m.group(2)):
            recs.append(tuple(int(g) for g in r.groups()))
        glyphs[m.group(1)] = recs

    faces = {}
    for m in re.finditer(r'const OsgfxFace osgfx_face_(\w+) = \{\s*'
                         r'(\w+)_verbs, \w+_pts, \w+_glyphs,\s*'
                         r'([\d,\s-]+)\};', src):
        faces[m.group(1)] = (m.group(2), [int(v) for v in
                                          m.group(3).replace("\n", "").split(",")
                                          if v.strip()])
    if not faces:
        print("outline: no OsgfxFace in %s" % sys.argv[1])
        return 1

    ok = True
    for name, (key, metrics) in sorted(faces.items()):
        if key not in verbs or key not in pts or key not in glyphs:
            print("outline: %s face has no arrays" % name)
            ok = False
            continue
        v, p, g = verbs[key], pts[key], glyphs[key]
        upem = metrics[0]
        adv = [rec[3] for rec in g if rec[1] > 0]
        if len(set(adv)) < 20:
            print("outline: %s has only %d distinct advances — fixed cell"
                  % (name, len(set(adv))))
            ok = False
        if max(adv) < 2 * min(adv):
            print("outline: %s advance spread %d..%d is too flat to be "
                  "proportional" % (name, min(adv), max(adv)))
            ok = False
        narrow = g[ord('i') - FIRST][3]
        wide = g[ord('W') - FIRST][3]
        if wide < 2 * narrow:
            print("outline: %s 'W' (%d) is not much wider than 'i' (%d)"
                  % (name, wide, narrow))
            ok = False
        quads = sum(1 for code in v if code == VERB_QUAD)
        if quads * 4 < len(v):
            print("outline: %s only %d/%d verbs are quadratics — not `glyf` "
                  "curves" % (name, quads, len(v)))
            ok = False
        if upem < 512 or max(p) < upem // 4:
            print("outline: %s upem %d vs max point %d — not em units"
                  % (name, upem, max(p)))
            ok = False
        if ok:
            print("outline: %-8s upem %d, %d glyphs, %d verbs (%d quads), "
                  "advance %d..%d ('i' %d vs 'W' %d)"
                  % (name, upem, len(g), len(v), quads, min(adv), max(adv),
                     narrow, wide))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
