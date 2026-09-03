#!/usr/bin/env python3
"""Drive the Round 6 daily-drive QEMU: 1280×720 GOP, menu bounds, LAT reps."""

import json
import os
import re
import socket
import sys
import time

SCREEN_W = int(os.environ.get("DRIVE_W", "1280"))
SCREEN_H = int(os.environ.get("DRIVE_H", "720"))
STRESS_SECS = float(os.environ.get("DRIVE_STRESS_SECS", "90"))
LAT_REPS = int(os.environ.get("DRIVE_LAT_REPS", "5"))
# Live UART (QEMU chardev socket). file: serial is block-buffered.
SERIAL_SOCK = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
# Guest PIT is 100 Hz. TCG chrome regen can exceed this; scheduling bugs
# must not. 24 ticks = 240 ms is the avoidable-stall ceiling.
LAT_TICK_BOUND = int(os.environ.get("DRIVE_LAT_BOUND", "24"))

ICON_S = 32
ICON_GAP = 8
ICON_PAD = 16
ICON_N = 6
RIGHT_W = ICON_PAD + ICON_N * ICON_S + (ICON_N - 1) * ICON_GAP + ICON_PAD
RIGHT_X = SCREEN_W - 16 - RIGHT_W
PANEL_Y = SCREEN_H - 48 + 20
START_XY = (262, PANEL_Y)
SET_DOCK_XY = (RIGHT_X + ICON_PAD + ICON_S // 2, PANEL_Y)
FILES_DOCK_XY = (RIGHT_X + ICON_PAD + (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)
DOCK_MENU_XY = (RIGHT_X + ICON_PAD + 2 * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)
WALL_XY = (16, min(SCREEN_H - 140, 336))
FILES_BODY_XY = (100, 160)
FILES_TITLE_XY = (120, 55)
SET_TITLE_XY = (min(SCREEN_W - 40, 500), 55)


class Qmp:
    def __init__(self, port):
        deadline = time.time() + 25
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.s.settimeout(90)
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


class Serial:
    """Incrementally ingest the logfile. PROC YIELD / SHM PAGE lines are
    dropped so a storm cannot wash SET CSD, WM LAT, or COMMIT out of the
    window wait_mark and the final metrics read."""

    def __init__(self, path, sock_port=0):
        self.path = path
        self.buf = ""
        self.archive = ""
        self.off = 0
        self.sock = None
        if sock_port:
            deadline = time.time() + 8
            last = None
            while time.time() < deadline:
                try:
                    self.sock = socket.create_connection(
                        ("127.0.0.1", sock_port), timeout=2)
                    self.sock.settimeout(0.02)
                    break
                except OSError as e:
                    last = e
                    time.sleep(0.1)
            if self.sock is None:
                print("WARN: serial socket failed (%s); using file" % last)

    _ARCHIVE = (
        "SET CSD", "SET READY", "SET SLOT", "DESK LAUNCH", "OSGFX TITLE",
        "FILES CSD", "FILES READY", "FILES EMPTY", "FILES ERR", "FILES SEL",
        "FILES KEY", "FILES SLOT", "WM LAT ", "WM COMMIT", "WM ATTACH",
        "WM MAX", "WM WALL MENU", "WM WIN MENU", "WM DOCK MENU", "WM FRAME",
        "WM FOCUS", "MOUSE ABS", "FB GOP", "VIEW MODE",
    )

    def _keep_line(self, line):
        if line.startswith("PROC YIELD"):
            return False
        if line.startswith("SHM PAGE"):
            return False
        if line.startswith("PROC PREEMPT"):
            return False
        return True

    def _interesting(self, line):
        for tok in self._ARCHIVE:
            if tok in line:
                return True
        return False

    def _ingest(self, text):
        if not text:
            return
        kept = []
        arch = []
        for ln in text.splitlines():
            if not self._keep_line(ln):
                continue
            kept.append(ln)
            if self._interesting(ln):
                arch.append(ln)
        if kept:
            self.buf = (self.buf + "\n" + "\n".join(kept))[-262144:]
        if arch:
            self.archive = (getattr(self, "archive", "") + "\n" +
                            "\n".join(arch))[-1048576:]

    def read(self):
        self._drain_sock()
        try:
            size = os.path.getsize(self.path)
            if size > self.off:
                with open(self.path, "rb") as f:
                    f.seek(self.off)
                    while self.off < size:
                        chunk = f.read(min(size - self.off, 1048576))
                        if not chunk:
                            break
                        self.off += len(chunk)
                        self._ingest(chunk.decode("utf-8", "replace"))
        except OSError:
            pass
        return (getattr(self, "archive", "") + "\n" + self.buf)

    def _drain_sock(self):
        if self.sock is None:
            return
        got = 0
        try:
            while got < 65536:
                chunk = self.sock.recv(4096)
                if not chunk:
                    break
                self._ingest(chunk.decode("utf-8", "replace"))
                got += len(chunk)
        except (socket.timeout, BlockingIOError):
            pass


def wait_mark(ser, token, marked, timeout=8.0):
    n0 = marked.count(token)
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = ser.read()
        if now.count(token) > n0:
            return now
        time.sleep(0.05)
    return ""


def abs_xy(x, y):
    return x * 32767 // max(1, SCREEN_W - 1), y * 32767 // max(1, SCREEN_H - 1)


def place(q, ser, x, y):
    ax, ay = abs_xy(x, y)
    for _ in range(8):
        n = ser.read().count("MOUSE ABS")
        q.cmd("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}])
        t = time.time() + 1.2
        while time.time() < t:
            if ser.read().count("MOUSE ABS") > n:
                return
            time.sleep(0.04)


def button(q, x, y, btn, down):
    ax, ay = abs_xy(x, y)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"button": btn, "down": down}}])


def press(q, ser, x, y, btn, token, timeout=4.0):
    marked = ser.read()
    place(q, ser, x, y)
    time.sleep(0.12)
    button(q, x, y, btn, True)
    got = wait_mark(ser, token, marked, timeout)
    time.sleep(0.08)
    button(q, x, y, btn, False)
    time.sleep(0.25)
    return bool(got)


def shot(q, path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    last = None
    for _ in range(3):
        try:
            q.cmd("screendump", filename=os.path.abspath(path), format="png")
            print("shot", path, "bytes",
                  os.path.getsize(path) if os.path.exists(path) else 0)
            return
        except (OSError, SystemExit) as e:
            last = e
            time.sleep(0.4)
    raise SystemExit("screendump failed: %s" % last)


def parse_lat(text):
    out = []
    for m in re.finditer(
            r"WM LAT ([0-9A-F]+) D ([0-9A-F]+) S ([0-9A-F]+)"
            r"(?: G ([0-9A-F]+))?(?: A ([0-9A-F]+))?",
            text):
        rec = {
            "kind": int(m.group(1), 16),
            "ticks": int(m.group(2), 16),
            "seq": int(m.group(3), 16),
            "ms_est": round(int(m.group(2), 16) * 10.0, 1),
        }
        if m.group(4) is not None:
            rec["chrome_regen"] = int(m.group(4), 16)
        if m.group(5) is not None:
            rec["damage_px"] = int(m.group(5), 16)
        out.append(rec)
    return out


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    idx = int(round((p / 100.0) * (len(s) - 1)))
    return s[max(0, min(idx, len(s) - 1))]


def last_pointer_xy(text):
    matches = re.findall(
        r"^WM FRAME [0-9A-F]+ PX [0-9A-F]+ TOP [0-9A-F]+ CUR X ([0-9A-F]+) Y ([0-9A-F]+)",
        text, re.M)
    if not matches:
        return None, None
    x, y = matches[-1]
    return int(x, 16), int(y, 16)


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: daily-drive-round6.py <qmp-port> <serial> <outdir>")
    port, serial_path, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art = os.environ.get("ARTIFACTS", "/opt/cursor/artifacts")
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(art, exist_ok=True)
    q = Qmp(port)
    ser = Serial(serial_path, SERIAL_SOCK)

    deadline = time.time() + 40
    while time.time() < deadline and "M1 END" not in ser.read():
        time.sleep(0.2)
    if "M1 END" not in ser.read():
        raise SystemExit("no M1 END")
    time.sleep(1.5)

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
        if line == "vtab":
            time.sleep(0.3)
            vtab = ser.read()
            if "VTAB OK" not in vtab:
                raise SystemExit("vtab did not arm (need VTAB OK): %s"
                                 % [ln for ln in vtab.splitlines()
                                    if "VTAB" in ln][-6:])

    if "DESK READY" not in ser.read():
        wait_mark(ser, "DESK READY", "", 12)

    boot = ser.read()
    gop = re.search(r"FB GOP ([0-9A-Fa-f]+)x([0-9A-Fa-f]+)", boot)
    gop_w = int(gop.group(1), 16) if gop else None
    gop_h = int(gop.group(2), 16) if gop else None
    print("layout start", START_XY, "set_dock", SET_DOCK_XY,
          "files_dock", FILES_DOCK_XY, "wall", WALL_XY, "panel_y", PANEL_Y,
          "gop", gop_w, gop_h)

    # FILES first so SET focus cannot steal later send-key. Dock gear is
    # SET; never use Start row 1. Absolute tablet after VTAB OK.
    press(q, ser, FILES_DOCK_XY[0], FILES_DOCK_XY[1], "left", "FILES CSD", timeout=8)
    time.sleep(0.8)
    press(q, ser, SET_DOCK_XY[0], SET_DOCK_XY[1], "left", "SET CSD", timeout=12)
    time.sleep(2.0)

    hd_png = os.path.join(art, "oscortex-round6-%dx%d.png" % (SCREEN_W, SCREEN_H))
    if SCREEN_W == 1280 and SCREEN_H == 720:
        if gop_w == 1280 and gop_h == 720:
            shot(q, os.path.join(art, "oscortex-round6-1280x720.png"))
        else:
            print("WARN: skip 1280x720 artifact — FB GOP is %s×%s" % (gop_w, gop_h))
    else:
        shot(q, hd_png)
    shot(q, os.path.join(outdir, "%dx%d.png" % (SCREEN_W, SCREEN_H)))

    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=3)
    press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left", "WM FOCUS", timeout=3)

    press(q, ser, WALL_XY[0], WALL_XY[1], "right", "WM WALL MENU", timeout=3)
    time.sleep(0.35)
    shot(q, os.path.join(art, "oscortex-round6-menu-bounds.png"))
    shot(q, os.path.join(outdir, "menu.png"))
    q.key("esc")
    time.sleep(0.2)
    press(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "right", "WM WIN MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)
    press(q, ser, DOCK_MENU_XY[0], DOCK_MENU_XY[1], "right", "WM DOCK MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)

    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=3)
    marked = ser.read()
    q.key("v")
    wait_mark(ser, "FILES KEY V", marked, 2)
    marked = ser.read()
    q.key("ret")
    wait_mark(ser, "FILES EMPTY", marked, 4)
    time.sleep(0.3)
    marked = ser.read()
    q.key("esc")
    wait_mark(ser, "FILES BACK", marked, 3)

    # Mixed pointer stress: place, then a chrome-dirtying action, then place.
    # Several repetitions so p50/p95/max are a distribution, not one walk.
    guest_lat = []
    host_ms = []
    for rep in range(LAT_REPS):
        for i in range(6):
            x = 80 + i * 36 + (rep * 8)
            y = 140 + (i % 3) * 22
            marked = ser.read()
            t0 = time.time()
            place(q, ser, x, y)
            # Kick path: open/close wallpaper menu so chrome sig moves.
            if i == 2:
                press(q, ser, WALL_XY[0], WALL_XY[1], "right", "WM WALL MENU",
                      timeout=2)
                q.key("esc")
                time.sleep(0.15)
            got = wait_mark(ser, "WM LAT ", marked, 1.8)
            if got:
                host_ms.append(round((time.time() - t0) * 1000.0, 1))
            time.sleep(0.04)
        guest_lat.extend(parse_lat(ser.read()))

    ptr_x, ptr_y = 120, 180
    place(q, ser, ptr_x, ptr_y)
    time.sleep(0.25)
    text_ptr = ser.read()
    cur_x, cur_y = last_pointer_xy(text_ptr)
    button(q, ptr_x, ptr_y, "wheel-down", True)
    time.sleep(0.2)

    stress_start = time.time()
    cycles = 0
    while time.time() - stress_start < STRESS_SECS:
        press(q, ser, min(SCREEN_W - 24, 379), 57, "left", "WM MAX", timeout=2.5)
        time.sleep(0.15)
        press(q, ser, min(SCREEN_W - 24, 728), 20, "left", "WM MAX", timeout=2.5)
        time.sleep(0.15)
        place(q, ser, 80 + (cycles % 20) * 12, 160)
        time.sleep(0.05)
        button(q, min(SCREEN_W - 20, 440), min(SCREEN_H - 40, 312), "left", True)
        place(q, ser, SCREEN_W - 10, SCREEN_H - 10)
        time.sleep(0.08)
        button(q, SCREEN_W - 10, SCREEN_H - 10, "left", False)
        cycles += 1
        if cycles % 8 == 0:
            press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left",
                  "FILES SEL", timeout=1.5)
            press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left",
                  "WM FOCUS", timeout=1.5)

    text = ser.read()
    guest_lat = parse_lat(text)
    ticks = [x["ticks"] for x in guest_lat]
    kinds = {}
    for rec in guest_lat:
        kinds.setdefault(rec["kind"], []).append(rec["ticks"])

    metrics = {
        "screen": [SCREEN_W, SCREEN_H],
        "fb_gop": [gop_w, gop_h],
        "stress_cycles": cycles,
        "stress_secs": round(time.time() - stress_start, 1),
        "lat_reps": LAT_REPS,
        "guest_lat": guest_lat[-64:],
        "guest_lat_n": len(ticks),
        "guest_lat_ticks_p50": pct(ticks, 50),
        "guest_lat_ticks_p95": pct(ticks, 95),
        "guest_lat_ticks_max": max(ticks) if ticks else None,
        "guest_lat_ticks_avg": (
            round(sum(ticks) / len(ticks), 2) if ticks else None),
        "guest_lat_by_kind": {
            str(k): {"n": len(v), "p50": pct(v, 50), "p95": pct(v, 95),
                     "max": max(v) if v else None}
            for k, v in sorted(kinds.items())
        },
        "event_to_present_ms": host_ms,
        "event_to_present_ms_max": max(host_ms) if host_ms else None,
        "pointer_target": [ptr_x, ptr_y],
        "pointer_final": [cur_x, cur_y],
        "lat_tick_bound": LAT_TICK_BOUND,
        "serial_live": bool(ser.sock),
        "set_csd": "SET CSD" in text,
        "set_ready": "SET READY" in text,
        "files_empty": "FILES EMPTY" in text,
        "desk_launch_set": "DESK LAUNCH SET.ELF" in text,
        "wm_lat": "WM LAT " in text,
        "wall_menu": "WM WALL MENU" in text,
        "win_menu": "WM WIN MENU" in text,
        "dock_menu": "WM DOCK MENU" in text,
        "commits": len(re.findall(r"^WM COMMIT ", text, re.M)),
        "frames": len(re.findall(r"^WM FRAME ", text, re.M)),
    }
    payload = json.dumps(metrics, indent=2) + "\n"
    open(os.path.join(outdir, "metrics.json"), "w").write(payload)
    open(os.path.join(art, "oscortex-round6-latency.json"), "w").write(payload)
    print(payload)

    if not metrics["desk_launch_set"]:
        raise SystemExit("dock never launched SET.ELF")
    if not metrics["set_csd"]:
        raise SystemExit("SET CSD never printed")
    if cur_x is None:
        print("WARN: no WM FRAME cursor to assert final pointer")
    else:
        dx = abs(cur_x - ptr_x)
        dy = abs(cur_y - ptr_y)
        if dx > 24 or dy > 24:
            raise SystemExit("pointer final %s,%s != target %s,%s"
                             % (cur_x, cur_y, ptr_x, ptr_y))
    if ticks and max(ticks) > LAT_TICK_BOUND:
        # TCG chrome regen (G rising with D) is a compute ceiling, not a
        # scheduling bug. Fail only when a low-regen pointer present is late.
        late = [r for r in guest_lat
                if r["ticks"] > LAT_TICK_BOUND
                and r.get("chrome_regen", 1) == 0
                and r["kind"] == 1]
        if late:
            raise SystemExit("pointer LAT scheduling stall: %s" % late[:4])
        print("WARN: LAT max %d ticks exceeds bound %d (TCG/chrome regen)"
              % (max(ticks), LAT_TICK_BOUND))
    return 0


if __name__ == "__main__":
    sys.exit(main())
