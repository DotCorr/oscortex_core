#!/usr/bin/env python3
"""core/tests/conformance/de-resize/derive.py

Host model for DE SE-corner resize. Reads geometry and colours out of
the kernel and WIN.ELF. Computes an SE grab (not title, not body), a
derived shrink, the vacated and landed probes, a title-drag that must
MOVE not resize, and a body-drag that does neither.

Never imports the kernel's functions.

Usage: derive.py <wmde.dart> <wmchrome.dart> <wm.dart> <fb.dart> <shm.dart> <win.c>
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


def under_cursor(px, py, cx, cy, cols=12, rows=16):
    return cx <= px < cx + cols and cy <= py < cy + rows


def main():
    if len(sys.argv) != 7:
        raise SystemExit("usage: derive.py <wmde.dart> <wmchrome.dart> "
                         "<wm.dart> <fb.dart> <shm.dart> <win.c>")
    ded, chd, wmd, fbd, shmd, winc = sys.argv[1:7]

    level = dartconst(ded, "wmDeLevel")
    edge = dartconst(ded, "wmResizeEdge")
    min_w = dartconst(ded, "wmResizeMinW")
    min_h = dartconst(ded, "wmResizeMinH")
    btn_s = dartconst(ded, "wmBtnS")
    btn_gap = dartconst(ded, "wmBtnGap")

    title_h = dartconst(chd, "wmTitleH")
    title_color = dartconst(chd, "wmTitleColor")

    desk = dartconst(wmd, "wmColorDesktop")
    store = dartconst(wmd, "wmStoreBytes")
    border = dartconst(wmd, "wmBorder")
    wm_max = dartconst(wmd, "wmMaxWindows")

    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")

    shm_max = dartconst(shmd, "shmMax")

    win_w = cdefine(winc, "WIN_W")
    win_h = cdefine(winc, "WIN_H")
    a_x = cdefine(winc, "A_X")
    a_y = cdefine(winc, "A_Y")
    a_fill = cdefine(winc, "A_FILL")
    a_ink = cdefine(winc, "A_INK")
    ink_inset = cdefine(winc, "INK_INSET")

    if store < 448:
        raise SystemExit("derive: wmStoreBytes is %d, expected >= 448" % store)
    if shm_max < 4:
        raise SystemExit("derive: shmMax is %d, need >= 4" % shm_max)
    if wm_max != shm_max:
        raise SystemExit("derive: wmMaxWindows %d != shmMax %d" % (wm_max, shm_max))
    if level != 2:
        raise SystemExit("derive: wmDeLevel is %d, expected 2" % level)
    if a_fill == desk or title_color == desk:
        raise SystemExit("derive: title or fill equals the desktop")
    if a_ink == a_fill or a_ink == desk:
        raise SystemExit("derive: ink is not distinct from fill or desktop")
    if edge < 4:
        raise SystemExit("derive: wmResizeEdge is %d, too small to grab" % edge)

    se_x = a_x + win_w - edge // 2
    se_y = a_y + win_h - edge // 2
    if not (a_x + win_w - edge <= se_x < a_x + win_w + border):
        raise SystemExit("derive: SE grab is off the handle in x")
    if not (a_y + win_h - edge <= se_y < a_y + win_h + border):
        raise SystemExit("derive: SE grab is off the handle in y")
    if se_y < a_y + title_h:
        raise SystemExit("derive: SE grab sits on the title")

    close_x = a_x + win_w - btn_gap - btn_s
    if se_y < a_y + title_h and se_x >= close_x:
        raise SystemExit("derive: SE grab sits on close/min")

    shrink_dx = -40
    shrink_dy = -40
    new_w = win_w + shrink_dx
    new_h = win_h + shrink_dy
    if new_w < min_w or new_h < min_h:
        raise SystemExit("derive: shrink hits the min clamp")
    if new_w == win_w and new_h == win_h:
        raise SystemExit("derive: shrink is zero")
    if a_x + new_w + border > fb_w or a_y + new_h + border > fb_h:
        raise SystemExit("derive: new size would clamp on the screen")

    title_px = a_x + 40
    title_py = a_y + title_h // 2
    min_x = close_x - btn_gap - btn_s
    if not (a_x <= title_px < min_x and a_y <= title_py < a_y + title_h):
        raise SystemExit("derive: title grab is on a button or off the caption")

    move_dx = 80
    move_dy = 40
    moved_x = a_x + move_dx
    moved_y = a_y + move_dy
    if moved_x + win_w + border > fb_w or moved_y + win_h + border > fb_h:
        raise SystemExit("derive: title-drag would clamp")

    body_x = a_x + 10
    body_y = a_y + title_h + 10
    if not (a_x <= body_x < a_x + win_w and a_y + title_h <= body_y < a_y + win_h):
        raise SystemExit("derive: body click is not in the client fill")
    if a_x + win_w - edge <= body_x < a_x + win_w + border:
        if a_y + win_h - edge <= body_y < a_y + win_h + border:
            raise SystemExit("derive: body click is on the SE handle")

    # After resize the cursor sits on the new SE. Probe pixels that
    # are not under the 12x16 cursor.
    cur_x = se_x + shrink_dx
    cur_y = se_y + shrink_dy
    still_title_x = a_x + 20
    still_title_y = a_y + 4
    still_fill_x = a_x + 10
    still_fill_y = a_y + title_h + 10
    vacated_x = a_x + win_w - 10
    vacated_y = a_y + win_h - 10
    new_se_x = a_x + new_w - 30
    new_se_y = a_y + new_h - 30
    for name, px, py in (
        ("still_title", still_title_x, still_title_y),
        ("still_fill", still_fill_x, still_fill_y),
        ("vacated", vacated_x, vacated_y),
        ("new_se", new_se_x, new_se_y),
    ):
        if under_cursor(px, py, cur_x, cur_y):
            raise SystemExit("derive: %s probe is under the resize cursor" % name)
    if not (a_x <= still_title_x < a_x + new_w
            and a_y <= still_title_y < a_y + title_h):
        raise SystemExit("derive: still-title probe is off the caption")
    if not (a_x <= still_fill_x < a_x + new_w
            and a_y + title_h <= still_fill_y < a_y + new_h):
        raise SystemExit("derive: still-fill probe is off the new body")
    if a_x <= vacated_x < a_x + new_w and a_y <= vacated_y < a_y + new_h:
        raise SystemExit("derive: vacated probe is still inside the new geom")
    if not (a_x <= new_se_x < a_x + new_w
            and a_y + title_h <= new_se_y < a_y + new_h):
        raise SystemExit("derive: new SE fill probe is off the new body")
    # Shrinking clips the original fill margin; the new SE sits in
    # the client's ink block. That is still client pixels.
    se_sx = new_se_x - a_x
    se_sy = new_se_y - a_y
    if not (ink_inset <= se_sx < win_w - ink_inset
            and ink_inset <= se_sy < win_h - ink_inset):
        raise SystemExit("derive: new SE probe is not in the ink block")

    moved_title_x = moved_x + 20
    moved_title_y = moved_y + 4
    moved_fill_x = moved_x + 10
    moved_fill_y = moved_y + title_h + 10
    moved_se_x = moved_x + win_w - 20
    moved_se_y = moved_y + win_h - 20
    tcur_x = title_px + move_dx
    tcur_y = title_py + move_dy
    for name, px, py in (
        ("moved_title", moved_title_x, moved_title_y),
        ("moved_fill", moved_fill_x, moved_fill_y),
        ("moved_se", moved_se_x, moved_se_y),
    ):
        if under_cursor(px, py, tcur_x, tcur_y):
            raise SystemExit("derive: %s probe is under the title cursor" % name)
    if not (moved_x <= moved_se_x < moved_x + win_w
            and moved_y + title_h <= moved_se_y < moved_y + win_h):
        raise SystemExit("derive: moved SE probe is off the unresized body")

    origin = (0, 0)
    rels_se_drag = drag_script(origin, (se_x, se_y), shrink_dx, shrink_dy)
    rels_title_drag = drag_script(origin, (title_px, title_py), move_dx, move_dy)
    rels_body_drag = drag_script(origin, (body_x, body_y), shrink_dx, shrink_dy)

    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("desk=%06X" % (desk & 0xFFFFFF))
    print("title=%06X" % (title_color & 0xFFFFFF))
    print("win_fill=%06X" % (a_fill & 0xFFFFFF))
    print("win_ink=%06X" % (a_ink & 0xFFFFFF))
    print("shm_max=%d" % shm_max)
    print("wm_max=%d" % wm_max)
    print("store=%d" % store)
    print("a_x=%d" % a_x)
    print("a_y=%d" % a_y)
    print("win_w=%d" % win_w)
    print("win_h=%d" % win_h)
    print("new_w=%d" % new_w)
    print("new_h=%d" % new_h)
    print("moved_x=%d" % moved_x)
    print("moved_y=%d" % moved_y)
    print("se_x=%d" % se_x)
    print("se_y=%d" % se_y)
    print("title_x=%d" % title_px)
    print("title_y=%d" % title_py)
    print("body_x=%d" % body_x)
    print("body_y=%d" % body_y)
    print("still_title_x=%d" % still_title_x)
    print("still_title_y=%d" % still_title_y)
    print("still_fill_x=%d" % still_fill_x)
    print("still_fill_y=%d" % still_fill_y)
    print("vacated_x=%d" % vacated_x)
    print("vacated_y=%d" % vacated_y)
    print("new_se_x=%d" % new_se_x)
    print("new_se_y=%d" % new_se_y)
    print("moved_title_x=%d" % moved_title_x)
    print("moved_title_y=%d" % moved_title_y)
    print("moved_fill_x=%d" % moved_fill_x)
    print("moved_fill_y=%d" % moved_fill_y)
    print("moved_se_x=%d" % moved_se_x)
    print("moved_se_y=%d" % moved_se_y)
    print("new_w_hex=%04X" % new_w)
    print("new_h_hex=%04X" % new_h)
    print("old_w_hex=%04X" % win_w)
    print("old_h_hex=%04X" % win_h)
    print("moved_x_hex=%04X" % moved_x)
    print("moved_y_hex=%04X" % moved_y)
    print("from_x_hex=%04X" % a_x)
    print("from_y_hex=%04X" % a_y)
    print("rels_se_drag=%s" % rels_se_drag)
    print("rels_title_drag=%s" % rels_title_drag)
    print("rels_body_drag=%s" % rels_body_drag)
    return 0


if __name__ == "__main__":
    sys.exit(main())
