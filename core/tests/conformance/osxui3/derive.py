#!/usr/bin/env python3
"""core/tests/conformance/osxui3/derive.py

Host-side picture for MENU.ELF: main + menu geometry, colours, open/band
clicks, and the open scancode, all read out of menu.c and the kernel
sources. Nothing is read back out of the kernel at derivation time.

    derive.py <menu.c> <wm.dart> <wmevent.dart> <kbdq.dart> <shm.dart>

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


def steps_to(dx, dy, cap=120):
    """Split a screen delta into PS/2-safe relative steps (each |d| <= cap)."""
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


# Scan-code set 1 make codes, same table d2-input / osxui2 use.
SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
}


def main():
    if len(sys.argv) != 6:
        die("usage: derive.py <menu.c> <wm.dart> <wmevent.dart> <kbdq.dart> <shm.dart>")
    menuc, wmdart, evdart, kbdqdart, shmdart = sys.argv[1:6]
    P = c_defs(menuc)
    W = dart_ints(wmdart)
    E = dart_ints(evdart)
    K = dart_ints(kbdqdart)
    S = dart_ints(shmdart)
    for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "SURF_FILL",
              "OPEN_X", "OPEN_Y", "OPEN_W", "OPEN_H", "OPEN_OFF",
              "MENU_W", "MENU_H", "MENU_X", "MENU_Y", "MENU_FILL",
              "BAND_X", "BAND_Y", "BAND_W", "BAND_H", "BAND_OFF", "BAND_ON",
              "OPEN_SCAN", "DISMISS_SCAN", "WIN_PAGES", "MENU_PAGES"):
        if k not in P:
            die("menu.c does not define %s" % k)
    for k in ("wmColorDesktop", "wmBorder", "wmColorFocus", "wmSysSurfaceNo",
              "wmMaxWindows"):
        if k not in W:
            die("wm.dart does not define %s" % k)
    if "wmeventSysNo" not in E:
        die("wmevent.dart does not define wmeventSysNo")
    if "kbdqSysNo" not in K:
        die("kbdq.dart does not define kbdqSysNo")
    if "shmMax" not in S:
        die("shm.dart does not define shmMax")

    w, h = P["WIN_W"], P["WIN_H"]
    sx, sy = P["SURF_X"], P["SURF_Y"]
    ox, oy, ow, oh = P["OPEN_X"], P["OPEN_Y"], P["OPEN_W"], P["OPEN_H"]
    mw, mh, mx, my = P["MENU_W"], P["MENU_H"], P["MENU_X"], P["MENU_Y"]
    bx, by, bw, bh = P["BAND_X"], P["BAND_Y"], P["BAND_W"], P["BAND_H"]
    fill, open_off = P["SURF_FILL"], P["OPEN_OFF"]
    menu_fill, band_off, band_on = P["MENU_FILL"], P["BAND_OFF"], P["BAND_ON"]
    scan = P["OPEN_SCAN"]
    desk = W["wmColorDesktop"]
    border = W["wmBorder"]
    focus = W["wmColorFocus"]
    fbw, fbh = 800, 600

    area = w * h
    menu_area = mw * mh
    band_area = bw * bh
    if area <= 0:
        die("main surface area is %d — anti-vacuity refuses a zero-area window" % area)
    if menu_area <= 0:
        die("menu area is %d — anti-vacuity refuses a zero-area menu" % menu_area)
    if menu_area == area:
        die("menu %dx%d equals the main %dx%d — the two surfaces would be the same"
            % (mw, mh, w, h))
    if band_area <= 0:
        die("band area is %d — anti-vacuity refuses a zero-area band" % band_area)
    if band_area >= menu_area:
        die("band %dx%d is the whole %dx%d menu — the outside-the-band "
            "probe would be vacuous" % (bw, bh, mw, mh))
    if ox < 0 or oy < 0 or ox + ow > w or oy + oh > h:
        die("opener (%d,%d) %dx%d does not sit inside %dx%d" % (ox, oy, ow, oh, w, h))
    if bx < 0 or by < 0 or bx + bw > mw or by + bh > mh:
        die("band (%d,%d) %dx%d does not sit inside the menu %dx%d"
            % (bx, by, bw, bh, mw, mh))
    need_main = (w * h * 4 + 4095) // 4096
    need_menu = (mw * mh * 4 + 4095) // 4096
    if P["WIN_PAGES"] != need_main:
        die("menu.c asks for %d main pages but %dx%d needs %d"
            % (P["WIN_PAGES"], w, h, need_main))
    if P["MENU_PAGES"] != need_menu:
        die("menu.c asks for %d menu pages but %dx%d needs %d"
            % (P["MENU_PAGES"], mw, mh, need_menu))
    if S["shmMax"] < 2:
        die("shmMax is %d, OSXUI3 needs at least two regions" % S["shmMax"])
    if W["wmMaxWindows"] != S["shmMax"]:
        die("wmMaxWindows is %d, expected %d (derived from shmMax)"
            % (W["wmMaxWindows"], S["shmMax"]))
    if W["wmMaxWindows"] < 2:
        die("wmMaxWindows is %d, OSXUI3 needs two slots" % W["wmMaxWindows"])
    colours = {
        "SURF_FILL": fill, "OPEN_OFF": open_off, "MENU_FILL": menu_fill,
        "BAND_OFF": band_off, "BAND_ON": band_on, "desk": desk,
    }
    seen = {}
    for name, c in colours.items():
        if c in seen:
            die("%s equals %s (0x%06X) — a probe would be vacuous"
                % (name, seen[c], c & 0xFFFFFF))
        seen[c] = name
    if sx < border or sy < border:
        die("main origin (%d,%d) does not leave room for the %d-px border"
            % (sx, sy, border))
    if mx < border or my < border:
        die("menu origin (%d,%d) does not leave room for the %d-px border"
            % (mx, my, border))
    if sx + w + border > fbw or sy + h + border > fbh:
        die("main (%d,%d) %dx%d plus border does not fit %dx%d"
            % (sx, sy, w, h, fbw, fbh))
    if mx + mw + border > fbw or my + mh + border > fbh:
        die("menu (%d,%d) %dx%d plus border does not fit %dx%d"
            % (mx, my, mw, mh, fbw, fbh))

    # Menu must not cover the opener or the main-miss point, or those
    # clicks would hit the menu window instead.
    def overlap(ax, ay, aw, ah, bx0, by0, bw0, bh0):
        return not (ax + aw <= bx0 or bx0 + bw0 <= ax or
                    ay + ah <= by0 or by0 + bh0 <= ay)

    if overlap(sx, sy, w, h, mx, my, mw, mh):
        # Overlap is allowed only if the miss and opener stay exclusive.
        pass

    if E["wmeventSysNo"] != 25:
        die("wmeventSysNo is %d, expected 25" % E["wmeventSysNo"])
    if K["kbdqSysNo"] != 24:
        die("kbdqSysNo is %d, expected 24" % K["kbdqSysNo"])
    if W["wmSysSurfaceNo"] != 23:
        die("wmSysSurfaceNo is %d, expected 23" % W["wmSysSurfaceNo"])

    open_rx = ox + ow // 2
    open_ry = oy + oh // 2
    miss_rx, miss_ry = 8, 8
    band_rx = bx + bw // 2
    band_ry = by + bh // 2
    if not (ox <= open_rx < ox + ow and oy <= open_ry < oy + oh):
        die("open point (%d,%d) is not inside the opener" % (open_rx, open_ry))
    if ox <= miss_rx < ox + ow and oy <= miss_ry < oy + oh:
        die("miss point (%d,%d) is inside the opener" % (miss_rx, miss_ry))
    if not (0 <= miss_rx < w and 0 <= miss_ry < h):
        die("miss point (%d,%d) is not on the main surface" % (miss_rx, miss_ry))
    if not (bx <= band_rx < bx + bw and by <= band_ry < by + bh):
        die("band point (%d,%d) is not inside the band" % (band_rx, band_ry))

    open_x, open_y = sx + open_rx, sy + open_ry
    miss_x, miss_y = sx + miss_rx, sy + miss_ry
    band_x, band_y = mx + band_rx, my + band_ry

    # Screen points must not land on the other surface.
    if mx <= open_x < mx + mw and my <= open_y < my + mh:
        die("opener click (%d,%d) is also on the menu" % (open_x, open_y))
    if mx <= miss_x < mx + mw and my <= miss_y < my + mh:
        die("main-miss click (%d,%d) is also on the menu" % (miss_x, miss_y))
    if sx <= band_x < sx + w and sy <= band_y < sy + h:
        die("band click (%d,%d) is also on the main surface — raise would hide the menu"
            % (band_x, band_y))

    def rels(steps):
        return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)

    park_x, park_y = 400, 10
    desk_x, desk_y = 20, 20

    rels_to_open = rels(steps_to(open_x, open_y))
    rels_to_miss = rels(steps_to(miss_x, miss_y))
    rels_open_to_band = rels(steps_to(band_x - open_x, band_y - open_y))
    rels_open_to_miss = rels(steps_to(miss_x - open_x, miss_y - open_y))
    rels_miss_to_park = rels(steps_to(park_x - miss_x, park_y - miss_y))
    rels_band_to_park = rels(steps_to(park_x - band_x, park_y - band_y))
    rels_open_to_park = rels(steps_to(park_x - open_x, park_y - open_y))

    key_letter = None
    for letter, make in SET1.items():
        if make == scan:
            key_letter = letter
            break
    if key_letter is None:
        die("OPEN_SCAN 0x%02X is not a letter in the host SET1 table" % scan)

    probes_idle = []
    probes_open = []
    probes_armed = []

    def add(bucket, name, px, py, colour):
        if not (0 <= px < fbw and 0 <= py < fbh):
            die("probe %s at (%d,%d) is off-screen" % (name, px, py))
        bucket.append((name, px, py, colour))

    fill_px, fill_py = sx + miss_rx, sy + miss_ry
    open_px, open_py = sx + ox + 8, sy + oy + 8
    menu_px, menu_py = mx + 4, my + 4
    band_px, band_py = mx + bx + 8, my + by + 8

    # After READY, before the menu exists: menu rect is desktop.
    add(probes_idle, "desk", desk_x, desk_y, desk)
    add(probes_idle, "fill", fill_px, fill_py, fill)
    add(probes_idle, "open", open_px, open_py, open_off)
    add(probes_idle, "menu_is_desk", menu_px, menu_py, desk)
    add(probes_idle, "border", sx - 1, sy, focus)

    add(probes_open, "desk", desk_x, desk_y, desk)
    add(probes_open, "fill", fill_px, fill_py, fill)
    add(probes_open, "menu", menu_px, menu_py, menu_fill)
    add(probes_open, "band", band_px, band_py, band_off)
    add(probes_open, "menu_border", mx - 1, my, focus)

    add(probes_armed, "desk", desk_x, desk_y, desk)
    add(probes_armed, "fill", fill_px, fill_py, fill)
    add(probes_armed, "menu", menu_px, menu_py, menu_fill)
    add(probes_armed, "band", band_px, band_py, band_on)
    add(probes_armed, "menu_border", mx - 1, my, focus)

    # After a main-surface click the menu is no longer top: its border
    # is dim. The band and fill must still be the idle menu colours.
    probes_miss = []
    add(probes_miss, "desk", desk_x, desk_y, desk)
    add(probes_miss, "fill", fill_px, fill_py, fill)
    add(probes_miss, "menu", menu_px, menu_py, menu_fill)
    add(probes_miss, "band", band_px, band_py, band_off)

    print("win_w=%d" % w)
    print("win_h=%d" % h)
    print("surf_x=%d" % sx)
    print("surf_y=%d" % sy)
    print("menu_w=%d" % mw)
    print("menu_h=%d" % mh)
    print("menu_x=%d" % mx)
    print("menu_y=%d" % my)
    print("menu_area=%d" % menu_area)
    print("area=%d" % area)
    print("band_area=%d" % band_area)
    print("shm_max=%d" % S["shmMax"])
    print("wm_max=%d" % W["wmMaxWindows"])
    print("surf_fill=%d" % fill)
    print("menu_fill=%d" % menu_fill)
    print("band_off=%d" % band_off)
    print("band_on=%d" % band_on)
    print("desk=%d" % desk)
    print("focus=%d" % focus)
    print("border=%d" % border)
    print("open_scan=%d" % scan)
    print("key_letter=%s" % key_letter)
    print("open_x=%d" % open_x)
    print("open_y=%d" % open_y)
    print("miss_x=%d" % miss_x)
    print("miss_y=%d" % miss_y)
    print("band_x=%d" % band_x)
    print("band_y=%d" % band_y)
    print("rels_to_open=%s" % rels_to_open)
    print("rels_to_miss=%s" % rels_to_miss)
    print("rels_open_to_band=%s" % rels_open_to_band)
    print("rels_open_to_miss=%s" % rels_open_to_miss)
    print("rels_miss_to_park=%s" % rels_miss_to_park)
    print("rels_band_to_park=%s" % rels_band_to_park)
    print("rels_open_to_park=%s" % rels_open_to_park)
    print("syscall_wm=%d" % W["wmSysSurfaceNo"])
    print("syscall_kbd=%d" % K["kbdqSysNo"])
    print("syscall_ev=%d" % E["wmeventSysNo"])
    print("surf_fill_hex=%08X" % (fill & 0xFFFFFF))
    print("menu_fill_hex=%08X" % (menu_fill & 0xFFFFFF))
    print("band_off_hex=%08X" % (band_off & 0xFFFFFF))
    print("band_on_hex=%08X" % (band_on & 0xFFFFFF))
    print("desk_hex=%08X" % (desk & 0xFFFFFF))
    print("open_line=OSXUI3 OPEN %08X" % (menu_fill & 0xFFFFFF))
    print("band_line=OSXUI3 BAND %08X" % (band_on & 0xFFFFFF))
    print("idle_probe_count=%d" % len(probes_idle))
    print("open_probe_count=%d" % len(probes_open))
    print("armed_probe_count=%d" % len(probes_armed))
    print("miss_probe_count=%d" % len(probes_miss))
    for name, px, py, colour in probes_idle:
        print("idle_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    for name, px, py, colour in probes_open:
        print("open_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    for name, px, py, colour in probes_armed:
        print("armed_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    for name, px, py, colour in probes_miss:
        print("miss_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    print("control_idle_menu=%s %d %d %08X" % ("menu_is_not_fill", menu_px, menu_py,
                                               menu_fill & 0xFFFFFF))
    print("control_miss_band=%s %d %d %08X" % ("band_is_not_on", band_px, band_py,
                                              band_on & 0xFFFFFF))
    print("control_nocom_desk=%s %d %d %08X" % ("nocom_desk", menu_px, menu_py,
                                               desk & 0xFFFFFF))
    print("control_nocom_fill=%s %d %d %08X" % ("nocom_not_fill", menu_px, menu_py,
                                               menu_fill & 0xFFFFFF))


if __name__ == "__main__":
    main()
