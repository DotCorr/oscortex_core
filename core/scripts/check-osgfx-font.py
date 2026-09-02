#!/usr/bin/env python3
"""Render osgfx_font_data.c on the host and write a PNG.

Independent check that gen-osgfx-font.py produced correct outlines: this
reads the GENERATED C (not the TTF) and rasterises it with its own
scanline filler, so a bad verb stream shows up as garbage here before it
costs a kernel build. Deliberately not Skia — two independent
rasterisations agreeing is the point.

Usage: check-osgfx-font.py osgfx_font_data.c out.png [face] [px]
"""
import re
import struct
import sys
import zlib

FIRST_CH = 0x20


def parse(path):
    src = open(path).read()
    faces = {}
    for m in re.finditer(r'const OsgfxFace osgfx_face_(\w+) = \{\s*'
                         r'(\w+)_verbs, (\w+)_pts, (\w+)_glyphs,\s*'
                         r'([\d,\s-]+)\};', src):
        name = m.group(1)
        nums = [int(v) for v in m.group(5).replace("\n", "").split(",") if v.strip()]
        faces[name] = {"metrics": nums}
    for key in ("verbs", "pts"):
        for m in re.finditer(r'static const (?:unsigned char|short) (\w+)_%s'
                             r'\[\d+\] = \{(.*?)\};' % key, src, re.S):
            nm = m.group(1)
            if nm in faces:
                faces[nm][key] = [int(v) for v in m.group(2).replace("\n", "")
                                  .split(",") if v.strip()]
    for m in re.finditer(r'static const OsgfxGlyphRec (\w+)_glyphs'
                         r'\[\d+\] = \{(.*?)\n\};', src, re.S):
        nm = m.group(1)
        recs = []
        for r in re.finditer(r'\{\s*(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)\s*\}',
                             m.group(2)):
            recs.append(tuple(int(g) for g in r.groups()))
        if nm in faces:
            faces[nm]["glyphs"] = recs
    return faces


def glyph_contours(face, ch, scale, ox, baseline):
    idx = ch - FIRST_CH
    if idx < 0 or idx >= len(face["glyphs"]):
        return [], 0
    vo, vn, po, adv = face["glyphs"][idx]
    verbs = face["verbs"][vo:vo + vn]
    pts = face["pts"]
    pi = po
    contours = []
    cur = []
    px = py = 0.0

    def dev(x, y):
        return (ox + x * scale, baseline - y * scale)

    for v in verbs:
        if v == 0:
            if len(cur) > 2:
                contours.append(cur)
            x, y = pts[pi], pts[pi + 1]
            pi += 2
            px, py = dev(x, y)
            cur = [(px, py)]
        elif v == 1:
            x, y = pts[pi], pts[pi + 1]
            pi += 2
            px, py = dev(x, y)
            cur.append((px, py))
        elif v == 2:
            cx, cy, x, y = pts[pi], pts[pi + 1], pts[pi + 2], pts[pi + 3]
            pi += 4
            c = dev(cx, cy)
            e = dev(x, y)
            s = (px, py)
            n = 8
            for i in range(1, n + 1):
                t = i / n
                mt = 1 - t
                cur.append((mt * mt * s[0] + 2 * mt * t * c[0] + t * t * e[0],
                            mt * mt * s[1] + 2 * mt * t * c[1] + t * t * e[1]))
            px, py = e
        elif v == 3:
            if len(cur) > 2:
                contours.append(cur)
            cur = []
    if len(cur) > 2:
        contours.append(cur)
    return contours, adv * scale


def fill(buf, w, h, contours, ss=4):
    """Nonzero-winding scanline fill with ssxss coverage."""
    edges = []
    for c in contours:
        for i in range(len(c)):
            x0, y0 = c[i]
            x1, y1 = c[(i + 1) % len(c)]
            if y0 != y1:
                edges.append((x0, y0, x1, y1))
    if not edges:
        return
    for py in range(h):
        acc = [0.0] * w
        for sy in range(ss):
            yy = py + (sy + 0.5) / ss
            xs = []
            for (x0, y0, x1, y1) in edges:
                if (y0 <= yy < y1) or (y1 <= yy < y0):
                    t = (yy - y0) / (y1 - y0)
                    xs.append((x0 + t * (x1 - x0), 1 if y1 > y0 else -1))
            if not xs:
                continue
            xs.sort()
            wind = 0
            spans = []
            for i in range(len(xs) - 1):
                wind += xs[i][1]
                if wind != 0:
                    spans.append((xs[i][0], xs[i + 1][0]))
            for (sa, sb) in spans:
                a = max(0, int(sa))
                b = min(w - 1, int(sb) + 1)
                for px in range(a, b + 1):
                    cov = min(px + 1.0, sb) - max(float(px), sa)
                    if cov > 0:
                        acc[px] += cov / ss
        for px in range(w):
            if acc[px] > 0:
                v = int(min(1.0, acc[px]) * 255)
                o = (py * w + px)
                buf[o] = max(buf[o], v)


def png(path, w, h, gray):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            v = 255 - gray[y * w + x]
            raw.extend((v, v, v))

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    open(path, "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b""))


def main():
    src, out = sys.argv[1], sys.argv[2]
    which = sys.argv[3] if len(sys.argv) > 3 else "medium"
    px = int(sys.argv[4]) if len(sys.argv) > 4 else 22
    faces = parse(src)
    if which not in faces:
        raise SystemExit("faces: %s" % ", ".join(faces))
    f = faces[which]
    upem, asc, desc = f["metrics"][0], f["metrics"][1], f["metrics"][2]
    scale = px / float(upem)
    lines = ["Start  Files  Settings", "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
             "abcdefghijklmnopqrstuvwxyz", "0123456789 .,:;!?()[]{}#@%"]
    line_h = int((asc - desc) * scale) + 4
    w = 0
    for ln in lines:
        adv = sum(glyph_contours(f, ord(c), scale, 0, 0)[1] for c in ln)
        w = max(w, int(adv) + 20)
    h = line_h * len(lines) + 8
    buf = bytearray(w * h)
    for li, ln in enumerate(lines):
        baseline = 4 + li * line_h + asc * scale
        ox = 8.0
        for c in ln:
            cont, adv = glyph_contours(f, ord(c), scale, ox, baseline)
            fill(buf, w, h, cont)
            ox += adv
    png(out, w, h, buf)
    print("check-osgfx-font: %s face=%s %dpx -> %s (%dx%d)"
          % (src, which, px, out, w, h))


main()
