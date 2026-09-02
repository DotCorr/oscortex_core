#!/usr/bin/env python3
"""core/tests/conformance/hid-sess/derive.py

Host model for ADR-0138. HID usage 0x04 → set-1 0x1E make+break.
Click centre of the single surface. Mouse plant: +DX on X, +DY on Y
(HID Y matches the framebuffer — not PS/2 inverted).

Usage: derive.py <prog.c> <wm.dart> <kbdq.dart> <usb.dart>
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
    m = re.search(r"^#define %s (\d+)UL$" % re.escape(name), text, re.M)
    if not m:
        m = re.search(r"^#define %s (\d+)$" % re.escape(name), text, re.M)
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


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: derive.py <prog.c> <wm.dart> <kbdq.dart> <usb.dart>")
    prog, wmd, kbdq, usbd = sys.argv[1:5]

    win_w = cdefine(prog, "WIN_W")
    win_h = cdefine(prog, "WIN_H")
    win_x = cdefine(prog, "WIN_X")
    win_y = cdefine(prog, "WIN_Y")
    seq_n = cdefine(prog, "SEQ_N")
    sysno = cdefine(prog, "SYS_KBDEVENT")

    border = dartconst(wmd, "wmBorder")
    focus_word = dartconst(wmd, "wmMetaFocus")
    ksys = dartconst(kbdq, "kbdqSysNo")

    usb = open(usbd).read()
    if "usbHidMouseApply" not in usb:
        raise SystemExit("derive: usb.dart has no usbHidMouseApply")
    if "usbHidApply" not in usb:
        raise SystemExit("derive: usb.dart has no usbHidApply")
    # HID usage 0x04 → set-1 0x1E is the table entry usb-hid.md documents.
    m = re.search(r"usbHidUsageSet1 = const \[(.*?)\];", usb, re.S)
    if not m:
        raise SystemExit("derive: no usbHidUsageSet1 table")
    entries = re.findall(r"u8\(0x([0-9A-Fa-f]+)\)", m.group(1))
    if len(entries) < 5:
        raise SystemExit("derive: usage table too short")
    set1_a = int(entries[4], 16)
    if set1_a != 0x1E:
        raise SystemExit("derive: usage 0x04 maps to 0x%02X, expected 0x1E" % set1_a)

    if sysno != ksys or ksys != 24:
        raise SystemExit("derive: kbdevent mismatch")
    if focus_word != 20:
        raise SystemExit("derive: wmMetaFocus is %d, expected 20" % focus_word)
    if seq_n != 2:
        raise SystemExit("derive: SEQ_N is %d, expected 2 (make+break)" % seq_n)

    click_x = win_x + border + win_w // 2
    click_y = win_y + border + win_h // 2
    rels = steps_to(click_x, click_y)
    rels_s = ",".join("rel:%d:%d" % (a, b) for a, b in rels)

    # Make 0x1E, break 0x11E.
    seq = "01E 11E"
    mouse_dx = 0x14  # +20
    mouse_dy = 0x08  # +8 down the screen (HID == framebuffer)
    mouse_btn = 0x00

    print("click_x=%d" % click_x)
    print("click_y=%d" % click_y)
    print("rels_to_click=%s" % rels_s)
    print("seq=%s" % seq)
    print("seq_n=%d" % seq_n)
    print("syscall=%d" % ksys)
    print("hid_usage=04")
    print("set1=%02X" % set1_a)
    print("mouse_dx=%02X" % mouse_dx)
    print("mouse_dy=%02X" % mouse_dy)
    print("mouse_btn=%02X" % mouse_btn)
    print("mouse_hex=%02X%02X%02X" % (mouse_btn, mouse_dx, mouse_dy))


if __name__ == "__main__":
    main()
