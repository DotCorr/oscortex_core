#!/usr/bin/env python3
"""core/tests/conformance/de-cfg/derive.py

Host model for configure / enter / leave. Reads geometry and event
types out of the kernel and WIN.ELF. Computes the attach configure
line, an SE shrink, a desktop click that must LEAVE, and a wrong
geom that must not match.

Never imports the kernel's functions.

Usage: derive.py <wmde.dart> <wmchrome.dart> <wm.dart> <wmevent.dart> <win.c>
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


def drag_script(from_xy, grab_xy, dx, dy):
    to_grab_dx = grab_xy[0] - from_xy[0]
    to_grab_dy = grab_xy[1] - from_xy[1]
    parts = []
    if to_grab_dx or to_grab_dy:
        parts.append(fmt_rels(steps_to(to_grab_dx, to_grab_dy)))
    parts.append("btn:left:down,wait:80")
    if dx or dy:
        parts.append(fmt_rels(steps_to(dx, dy)))
    parts.append("wait:80,btn:left:up")
    return ",".join(p for p in parts if p)


def click_script(from_xy, at_xy):
    dx = at_xy[0] - from_xy[0]
    dy = at_xy[1] - from_xy[1]
    parts = []
    if dx or dy:
        parts.append(fmt_rels(steps_to(dx, dy)))
    parts.append("btn:left:down,wait:80,btn:left:up")
    return ",".join(p for p in parts if p)


def main():
    if len(sys.argv) != 6:
        raise SystemExit("usage: derive.py <wmde.dart> <wmchrome.dart> "
                         "<wm.dart> <wmevent.dart> <win.c>")
    ded, chd, wmd, evd, winc = sys.argv[1:6]

    level = dartconst(ded, "wmDeLevel")
    edge = dartconst(ded, "wmResizeEdge")
    min_w = dartconst(ded, "wmResizeMinW")
    min_h = dartconst(ded, "wmResizeMinH")

    title_h = dartconst(chd, "wmTitleH")
    wm_max = dartconst(wmd, "wmMaxWindows")

    typ_press = dartconst(evd, "wmeventTypePress")
    typ_cfg = dartconst(evd, "wmeventTypeConfigure")
    typ_enter = dartconst(evd, "wmeventTypeEnter")
    typ_leave = dartconst(evd, "wmeventTypeLeave")
    sysno = dartconst(evd, "wmeventSysNo")
    store = dartconst(evd, "wmeventStoreBytes")

    win_w = cdefine(winc, "WIN_W")
    win_h = cdefine(winc, "WIN_H")
    a_x = cdefine(winc, "A_X")
    a_y = cdefine(winc, "A_Y")
    c_cfg = cdefine(winc, "WMEVENT_TYPE_CONFIGURE")
    c_enter = cdefine(winc, "WMEVENT_TYPE_ENTER")
    c_leave = cdefine(winc, "WMEVENT_TYPE_LEAVE")
    c_sys = cdefine(winc, "SYS_WMEVENT")

    if level != 2:
        raise SystemExit("derive: wmDeLevel is %d, expected 2" % level)
    if typ_press != 1 or typ_cfg != 2 or typ_enter != 3 or typ_leave != 4:
        raise SystemExit("derive: wmevent types are not 1/2/3/4")
    if c_cfg != typ_cfg or c_enter != typ_enter or c_leave != typ_leave:
        raise SystemExit("derive: win.c types disagree with the kernel")
    if c_sys != sysno or sysno != 25:
        raise SystemExit("derive: SYS_WMEVENT is not 25")
    if store != 1920:
        raise SystemExit("derive: wmeventStoreBytes is %d, expected 1920" % store)
    if edge < 4:
        raise SystemExit("derive: wmResizeEdge is %d, too small to grab" % edge)

    se_x = a_x + win_w - edge // 2
    se_y = a_y + win_h - edge // 2
    if not (a_x + win_w - edge <= se_x < a_x + win_w):
        raise SystemExit("derive: SE grab is off the handle in x")
    if not (a_y + win_h - edge <= se_y < a_y + win_h):
        raise SystemExit("derive: SE grab is off the handle in y")
    if se_y < a_y + title_h:
        raise SystemExit("derive: SE grab sits on the title")

    shrink_dx = -40
    shrink_dy = -40
    new_w = win_w + shrink_dx
    new_h = win_h + shrink_dy
    if new_w < min_w or new_h < min_h:
        raise SystemExit("derive: shrink hits the min clamp")
    if new_w == win_w and new_h == win_h:
        raise SystemExit("derive: shrink is zero")

    desk_x = 20
    desk_y = 20
    if a_x <= desk_x < a_x + win_w and a_y <= desk_y < a_y + win_h:
        raise SystemExit("derive: desktop click sits on the window")

    origin = (0, 0)
    after_se = (se_x + shrink_dx, se_y + shrink_dy)
    rels_se_drag = drag_script(origin, (se_x, se_y), shrink_dx, shrink_dy)
    rels_desk = click_script(after_se, (desk_x, desk_y))

    attach_line = "DE CFG CONFIGURE %04X %04X %04X %04X" % (
        a_x & 0xFFF, a_y & 0xFFF, win_w & 0xFFF, win_h & 0xFFF)
    resize_line = "DE CFG CONFIGURE %04X %04X %04X %04X" % (
        a_x & 0xFFF, a_y & 0xFFF, new_w & 0xFFF, new_h & 0xFFF)
    wrong_line = "DE CFG CONFIGURE %04X %04X %04X %04X" % (
        a_x & 0xFFF, a_y & 0xFFF, win_w & 0xFFF, (win_h + 1) & 0xFFF)
    if attach_line == resize_line:
        raise SystemExit("derive: attach and resize configure lines match")
    if attach_line == wrong_line or resize_line == wrong_line:
        raise SystemExit("derive: wrong-geom line is not distinct")

    print("wm_max=%d" % wm_max)
    print("store=%d" % store)
    print("sysno=%d" % sysno)
    print("type_press=%d" % typ_press)
    print("type_configure=%d" % typ_cfg)
    print("type_enter=%d" % typ_enter)
    print("type_leave=%d" % typ_leave)
    print("a_x=%d" % a_x)
    print("a_y=%d" % a_y)
    print("win_w=%d" % win_w)
    print("win_h=%d" % win_h)
    print("new_w=%d" % new_w)
    print("new_h=%d" % new_h)
    print("se_x=%d" % se_x)
    print("se_y=%d" % se_y)
    print("desk_x=%d" % desk_x)
    print("desk_y=%d" % desk_y)
    print("attach_line=%s" % attach_line)
    print("resize_line=%s" % resize_line)
    print("wrong_line=%s" % wrong_line)
    print("rels_se_drag=%s" % rels_se_drag)
    print("rels_desk=%s" % rels_desk)
    return 0


if __name__ == "__main__":
    sys.exit(main())
