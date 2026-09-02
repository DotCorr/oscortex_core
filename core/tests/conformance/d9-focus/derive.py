#!/usr/bin/env python3
"""core/tests/conformance/d9-focus/derive.py

Host model for D9. Reads geometry out of prog.c and the syscall / focus
word out of the kernel, then computes:

  * a click that is inside surface B and outside surface A
    (stacking order must not decide who is focused)
  * the relative-motion script that reaches that point from (0,0)
  * the packed make+break sequence QEMU's send-key will produce for
    the injected letters, from scan-code set 1 -- not imported from
    the kernel

Never imports the kernel's functions. If the two sources disagree, one
is wrong and this file refuses to emit expectations.

Usage: derive.py <prog.c> <wm.dart> <kbdq.dart>
"""

import re
import sys

# Scan-code set 1 make codes, derived from the XT chart the 8042 emits
# under QEMU (translation on). Same table d2-input uses.
SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
}


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


def pack(make, brk):
    return make | (0x100 if brk else 0)


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: derive.py <prog.c> <wm.dart> <kbdq.dart>")
    prog, wmd, kbdq = sys.argv[1:4]

    win_w = cdefine(prog, "WIN_W")
    win_h = cdefine(prog, "WIN_H")
    a_x = cdefine(prog, "A_X")
    a_y = cdefine(prog, "A_Y")
    b_x = cdefine(prog, "B_X")
    b_y = cdefine(prog, "B_Y")
    seq_n = cdefine(prog, "SEQ_N")
    sysno = cdefine(prog, "SYS_KBDEVENT")

    border = dartconst(wmd, "wmBorder")
    focus_word = dartconst(wmd, "wmMetaFocus")
    ksys = dartconst(kbdq, "kbdqSysNo")
    kdepth = dartconst(kbdq, "kbdqDepth")
    kstore = dartconst(kbdq, "kbdqStoreBytes")

    if sysno != ksys:
        raise SystemExit("derive: prog.c SYS_KBDEVENT is %d, kernel is %d"
                         % (sysno, ksys))
    if ksys != 24:
        raise SystemExit("derive: kbdevent is %d, expected 24" % ksys)
    if focus_word != 20:
        raise SystemExit("derive: wmMetaFocus is %d, expected 20 (chrome is 19)"
                         % focus_word)
    if seq_n != 6:
        raise SystemExit("derive: SEQ_N is %d, expected 6 (xyz make+break)"
                         % seq_n)

    keys = "xyz"
    want = []
    for k in keys:
        want.append(pack(SET1[k], 0))
        want.append(pack(SET1[k], 1))
    if len(want) != seq_n:
        raise SystemExit("derive: packed sequence length %d != SEQ_N %d"
                         % (len(want), seq_n))

    # Exclusive to B: right of A's right edge and below A's bottom,
    # still inside B. Stacking order cannot steal this click.
    click_x = b_x + (win_w * 3) // 4
    click_y = b_y + (win_h * 3) // 4
    if not (b_x <= click_x < b_x + win_w and b_y <= click_y < b_y + win_h):
        raise SystemExit("derive: click is not inside surface B")
    if a_x <= click_x < a_x + win_w and a_y <= click_y < a_y + win_h:
        raise SystemExit("derive: click is inside surface A — exclusive "
                         "B is the point of the test")

    to_click = steps_to(click_x, click_y)

    def rels(steps):
        return ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps)

    def hex3(v):
        return "%03X" % v

    print("syscall=%d" % sysno)
    print("focus_word=%d" % focus_word)
    print("win_w=%d" % win_w)
    print("win_h=%d" % win_h)
    print("a_x=%d" % a_x)
    print("a_y=%d" % a_y)
    print("b_x=%d" % b_x)
    print("b_y=%d" % b_y)
    print("border=%d" % border)
    print("click_x=%d" % click_x)
    print("click_y=%d" % click_y)
    print("rels_to_click=%s" % rels(to_click))
    print("keys=%s" % keys)
    print("seq_n=%d" % seq_n)
    print("seq=%s" % " ".join(hex3(v) for v in want))
    print("store_bytes=%d" % kstore)
    print("depth=%d" % kdepth)


if __name__ == "__main__":
    main()
