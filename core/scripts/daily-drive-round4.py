#!/usr/bin/env python3
"""Drive the Round 4 daily-drive QEMU: FILES+SET, menus, empty/error, stress."""

import json
import os
import re
import socket
import sys
import time

SCREEN_W = int(os.environ.get("DRIVE_W", "800"))
SCREEN_H = int(os.environ.get("DRIVE_H", "600"))


class Qmp:
    def __init__(self, port):
        deadline = time.time() + 25
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
        raise SystemExit("QMP connect failed: %s" % last)

    def cmd(self, execute, **args):
        msg = {"execute": execute}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            obj = json.loads(line)
            if "event" in obj:
                continue
            if "error" in obj:
                raise SystemExit("QMP %s: %s" % (execute, obj["error"]))
            if "return" in obj:
                return obj["return"]

    def key(self, name):
        self.cmd("send-key", keys=[{"type": "qcode", "data": name}])

    def type_line(self, text):
        special = {" ": "spc", ".": "dot", "-": "minus"}
        for ch in text:
            if ch in special:
                self.key(special[ch])
            elif "A" <= ch <= "Z":
                self.cmd("send-key", keys=[
                    {"type": "qcode", "data": "shift"},
                    {"type": "qcode", "data": ch.lower()},
                ])
            else:
                self.key(ch)
        self.key("ret")


def read_serial(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""


def wait_mark(serial, token, marked, timeout=8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = read_serial(serial)
        if token in now[len(marked):]:
            return now
        time.sleep(0.05)
    return ""


def abs_xy(x, y):
    return x * 32767 // max(1, SCREEN_W - 1), y * 32767 // max(1, SCREEN_H - 1)


def place(q, serial, x, y):
    ax, ay = abs_xy(x, y)
    for _ in range(8):
        n = read_serial(serial).count("MOUSE ABS")
        q.cmd("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}])
        t = time.time() + 1.2
        while time.time() < t:
            if read_serial(serial).count("MOUSE ABS") > n:
                return
            time.sleep(0.04)


def button(q, x, y, btn, down):
    ax, ay = abs_xy(x, y)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"button": btn, "down": down}}])


def press(q, serial, x, y, btn, token, timeout=4.0):
    marked = read_serial(serial)
    place(q, serial, x, y)
    time.sleep(0.12)
    button(q, x, y, btn, True)
    got = wait_mark(serial, token, marked, timeout)
    time.sleep(0.08)
    button(q, x, y, btn, False)
    time.sleep(0.25)
    return bool(got)


def shot(q, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    q.cmd("screendump", filename=os.path.abspath(path), format="png")
    print("shot", path, "bytes", os.path.getsize(path) if os.path.exists(path) else 0)


def count_refuse_commit(text):
    return len(re.findall(r"WM REFUSE C 17 OP 0+2 .* R F+8", text))


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: daily-drive-round4.py <qmp-port> <serial> <outdir>")
    port, serial, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art = os.environ.get("ARTIFACTS", "/opt/cursor/artifacts")
    q = Qmp(port)

    deadline = time.time() + 40
    while time.time() < deadline and "oscortex>" not in read_serial(serial):
        time.sleep(0.2)
    if "oscortex>" not in read_serial(serial):
        raise SystemExit("no prompt")

    for line, wait in (
        ("fb", 1.5),
        ("wm on", 2.5),
        ("wm gfx", 1.0),
        ("wm de", 1.0),
        ("wm pace", 0.5),
        ("vtab", 0.4),
        ("proc spawn desk.elf", 2.0),
    ):
        q.type_line(line)
        time.sleep(wait)

    if "DESK READY" not in read_serial(serial):
        wait_mark(serial, "DESK READY", "", 12)

    # FILES from dock (right of Start on 800x600).
    press(q, serial, 592, 572, "left", "FILES CSD", timeout=8)
    time.sleep(0.6)
    # SET from Start row 1.
    press(q, serial, 262, 572, "left", "WM DE START", timeout=4)
    time.sleep(0.3)
    press(q, serial, 40, 500, "left", "SET CSD", timeout=10)
    time.sleep(0.5)

    shot(q, os.path.join(art, "oscortex-round4-800x600.png"))
    shot(q, os.path.join(outdir, "800x600.png"))

    # Both windows reachable: FILES body then SET title.
    press(q, serial, 100, 160, "left", "FILES SEL", timeout=3)
    press(q, serial, 500, 55, "left", "WM FOCUS", timeout=3)

    # Wallpaper / window menus.
    press(q, serial, 700, 200, "right", "WM WALL MENU", timeout=3)
    time.sleep(0.2)
    shot(q, os.path.join(art, "oscortex-round4-menu.png"))
    shot(q, os.path.join(outdir, "menu.png"))
    q.key("esc")
    time.sleep(0.2)
    press(q, serial, 350, 55, "right", "WM WIN MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)
    press(q, serial, 650, 572, "right", "WM DOCK MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)

    # Empty + error sit-ins.
    press(q, serial, 100, 160, "left", "FILES SEL", timeout=3)
    marked = read_serial(serial)
    q.key("v")
    if not wait_mark(serial, "FILES KEY V", marked, 2):
        print("WARN: no FILES KEY V")
    marked = read_serial(serial)
    q.key("ret")
    wait_mark(serial, "FILES EMPTY", marked, 3)
    shot(q, os.path.join(outdir, "empty.png"))
    q.key("esc")
    time.sleep(0.2)
    marked = read_serial(serial)
    q.key("m")
    wait_mark(serial, "FILES KEY M", marked, 2)
    marked = read_serial(serial)
    q.key("ret")
    wait_mark(serial, "FILES ERR", marked, 3)
    shot(q, os.path.join(art, "oscortex-round4-empty-error.png"))
    shot(q, os.path.join(outdir, "error.png"))
    q.key("esc")
    time.sleep(0.2)

    # Cadence: pointer / scroll / drag → WM FRAME.
    latencies = []
    for i in range(8):
        x = 80 + i * 30
        y = 140 + (i % 3) * 20
        marked = read_serial(serial)
        t0 = time.time()
        place(q, serial, x, y)
        got = wait_mark(serial, "WM FRAME", marked, 1.5)
        if got:
            latencies.append((time.time() - t0) * 1000.0)
        time.sleep(0.05)
    # Scroll over FILES.
    place(q, serial, 120, 180)
    button(q, 120, 180, "wheel-down", True)
    time.sleep(0.2)

    # 5-minute max/restore/resize/pointer stress.
    stress_start = time.time()
    cycles = 0
    while time.time() - stress_start < 300:
        press(q, serial, 379, 57, "left", "WM MAX", timeout=2.5)
        time.sleep(0.15)
        press(q, serial, 728, 20, "left", "WM MAX", timeout=2.5)
        time.sleep(0.15)
        place(q, serial, 80 + (cycles % 20) * 12, 160)
        time.sleep(0.05)
        button(q, 440, 312, "left", True)
        place(q, serial, 790, 590)
        time.sleep(0.08)
        button(q, 790, 590, "left", False)
        cycles += 1
        if cycles % 8 == 0:
            press(q, serial, 100, 160, "left", "FILES SEL", timeout=1.5)
            press(q, serial, 500, 55, "left", "WM FOCUS", timeout=1.5)

    text = read_serial(serial)
    refuse = count_refuse_commit(text)
    commits = len(re.findall(r"^WM COMMIT ", text, re.M))
    frames = len(re.findall(r"^WM FRAME ", text, re.M))
    metrics = {
        "screen": [SCREEN_W, SCREEN_H],
        "stress_cycles": cycles,
        "stress_secs": round(time.time() - stress_start, 1),
        "commit_badgeom_refusals": refuse,
        "commits": commits,
        "frames": frames,
        "event_to_present_ms": latencies,
        "event_to_present_ms_max": max(latencies) if latencies else None,
        "event_to_present_ms_avg": (
            round(sum(latencies) / len(latencies), 1) if latencies else None),
        "files_empty": "FILES EMPTY" in text,
        "files_err": "FILES ERR" in text,
        "set_csd": "SET CSD" in text,
        "win_menu": "WM WIN MENU" in text,
        "wall_menu": "WM WALL MENU" in text,
        "dock_menu": "WM DOCK MENU" in text,
    }
    open(os.path.join(outdir, "metrics.json"), "w").write(
        json.dumps(metrics, indent=2) + "\n")
    print(json.dumps(metrics, indent=2))
    if refuse:
        raise SystemExit("COMMIT bad-geom refusals: %d" % refuse)
    if commits < 1:
        raise SystemExit("no commits — refuse gate would be vacuous")
    return 0


if __name__ == "__main__":
    sys.exit(main())
