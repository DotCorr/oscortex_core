#!/usr/bin/env python3
"""core/tests/conformance/de-wm/derive.py

Host model for DE title-drag. Reads geometry and colours out of the
kernel and WIN.ELF. Computes a title-grab point (not close/min), a
derived move, the vacated and landed probes, a body-drag anti-vacuity
script, and the panel/close clicks.

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


def click_script(from_xy, to_xy):
    dx = to_xy[0] - from_xy[0]
    dy = to_xy[1] - from_xy[1]
    rels = fmt_rels(steps_to(dx, dy)) if (dx or dy) else ""
    parts = [rels] if rels else []
    parts.append("btn:left:down,wait:80,btn:left:up")
    return ",".join(parts), to_xy


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


def main():
    if len(sys.argv) != 7:
        raise SystemExit("usage: derive.py <wmde.dart> <wmchrome.dart> "
                         "<wm.dart> <fb.dart> <shm.dart> <win.c>")
    ded, chd, wmd, fbd, shmd, winc = sys.argv[1:7]

    level = dartconst(ded, "wmDeLevel")
    btn_s = dartconst(ded, "wmBtnS")
    btn_gap = dartconst(ded, "wmBtnGap")
    close_color = dartconst(ded, "wmCloseColor")
    note_w = dartconst(ded, "wmNoteW")
    note_color = dartconst(ded, "wmNoteColor")
    panel_row0 = dartconst(ded, "wmPanelRow0")
    panel_w = dartconst(ded, "wmPanelW")
    panel_h = dartconst(ded, "wmPanelH")
    launch_row_h = dartconst(ded, "wmLaunchRowH")

    chrome_h = dartconst(chd, "wmChromeH")
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
    if close_color == title_color:
        raise SystemExit("derive: close colour equals the title")

    # Title grab: left of the caption, not on close/min.
    title_px = a_x + 40
    title_py = a_y + title_h // 2
    close_x = a_x + win_w - btn_gap - btn_s
    min_x = close_x - btn_gap - btn_s
    close_px = close_x + btn_s // 2
    close_py = a_y + btn_gap + btn_s // 2
    if not (a_x <= title_px < min_x and a_y <= title_py < a_y + title_h):
        raise SystemExit("derive: title grab is on a button or off the caption")

    move_dx = 80
    move_dy = 40
    new_x = a_x + move_dx
    new_y = a_y + move_dy
    if new_x < border or new_y < border:
        raise SystemExit("derive: moved origin is inside the border clamp")
    if new_x + win_w + border > fb_w or new_y + win_h + border > fb_h:
        raise SystemExit("derive: moved window would clamp")

    body_x = a_x + 10
    body_y = a_y + title_h + 10
    if not (a_x <= body_x < a_x + win_w and a_y + title_h <= body_y < a_y + win_h):
        raise SystemExit("derive: body click is not in the client fill")

    # After the drag the cursor sits on the title. Probe a title pixel
    # that is not under the 12x16 cursor, and a fill pixel that moved.
    new_title_x = new_x + 20
    new_title_y = new_y + 4
    new_fill_x = new_x + 10
    new_fill_y = new_y + title_h + 10
    cur_x = title_px + move_dx
    cur_y = title_py + move_dy
    if (new_title_x >= cur_x and new_title_x < cur_x + 12
            and new_title_y >= cur_y and new_title_y < cur_y + 16):
        raise SystemExit("derive: new title probe is under the cursor")
    if (new_fill_x >= cur_x and new_fill_x < cur_x + 12
            and new_fill_y >= cur_y and new_fill_y < cur_y + 16):
        raise SystemExit("derive: new fill probe is under the cursor")
    if not (new_x <= new_title_x < new_x + win_w
            and new_y <= new_title_y < new_y + title_h):
        raise SystemExit("derive: new title probe is off the caption")
    if not (new_x <= new_fill_x < new_x + win_w
            and new_y + title_h <= new_fill_y < new_y + win_h):
        raise SystemExit("derive: new fill probe is off the body")

    start_y = fb_h - chrome_h // 2
    note_x = fb_w - note_w // 2
    note_y = start_y
    panel_x0 = fb_w - panel_w
    panel_y0 = fb_h - chrome_h - panel_h
    panel_row_x = panel_x0 + 10
    panel_row_y = panel_y0 + 4 + launch_row_h // 2

    origin = (0, 0)
    rels_title_drag = drag_script(origin, (title_px, title_py), move_dx, move_dy)
    rels_body_drag = drag_script(origin, (body_x, body_y), move_dx, move_dy)
    rels_note, after_note = click_script(origin, (note_x, note_y))
    rels_close_from_note, after_close = click_script(after_note, (close_px, close_py))
    rels_note_again, _ = click_script(after_close, (note_x, note_y))

    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("desk=%06X" % (desk & 0xFFFFFF))
    print("title=%06X" % (title_color & 0xFFFFFF))
    print("note_color=%06X" % (note_color & 0xFFFFFF))
    print("panel_row0=%06X" % (panel_row0 & 0xFFFFFF))
    print("win_fill=%06X" % (a_fill & 0xFFFFFF))
    print("shm_max=%d" % shm_max)
    print("wm_max=%d" % wm_max)
    print("store=%d" % store)
    print("a_x=%d" % a_x)
    print("a_y=%d" % a_y)
    print("new_x=%d" % new_x)
    print("new_y=%d" % new_y)
    print("move_dx=%d" % move_dx)
    print("move_dy=%d" % move_dy)
    print("title_x=%d" % title_px)
    print("title_y=%d" % title_py)
    print("body_x=%d" % body_x)
    print("body_y=%d" % body_y)
    print("new_title_x=%d" % new_title_x)
    print("new_title_y=%d" % new_title_y)
    print("new_fill_x=%d" % new_fill_x)
    print("new_fill_y=%d" % new_fill_y)
    print("old_fill_x=%d" % body_x)
    print("old_fill_y=%d" % body_y)
    print("note_x=%d" % note_x)
    print("note_y=%d" % note_y)
    print("panel_row_x=%d" % panel_row_x)
    print("panel_row_y=%d" % panel_row_y)
    print("move_x_hex=%04X" % new_x)
    print("move_y_hex=%04X" % new_y)
    print("from_x_hex=%04X" % a_x)
    print("from_y_hex=%04X" % a_y)
    print("rels_title_drag=%s" % rels_title_drag)
    print("rels_body_drag=%s" % rels_body_drag)
    print("rels_note=%s" % rels_note)
    print("rels_close_from_note=%s" % rels_close_from_note)
    print("rels_note_again=%s" % rels_note_again)
    return 0


if __name__ == "__main__":
    sys.exit(main())
