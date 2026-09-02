#!/usr/bin/env python3
"""core/tests/conformance/frame3/derive.py

Host-side picture for FRAME3: geometry and colours from surf.c, desktop
from wm.dart, set-1 scancodes from the XT chart (not the kernel). The
persist record is THEME_BYTES of the last key's fill colour.

    derive.py <surf.c> <wm.dart>

Exit status: 0 and key=value lines on stdout, 2 on a derivation failure.
"""

import re
import sys

# Scan-code set 1 make codes, derived from the XT chart the 8042 emits
# under QEMU (translation on). Same table d2-input / d9-focus use.
SET1 = {
    "a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12,
    "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17, "j": 0x24,
    "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18,
    "p": 0x19, "q": 0x10, "r": 0x13, "s": 0x1F, "t": 0x14,
    "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15,
    "z": 0x2C,
}


def die(msg):
    print("derive: " + msg, file=sys.stderr)
    raise SystemExit(2)


def c_defs(path):
    out = {}
    for m in re.finditer(r"^#define\s+([A-Z_0-9]+)\s+(0[xX][0-9A-Fa-f]+|\d+)U?L?$",
                         open(path).read(), re.M):
        out[m.group(1)] = int(m.group(2), 0)
    return out


def c_str(path, name):
    text = open(path).read()
    m = re.search(r'^#define\s+%s\s+"([^"]+)"' % re.escape(name), text, re.M)
    if not m:
        die("surf.c does not define string %s" % name)
    return m.group(1)


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
            die("cannot step (%d,%d)" % (dx, dy))
        out.append((sx, sy))
        x -= sx
        y -= sy
    return out


def main():
    if len(sys.argv) != 3:
        die("usage: derive.py <surf.c> <wm.dart>")
    surfc, wmdart = sys.argv[1], sys.argv[2]
    P = c_defs(surfc)
    W = dart_ints(wmdart)
    for k in ("WIN_W", "WIN_H", "SURF_X", "SURF_Y", "SURF_FILL", "SURF_INK",
              "INK_INSET", "WIN_PAGES", "KEY_A", "KEY_C", "COLOUR_A",
              "COLOUR_C", "THEME_BYTES"):
        if k not in P:
            die("surf.c does not define %s" % k)
    for k in ("wmColorDesktop", "wmBorder", "wmColorFocus"):
        if k not in W:
            die("wm.dart does not define %s" % k)

    theme = c_str(surfc, "THEME_FILE")
    if "." in theme:
        stem, ext = theme.split(".", 1)
    else:
        stem, ext = theme, ""
    if len(stem) > 8 or len(ext) > 3:
        die("THEME_FILE %r is not an 8.3 name" % theme)

    w, h = P["WIN_W"], P["WIN_H"]
    x, y = P["SURF_X"], P["SURF_Y"]
    inset = P["INK_INSET"]
    fill, ink = P["SURF_FILL"], P["SURF_INK"]
    ca, cc = P["COLOUR_A"], P["COLOUR_C"]
    key_a, key_c = P["KEY_A"], P["KEY_C"]
    persist_bytes = P["THEME_BYTES"]
    desk = W["wmColorDesktop"]
    border = W["wmBorder"]
    focus = W["wmColorFocus"]
    fbw, fbh = 800, 600

    if persist_bytes != 4:
        die("THEME_BYTES is %d; FRAME3 persists a u32 (4 bytes)" % persist_bytes)
    # The APP1/M16 sizeof-buf control: a write of a 64-byte buffer is not 4.
    sizeof_buf = 64
    if sizeof_buf == persist_bytes:
        die("sizeof-buf control is vacuous: %d == THEME_BYTES" % sizeof_buf)

    if key_a != SET1["a"]:
        die("KEY_A is 0x%X, set-1 'a' is 0x%X" % (key_a, SET1["a"]))
    if key_c != SET1["c"]:
        die("KEY_C is 0x%X, set-1 'c' is 0x%X" % (key_c, SET1["c"]))
    if key_a == key_c:
        die("KEY_A equals KEY_C — two keys cannot prove the queue")

    area = w * h
    if area <= 0:
        die("expected surface area is %d pixels — anti-vacuity" % area)
    if ca == cc:
        die("COLOUR_A equals COLOUR_C — two keys would paint one colour")
    if ca == fill or cc == fill:
        die("a key colour equals SURF_FILL — the nokbd control would be vacuous")
    if ca == desk or cc == desk or fill == desk:
        die("a fill colour equals the desktop")
    if ink == ca or ink == cc or ink == fill:
        die("SURF_INK collides with a fill colour")
    if x < border or y < border:
        die("surface origin (%d,%d) does not leave room for the %d-px border"
            % (x, y, border))
    if x + w + border > fbw or y + h + border > fbh:
        die("surface (%d,%d) %dx%d plus border does not fit %dx%d"
            % (x, y, w, h, fbw, fbh))

    # Click in the FILL ring, not the ink block and not the cursor's
    # resting pixel at the ink probe. A click on the ink centre paints
    # the cursor over the one pixel that proves the blit.
    click_x = x + 8
    click_y = y + 8
    if not (x <= click_x < x + w and y <= click_y < y + h):
        die("click (%d,%d) is not inside the surface" % (click_x, click_y))
    if inset <= (click_x - x) < (w - inset) and inset <= (click_y - y) < (h - inset):
        die("click (%d,%d) is inside the ink block" % (click_x, click_y))
    rels = ",".join("rel:%d:%d" % (dx, dy) for dx, dy in steps_to(click_x, click_y))

    probes = []

    def add(name, sx, sy, colour):
        if not (0 <= sx < fbw and 0 <= sy < fbh):
            die("probe %s at (%d,%d) is off-screen" % (name, sx, sy))
        probes.append((name, sx, sy, colour))

    add("desk", 20, 20, desk)
    add("fill", x + 4, y + 4, cc)
    add("ink", x + w // 2, y + h // 2, ink)
    add("border", x - 1, y, focus)

    print("win_w=%d" % w)
    print("win_h=%d" % h)
    print("surf_x=%d" % x)
    print("surf_y=%d" % y)
    print("surf_fill=%d" % fill)
    print("colour_a=%d" % ca)
    print("colour_c=%d" % cc)
    print("desk=%d" % desk)
    print("area=%d" % area)
    print("key_a=%d" % key_a)
    print("key_c=%d" % key_c)
    print("keys=ac")
    print("theme_file=%s" % theme)
    print("persist_bytes=%d" % persist_bytes)
    print("sizeof_buf=%d" % sizeof_buf)
    print("click_x=%d" % click_x)
    print("click_y=%d" % click_y)
    print("rels_to_click=%s" % rels)
    print("probe_count=%d" % len(probes))
    print("surf_fill_hex=%08X" % (fill & 0xFFFFFF))
    print("colour_a_hex=%08X" % (ca & 0xFFFFFF))
    print("colour_c_hex=%08X" % (cc & 0xFFFFFF))
    print("desk_hex=%08X" % (desk & 0xFFFFFF))
    print("ink_hex=%08X" % (ink & 0xFFFFFF))
    print("focus_hex=%08X" % (focus & 0xFFFFFF))
    for name, sx, sy, colour in probes:
        print("probe=%s %d %d %08X" % (name, sx, sy, colour & 0xFFFFFF))
    print("nokbd_fill=%d %d %08X" % (x + 4, y + 4, fill & 0xFFFFFF))


if __name__ == "__main__":
    main()
