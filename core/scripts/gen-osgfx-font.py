#!/usr/bin/env python3
"""Extract real TrueType glyph OUTLINES into a C table for osgfx.

This is NOT a bitmap font dump and NOT a coverage-mask bake. It reads the
`glyf` table of a real proportional TTF and emits the quadratic outline of
each ASCII glyph as move/line/quad/close verbs in font units, plus the real
`hmtx` advance and the real `hhea`/`OS/2` vertical metrics.

osgfx_text() then replays those verbs into an SkPathBuilder and hands the
SkPath to SkCanvas::drawPath with antialiasing on, so the glyph is
rasterised live, in the OS, by Skia's own scan converter -- at whatever
pixel size the caller asks for. TrueType outlines are quadratic, which is
exactly SkPathBuilder::quadTo, so nothing is approximated here.

Usage:
  gen-osgfx-font.py OUT.c NAME=path/to/Font.ttf [NAME2=...]

Coordinates are emitted in font units with y UP (TrueType convention).
osgfx_text flips y at raster time against the baseline.
"""
import struct
import sys

FIRST_CH = 0x20
LAST_CH = 0x7E
NGLYPH = LAST_CH - FIRST_CH + 1

VERB_MOVE, VERB_LINE, VERB_QUAD, VERB_CLOSE = 0, 1, 2, 3


class Ttf:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        self.path = path
        tag = self.d[:4]
        if tag == b"ttcf":
            n = struct.unpack_from(">I", self.d, 8)[0]
            if n < 1:
                raise SystemExit("%s: empty ttc" % path)
            base = struct.unpack_from(">I", self.d, 12)[0]
        else:
            base = 0
        num_tables = struct.unpack_from(">H", self.d, base + 4)[0]
        self.tables = {}
        for i in range(num_tables):
            off = base + 12 + i * 16
            tg, _cs, to, tl = struct.unpack_from(">4sIII", self.d, off)
            self.tables[tg.decode("latin-1")] = (to, tl)
        for need in ("head", "maxp", "loca", "glyf", "cmap", "hhea", "hmtx"):
            if need not in self.tables:
                raise SystemExit("%s: missing %s table" % (path, need))

        ho, _ = self.tables["head"]
        self.upem = struct.unpack_from(">H", self.d, ho + 18)[0]
        self.index_to_loc = struct.unpack_from(">h", self.d, ho + 50)[0]

        mo, _ = self.tables["maxp"]
        self.num_glyphs = struct.unpack_from(">H", self.d, mo + 4)[0]

        ao, _ = self.tables["hhea"]
        self.ascent = struct.unpack_from(">h", self.d, ao + 4)[0]
        self.descent = struct.unpack_from(">h", self.d, ao + 6)[0]
        self.line_gap = struct.unpack_from(">h", self.d, ao + 8)[0]
        self.num_hmetrics = struct.unpack_from(">H", self.d, ao + 34)[0]

        self.cap_height = 0
        self.x_height = 0
        if "OS/2" in self.tables:
            oo, ol = self.tables["OS/2"]
            ver = struct.unpack_from(">H", self.d, oo)[0]
            if ver >= 2 and ol >= 90:
                self.x_height = struct.unpack_from(">h", self.d, oo + 86)[0]
                self.cap_height = struct.unpack_from(">h", self.d, oo + 88)[0]
        if self.cap_height == 0:
            self.cap_height = int(self.upem * 0.71)
        if self.x_height == 0:
            self.x_height = int(self.upem * 0.52)

        self._loca()
        self._cmap()

    def _loca(self):
        lo, _ = self.tables["loca"]
        n = self.num_glyphs + 1
        if self.index_to_loc == 0:
            raw = struct.unpack_from(">%dH" % n, self.d, lo)
            self.loca = [v * 2 for v in raw]
        else:
            self.loca = list(struct.unpack_from(">%dI" % n, self.d, lo))

    def _cmap(self):
        co, _ = self.tables["cmap"]
        n = struct.unpack_from(">H", self.d, co + 2)[0]
        best = None
        for i in range(n):
            pid, eid, off = struct.unpack_from(">HHI", self.d, co + 4 + i * 8)
            score = {(3, 10): 5, (3, 1): 4, (0, 4): 3, (0, 3): 3, (0, 6): 3,
                     (3, 0): 1, (1, 0): 1}.get((pid, eid), 0)
            if score and (best is None or score > best[0]):
                best = (score, co + off)
        if best is None:
            raise SystemExit("%s: no usable cmap subtable" % self.path)
        self.cmap = self._cmap_sub(best[1])

    def _cmap_sub(self, off):
        fmt = struct.unpack_from(">H", self.d, off)[0]
        m = {}
        if fmt == 4:
            segx2 = struct.unpack_from(">H", self.d, off + 6)[0]
            seg = segx2 // 2
            ends = struct.unpack_from(">%dH" % seg, self.d, off + 14)
            starts_off = off + 16 + segx2
            starts = struct.unpack_from(">%dH" % seg, self.d, starts_off)
            deltas_off = starts_off + segx2
            deltas = struct.unpack_from(">%dh" % seg, self.d, deltas_off)
            ranges_off = deltas_off + segx2
            ranges = struct.unpack_from(">%dH" % seg, self.d, ranges_off)
            for i in range(seg):
                for c in range(starts[i], min(ends[i], 0xFFFF) + 1):
                    if ranges[i] == 0:
                        g = (c + deltas[i]) & 0xFFFF
                    else:
                        p = ranges_off + i * 2 + ranges[i] + (c - starts[i]) * 2
                        if p + 2 > len(self.d):
                            continue
                        g = struct.unpack_from(">H", self.d, p)[0]
                        if g:
                            g = (g + deltas[i]) & 0xFFFF
                    if g:
                        m[c] = g
        elif fmt == 12:
            ngroups = struct.unpack_from(">I", self.d, off + 12)[0]
            for i in range(ngroups):
                s, e, gi = struct.unpack_from(">III", self.d, off + 16 + i * 12)
                for c in range(s, min(e, 0x10FFFF) + 1):
                    m[c] = gi + (c - s)
        elif fmt == 6:
            first, cnt = struct.unpack_from(">HH", self.d, off + 6)
            ids = struct.unpack_from(">%dH" % cnt, self.d, off + 10)
            for i in range(cnt):
                if ids[i]:
                    m[first + i] = ids[i]
        elif fmt == 0:
            ids = struct.unpack_from(">256B", self.d, off + 6)
            for c in range(256):
                if ids[c]:
                    m[c] = ids[c]
        else:
            raise SystemExit("%s: cmap format %d unsupported" % (self.path, fmt))
        return m

    def advance(self, gid):
        ho, _ = self.tables["hmtx"]
        if gid < self.num_hmetrics:
            return struct.unpack_from(">H", self.d, ho + gid * 4)[0]
        if self.num_hmetrics == 0:
            return 0
        return struct.unpack_from(">H", self.d, ho + (self.num_hmetrics - 1) * 4)[0]

    def contours(self, gid, depth=0):
        """Return [[(x, y, on_curve), ...], ...] in font units, y up."""
        if depth > 4 or gid + 1 >= len(self.loca):
            return []
        go, _ = self.tables["glyf"]
        start, end = self.loca[gid], self.loca[gid + 1]
        if end <= start:
            return []
        p = go + start
        ncont = struct.unpack_from(">h", self.d, p)[0]
        p += 10
        if ncont < 0:
            return self._composite(p, depth)
        end_pts = struct.unpack_from(">%dH" % ncont, self.d, p)
        p += ncont * 2
        npts = (end_pts[-1] + 1) if ncont else 0
        ilen = struct.unpack_from(">H", self.d, p)[0]
        p += 2 + ilen

        flags = []
        while len(flags) < npts:
            f = self.d[p]
            p += 1
            flags.append(f)
            if f & 8:
                rep = self.d[p]
                p += 1
                flags.extend([f] * rep)
        flags = flags[:npts]

        xs = []
        v = 0
        for f in flags:
            if f & 2:
                dx = self.d[p]
                p += 1
                v += dx if (f & 16) else -dx
            elif not (f & 16):
                v += struct.unpack_from(">h", self.d, p)[0]
                p += 2
            xs.append(v)
        ys = []
        v = 0
        for f in flags:
            if f & 4:
                dy = self.d[p]
                p += 1
                v += dy if (f & 32) else -dy
            elif not (f & 32):
                v += struct.unpack_from(">h", self.d, p)[0]
                p += 2
            ys.append(v)

        out = []
        first = 0
        for e in end_pts:
            pts = [(xs[i], ys[i], bool(flags[i] & 1))
                   for i in range(first, min(e + 1, npts))]
            if len(pts) >= 2:
                out.append(pts)
            first = e + 1
        return out

    def _composite(self, p, depth):
        out = []
        while True:
            flags, glyph_index = struct.unpack_from(">HH", self.d, p)
            p += 4
            if flags & 1:
                a1, a2 = struct.unpack_from(">hh", self.d, p)
                p += 4
            else:
                a1, a2 = struct.unpack_from(">bb", self.d, p)
                p += 2
            if flags & 8:
                p += 2
            elif flags & 0x40:
                p += 4
            elif flags & 0x80:
                p += 8
            dx, dy = (a1, a2) if (flags & 2) else (0, 0)
            for c in self.contours(glyph_index, depth + 1):
                out.append([(x + dx, y + dy, on) for (x, y, on) in c])
            if not (flags & 0x20):
                break
        return out


def to_verbs(contours):
    """TrueType point stream -> move/line/quad/close verbs."""
    verbs = []
    pts = []

    def emit(v, *coords):
        verbs.append(v)
        pts.extend(coords)

    for c in contours:
        n = len(c)
        if c[0][2]:
            sx, sy = c[0][0], c[0][1]
            order = list(range(1, n)) + [0]
        elif c[-1][2]:
            sx, sy = c[-1][0], c[-1][1]
            order = list(range(0, n))
        else:
            sx = (c[0][0] + c[-1][0]) / 2.0
            sy = (c[0][1] + c[-1][1]) / 2.0
            order = list(range(0, n)) + [0]
        emit(VERB_MOVE, int(round(sx)), int(round(sy)))
        ctrl = None
        for i in order:
            x, y, on = c[i]
            if on:
                if ctrl is None:
                    emit(VERB_LINE, x, y)
                else:
                    emit(VERB_QUAD, ctrl[0], ctrl[1], x, y)
                    ctrl = None
            else:
                if ctrl is not None:
                    mx = int(round((ctrl[0] + x) / 2.0))
                    my = int(round((ctrl[1] + y) / 2.0))
                    emit(VERB_QUAD, ctrl[0], ctrl[1], mx, my)
                ctrl = (x, y)
        if ctrl is not None:
            emit(VERB_QUAD, ctrl[0], ctrl[1], int(round(sx)), int(round(sy)))
        emit(VERB_CLOSE)
    return verbs, pts


def rows(vals, per, fmt="%d"):
    out = []
    for i in range(0, len(vals), per):
        out.append("  " + ", ".join(fmt % v for v in vals[i:i + per]) + ",")
    return "\n".join(out) if out else "  0,"


def build(name, path):
    f = Ttf(path)
    all_verbs = []
    all_pts = []
    recs = []
    missing = []
    for ch in range(FIRST_CH, LAST_CH + 1):
        gid = f.cmap.get(ch, 0)
        if gid == 0 and ch != 0x20:
            missing.append(chr(ch))
        cont = f.contours(gid)
        v, p = to_verbs(cont)
        recs.append((len(all_verbs), len(v), len(all_pts), f.advance(gid)))
        all_verbs.extend(v)
        all_pts.extend(p)
    if missing:
        sys.stderr.write("gen-osgfx-font: %s has no glyph for %r\n"
                         % (name, "".join(missing)))
    for v in all_pts:
        if not -32768 <= v <= 32767:
            raise SystemExit("%s: point %d does not fit int16" % (name, v))
    if len(all_verbs) > 0xFFFF or len(all_pts) > 0xFFFF:
        raise SystemExit("%s: index does not fit uint16" % name)
    return f, all_verbs, all_pts, recs


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    out_path = sys.argv[1]
    faces = []
    for spec in sys.argv[2:]:
        name, _, path = spec.partition("=")
        faces.append((name, path))

    L = []
    L.append("/* core/plat/osgfx/osgfx_font_data.c — GENERATED. Do not edit.")
    L.append(" *")
    L.append(" * core/scripts/gen-osgfx-font.py extracted these from the `glyf`")
    L.append(" * table of a real proportional TTF. They are OUTLINES in font")
    L.append(" * units (y up), not bitmaps and not coverage masks: osgfx_text()")
    L.append(" * replays them into an SkPathBuilder and Skia rasterises the")
    L.append(" * SkPath live, in the OS, with antialiasing on.")
    L.append(" *")
    for name, path in faces:
        L.append(" *   %-8s %s" % (name, path))
    L.append(" */")
    L.append('#include "osgfx_font.h"')
    L.append("")

    for name, path in faces:
        f, verbs, pts, recs = build(name, path)
        low = name.lower()
        sys.stderr.write("gen-osgfx-font: %-8s upem=%d asc=%d desc=%d cap=%d "
                         "verbs=%d pts=%d\n"
                         % (name, f.upem, f.ascent, f.descent, f.cap_height,
                            len(verbs), len(pts)))
        L.append("static const unsigned char %s_verbs[%d] = {"
                 % (low, max(len(verbs), 1)))
        L.append(rows(verbs, 32))
        L.append("};")
        L.append("")
        L.append("static const short %s_pts[%d] = {" % (low, max(len(pts), 1)))
        L.append(rows(pts, 16))
        L.append("};")
        L.append("")
        L.append("static const OsgfxGlyphRec %s_glyphs[%d] = {" % (low, NGLYPH))
        for i, (vo, vn, po, adv) in enumerate(recs):
            L.append("  { %5d, %4d, %5d, %5d },  /* %s */"
                     % (vo, vn, po, adv,
                        repr(chr(FIRST_CH + i)).replace("*/", "")))
        L.append("};")
        L.append("")
        L.append("const OsgfxFace osgfx_face_%s = {" % low)
        L.append("  %s_verbs, %s_pts, %s_glyphs," % (low, low, low))
        L.append("  %d, %d, %d, %d, %d, %d"
                 % (f.upem, f.ascent, f.descent, f.line_gap, f.cap_height,
                    f.x_height))
        L.append("};")
        L.append("")

    open(out_path, "w").write("\n".join(L) + "\n")
    sys.stderr.write("gen-osgfx-font: wrote %s\n" % out_path)


main()
