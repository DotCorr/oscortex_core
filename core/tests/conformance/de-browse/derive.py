#!/usr/bin/env python3
"""Restate browse.c / oschrome.h constants. Not a golden."""
import re
import sys

def c_u(src, name):
    m = re.search(r"#define\s+%s\s+(\d+)UL" % name, src)
    if not m:
        raise SystemExit("no #define %s" % name)
    return int(m.group(1))


def hdr_enum(src, name):
    m = re.search(r"%s\s*=\s*(0x[0-9A-Fa-f]+|\d+)" % name, src)
    if not m:
        raise SystemExit("no %s in oschrome.h" % name)
    return int(m.group(1), 0)


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: derive.py <browse.c> <oschrome.h> <osframe.h>")
    src = open(sys.argv[1]).read()
    hdr = open(sys.argv[2]).read()
    frame = open(sys.argv[3]).read()

    win_w = c_u(src, "WIN_W")
    win_h = c_u(src, "WIN_H")
    surf_x = c_u(src, "SURF_X")
    surf_y = c_u(src, "SURF_Y")
    px = c_u(src, "PX")
    py = c_u(src, "PY")
    page = hdr_enum(hdr, "OSCHROME_PAGE")
    desk = hdr_enum(hdr, "OSCHROME_DESK")
    ow = hdr_enum(hdr, "OSCHROME_W")
    oh = hdr_enum(hdr, "OSCHROME_H")
    opx = hdr_enum(hdr, "OSCHROME_PX")
    opy = hdr_enum(hdr, "OSCHROME_PY")
    if win_w != ow or win_h != oh:
        raise SystemExit("browse.c size %dx%d != oschrome.h %dx%d" %
                         (win_w, win_h, ow, oh))
    if px != opx or py != opy:
        raise SystemExit("browse.c probe %d,%d != oschrome.h %d,%d" %
                         (px, py, opx, opy))
    if page == 0:
        raise SystemExit("PAGE is zero")
    if page == desk:
        raise SystemExit("PAGE equals DESK")
    if px >= win_w or py >= win_h:
        raise SystemExit("probe outside the surface")

    # Title chrome is the top 18 rows (wmTitleH). Probe must sit in the body.
    title_h = 18
    if py <= title_h:
        raise SystemExit("PY %d is inside the title bar (%d)" % (py, title_h))

    probe_x = surf_x + px
    probe_y = surf_y + py
    print("win_w=%d" % win_w)
    print("win_h=%d" % win_h)
    print("surf_x=%d" % surf_x)
    print("surf_y=%d" % surf_y)
    print("px=%d" % px)
    print("py=%d" % py)
    print("probe_x=%d" % probe_x)
    print("probe_y=%d" % probe_y)
    print("page=0x%08X" % (page & 0xFFFFFF))
    print("desk=0x%08X" % (desk & 0xFFFFFF))
    print("title_h=%d" % title_h)
    print("go_page=go browse.elf")
    print("go_none=go ninit.elf")
    print("go_line=GO")
    print("ready_line=BROWSE READY")
    print("none_line=BROWSE NONE")
    if "SYS_WMSURFACE 23" not in frame:
        raise SystemExit("osframe.h lost SYS_WMSURFACE 23")
    print("syscall_wm=23")
    print("syscall_kbd=24")
    print("syscall_ev=25")
    print("syscall_spawn=26")


if __name__ == "__main__":
    main()
