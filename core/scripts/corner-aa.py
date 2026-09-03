#!/usr/bin/env python3
"""PIL corner-AA inspector for guest framebuffer PNGs.

A binary cream/teal stair in a rounded-card corner is a tooth.
True #FFFFFF is not required — cream E8EEF4 next to wallpaper without
an intermediate mix is the failure. Use PIL; a raw IDAT walk without
PNG unfilter invents checkerboards.
"""

from __future__ import annotations

import json
import os
import sys

try:
    from PIL import Image
except ImportError:
    raise SystemExit("corner-aa.py needs Pillow")


WALL_TEAL = ((0x48, 0xA0, 0x90), (0x78, 0xE0, 0xD8))


def load_rgb(path):
    im = Image.open(path).convert("RGB")
    return im.size[0], im.size[1], im.load()


def is_wallpaper(rgb):
    r, g, b = rgb
    lo, hi = WALL_TEAL
    if r < lo[0] or r > hi[0]:
        return False
    if g < lo[1] or g > hi[1]:
        return False
    if b < lo[2] or b > hi[2]:
        return False
    return (g - r) > 40


def near_white(rgb):
    r, g, b = rgb
    return r > 240 and g > 240 and b > 240


def shades(pix, x0, y0, x1, y1, w, h):
    seen = {}
    n_wall = n_white = n_other = 0
    for y in range(max(0, y0), min(h, y1)):
        for x in range(max(0, x0), min(w, x1)):
            c = pix[x, y]
            seen[c] = seen.get(c, 0) + 1
            if is_wallpaper(c):
                n_wall += 1
            elif near_white(c):
                n_white += 1
            else:
                n_other += 1
    return {
        "n_shades": len(seen),
        "n_wall": n_wall,
        "n_white": n_white,
        "n_other": n_other,
        "top": sorted(seen.items(), key=lambda kv: -kv[1])[:8],
    }


def corner_tooth(pix, x0, y0, x1, y1, w, h):
    """Binary wall↔fill jump with no mix neighbour counts as a tooth."""
    teeth = 0
    samples = 0
    for y in range(max(1, y0), min(h - 1, y1)):
        for x in range(max(1, x0), min(w - 1, x1)):
            c = pix[x, y]
            samples += 1
            if not is_wallpaper(c):
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                n = pix[x + dx, y + dy]
                if is_wallpaper(n) or near_white(n):
                    if near_white(n):
                        teeth += 1
                    continue
                # fill-ish neighbour of a wallpaper pixel is OK if it is
                # mixed (not a hard cream jump). Cream E8EEF4 is ~232,238,244.
                nr, ng, nb = n
                if nr >= 220 and ng >= 220 and nb >= 220:
                    # look for a mix in the 4-neighbourhood of the fill px
                    mixed = False
                    for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        m = pix[x + dx + ddx, y + dy + ddy]
                        if is_wallpaper(m) or near_white(m):
                            continue
                        mr, mg, mb = m
                        if mr < 220 or mg < 220 or mb < 220:
                            mixed = True
                            break
                    if not mixed:
                        teeth += 1
    return teeth, samples


def inspect_card(pix, w, h, x, y, cw, ch, r, name):
    corners = {
        "tl": (x, y),
        "tr": (x + cw - r, y),
        "bl": (x, y + ch - r),
        "br": (x + cw - r, y + ch - r),
    }
    out = {"name": name, "rect": [x, y, cw, ch], "radius": r, "corners": {}}
    teeth = 0
    for key, (cx, cy) in corners.items():
        band = shades(pix, cx - 1, cy - 1, cx + r + 2, cy + r + 2, w, h)
        t, s = corner_tooth(pix, cx - 1, cy - 1, cx + r + 2, cy + r + 2, w, h)
        band["teeth"] = t
        band["samples"] = s
        out["corners"][key] = band
        teeth += t
        if band["n_shades"] < 3 and band["n_other"] > 0 and band["n_wall"] > 0:
            teeth += 1
            band["binary_stair"] = True
    out["teeth"] = teeth
    out["bad"] = teeth > 0
    return out


def inspect_png(path, files_xywh=(48, 40, 400, 280), set_xywh=(180, 48, 440, 280),
                r=18):
    w, h, pix = load_rgb(path)
    recs = []
    fx, fy, fw, fh = files_xywh
    sx, sy, sw, sh = set_xywh
    recs.append(inspect_card(pix, w, h, fx, fy, fw, fh, r, "files"))
    recs.append(inspect_card(pix, w, h, sx, sy, sw, sh, r, "set"))
    # Dock glass pills sit on the bottom strip; probe the right island.
    recs.append(inspect_card(pix, w, h, w - 220, h - 44, 200, 36, 12, "dock"))
    teeth = sum(c["teeth"] for c in recs)
    return {
        "png": path,
        "size": [w, h],
        "cards": recs,
        "teeth": teeth,
        "bad": teeth > 0,
    }


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: corner-aa.py <png> [...]")
    out = []
    bad = 0
    for p in sys.argv[1:]:
        rec = inspect_png(p)
        out.append(rec)
        if rec["bad"]:
            bad += 1
            print("BAD", rec["png"], "teeth", rec["teeth"])
        else:
            print("OK", rec["png"], "teeth", rec["teeth"])
    summary = {"n": len(out), "bad": bad, "frames": out}
    print(json.dumps({k: summary[k] for k in ("n", "bad")}, indent=2))
    art = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
    try:
        os.makedirs(art, exist_ok=True)
        open(os.path.join(art, "oscortex-round17-corner-aa.json"), "w").write(
            json.dumps(summary, indent=2) + "\n")
    except OSError:
        pass
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
