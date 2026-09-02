#!/usr/bin/env python3
"""core/tests/conformance/de-osxui/derive.py

Host model for live Start through osxui_button. Reads geometry and
colours out of the kernel and osxui.h. Refuses if the two sources
disagree. Also reads one PPM pixel so the host stub path has no
second colour table.

Usage:
  derive.py geometry <wmde.dart> <wmchrome.dart> <wm.dart> <osxui.h>
  derive.py ppm <path> <x> <y>
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


def cenum(path, name):
    text = open(path).read()
    m = re.search(r"\b%s = (0x[0-9A-Fa-f]+|\d+)\b" % re.escape(name), text)
    if not m:
        raise SystemExit("derive: no %s in %s" % (name, path))
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
    return ",".join(parts)


def ppm_pixel(path, x, y):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        raise SystemExit("derive: not a P6 PPM")
    i = 3
    if data[i:i + 1] == b"\n":
        i += 1
    while data[i:i + 1] == b"#":
        nl = data.find(b"\n", i)
        if nl < 0:
            raise SystemExit("derive: truncated PPM comment")
        i = nl + 1
    m = re.match(br"(\d+)\s+(\d+)\s+255\n", data[i:])
    if not m:
        raise SystemExit("derive: bad PPM header")
    w, h = int(m.group(1)), int(m.group(2))
    i += m.end()
    if x < 0 or y < 0 or x >= w or y >= h:
        raise SystemExit("derive: (%d,%d) outside %dx%d" % (x, y, w, h))
    off = i + (y * w + x) * 3
    r, g, b = data[off], data[off + 1], data[off + 2]
    return (r << 16) | (g << 8) | b


def geometry(argv):
    if len(argv) != 5:
        raise SystemExit("usage: derive.py geometry <wmde> <wmchrome> "
                         "<wm> <osxui.h>")
    ded, chd, wmd, ui = argv[1:5]
    start_w = dartconst(ded, "wmStartW")
    start_c = dartconst(ded, "wmStartColor")
    start_r = dartconst(ded, "wmStartR")
    chrome_h = dartconst(chd, "wmChromeH")
    chrome_c = dartconst(chd, "wmChromeColor")
    desk = dartconst(wmd, "wmColorDesktop")
    ui_w = cenum(ui, "OSXUI_START_W")
    ui_h = cenum(ui, "OSXUI_START_H")
    ui_r = cenum(ui, "OSXUI_START_R")
    ui_c = cenum(ui, "OSXUI_START")
    gfx_h = cenum(ui.replace("osxui/osxui.h", "osgfx/osgfx.h"), "OSGFX_H")
    gfx_chrome = cenum(ui.replace("osxui/osxui.h", "osgfx/osgfx.h"),
                       "OSGFX_CHROME_H")
    gfx_chrome_c = cenum(ui.replace("osxui/osxui.h", "osgfx/osgfx.h"),
                         "OSGFX_CHROME")
    if start_w != ui_w:
        raise SystemExit("derive: Start W %d != osxui %d" % (start_w, ui_w))
    # The pill is not the bar. This used to demand wmChromeH == OSXUI_START_H,
    # which was only ever true because both happened to be 36; ADR-0187 raised
    # the taskbar to 48 and left the Start pill at 36, which is a pill inset in
    # a taller bar, not a disagreement. What has to hold is that the two C
    # copies of the pill height agree with each other and that the pill fits
    # the bar -- both checked, so a pill that outgrows its bar or a session
    # module that drifts from osxui.h is still caught, which the old equality
    # could not distinguish from a legal redesign.
    sess_h = cenum(ui.replace("osxui/osxui.h", "osgfx/osgfx_session.c"),
                   "SESS_START_H")
    if ui_h != sess_h:
        raise SystemExit("derive: Start H is %d in osxui.h and %d in "
                         "osgfx_session.c" % (ui_h, sess_h))
    if ui_h > chrome_h:
        raise SystemExit("derive: Start pill is %d tall in a %d-tall chrome "
                         "bar — it does not fit" % (ui_h, chrome_h))
    if start_r != ui_r:
        raise SystemExit("derive: Start R %d != osxui %d" % (start_r, ui_r))
    if (start_c & 0xFFFFFF) != (ui_c & 0xFFFFFF):
        raise SystemExit("derive: Start colour moved")
    if chrome_h != gfx_chrome:
        raise SystemExit("derive: chrome H != OSGFX_CHROME_H")
    if (chrome_c & 0xFFFFFF) != (gfx_chrome_c & 0xFFFFFF):
        raise SystemExit("derive: chrome colour != OSGFX_CHROME")
    if start_r < 1:
        raise SystemExit("derive: Start radius is zero — square blit")
    if start_c == chrome_c or start_c == desk:
        raise SystemExit("derive: Start colour collapsed")
    fb_h = gfx_h
    aabb_x = 0
    aabb_y = fb_h - chrome_h
    mid_x = start_w // 2
    mid_y = fb_h - chrome_h // 2
    strip_x = start_w + 8
    strip_y = mid_y
    # wmDeChromeDraw labels the pill after painting it, so mid_x is label ink,
    # not fill. Keep mid_x as the CLICK target and probe the fill to the right
    # of the label's widest possible ink box (8 px per stem bounds both the CPU
    # font and ADR-0187's proportional face); the label gets its own probe.
    label_fg = dartconst(ded, "wmLabelFg")
    label_x0 = dartconst(ded, "wmStartPadX")
    label_x1 = label_x0 + dartconst(ded, "wmStartStemN") * 8
    label_y0 = fb_h - chrome_h + dartconst(ded, "wmStartPadY")
    label_y1 = label_y0 + 16
    fill_x = (label_x1 + start_w) // 2
    if not (label_x1 < fill_x < start_w):
        raise SystemExit("derive: the Start label leaves no fill to probe")
    if (label_fg & 0xFFFFFF) == (start_c & 0xFFFFFF):
        raise SystemExit("derive: the Start label is the same colour as its fill")
    if label_y1 > fb_h:
        raise SystemExit("derive: the Start label box runs off the screen")
    print("fb_h=%d" % fb_h)
    print("start_w=%d" % start_w)
    print("start_h=%d" % chrome_h)
    print("start_r=%d" % start_r)
    print("start_color=%06X" % (start_c & 0xFFFFFF))
    print("chrome=%06X" % (chrome_c & 0xFFFFFF))
    print("desk=%06X" % (desk & 0xFFFFFF))
    print("aabb_x=%d" % aabb_x)
    print("aabb_y=%d" % aabb_y)
    print("mid_x=%d" % mid_x)
    print("mid_y=%d" % mid_y)
    print("strip_x=%d" % strip_x)
    print("strip_y=%d" % strip_y)
    print("fill_x=%d" % fill_x)
    print("label_fg=%06X" % (label_fg & 0xFFFFFF))
    print("label_x0=%d" % label_x0)
    print("label_x1=%d" % label_x1)
    print("label_y0=%d" % label_y0)
    print("label_y1=%d" % label_y1)
    print("rels_start=%s" % click_script((0, 0), (mid_x, mid_y)))
    return 0


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: derive.py geometry|ppm ...")
    if sys.argv[1] == "geometry":
        return geometry(sys.argv[1:])
    if sys.argv[1] == "ppm":
        if len(sys.argv) != 5:
            raise SystemExit("usage: derive.py ppm <path> <x> <y>")
        print("%06X" % ppm_pixel(sys.argv[2], int(sys.argv[3]),
                                 int(sys.argv[4])))
        return 0
    raise SystemExit("usage: derive.py geometry|ppm ...")


if __name__ == "__main__":
    sys.exit(main())
