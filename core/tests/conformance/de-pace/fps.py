#!/usr/bin/env python3
"""core/tests/conformance/de-pace/fps.py

Boots the kernel, types `fb` / `wm on` / `wm gfx` / `wm de` / `wm fps`, and
prints ADR-0188's before/after table out of the `WM FPS` lines.

    fps.py <qmp-port> <serial>

The before/after is the SAME BINARY, the same host and the same resolution:
`K 8` and `K 9` clear the wallpaper cache before every iteration, so they do
what the code did before ADR-0188, and `K 3` and `K 5` are the same two
stages with the cache serving them. See wmfps.dart.
"""

import json
import os
import re
import socket
import sys
import time

TICK_MS = 10.0  # the PIT is 100 Hz (pitInit)

STAGES = [
    (0, "serial line  (one WM FRAME-shaped line)"),
    (1, "fbFill       (a plain store per pixel)"),
    (2, "client blit  (every window, bottom-up)"),
    (8, "wallpaper    BEFORE  (field maths per frame)"),
    (3, "wallpaper    AFTER   (blit from cache)"),
    (13, "session tick BEFORE  (chrome + gradient per tick)"),
    (11, "session tick        (chrome per tick, band cached)"),
    (4, "session tick AFTER   (blit from chrome cache)"),
    (9, "FULL FRAME   ADR-0188 before (field per frame)"),
    (12, "FULL FRAME   a chrome CHANGE (repaint + present)"),
    (5, "FULL FRAME   AFTER   (all cached)"),
    (10, "PACED FRAME  AFTER   (64x64 damage present)"),
    (6, "session tick, solid wallpaper"),
]


class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("could not connect to QMP: %s" % last)

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    raise SystemExit("QMP %s: %s" % (execute, msg["error"]))
                return msg["return"]

    def line(self, text):
        for ch in text + "\n":
            code = {" ": "spc", "\n": "ret"}.get(ch, ch.lower())
            self.cmd("send-key", keys=[{"type": "qcode", "data": code}])
            time.sleep(0.03)


def serial(path):
    if not os.path.exists(path):
        return ""
    return open(path, "r", encoding="latin-1", errors="replace").read()


def wait(path, marker, timeout=90, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if serial(path).count(marker) >= at_least:
            return True
        time.sleep(0.2)
    return False


FPS_RE = re.compile(r"^WM FPS K ([0-9A-F]) N ([0-9A-F]{8}) T ([0-9A-F]{8})",
                    re.M)


def main():
    port, ser = int(sys.argv[1]), sys.argv[2]
    q = Qmp(port)
    if not wait(ser, "M1 END\n"):
        raise SystemExit("kernel never reached the prompt")
    time.sleep(0.5)
    q.line("fb")
    time.sleep(1.5)
    q.line("wm on")
    time.sleep(2.5)
    q.line("wm gfx")
    time.sleep(3.0)
    q.line("wm de")
    time.sleep(2.0)
    if not wait(ser, "OSGFX DESK GEN\n"):
        raise SystemExit("the generative desk never ran")
    q.line("wm fps")
    # Nine stages at a 1.2 s budget each, plus whatever a single slow
    # iteration overruns by.
    if not wait(ser, "WM FPS K 6", timeout=420):
        raise SystemExit("wm fps never reached its last stage")
    time.sleep(1.0)

    got = {}
    for k, n, t in FPS_RE.findall(serial(ser)):
        got.setdefault(int(k, 16), []).append((int(n, 16), int(t, 16)))

    print()
    print("=== wm fps, 800x600, qemu64 TCG, stdvga ===")
    print("%-46s %7s %7s %10s %9s" % ("stage", "iters", "ticks", "ms/iter",
                                      "per-sec"))
    ms = {}
    for kind, label in STAGES:
        runs = got.get(kind)
        if not runs:
            print("%-46s %7s" % (label, "MISSING"))
            continue
        n, t = runs[-1]
        per = (t * TICK_MS) / n if n else float("nan")
        ms[kind] = per
        print("%-46s %7d %7d %10.3f %9.1f"
              % (label, n, t, per, (1000.0 / per) if per > 0 else float("inf")))

    print()
    if 8 in ms and 3 in ms:
        print("wallpaper: %.1f ms -> %.3f ms  (%.0fx)"
              % (ms[8], ms[3], ms[8] / ms[3] if ms[3] else float("inf")))
    if 13 in ms and 4 in ms:
        print("session tick: %.1f ms -> %.3f ms  (%.0fx)"
              % (ms[13], ms[4], ms[13] / ms[4] if ms[4] else float("inf")))
    if 13 in ms and 11 in ms:
        print("a chrome REPAINT (what a raise/focus/popover pays):")
        print("            %.1f ms (%.1f fps) -> %.2f ms (%.0f fps)  (%.0fx) "
              "-- the taskbar gradient band cache"
              % (ms[13], 1000.0 / ms[13], ms[11],
                 (1000.0 / ms[11]) if ms[11] else float("inf"),
                 ms[13] / ms[11] if ms[11] else float("inf")))
    if 5 in ms:
        print("a FULL COMPOSE with nothing changed: %.3f ms (%.0f fps)"
              % (ms[5], 1000.0 / ms[5] if ms[5] else float("inf")))
    if 9 in ms and 10 in ms:
        print("a CLIENT UPDATE, which is what the gfx arm used to turn into a "
              "full compose:")
        print("            %.1f ms (%.2f fps) -> %.3f ms (%.0f fps)  (%.0fx)"
              % (ms[9], 1000.0 / ms[9], ms[10],
                 (1000.0 / ms[10]) if ms[10] else float("inf"),
                 (ms[9] / ms[10]) if ms[10] else float("inf")))
    q.cmd("quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
