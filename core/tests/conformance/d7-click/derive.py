#!/usr/bin/env python3
"""core/tests/conformance/d7-click/derive.py

Host model for D7. Reads geometry out of prog.c and the bit layout /
syscall number out of the kernel, then computes:

  * the overlap of the two surfaces
  * a click inside that overlap
  * surface-relative coordinates for the TOP surface (B, attached second)
  * what the BOTTOM surface would have reported (must differ)
  * a desktop point outside both decorated rectangles
  * the relative-motion script that reaches those points from (0,0)

Never imports the kernel's functions. If the two sources disagree, one
is wrong and this file refuses to emit expectations.

Usage: derive.py <prog.c> <wm.dart> <wmevent.dart> <mouse.dart>
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
    m = re.search(r"^#define %s (\d+)UL$" % re.escape(name), text, re.M)
    if not m:
        m = re.search(r"^#define %s (\d+)$" % re.escape(name), text, re.M)
    if not m:
        raise SystemExit("derive: no #define %s in %s" % (name, path))
    return int(m.group(1), 0)


def steps_to(dx, dy, cap=120):
    """Split a screen delta into PS/2-safe relative steps (each |d| <= cap)."""
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


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: derive.py <prog.c> <wm.dart> <wmevent.dart> "
                         "<mouse.dart>")
    prog, wmd, evd, _moused = sys.argv[1:5]

    win_w = cdefine(prog, "WIN_W")
    win_h = cdefine(prog, "WIN_H")
    a_x = cdefine(prog, "A_X")
    a_y = cdefine(prog, "A_Y")
    b_x = cdefine(prog, "B_X")
    b_y = cdefine(prog, "B_Y")
    sysno = cdefine(prog, "SYS_WMEVENT")

    border = dartconst(wmd, "wmBorder")
    ksys = dartconst(evd, "wmeventSysNo")
    ktype = dartconst(evd, "wmeventTypePress")
    kslots = dartconst(evd, "wmeventSlots")
    kdepth = dartconst(evd, "wmeventDepth")
    kstore = dartconst(evd, "wmeventStoreBytes")
    wmax = dartconst(wmd, "wmMaxWindows")

    if sysno != ksys:
        raise SystemExit("derive: prog.c SYS_WMEVENT is %d, kernel is %d"
                         % (sysno, ksys))
    if kslots != wmax:
        raise SystemExit("derive: wmeventSlots is %d, wmMaxWindows is %d"
                         % (kslots, wmax))
    if kstore != kslots * (4 + kdepth) * 8:
        raise SystemExit("derive: wmeventStoreBytes %d does not tile "
                         "%d slots of (4+%d) words" % (kstore, kslots, kdepth))

    ox0 = max(a_x, b_x)
    oy0 = max(a_y, b_y)
    ox1 = min(a_x + win_w, b_x + win_w)
    oy1 = min(a_y + win_h, b_y + win_h)
    if ox1 <= ox0 or oy1 <= oy0:
        raise SystemExit("derive: the two surfaces do not overlap — D7 "
                         "would be vacuous")
    overlap_w = ox1 - ox0
    overlap_h = oy1 - oy0

    click_x = ox0 + overlap_w // 2
    click_y = oy0 + overlap_h // 2
    if not (a_x <= click_x < a_x + win_w and a_y <= click_y < a_y + win_h):
        raise SystemExit("derive: click is not inside surface A")
    if not (b_x <= click_x < b_x + win_w and b_y <= click_y < b_y + win_h):
        raise SystemExit("derive: click is not inside surface B")

    top_rx = click_x - b_x
    top_ry = click_y - b_y
    bot_rx = click_x - a_x
    bot_ry = click_y - a_y
    if (top_rx, top_ry) == (bot_rx, bot_ry):
        raise SystemExit("derive: both surfaces would report the same "
                         "relative point — the wrong-owner assertion "
                         "would be vacuous")

    desk_x, desk_y = 10, 10
    a_x0, a_y0 = a_x - border, a_y - border
    a_x1, a_y1 = a_x + win_w + border, a_y + win_h + border
    b_x0, b_y0 = b_x - border, b_y - border
    b_x1, b_y1 = b_x + win_w + border, b_y + win_h + border
    if a_x0 <= desk_x < a_x1 and a_y0 <= desk_y < a_y1:
        raise SystemExit("derive: desktop click hits A's decorated rect")
    if b_x0 <= desk_x < b_x1 and b_y0 <= desk_y < b_y1:
        raise SystemExit("derive: desktop click hits B's decorated rect")

    to_click = steps_to(click_x, click_y)
    to_desk = steps_to(desk_x - click_x, desk_y - click_y)

    def rels(steps):
        return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)

    print("syscall=%d" % sysno)
    print("type_press=%d" % ktype)
    print("win_w=%d" % win_w)
    print("win_h=%d" % win_h)
    print("a_x=%d" % a_x)
    print("a_y=%d" % a_y)
    print("b_x=%d" % b_x)
    print("b_y=%d" % b_y)
    print("border=%d" % border)
    print("overlap_w=%d" % overlap_w)
    print("overlap_h=%d" % overlap_h)
    print("overlap_area=%d" % (overlap_w * overlap_h))
    print("click_x=%d" % click_x)
    print("click_y=%d" % click_y)
    print("top_rx=%d" % top_rx)
    print("top_ry=%d" % top_ry)
    print("bot_rx=%d" % bot_rx)
    print("bot_ry=%d" % bot_ry)
    print("desk_x=%d" % desk_x)
    print("desk_y=%d" % desk_y)
    print("rels_to_click=%s" % rels(to_click))
    print("rels_to_desk=%s" % rels(to_desk))
    print("store_bytes=%d" % kstore)
    print("depth=%d" % kdepth)


if __name__ == "__main__":
    main()
