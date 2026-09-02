#!/usr/bin/env python3
"""core/tests/conformance/osxui2/derive.py

Host-side picture for BTN.ELF: geometry, colours, hit/miss clicks, and
the flip scancode, all read out of btn.c and the kernel sources. Nothing
is read back out of the kernel at derivation time.

    derive.py <btn.c> <wm.dart> <wmevent.dart> <kbdq.dart>

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


# Scan-code set 1 make codes, same table d2-input / d9-focus use.
SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
}


def main():
    if len(sys.argv) != 5:
        die("usage: derive.py <btn.c> <wm.dart> <wmevent.dart> <kbdq.dart>")
    btnc, wmdart, evdart, kbdqdart = sys.argv[1:5]
    P = c_defs(btnc)
    W = dart_ints(wmdart)
    E = dart_ints(evdart)
    K = dart_ints(kbdqdart)
    for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "SURF_FILL",
              "CTL_X", "CTL_Y", "CTL_W", "CTL_H", "CTL_OFF", "CTL_ON",
              "FLIP_SCAN", "WIN_PAGES"):
        if k not in P:
            die("btn.c does not define %s" % k)
    for k in ("wmColorDesktop", "wmBorder", "wmColorFocus", "wmSysSurfaceNo"):
        if k not in W:
            die("wm.dart does not define %s" % k)
    if "wmeventSysNo" not in E:
        die("wmevent.dart does not define wmeventSysNo")
    if "kbdqSysNo" not in K:
        die("kbdq.dart does not define kbdqSysNo")

    w, h = P["WIN_W"], P["WIN_H"]
    sx, sy = P["SURF_X"], P["SURF_Y"]
    cx, cy, cw, ch = P["CTL_X"], P["CTL_Y"], P["CTL_W"], P["CTL_H"]
    fill, off, on = P["SURF_FILL"], P["CTL_OFF"], P["CTL_ON"]
    scan = P["FLIP_SCAN"]
    desk = W["wmColorDesktop"]
    border = W["wmBorder"]
    focus = W["wmColorFocus"]
    fbw, fbh = 800, 600

    area = w * h
    ctl_area = cw * ch
    if area <= 0:
        die("surface area is %d — anti-vacuity refuses a zero-area window" % area)
    if ctl_area <= 0:
        die("control area is %d — anti-vacuity refuses a zero-area control" % ctl_area)
    if ctl_area >= area:
        die("control %dx%d is the whole %dx%d surface — the outside-the-control "
            "probe would be vacuous" % (cw, ch, w, h))
    if cx < 0 or cy < 0 or cx + cw > w or cy + ch > h:
        die("control (%d,%d) %dx%d does not sit inside %dx%d" % (cx, cy, cw, ch, w, h))
    need_pages = (w * h * 4 + 4095) // 4096
    if P["WIN_PAGES"] != need_pages:
        die("btn.c asks for %d pages but %dx%d at 4 bytes per pixel needs %d"
            % (P["WIN_PAGES"], w, h, need_pages))
    if off == on:
        die("CTL_OFF equals CTL_ON — the flip cannot be seen")
    if off == fill or on == fill:
        die("a control colour equals SURF_FILL — the control would vanish")
    if off == desk or on == desk or fill == desk:
        die("a surface colour equals the desktop — a probe would be vacuous")
    if sx < border or sy < border:
        die("surface origin (%d,%d) does not leave room for the %d-px border"
            % (sx, sy, border))
    if sx + w + border > fbw or sy + h + border > fbh:
        die("surface (%d,%d) %dx%d plus border does not fit %dx%d"
            % (sx, sy, w, h, fbw, fbh))

    if E["wmeventSysNo"] != 25:
        die("wmeventSysNo is %d, expected 25" % E["wmeventSysNo"])
    if K["kbdqSysNo"] != 24:
        die("kbdqSysNo is %d, expected 24" % K["kbdqSysNo"])
    if W["wmSysSurfaceNo"] != 23:
        die("wmSysSurfaceNo is %d, expected 23" % W["wmSysSurfaceNo"])

    # Inside the control: centre. Outside the control but on the surface:
    # a point in the fill band left of the control.
    hit_rx = cx + cw // 2
    hit_ry = cy + ch // 2
    miss_rx = 8
    miss_ry = 8
    if not (cx <= hit_rx < cx + cw and cy <= hit_ry < cy + ch):
        die("hit point (%d,%d) is not inside the control" % (hit_rx, hit_ry))
    if cx <= miss_rx < cx + cw and cy <= miss_ry < cy + ch:
        die("miss point (%d,%d) is inside the control — the negative "
            "control would be vacuous" % (miss_rx, miss_ry))
    if not (0 <= miss_rx < w and 0 <= miss_ry < h):
        die("miss point (%d,%d) is not on the surface" % (miss_rx, miss_ry))

    hit_x = sx + hit_rx
    hit_y = sy + hit_ry
    miss_x = sx + miss_rx
    miss_y = sy + miss_ry

    def rels(steps):
        return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)

    rels_hit = rels(steps_to(hit_x, hit_y))
    rels_miss = rels(steps_to(miss_x, miss_y))
    # Park the pointer after the click so the compositor cursor is not
    # sitting on a probe pixel. (400,10) is desktop, clear of the window
    # and of the (20,20) desk probe.
    park_x, park_y = 400, 10
    desk_x, desk_y = 20, 20
    rels_hit_to_desk = rels(steps_to(park_x - hit_x, park_y - hit_y))
    rels_miss_to_desk = rels(steps_to(park_x - miss_x, park_y - miss_y))

    key_letter = None
    for letter, make in SET1.items():
        if make == scan:
            key_letter = letter
            break
    if key_letter is None:
        die("FLIP_SCAN 0x%02X is not a letter in the host SET1 table" % scan)

    probes_idle = []
    probes_armed = []

    def add(bucket, name, px, py, colour):
        if not (0 <= px < fbw and 0 <= py < fbh):
            die("probe %s at (%d,%d) is off-screen" % (name, px, py))
        bucket.append((name, px, py, colour))

    # Probe a pixel inside the control that is not the click (the
    # compositor draws the pointer on top of the last packet).
    ctl_px = sx + cx + 8
    ctl_py = sy + cy + 8
    fill_px = sx + miss_rx
    fill_py = sy + miss_ry

    add(probes_idle, "desk", desk_x, desk_y, desk)
    add(probes_idle, "fill", fill_px, fill_py, fill)
    add(probes_idle, "ctl", ctl_px, ctl_py, off)
    add(probes_idle, "border", sx - 1, sy, focus)

    add(probes_armed, "desk", desk_x, desk_y, desk)
    add(probes_armed, "fill", fill_px, fill_py, fill)
    add(probes_armed, "ctl", ctl_px, ctl_py, on)
    add(probes_armed, "border", sx - 1, sy, focus)

    # Control: the ON colour at the control probe on the idle picture,
    # and the same point after a miss. Must FAIL.
    control_idle_is_not_on = ("ctl_is_not_on", ctl_px, ctl_py, on)
    control_miss_is_not_on = ("miss_is_not_on", ctl_px, ctl_py, on)
    # A client that fills the whole surface with the armed colour fails:
    # the fill band must stay SURF_FILL after a flip.
    control_fill_is_not_on = ("fill_is_not_on", fill_px, fill_py, on)

    print("win_w=%d" % w)
    print("win_h=%d" % h)
    print("surf_x=%d" % sx)
    print("surf_y=%d" % sy)
    print("ctl_x=%d" % cx)
    print("ctl_y=%d" % cy)
    print("ctl_w=%d" % cw)
    print("ctl_h=%d" % ch)
    print("ctl_area=%d" % ctl_area)
    print("area=%d" % area)
    print("surf_fill=%d" % fill)
    print("ctl_off=%d" % off)
    print("ctl_on=%d" % on)
    print("desk=%d" % desk)
    print("focus=%d" % focus)
    print("border=%d" % border)
    print("flip_scan=%d" % scan)
    print("key_letter=%s" % key_letter)
    print("hit_rx=%d" % hit_rx)
    print("hit_ry=%d" % hit_ry)
    print("miss_rx=%d" % miss_rx)
    print("miss_ry=%d" % miss_ry)
    print("hit_x=%d" % hit_x)
    print("hit_y=%d" % hit_y)
    print("miss_x=%d" % miss_x)
    print("miss_y=%d" % miss_y)
    print("rels_to_hit=%s" % rels_hit)
    print("rels_to_miss=%s" % rels_miss)
    print("rels_hit_to_desk=%s" % rels_hit_to_desk)
    print("rels_miss_to_desk=%s" % rels_miss_to_desk)
    print("syscall_wm=%d" % W["wmSysSurfaceNo"])
    print("syscall_kbd=%d" % K["kbdqSysNo"])
    print("syscall_ev=%d" % E["wmeventSysNo"])
    print("surf_fill_hex=%08X" % (fill & 0xFFFFFF))
    print("ctl_off_hex=%08X" % (off & 0xFFFFFF))
    print("ctl_on_hex=%08X" % (on & 0xFFFFFF))
    print("desk_hex=%08X" % (desk & 0xFFFFFF))
    print("hit_line=OSXUI2 HIT %08X" % (on & 0xFFFFFF))
    print("idle_probe_count=%d" % len(probes_idle))
    print("armed_probe_count=%d" % len(probes_armed))
    for name, px, py, colour in probes_idle:
        print("idle_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    for name, px, py, colour in probes_armed:
        print("armed_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    print("control_idle=%s %d %d %08X" % (control_idle_is_not_on[0],
                                          control_idle_is_not_on[1],
                                          control_idle_is_not_on[2],
                                          control_idle_is_not_on[3] & 0xFFFFFF))
    print("control_miss=%s %d %d %08X" % (control_miss_is_not_on[0],
                                          control_miss_is_not_on[1],
                                          control_miss_is_not_on[2],
                                          control_miss_is_not_on[3] & 0xFFFFFF))
    print("control_fill=%s %d %d %08X" % (control_fill_is_not_on[0],
                                          control_fill_is_not_on[1],
                                          control_fill_is_not_on[2],
                                          control_fill_is_not_on[3] & 0xFFFFFF))


if __name__ == "__main__":
    main()
