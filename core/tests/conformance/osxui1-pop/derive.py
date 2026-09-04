#!/usr/bin/env python3
"""core/tests/conformance/osxui1-pop/derive.py

Host model for OSXUI1. Reads geometry and colours out of the kernel and
computes:

  * a desktop point to right-click (pointer starts at 0,0)
  * the popover origin the kernel will choose (pointer + gap, clamped)
  * a probe inside that rectangle and clear of the cursor
  * a desktop point outside the popover for the dismiss left-click
  * the QMP rel: script that reaches those points

Never imports the kernel's functions. If two sources disagree, this file
refuses to emit expectations.

Usage: derive.py <wm.dart> <wmpop.dart> <wmchrome.dart> <mouse.dart> <fb.dart>
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


def main():
    if len(sys.argv) != 6:
        raise SystemExit("usage: derive.py <wm.dart> <wmpop.dart> "
                         "<wmchrome.dart> <mouse.dart> <fb.dart>")
    wmd, popd, chd, moused, fbd = sys.argv[1:6]

    desk = dartconst(wmd, "wmColorDesktop")
    store = dartconst(wmd, "wmStoreBytes")
    meta_words = dartconst(wmd, "wmMetaWords")
    focus = dartconst(wmd, "wmMetaFocus")

    pop_w = dartconst(popd, "wmPopW")
    pop_h = dartconst(popd, "wmPopH")
    gap = dartconst(popd, "wmPopGap")
    pop_color = dartconst(popd, "wmPopColor")
    meta_pop = dartconst(popd, "wmMetaPop")
    meta_xy = dartconst(popd, "wmMetaPopXY")

    chrome_color = dartconst(chd, "wmChromeColor")
    meta_chrome = dartconst(chd, "wmMetaChrome")

    cur_w = dartconst(moused, "mouseCursorCols")
    cur_h = dartconst(moused, "mouseCursorRows")

    fb_w = dartconst(fbd, "fbWidth")
    fb_h = dartconst(fbd, "fbHeight")

    if store != 704:
        raise SystemExit("derive: wmStoreBytes is %d, expected 704" % store)
    if meta_pop != 21:
        raise SystemExit("derive: wmMetaPop is %d, expected 21" % meta_pop)
    if meta_xy != 22:
        raise SystemExit("derive: wmMetaPopXY is %d, expected 22" % meta_xy)
    if meta_chrome != 19:
        raise SystemExit("derive: wmMetaChrome is %d, expected 19" % meta_chrome)
    if focus != 20:
        raise SystemExit("derive: wmMetaFocus is %d, expected 20" % focus)
    if meta_pop >= meta_words or meta_xy >= meta_words:
        raise SystemExit("derive: popover words are outside the meta block")
    if pop_color == desk:
        raise SystemExit("derive: wmPopColor equals the desktop")
    if pop_color == chrome_color:
        raise SystemExit("derive: wmPopColor equals chrome")
    if pop_w < 8 or pop_h < 8:
        raise SystemExit("derive: popover is too small to probe")
    if pop_w >= fb_w or pop_h >= fb_h:
        raise SystemExit("derive: popover does not fit the framebuffer")

    # Pointer starts at (0,0). A mid-desktop point keeps the +gap origin
    # on-screen without exercising the clamp, so the host model and the
    # kernel agree without a second copy of the clamp.
    click_x = 200
    click_y = 150
    if click_x + gap + pop_w > fb_w or click_y + gap + pop_h > fb_h:
        raise SystemExit("derive: click (%d,%d) + gap would clamp" %
                         (click_x, click_y))

    pop_x = click_x + gap
    pop_y = click_y + gap
    probe_x = pop_x + (pop_w // 2)
    probe_y = pop_y + (pop_h // 2)

    if not (pop_x <= probe_x < pop_x + pop_w and
            pop_y <= probe_y < pop_y + pop_h):
        raise SystemExit("derive: probe is not inside the popover")
    if (click_x <= probe_x < click_x + cur_w and
            click_y <= probe_y < click_y + cur_h):
        raise SystemExit("derive: probe sits under the cursor")

    # Dismiss click: top-left desktop, outside the popover and not on the
    # chrome strip (chrome is off on this boot anyway).
    desk_x = 40
    desk_y = 40
    if (pop_x <= desk_x < pop_x + pop_w and
            pop_y <= desk_y < pop_y + pop_h):
        raise SystemExit("derive: dismiss point is inside the popover")
    if desk_x == click_x and desk_y == click_y:
        raise SystemExit("derive: dismiss point equals the right-click")

    rels_click = fmt_rels(steps_to(click_x, click_y))
    rels_desk = fmt_rels(steps_to(desk_x - click_x, desk_y - click_y))

    print("click_x=%d" % click_x)
    print("click_y=%d" % click_y)
    print("desk_x=%d" % desk_x)
    print("desk_y=%d" % desk_y)
    print("pop_x=%d" % pop_x)
    print("pop_y=%d" % pop_y)
    print("pop_w=%d" % pop_w)
    print("pop_h=%d" % pop_h)
    print("probe_x=%d" % probe_x)
    print("probe_y=%d" % probe_y)
    print("pop_color=%06X" % (pop_color & 0xFFFFFF))
    print("desk_color=%06X" % (desk & 0xFFFFFF))
    print("chrome_color=%06X" % (chrome_color & 0xFFFFFF))
    print("rels_to_click=%s" % rels_click)
    print("rels_to_desk=%s" % rels_desk)
    print("meta_pop=%d" % meta_pop)
    print("meta_xy=%d" % meta_xy)
    print("fb_w=%d" % fb_w)
    print("fb_h=%d" % fb_h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
