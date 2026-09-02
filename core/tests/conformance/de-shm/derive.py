#!/usr/bin/env python3
"""core/tests/conformance/de-shm/derive.py

Host model for three concurrent surfaces spawned from Start.
Reads geometry and fills from a.c / b.c / c.c, caps from the kernel,
and Start / launch-row clicks from wmde + chrome + fb.

    derive.py <shm.dart> <wm.dart> <wmevent.dart> <wmde.dart> \
              <wmchrome.dart> <fb.dart> <a.c> <b.c> <c.c>
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


def steps_to(dx, dy, cap=120):
    out = []
    x, y = dx, dy
    while x != 0 or y != 0:
        sx = max(-cap, min(cap, x))
        sy = max(-cap, min(cap, y))
        if sx == 0 and sy == 0:
            raise SystemExit("derive: cannot step (%d,%d)" % (dx, dy))
        out.append((sx, sy))
        x -= sx
        y -= sy
    return out


def fmt_rels(steps):
    return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)


def click_script(from_xy, to_xy):
    dx = to_xy[0] - from_xy[0]
    dy = to_xy[1] - from_xy[1]
    rels = fmt_rels(steps_to(dx, dy)) if (dx or dy) else ""
    parts = [rels] if rels else []
    parts.append("btn:left:down,wait:80,btn:left:up")
    return ",".join(parts), to_xy


def load_surf(path, tag):
    w = cdefine(path, "SURF_W")
    h = cdefine(path, "SURF_H")
    x = cdefine(path, "SURF_X")
    y = cdefine(path, "SURF_Y")
    fill = cdefine(path, "SURF_FILL")
    pages = cdefine(path, "SURF_PAGES")
    need = (w * h * 4 + 4095) // 4096
    if pages != need:
        raise SystemExit("derive: %s asks for %d pages but %dx%d needs %d"
                         % (tag, pages, w, h, need))
    if w < 1 or h < 1:
        raise SystemExit("derive: %s area is zero" % tag)
    return {
        "w": w, "h": h, "x": x, "y": y, "fill": fill, "pages": pages,
        "px": x + (w // 2), "py": y + (h // 2),
    }


def main():
    if len(sys.argv) != 10:
        raise SystemExit(
            "usage: derive.py <shm.dart> <wm.dart> <wmevent.dart> "
            "<wmde.dart> <wmchrome.dart> <fb.dart> <a.c> <b.c> <c.c>")
    shm, wm, ev, ded, chd, fbd, ac, bc, cc = sys.argv[1:]
    shm_max = dartconst(shm, "shmMax")
    wm_max = dartconst(wm, "wmMaxWindows")
    ev_slots = dartconst(ev, "wmeventSlots")
    if shm_max < 4:
        raise SystemExit("derive: shmMax is %d, need >= 4" % shm_max)
    if wm_max != shm_max:
        raise SystemExit("derive: wmMaxWindows %d != shmMax %d" % (wm_max, shm_max))
    if ev_slots != wm_max:
        raise SystemExit("derive: wmeventSlots %d != wmMaxWindows %d"
                         % (ev_slots, wm_max))

    a = load_surf(ac, "A")
    b = load_surf(bc, "B")
    c = load_surf(cc, "C")
    fills = {"A": a["fill"], "B": b["fill"], "C": c["fill"]}
    seen = {}
    for name, fill in fills.items():
        key = fill & 0xFFFFFF
        if key in seen:
            raise SystemExit("derive: %s fill equals %s (0x%06X)"
                             % (name, seen[key], key))
        seen[key] = name

    boxes = (("A", a), ("B", b), ("C", c))
    for i, (n1, s1) in enumerate(boxes):
        for n2, s2 in boxes[i + 1:]:
            ax0, ay0 = s1["x"], s1["y"]
            ax1, ay1 = ax0 + s1["w"], ay0 + s1["h"]
            bx0, by0 = s2["x"], s2["y"]
            bx1, by1 = bx0 + s2["w"], by0 + s2["h"]
            if ax0 < bx1 and ax1 > bx0 and ay0 < by1 and ay1 > by0:
                raise SystemExit("derive: %s overlaps %s" % (n1, n2))

    start_w = dartconst(ded, "wmStartW")
    launch_w = dartconst(ded, "wmLaunchW")
    launch_h = dartconst(ded, "wmLaunchH")
    launch_row_h = dartconst(ded, "wmLaunchRowH")
    launch_max = dartconst(ded, "wmDeLaunchMax")
    chrome_h = dartconst(chd, "wmChromeH")
    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")
    if launch_max < 3:
        raise SystemExit("derive: wmDeLaunchMax is %d, need >= 3" % launch_max)

    start_x = start_w // 2
    start_y = fb_h - chrome_h // 2
    launch_y0 = fb_h - chrome_h - launch_h
    launch_row_x = launch_w // 2

    def row_y(i):
        return launch_y0 + 4 + i * launch_row_h + launch_row_h // 2

    for i in range(3):
        if row_y(i) >= fb_h - chrome_h:
            raise SystemExit("derive: launch row %d sits on the taskbar" % i)

    # Surfaces must not cover Start or the launch rows — a click that
    # hits a client instead of chrome would not spawn.
    for tag, s in (("A", a), ("B", b), ("C", c)):
        if (s["x"] <= start_x < s["x"] + s["w"]
                and s["y"] <= start_y < s["y"] + s["h"]):
            raise SystemExit("derive: %s covers the start hit" % tag)
        for i in range(3):
            rx, ry = launch_row_x, row_y(i)
            if (s["x"] <= rx < s["x"] + s["w"]
                    and s["y"] <= ry < s["y"] + s["h"]):
                raise SystemExit("derive: %s covers launch row %d" % (tag, i))

    origin = (0, 0)
    rels_start0, p = click_script(origin, (start_x, start_y))
    rels_row0, p = click_script(p, (launch_row_x, row_y(0)))
    rels_start1, p = click_script(p, (start_x, start_y))
    rels_row1, p = click_script(p, (launch_row_x, row_y(1)))
    rels_start2, p = click_script(p, (start_x, start_y))
    rels_row2, p = click_script(p, (launch_row_x, row_y(2)))

    print("shm_max=%d" % shm_max)
    print("wm_max=%d" % wm_max)
    print("ev_slots=%d" % ev_slots)
    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("start_x=%d" % start_x)
    print("start_y=%d" % start_y)
    for tag, s in (("a", a), ("b", b), ("c", c)):
        print("%s_x=%d" % (tag, s["x"]))
        print("%s_y=%d" % (tag, s["y"]))
        print("%s_w=%d" % (tag, s["w"]))
        print("%s_h=%d" % (tag, s["h"]))
        print("%s_fill=0x%08X" % (tag, s["fill"]))
        print("%s_px=%d" % (tag, s["px"]))
        print("%s_py=%d" % (tag, s["py"]))
    print("rels_start0=%s" % rels_start0)
    print("rels_row0=%s" % rels_row0)
    print("rels_start1=%s" % rels_start1)
    print("rels_row1=%s" % rels_row1)
    print("rels_start2=%s" % rels_start2)
    print("rels_row2=%s" % rels_row2)


if __name__ == "__main__":
    main()
