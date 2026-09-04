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


# Generative wallpaper is ~5BC0B7. A wide teal band also matches AA mixes
# (6DD3BF) and invents teeth. Tight match is the wallpaper field only.
WALL = (0x5B, 0xC0, 0xB7)
CREAM = (0xE8, 0xEE, 0xF4)
SET_FILL = (0xF0, 0xF4, 0xF8)


def load_rgb(path):
    im = Image.open(path).convert("RGB")
    return im.size[0], im.size[1], im.load()


def is_wallpaper(rgb):
    r, g, b = rgb
    # G±8 keeps the generative field (5BC0B7) and drops AA mixes
    # (G≈207) that used to invent BL teeth next to cream.
    if abs(r - WALL[0]) > 8 or abs(g - WALL[1]) > 8 or abs(b - WALL[2]) > 12:
        return False
    return (g - r) > 40


def is_opaque_fill(rgb):
    return rgb == CREAM or rgb == SET_FILL


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


def inside_rrect(px, py, x, y, cw, ch, r):
    """True if (px, py) is inside the rounded card, not the AABB cutout."""
    if px < x or py < y or px >= x + cw or py >= y + ch:
        return False
    # AABB perimeter next to wallpaper is the straight edge, not a tooth.
    if px == x or py == y or px == x + cw - 1 or py == y + ch - 1:
        return False
    if r <= 0:
        return True
    ix0 = x + r
    iy0 = y + r
    ix1 = x + cw - r
    iy1 = y + ch - r
    if ix0 <= px < ix1:
        return True
    if iy0 <= py < iy1:
        return True
    cx = ix0 if px < ix0 else ix1 - 1
    cy = iy0 if py < iy0 else iy1 - 1
    dx = px - cx
    dy = py - cy
    return (dx * dx + dy * dy) <= (r * r)


def corner_tooth(pix, x0, y0, x1, y1, w, h, rect=None, radius=18):
    """Wallpaper 4-adjacent to opaque fill *inside* the card is a tooth.

    Wallpaper just outside the AABB next to an opaque side is the
    straight edge, not a corner stair. Wallpaper in the AABB but
    outside the rrect (the rounded cutout) is also not a tooth.
    """
    teeth = 0
    samples = 0
    rx0 = ry0 = rx1 = ry1 = None
    if rect is not None:
        rx0, ry0, rw, rh = rect
        rx1 = rx0 + rw
        ry1 = ry0 + rh
    for y in range(max(1, y0), min(h - 1, y1)):
        for x in range(max(1, x0), min(w - 1, x1)):
            c = pix[x, y]
            samples += 1
            if not is_wallpaper(c):
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                n = pix[nx, ny]
                if not (is_opaque_fill(n) or near_white(n)):
                    continue
                if rx0 is not None:
                    inside_w = rx0 <= x < rx1 and ry0 <= y < ry1
                    inside_f = rx0 <= nx < rx1 and ry0 <= ny < ry1
                    if not (inside_w and inside_f):
                        continue
                    rw = rx1 - rx0
                    rh = ry1 - ry0
                    if not (inside_rrect(x, y, rx0, ry0, rw, rh, radius)
                            and inside_rrect(nx, ny, rx0, ry0, rw, rh, radius)):
                        continue
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
        t, s = corner_tooth(pix, cx - 1, cy - 1, cx + r + 2, cy + r + 2, w, h,
                            rect=(x, y, cw, ch), radius=r)
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


def title_seam(pix, x, y, cw, ch, r, th=32):
    """Wallpaper inside the card on title rows past the top radius is a
    short-card bottom wedge (title/body seam)."""
    if ch < th:
        th = ch
    teeth = 0
    y0 = y + r
    y1 = y + th
    # Interior of the rrect only. The AABB flanks past the top radius are
    # outside the mask (wallpaper is correct). An outside focus ring used
    # to paint those flanks and hide this; the 2px inset ring does not.
    x0 = x + r
    x1 = x + cw - r
    # A short-card seam is a wide wedge, not a 4px caption/icon chip
    # whose teal happens to match the wallpaper field.
    run_min = 16
    for yy in range(max(0, y0), min(y + ch, y1)):
        run = 0
        for xx in range(max(0, x0), min(x + cw, x1)):
            if is_wallpaper(pix[xx, yy]):
                run += 1
                if run >= run_min:
                    teeth += 1
            else:
                run = 0
    return teeth


def inspect_png(path, files_xywh=None, set_xywh=None, r=18):
    w, h, pix = load_rgb(path)
    if files_xywh is None:
        files_xywh = (48, 40, 400, 280)
    if set_xywh is None:
        # 1280 tiles SET to the right of FILES; 800×600 overlaps it.
        set_xywh = (584, 40, 320, 280) if w >= 1200 else (180, 48, 440, 280)
    recs = []
    fx, fy, fw, fh = files_xywh
    sx, sy, sw, sh = set_xywh
    recs.append(inspect_card(pix, w, h, fx, fy, fw, fh, r, "files"))
    recs.append(inspect_card(pix, w, h, sx, sy, sw, sh, r, "set"))
    for rec in recs:
        seam = title_seam(pix, rec["rect"][0], rec["rect"][1], rec["rect"][2],
                          rec["rect"][3], r)
        rec["title_seam"] = seam
        rec["teeth"] += seam
        if seam > 0:
            rec["bad"] = True
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
