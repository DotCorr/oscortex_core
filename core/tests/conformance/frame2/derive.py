#!/usr/bin/env python3
"""core/tests/conformance/frame2/derive.py

Host-side picture for SURF.ELF: geometry and colours read out of surf.c
and wm.dart. Nothing is read back out of the kernel at derivation time.

    derive.py <surf.c> <wm.dart>

Exit status: 0 and key=value lines on stdout, 2 on a derivation failure.
"""

import re
import sys


def die(msg):
    print("derive: " + msg, file=sys.stderr)
    raise SystemExit(2)


def c_defs(path):
    out = {}
    for m in re.finditer(r"^#define\s+([A-Z_0-9]+)\s+(0[xX][0-9A-Fa-f]+|\d+)U?L?$",
                         open(path).read(), re.M):
        out[m.group(1)] = int(m.group(2), 0)
    return out


def dart_ints(path):
    out = {}
    for m in re.finditer(r"^const int (\w+) = (0x[0-9A-Fa-f]+|\d+);$",
                         open(path).read(), re.M):
        out[m.group(1)] = int(m.group(2), 0)
    return out


def main():
    if len(sys.argv) != 3:
        die("usage: derive.py <surf.c> <wm.dart>")
    surfc, wmdart = sys.argv[1], sys.argv[2]
    P = c_defs(surfc)
    W = dart_ints(wmdart)
    for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "SURF_FILL", "SURF_INK",
              "INK_INSET", "WIN_PAGES"):
        if k not in P:
            die("surf.c does not define %s" % k)
    for k in ("wmColorDesktop", "wmBorder", "wmColorFocus", "wmSysSurfaceNo"):
        if k not in W:
            die("wm.dart does not define %s" % k)

    w, h = P["WIN_W"], P["WIN_H"]
    x, y = P["SURF_X"], P["SURF_Y"]
    inset = P["INK_INSET"]
    fill, ink = P["SURF_FILL"], P["SURF_INK"]
    desk = W["wmColorDesktop"]
    border = W["wmBorder"]
    focus = W["wmColorFocus"]
    fbw, fbh = 800, 600

    area = w * h
    if area <= 0:
        die("expected surface area is %d pixels — FRAME2's anti-vacuity "
            "guard refuses a zero-area rectangle" % area)
    need_pages = (w * h * 4 + 4095) // 4096
    if P["WIN_PAGES"] != need_pages:
        die("surf.c asks for %d pages but %dx%d at 4 bytes per pixel needs %d"
            % (P["WIN_PAGES"], w, h, need_pages))
    if fill == desk:
        die("SURF_FILL equals the desktop colour — a probe on the surface "
            "would be vacuous")
    if ink == fill:
        die("SURF_INK equals SURF_FILL — the inner block cannot prove a blit")
    if ink == desk:
        die("SURF_INK equals the desktop colour")
    if inset <= 0 or inset * 2 >= w or inset * 2 >= h:
        die("INK_INSET %d does not leave an inner block inside %dx%d" % (inset, w, h))
    if x < border or y < border:
        die("surface origin (%d,%d) does not leave room for the %d-px border"
            % (x, y, border))
    if x + w + border > fbw or y + h + border > fbh:
        die("surface (%d,%d) %dx%d plus border does not fit %dx%d"
            % (x, y, w, h, fbw, fbh))

    decorated = (w + 2 * border) * (h + 2 * border)
    px1 = fbw * fbh
    px2 = decorated
    if px2 >= px1:
        die("a decorated window is %d pixels and the desktop is %d"
            % (px2, px1))

    def surface_pixel(px, py):
        inside = (inset <= px < w - inset) and (inset <= py < h - inset)
        return ink if inside else fill

    probes = []

    def add(name, sx, sy, colour):
        if not (0 <= sx < fbw and 0 <= sy < fbh):
            die("probe %s at (%d,%d) is off-screen" % (name, sx, sy))
        probes.append((name, sx, sy, colour))

    # Desktop, well clear of the window, the border, and the cursor at (0,0).
    add("desk", 20, 20, desk)
    add("fill", x + 4, y + 4, fill)
    add("ink", x + w // 2, y + h // 2, ink)
    add("border", x - 1, y, focus)

    # Control: the FILL colour at a desktop coordinate. Must FAIL on the
    # commit boot (the desktop is there). On the nocommit boot the same
    # coordinate is still desktop — this control is about the commit picture.
    control = ("desk_is_not_fill", 20, 20, fill)

    print("win_w=%d" % w)
    print("win_h=%d" % h)
    print("surf_x=%d" % x)
    print("surf_y=%d" % y)
    print("surf_fill=%d" % fill)
    print("surf_ink=%d" % ink)
    print("desk=%d" % desk)
    print("focus=%d" % focus)
    print("border=%d" % border)
    print("area=%d" % area)
    print("px1=%08X" % px1)
    print("px2=%08X" % px2)
    print("syscall=%d" % W["wmSysSurfaceNo"])
    print("probe_count=%d" % len(probes))
    print("surf_fill_hex=%08X" % (fill & 0xFFFFFF))
    print("surf_ink_hex=%08X" % (ink & 0xFFFFFF))
    print("desk_hex=%08X" % (desk & 0xFFFFFF))
    print("focus_hex=%08X" % (focus & 0xFFFFFF))
    for name, sx, sy, colour in probes:
        print("probe=%s %d %d %08X" % (name, sx, sy, colour & 0xFFFFFF))
    print("control=%s %d %d %08X" % (control[0], control[1], control[2],
                                     control[3] & 0xFFFFFF))


if __name__ == "__main__":
    main()
