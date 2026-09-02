#!/usr/bin/env python3
"""Host model for de-wall — wallpaper menu geometry + colours."""
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


def main():
    if len(sys.argv) != 5:
        raise SystemExit(
            "usage: derive.py <wmpop.dart> <wm.dart> <mouse.dart> <fb.dart>")
    popd, wmd, moused, fbd = sys.argv[1:5]

    pop_w = dartconst(popd, "wmPopW")
    pop_h = dartconst(popd, "wmPopH")
    gap = dartconst(popd, "wmPopGap")
    pop_color = dartconst(popd, "wmPopColor")
    row0 = dartconst(popd, "wmPopRow0")
    row1 = dartconst(popd, "wmPopRow1")
    row_pad = dartconst(popd, "wmPopRowPad")
    row_h = dartconst(popd, "wmPopRowH")
    lab_x = dartconst(popd, "wmPopLabelPadX")
    lab_y = dartconst(popd, "wmPopLabelPadY")
    lab_fg = dartconst(popd, "wmPopLabelFg")

    desk = dartconst(wmd, "wmColorDesktop")
    cur_w = dartconst(moused, "mouseCursorCols")
    cur_h = dartconst(moused, "mouseCursorRows")
    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")

    # Mid-desktop, clear of chrome (bottom 24) and clamp.
    click_x = 200
    click_y = 150
    if click_x + gap + pop_w > fb_w or click_y + gap + pop_h > fb_h:
        raise SystemExit("derive: click would clamp")

    pop_x = click_x + gap
    pop_y = click_y + gap

    # Row centres — clear of the 12x16 cursor at the pointer.
    row0_x = pop_x + lab_x + 16
    row0_y = pop_y + row_pad + (row_h // 2)
    row1_x = pop_x + lab_x + 16
    row1_y = pop_y + row_pad + row_h + (row_h // 2)

    # Label ink sample: first glyph cell of "Regen" / "Image".
    lab0_x = pop_x + lab_x + 2
    lab0_y = pop_y + row_pad + lab_y + 4
    lab1_x = pop_x + lab_x + 2
    lab1_y = pop_y + row_pad + row_h + lab_y + 4

    if (click_x <= row0_x < click_x + cur_w and
            click_y <= row0_y < click_y + cur_h):
        raise SystemExit("derive: row0 probe under cursor")

    # Desk sample away from popover for before/after regen.
    desk_sx = 40
    desk_sy = 40

    # Click Regen: move from right-click point to row0 centre.
    # After Regen, pointer sits on row0 — back to click for a second menu.
    rels_click = fmt_rels(steps_to(click_x, click_y))
    rels_regen = fmt_rels(steps_to(row0_x - click_x, row0_y - click_y))
    rels_image = fmt_rels(steps_to(row1_x - click_x, row1_y - click_y))
    rels_image_from_regen = fmt_rels(steps_to(row1_x - row0_x, row1_y - row0_y))
    rels_back_click = fmt_rels(steps_to(click_x - row0_x, click_y - row0_y))

    print("click_x=%d" % click_x)
    print("click_y=%d" % click_y)
    print("pop_x=%d" % pop_x)
    print("pop_y=%d" % pop_y)
    print("pop_w=%d" % pop_w)
    print("pop_h=%d" % pop_h)
    print("row0_x=%d" % row0_x)
    print("row0_y=%d" % row0_y)
    print("row1_x=%d" % row1_x)
    print("row1_y=%d" % row1_y)
    print("lab0_x=%d" % lab0_x)
    print("lab0_y=%d" % lab0_y)
    print("lab1_x=%d" % lab1_x)
    print("lab1_y=%d" % lab1_y)
    print("desk_sx=%d" % desk_sx)
    print("desk_sy=%d" % desk_sy)
    print("pop_color=%06X" % (pop_color & 0xFFFFFF))
    print("row0_color=%06X" % (row0 & 0xFFFFFF))
    print("row1_color=%06X" % (row1 & 0xFFFFFF))
    print("lab_fg=%06X" % (lab_fg & 0xFFFFFF))
    print("desk_color=%06X" % (desk & 0xFFFFFF))
    print("wall_raw=%06X" % 0x00C04020)
    print("rels_to_click=%s" % rels_click)
    print("rels_to_regen=%s" % rels_regen)
    print("rels_to_image=%s" % rels_image)
    print("rels_image_from_regen=%s" % rels_image_from_regen)
    print("rels_back_click=%s" % rels_back_click)
    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
