#!/usr/bin/env python3
"""core/tests/conformance/de-set2/derive.py

Host-side picture for the live-chrome leftover: de-set's model plus the
notify-strip pixels `wm de` paints. The toggle writes CHROME.DAT; the
compositor notices that file and the note colour changes.

    derive.py <set.c> <fb.dart> <wm.dart> <wmchrome.dart> <wmevent.dart> \\
              <kbdq.dart> <wmde.dart>

Exit status: 0 and key=value lines on stdout, 2 on a derivation failure.
"""

import re
import subprocess
import sys


def die(msg):
    print("derive: " + msg, file=sys.stderr)
    raise SystemExit(2)


def dart_ints(path):
    out = {}
    for m in re.finditer(r"^const int (\w+) = (0x[0-9A-Fa-f]+|\d+);$",
                         open(path).read(), re.M):
        out[m.group(1)] = int(m.group(2), 0)
    return out


def main():
    if len(sys.argv) != 8:
        die("usage: derive.py <set.c> <fb.dart> <wm.dart> <wmchrome.dart> "
            "<wmevent.dart> <kbdq.dart> <wmde.dart>")
    setc, fbdart, wmdart, chromedart, evdart, kbdqdart, wmdedart = sys.argv[1:8]
    parent = __import__("os").path.join(
        __import__("os").path.dirname(__import__("os").path.abspath(__file__)),
        "..", "de-set", "derive.py")
    proc = subprocess.run(
        [sys.executable, parent, setc, fbdart, wmdart, chromedart, evdart,
         kbdqdart],
        capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        die("de-set derive.py failed")
    sys.stdout.write(proc.stdout)
    if not proc.stdout.endswith("\n"):
        sys.stdout.write("\n")

    D = dart_ints(wmdedart)
    C = dart_ints(chromedart)
    F = dart_ints(fbdart)
    W = dart_ints(wmdart)
    for k in ("wmNoteW", "wmNoteColor", "wmDeSetColor", "wmDePrefMask",
              "wmStartW", "wmStartColor"):
        if k not in D:
            die("wmde.dart does not define %s" % k)
    for k in ("wmChromeH", "wmChromeColor"):
        if k not in C:
            die("wmchrome.dart does not define %s" % k)
    if "fbWidth" not in F or "fbHeight" not in F:
        die("fb.dart missing geometry")
    if "wmColorDesktop" not in W:
        die("wm.dart missing wmColorDesktop")

    fbw, fbh = F["fbWidth"], F["fbHeight"]
    note_w, chrome_h = D["wmNoteW"], C["wmChromeH"]
    note = D["wmNoteColor"]
    armed = D["wmDeSetColor"]
    desk = W["wmColorDesktop"]
    bar = C["wmChromeColor"]
    start = D["wmStartColor"]
    if note == armed:
        die("idle note colour equals the pref colour — the toggle is vacuous")
    if armed in (desk, bar, start, note):
        die("pref colour collapsed onto desk/bar/start/note")
    if D["wmDePrefMask"] != 0x10:
        die("wmDePrefMask is %#x, expected 0x10" % D["wmDePrefMask"])

    note_x = fbw - note_w + (note_w // 2)
    note_y = fbh - chrome_h + (chrome_h // 2)
    start_x = D["wmStartW"] // 2
    start_y = note_y
    if not (0 <= note_x < fbw and 0 <= note_y < fbh):
        die("note probe (%d,%d) is off-screen" % (note_x, note_y))

    print("note_x=%d" % note_x)
    print("note_y=%d" % note_y)
    print("start_x=%d" % start_x)
    print("start_y=%d" % start_y)
    print("note_hex=%08X" % (note & 0xFFFFFF))
    print("pref_hex=%08X" % (armed & 0xFFFFFF))
    print("start_hex=%08X" % (start & 0xFFFFFF))
    print("note_idle=%s %d %d %08X" % ("note", note_x, note_y, note & 0xFFFFFF))
    print("note_armed=%s %d %d %08X" %
          ("note_pref", note_x, note_y, armed & 0xFFFFFF))
    print("note_not_pref=%s %d %d %08X" %
          ("note_is_not_pref", note_x, note_y, armed & 0xFFFFFF))
    print("note_not_idle=%s %d %d %08X" %
          ("note_is_not_idle", note_x, note_y, note & 0xFFFFFF))
    print("de_line=WM DE SET ON")
    print("pref_name=CHROME.DAT")


if __name__ == "__main__":
    main()
