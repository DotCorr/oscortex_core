#!/usr/bin/env python3
"""core/tests/conformance/de-sitfat/derive.py

Host model for sit-in FAT start. Reads launch geometry out of wmde /
wmchrome / fb. Planted 8.3 names are arguments (directory order =
launch-row order). Never imports the kernel.

    derive.py <wmde.dart> <wmchrome.dart> <fb.dart> NAME [NAME ...]
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


def eightthree_print(name):
    """Same padding fatPrintName writes: 8 stem bytes, '.', 3 ext bytes."""
    if "." in name:
        stem, ext = name.split(".", 1)
    else:
        stem, ext = name, ""
    return stem.ljust(8) + "." + ext.ljust(3)


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: derive.py <wmde.dart> <wmchrome.dart> <fb.dart> NAME [...]")
    ded, chd, fbd = sys.argv[1], sys.argv[2], sys.argv[3]
    names = [n.upper() for n in sys.argv[4:]]
    elves = [n for n in names if n.endswith(".ELF")]
    if not elves:
        raise SystemExit("derive: need at least one .ELF name")

    start_w = dartconst(ded, "wmStartW")
    start_color = dartconst(ded, "wmStartColor")
    launch_w = dartconst(ded, "wmLaunchW")
    launch_h = dartconst(ded, "wmLaunchH")
    launch_color = dartconst(ded, "wmLaunchColor")
    launch_row_h = dartconst(ded, "wmLaunchRowH")
    launch_row0 = dartconst(ded, "wmLaunchRow0")
    launch_row1 = dartconst(ded, "wmLaunchRow1")
    launch_max = dartconst(ded, "wmDeLaunchMax")
    chrome_h = dartconst(chd, "wmChromeH")
    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")

    listed = elves[:launch_max]
    if "PING.ELF" not in listed:
        raise SystemExit("derive: PING.ELF is not in the first %d ELF names"
                         % launch_max)
    ping_row = listed.index("PING.ELF")
    n = len(listed)

    start_x = start_w // 2
    start_y = fb_h - chrome_h // 2
    launch_y0 = fb_h - chrome_h - launch_h
    launch_row_x = launch_w // 2
    launch_row_y = (launch_y0 + 4 + ping_row * launch_row_h
                    + launch_row_h // 2)
    row0_x = launch_w // 2
    row0_y = launch_y0 + 4 + launch_row_h // 2
    if launch_row_y >= fb_h - chrome_h:
        raise SystemExit("derive: PING launch row sits on the taskbar")
    if n < 1:
        raise SystemExit("derive: no launch rows")

    origin = (0, 0)
    rels_start, after_start = click_script(origin, (start_x, start_y))
    rels_ping_row, _ = click_script(after_start, (launch_row_x, launch_row_y))

    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("start_x=%d" % start_x)
    print("start_y=%d" % start_y)
    print("start_color=%06X" % (start_color & 0xFFFFFF))
    print("launch_color=%06X" % (launch_color & 0xFFFFFF))
    print("launch_row0=%06X" % (launch_row0 & 0xFFFFFF))
    print("launch_row1=%06X" % (launch_row1 & 0xFFFFFF))
    print("launch_row_x=%d" % launch_row_x)
    print("launch_row_y=%d" % launch_row_y)
    print("row0_x=%d" % row0_x)
    print("row0_y=%d" % row0_y)
    print("ping_row=%d" % ping_row)
    print("launch_n=%d" % n)
    print("launch_max=%d" % launch_max)
    print("start_count=%02X" % n)
    print("rels_start=%s" % rels_start)
    print("rels_ping_row=%s" % rels_ping_row)
    print("elves=%s" % ",".join(listed))
    print("ping_open=%s" % eightthree_print("PING.ELF"))
    for i, name in enumerate(listed):
        print("elf_%d=%s" % (i, name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
