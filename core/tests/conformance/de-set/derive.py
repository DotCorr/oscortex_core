#!/usr/bin/env python3
"""core/tests/conformance/de-set/derive.py

Host-side picture for SET.ELF: framebuffer geometry and chrome policy
colours read out of the kernel sources, window geometry from set.c,
and the planted FACTS.DAT bytes. Nothing is read back out of the
kernel at derivation time.

    derive.py <set.c> <fb.dart> <wm.dart> <wmchrome.dart> <wmevent.dart> <kbdq.dart>

Exit status: 0 and key=value lines on stdout, 2 on a derivation failure.
"""

import re
import struct
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


SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
}


def facts_blob(fb_w, fb_h, chrome_on, desk, chrome, title, pad=22):
    chk = ((fb_w | (fb_h << 16)) ^ desk ^ chrome ^ title ^ chrome_on) & 0xFFFFFFFF
    body = b"SET1" + struct.pack("<HHBBIIII",
                                 fb_w, fb_h, chrome_on, 0,
                                 desk, chrome, title, chk)
    # Padding so a one-field / one-sector-of-zeros hash cannot pass.
    extra = bytes((0xA5 ^ i) & 0xFF for i in range(pad))
    return body + extra


def main():
    if len(sys.argv) != 7:
        die("usage: derive.py <set.c> <fb.dart> <wm.dart> <wmchrome.dart> "
            "<wmevent.dart> <kbdq.dart>")
    setc, fbdart, wmdart, chromedart, evdart, kbdqdart = sys.argv[1:7]
    src = open(setc).read()
    P = c_defs(setc)
    F = dart_ints(fbdart)
    W = dart_ints(wmdart)
    C = dart_ints(chromedart)
    E = dart_ints(evdart)
    K = dart_ints(kbdqdart)

    for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "SURF_FILL",
              "SW_X", "SW_Y", "SW_W", "SW_H", "SW_GAP",
              "CTL_X", "CTL_Y", "CTL_W", "CTL_H", "CTL_OFF", "CTL_ON",
              "FLIP_SCAN", "WIN_PAGES", "FACTS_NEED"):
        if k not in P:
            die("set.c does not define %s" % k)
    for k in ("fbWidth", "fbHeight"):
        if k not in F:
            die("fb.dart does not define %s" % k)
    for k in ("wmColorDesktop", "wmBorder", "wmColorFocus", "wmSysSurfaceNo"):
        if k not in W:
            die("wm.dart does not define %s" % k)
    for k in ("wmChromeH", "wmChromeColor", "wmTitleH", "wmTitleColor"):
        if k not in C:
            die("wmchrome.dart does not define %s" % k)
    if "wmeventSysNo" not in E:
        die("wmevent.dart does not define wmeventSysNo")
    if "kbdqSysNo" not in K:
        die("kbdq.dart does not define kbdqSysNo")

    if re.search(r"\b800\b", src) or re.search(r"\b600\b", src):
        die("set.c bakes 800 or 600 — facts must come from FACTS.DAT")
    if re.search(r"0x00C09048", src, re.I) or re.search(r"0x00D8B060", src, re.I):
        die("set.c bakes a chrome/title colour — those come from the planted file")
    if re.search(r"0x00184060", src, re.I):
        die("set.c bakes wmColorDesktop — that comes from the planted file")
    if "SYS_FDWAIT" in src:
        die("set.c names SYS_FDWAIT — 11 stays reserved")

    w, h = P["WIN_W"], P["WIN_H"]
    sx, sy = P["SURF_X"], P["SURF_Y"]
    swx, swy, sww, swh, swg = (P["SW_X"], P["SW_Y"], P["SW_W"],
                               P["SW_H"], P["SW_GAP"])
    cx, cy, cw, ch = P["CTL_X"], P["CTL_Y"], P["CTL_W"], P["CTL_H"]
    fill, off, on = P["SURF_FILL"], P["CTL_OFF"], P["CTL_ON"]
    scan = P["FLIP_SCAN"]
    desk = W["wmColorDesktop"]
    chrome_c = C["wmChromeColor"]
    title_c = C["wmTitleColor"]
    chrome_h = C["wmChromeH"]
    title_h = C["wmTitleH"]
    border = W["wmBorder"]
    focus = W["wmColorFocus"]
    fbw, fbh = F["fbWidth"], F["fbHeight"]
    chrome_on = 0

    area = w * h
    ctl_area = cw * ch
    sw_area = sww * swh
    if area <= 0:
        die("surface area is %d — anti-vacuity refuses a zero-area window" % area)
    if ctl_area <= 0:
        die("control area is %d — anti-vacuity refuses a zero-area control" % ctl_area)
    if sw_area <= 0:
        die("swatch area is %d — anti-vacuity refuses a zero-area swatch" % sw_area)
    if ctl_area >= area:
        die("control %dx%d is the whole %dx%d surface" % (cw, ch, w, h))
    if cx < 0 or cy < 0 or cx + cw > w or cy + ch > h:
        die("control does not sit inside the surface")
    need_pages = (w * h * 4 + 4095) // 4096
    if P["WIN_PAGES"] != need_pages:
        die("set.c asks for %d pages but %dx%d needs %d"
            % (P["WIN_PAGES"], w, h, need_pages))
    if fbw <= 0 or fbh <= 0:
        die("derived fb %dx%d is vacuous" % (fbw, fbh))
    if fbw * fbh == 0:
        die("fb area is zero")
    if desk == chrome_c or desk == title_c or chrome_c == title_c:
        die("policy colours are not distinct")
    if off == on:
        die("CTL_OFF equals CTL_ON")
    if off == fill or on == fill:
        die("a control colour equals SURF_FILL")
    for col, name in ((off, "CTL_OFF"), (on, "CTL_ON"), (fill, "SURF_FILL")):
        if col in (desk, chrome_c, title_c):
            die("%s equals a policy colour — a swatch probe would be vacuous" % name)
    if sx < border or sy < border:
        die("surface origin does not leave room for the border")
    if sx + w + border > fbw or sy + h + border > fbh:
        die("surface plus border does not fit the derived framebuffer")

    if E["wmeventSysNo"] != 25:
        die("wmeventSysNo is %d, expected 25" % E["wmeventSysNo"])
    if K["kbdqSysNo"] != 24:
        die("kbdqSysNo is %d, expected 24" % K["kbdqSysNo"])
    if W["wmSysSurfaceNo"] != 23:
        die("wmSysSurfaceNo is %d, expected 23" % W["wmSysSurfaceNo"])
    if P["FACTS_NEED"] != 26:
        die("FACTS_NEED is %d, expected 26" % P["FACTS_NEED"])

    hit_rx = cx + cw // 2
    hit_ry = cy + ch // 2
    # Content pane: left of fact swatches, above the bottom band.
    side_w = P.get("SIDE_W", 0)
    miss_rx = max(side_w + 16, 8)
    miss_ry = P["SW_Y"] - 8
    if (miss_rx >= P["SW_X"] and
            miss_rx < P["SW_X"] + 3 * (P["SW_W"] + P["SW_GAP"]) and
            miss_ry >= P["SW_Y"] and miss_ry < P["SW_Y"] + P["SW_H"]):
        die("miss point lands on a fact swatch")
    if not (cx <= hit_rx < cx + cw and cy <= hit_ry < cy + ch):
        die("hit point is not inside the control")
    if cx <= miss_rx < cx + cw and cy <= miss_ry < cy + ch:
        die("miss point is inside the control")
    if miss_rx < side_w:
        die("miss point is inside the sidebar")
    if not (0 <= miss_rx < w and 0 <= miss_ry < h):
        die("miss point is not on the surface")

    hit_x = sx + hit_rx
    hit_y = sy + hit_ry
    miss_x = sx + miss_rx
    miss_y = sy + miss_ry

    def rels(steps):
        return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)

    park_x, park_y = 400, 10
    desk_x, desk_y = 20, 20
    rels_hit = rels(steps_to(hit_x, hit_y))
    rels_miss = rels(steps_to(miss_x, miss_y))
    rels_hit_to_desk = rels(steps_to(park_x - hit_x, park_y - hit_y))
    rels_miss_to_desk = rels(steps_to(park_x - miss_x, park_y - miss_y))

    key_letter = None
    for letter, make in SET1.items():
        if make == scan:
            key_letter = letter
            break
    if key_letter is None:
        die("FLIP_SCAN 0x%02X is not a letter in the host SET1 table" % scan)

    sw1x = swx + sww + swg
    sw2x = sw1x + sww + swg
    desk_px = sx + swx + 8
    desk_py = sy + swy + 8
    bar_px = sx + sw1x + 8
    bar_py = sy + swy + 8
    title_px = sx + sw2x + 8
    title_py = sy + swy + 8
    ctl_px = sx + cx + 8
    ctl_py = sy + cy + 8
    fill_px = sx + miss_rx
    fill_py = sy + miss_ry

    blob = facts_blob(fbw, fbh, chrome_on, desk, chrome_c, title_c)
    if len(blob) <= P["FACTS_NEED"]:
        die("planted FACTS.DAT is %d bytes, need more than %d"
            % (len(blob), P["FACTS_NEED"]))
    trunc = blob[:8]
    if len(trunc) >= P["FACTS_NEED"]:
        die("trunc blob is not shorter than FACTS_NEED")

    probes_idle = []
    probes_armed = []

    def add(bucket, name, px, py, colour):
        if not (0 <= px < fbw and 0 <= py < fbh):
            die("probe %s at (%d,%d) is off-screen" % (name, px, py))
        bucket.append((name, px, py, colour))

    add(probes_idle, "desk", desk_x, desk_y, desk)
    add(probes_idle, "fill", fill_px, fill_py, fill)
    add(probes_idle, "sw_desk", desk_px, desk_py, desk)
    add(probes_idle, "sw_bar", bar_px, bar_py, chrome_c)
    add(probes_idle, "sw_title", title_px, title_py, title_c)
    add(probes_idle, "ctl", ctl_px, ctl_py, off)
    add(probes_idle, "border", sx - 1, sy, focus)

    add(probes_armed, "desk", desk_x, desk_y, desk)
    add(probes_armed, "fill", fill_px, fill_py, fill)
    add(probes_armed, "sw_desk", desk_px, desk_py, desk)
    add(probes_armed, "sw_bar", bar_px, bar_py, title_c)
    add(probes_armed, "sw_title", title_px, title_py, title_c)
    add(probes_armed, "ctl", ctl_px, ctl_py, on)
    add(probes_armed, "border", sx - 1, sy, focus)

    print("win_w=%d" % w)
    print("win_h=%d" % h)
    print("surf_x=%d" % sx)
    print("surf_y=%d" % sy)
    print("ctl_area=%d" % ctl_area)
    print("sw_area=%d" % sw_area)
    print("area=%d" % area)
    print("fb_w=%d" % fbw)
    print("fb_h=%d" % fbh)
    print("fb_area=%d" % (fbw * fbh))
    print("chrome_h=%d" % chrome_h)
    print("title_h=%d" % title_h)
    print("chrome_on=%d" % chrome_on)
    print("desk=%d" % desk)
    print("chrome=%d" % chrome_c)
    print("title=%d" % title_c)
    print("surf_fill=%d" % fill)
    print("ctl_off=%d" % off)
    print("ctl_on=%d" % on)
    print("focus=%d" % focus)
    print("border=%d" % border)
    print("flip_scan=%d" % scan)
    print("key_letter=%s" % key_letter)
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
    print("chrome_hex=%08X" % (chrome_c & 0xFFFFFF))
    print("title_hex=%08X" % (title_c & 0xFFFFFF))
    print("fb_line=SET FB %04Xx%04X" % (fbw, fbh))
    # The kernel's fb probe prints MODE <w>x<h>x<bpp> with no spaces.
    print("fb_mode=%04Xx%04X" % (fbw, fbh))
    print("chrome_line=SET CHROME OFF")
    print("desk_line=SET DESK %08X" % (desk & 0xFFFFFF))
    print("bar_line=SET BAR %08X" % (chrome_c & 0xFFFFFF))
    print("title_line=SET TITLE %08X" % (title_c & 0xFFFFFF))
    print("toggle_off_line=SET TOGGLE OFF %08X" % (chrome_c & 0xFFFFFF))
    print("toggle_on_line=SET TOGGLE ON %08X" % (title_c & 0xFFFFFF))
    print("facts_len=%d" % len(blob))
    print("facts_trunc_len=%d" % len(trunc))
    print("facts_hex=%s" % blob.hex())
    print("facts_trunc_hex=%s" % trunc.hex())
    print("idle_probe_count=%d" % len(probes_idle))
    print("armed_probe_count=%d" % len(probes_armed))
    for name, px, py, colour in probes_idle:
        print("idle_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    for name, px, py, colour in probes_armed:
        print("armed_probe=%s %d %d %08X" % (name, px, py, colour & 0xFFFFFF))
    print("control_idle=%s %d %d %08X" % ("ctl_is_not_on", ctl_px, ctl_py, on & 0xFFFFFF))
    print("control_miss=%s %d %d %08X" % ("miss_is_not_on", ctl_px, ctl_py, on & 0xFFFFFF))
    print("control_fill=%s %d %d %08X" % ("fill_is_not_on", fill_px, fill_py, on & 0xFFFFFF))
    print("control_bar_idle=%s %d %d %08X" % ("bar_is_not_title", bar_px, bar_py, title_c & 0xFFFFFF))


if __name__ == "__main__":
    main()
