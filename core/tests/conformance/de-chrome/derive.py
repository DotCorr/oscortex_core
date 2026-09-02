#!/usr/bin/env python3
"""core/tests/conformance/de-chrome/derive.py

Host model for DE chrome. Reads geometry and colours out of the kernel
and the two test programs. Computes close / min / body / start / slot /
launch-row / notify click points and the QMP rel: scripts from (0,0).

Never imports the kernel's functions. If two sources disagree, this
file refuses to emit expectations.

Usage: derive.py <wmde.dart> <wmchrome.dart> <wm.dart> <fb.dart> <win.c> <ping.c>
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


def main():
    if len(sys.argv) != 7:
        raise SystemExit("usage: derive.py <wmde.dart> <wmchrome.dart> "
                         "<wm.dart> <fb.dart> <win.c> <ping.c>")
    ded, chd, wmd, fbd, winc, pingc = sys.argv[1:7]

    level = dartconst(ded, "wmDeLevel")
    btn_s = dartconst(ded, "wmBtnS")
    btn_gap = dartconst(ded, "wmBtnGap")
    close_color = dartconst(ded, "wmCloseColor")
    min_color = dartconst(ded, "wmMinColor")
    start_w = dartconst(ded, "wmStartW")
    start_color = dartconst(ded, "wmStartColor")
    start_pad_x = dartconst(ded, "wmStartPadX")
    start_pad_y = dartconst(ded, "wmStartPadY")
    start_stem_n = dartconst(ded, "wmStartStemN")
    label_fg = dartconst(ded, "wmLabelFg")
    note_w = dartconst(ded, "wmNoteW")
    note_color = dartconst(ded, "wmNoteColor")
    slot_w = dartconst(ded, "wmSlotW")
    slot0_color = dartconst(ded, "wmSlot0Color")
    launch_w = dartconst(ded, "wmLaunchW")
    launch_h = dartconst(ded, "wmLaunchH")
    launch_color = dartconst(ded, "wmLaunchColor")
    launch_row_h = dartconst(ded, "wmLaunchRowH")
    launch_row0 = dartconst(ded, "wmLaunchRow0")
    launch_row1 = dartconst(ded, "wmLaunchRow1")
    panel_w = dartconst(ded, "wmPanelW")
    panel_h = dartconst(ded, "wmPanelH")
    panel_color = dartconst(ded, "wmPanelColor")
    panel_row0 = dartconst(ded, "wmPanelRow0")
    pop_launch = dartconst(ded, "wmPopLaunch")
    pop_panel = dartconst(ded, "wmPopPanel")

    chrome_h = dartconst(chd, "wmChromeH")
    chrome_color = dartconst(chd, "wmChromeColor")
    title_h = dartconst(chd, "wmTitleH")
    title_color = dartconst(chd, "wmTitleColor")

    desk = dartconst(wmd, "wmColorDesktop")
    store = dartconst(wmd, "wmStoreBytes")

    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")

    win_w = cdefine(winc, "WIN_W")
    win_h = cdefine(winc, "WIN_H")
    a_x = cdefine(winc, "A_X")
    a_y = cdefine(winc, "A_Y")
    a_fill = cdefine(winc, "A_FILL")

    ping_x = cdefine(pingc, "PING_X")
    ping_y = cdefine(pingc, "PING_Y")
    ping_w = cdefine(pingc, "PING_W")
    ping_h = cdefine(pingc, "PING_H")
    ping_fill = cdefine(pingc, "PING_FILL")

    if store != 448:
        raise SystemExit("derive: wmStoreBytes is %d, expected 448" % store)
    if level != 2:
        raise SystemExit("derive: wmDeLevel is %d, expected 2" % level)
    if pop_launch != 2 or pop_panel != 3:
        raise SystemExit("derive: popover kinds moved")
    if close_color == title_color or min_color == title_color:
        raise SystemExit("derive: button colour equals the title")
    if close_color == desk or min_color == desk:
        raise SystemExit("derive: button colour equals the desktop")
    if start_color == chrome_color or note_color == chrome_color:
        raise SystemExit("derive: start/note equals the strip")
    if launch_color == desk or panel_color == desk:
        raise SystemExit("derive: popover colour equals the desktop")
    if a_fill == desk:
        raise SystemExit("derive: WIN fill equals the desktop")
    if ping_fill == a_fill or ping_fill == desk:
        raise SystemExit("derive: PING fill is not distinct")

    close_x = a_x + win_w - btn_gap - btn_s
    close_y = a_y + btn_gap
    min_x = close_x - btn_gap - btn_s
    close_px = close_x + btn_s // 2
    close_py = close_y + btn_s // 2
    min_px = min_x + btn_s // 2
    min_py = close_y + btn_s // 2
    body_x = a_x + 10
    body_y = a_y + title_h + 10
    start_mx = dartconst(ded, "wmStartMX")
    start_x = start_mx + start_w // 2
    start_y = fb_h - chrome_h // 2
    # wmDeChromeDraw paints the button and THEN labels it (wmLabelFg), so the
    # centre of the button is label ink, not fill. Probe the fill to the right
    # of the label's widest possible ink box -- 8 px per stem is the CPU font's
    # advance and an upper bound on the proportional Skia face (ADR-0187) --
    # and probe the label separately so the button still has to be labelled.
    label_x0 = start_mx + start_pad_x
    label_x1 = start_mx + start_pad_x + start_stem_n * 8
    label_y0 = fb_h - chrome_h + start_pad_y
    label_y1 = label_y0 + 16
    start_fill_x = (label_x1 + start_mx + start_w) // 2
    note_x = fb_w - note_w // 2
    note_y = start_y
    slot_gap = dartconst(ded, "wmSlotGap")
    slot0_x = start_mx + start_w + slot_gap + slot_w // 2
    slot0_y = start_y
    launch_y0 = fb_h - chrome_h - launch_h
    ping_row = 1
    launch_row_x = launch_w // 2
    launch_row_y = launch_y0 + 4 + ping_row * launch_row_h + launch_row_h // 2
    panel_x0 = fb_w - panel_w
    panel_y0 = fb_h - chrome_h - panel_h
    panel_row_x = panel_x0 + 10
    panel_row_y = panel_y0 + 4 + launch_row_h // 2

    if not (a_x <= close_px < a_x + win_w and a_y <= close_py < a_y + title_h):
        raise SystemExit("derive: close probe is outside the title")
    if not (a_x <= min_px < a_x + win_w and a_y <= min_py < a_y + title_h):
        raise SystemExit("derive: min probe is outside the title")
    if not (a_x <= body_x < a_x + win_w and a_y + title_h <= body_y < a_y + win_h):
        raise SystemExit("derive: body click is not in the client fill")
    if ping_x <= close_px < ping_x + ping_w and ping_y <= close_py < ping_y + ping_h:
        raise SystemExit("derive: PING covers WIN's close button")
    if launch_row_y >= fb_h - chrome_h:
        raise SystemExit("derive: launch row sits on the taskbar")
    if not (label_x1 < start_fill_x < start_mx + start_w):
        raise SystemExit("derive: the Start label leaves no fill to probe")
    if label_fg == start_color:
        raise SystemExit("derive: the Start label is the same colour as its fill")
    if label_y1 > fb_h:
        raise SystemExit("derive: the Start label box runs off the screen")

    origin = (0, 0)
    rels_close, _ = click_script(origin, (close_px, close_py))
    rels_min, after_min = click_script(origin, (min_px, min_py))
    rels_body, _ = click_script(origin, (body_x, body_y))
    rels_start, after_start = click_script(origin, (start_x, start_y))
    rels_ping_row, after_ping = click_script(after_start, (launch_row_x, launch_row_y))
    rels_note_from_ping, _ = click_script(after_ping, (note_x, note_y))
    rels_note, after_note = click_script(origin, (note_x, note_y))
    rels_close_from_note, after_close2 = click_script(after_note, (close_px, close_py))
    rels_note_again, _ = click_script(after_close2, (note_x, note_y))
    rels_slot_from_min, _ = click_script(after_min, (slot0_x, slot0_y))

    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    print("desk=%06X" % (desk & 0xFFFFFF))
    print("title=%06X" % (title_color & 0xFFFFFF))
    print("chrome=%06X" % (chrome_color & 0xFFFFFF))
    print("close_color=%06X" % (close_color & 0xFFFFFF))
    print("min_color=%06X" % (min_color & 0xFFFFFF))
    print("start_color=%06X" % (start_color & 0xFFFFFF))
    print("note_color=%06X" % (note_color & 0xFFFFFF))
    print("slot0_color=%06X" % (slot0_color & 0xFFFFFF))
    print("launch_color=%06X" % (launch_color & 0xFFFFFF))
    print("launch_row1=%06X" % (launch_row1 & 0xFFFFFF))
    print("panel_color=%06X" % (panel_color & 0xFFFFFF))
    print("panel_row0=%06X" % (panel_row0 & 0xFFFFFF))
    print("win_fill=%06X" % (a_fill & 0xFFFFFF))
    print("ping_fill=%06X" % (ping_fill & 0xFFFFFF))
    print("close_x=%d" % close_px)
    print("close_y=%d" % close_py)
    print("min_x=%d" % min_px)
    print("min_y=%d" % min_py)
    print("body_x=%d" % body_x)
    print("body_y=%d" % body_y)
    print("start_x=%d" % start_x)
    print("start_y=%d" % start_y)
    print("start_fill_x=%d" % start_fill_x)
    print("label_fg=%06X" % (label_fg & 0xFFFFFF))
    print("label_x0=%d" % label_x0)
    print("label_x1=%d" % label_x1)
    print("label_y0=%d" % label_y0)
    print("label_y1=%d" % label_y1)
    print("note_x=%d" % note_x)
    print("note_y=%d" % note_y)
    print("slot0_x=%d" % slot0_x)
    print("slot0_y=%d" % slot0_y)
    print("launch_row_x=%d" % launch_row_x)
    print("launch_row_y=%d" % launch_row_y)
    print("panel_row_x=%d" % panel_row_x)
    print("panel_row_y=%d" % panel_row_y)
    print("rels_close=%s" % rels_close)
    print("rels_min=%s" % rels_min)
    print("rels_body=%s" % rels_body)
    print("rels_start=%s" % rels_start)
    print("rels_ping_row=%s" % rels_ping_row)
    print("rels_note_from_ping=%s" % rels_note_from_ping)
    print("rels_note=%s" % rels_note)
    print("rels_close_from_note=%s" % rels_close_from_note)
    print("rels_note_again=%s" % rels_note_again)
    print("rels_slot_from_min=%s" % rels_slot_from_min)
    return 0


if __name__ == "__main__":
    sys.exit(main())
