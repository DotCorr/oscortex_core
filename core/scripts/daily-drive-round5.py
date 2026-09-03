#!/usr/bin/env python3
"""Drive the Round 5 daily-drive QEMU: identity, 168x80 menu, guest LAT."""

import json
import os
import re
import socket
import sys
import time

SCREEN_W = int(os.environ.get("DRIVE_W", "800"))
SCREEN_H = int(os.environ.get("DRIVE_H", "600"))
STRESS_SECS = float(os.environ.get("DRIVE_STRESS_SECS", "90"))
# Live UART (QEMU chardev socket). file: serial is block-buffered.
SERIAL_SOCK = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))

# DESK glass dock (desk.c): right island + 32px icons, 48px panel.
ICON_S = 32
ICON_GAP = 8
ICON_PAD = 16
ICON_N = 6
RIGHT_W = ICON_PAD + ICON_N * ICON_S + (ICON_N - 1) * ICON_GAP + ICON_PAD
RIGHT_X = SCREEN_W - 16 - RIGHT_W
PANEL_Y = SCREEN_H - 48 + 20
START_XY = (262, PANEL_Y)
FILES_DOCK_XY = (RIGHT_X + ICON_PAD + (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)
DOCK_MENU_XY = (RIGHT_X + ICON_PAD + 2 * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)
# Below the tiled pair (y=40+280=320) so the 168×80 card sits on wallpaper.
WALL_XY = (16, min(SCREEN_H - 140, 336))
FILES_BODY_XY = (100, 160)
FILES_TITLE_XY = (120, 55)
SET_TITLE_XY = (min(SCREEN_W - 40, 500), 55)
START_ROW1_XY = (40, min(500, SCREEN_H - 120))


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


class Serial:
    """File is the source of truth. An optional socket is drained with a
    cap so a PROC YIELD storm cannot livelock wait_mark."""

    def __init__(self, path, sock_port=0):
        self.path = path
        self.buf = ""
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

    def _drain_sock(self):
        if self.sock is None:
            return
        got = 0
        try:
            while got < 65536:
                chunk = self.sock.recv(4096)
                if not chunk:
                    break
                self.buf += chunk.decode("utf-8", "replace")
                got += len(chunk)
        except (socket.timeout, BlockingIOError):
            pass
        if len(self.buf) > 1048576:
            self.buf = self.buf[-524288:]

    def read(self):
        self._drain_sock()
        try:
            # Tail the logfile. A full 88MiB reread on every wait_mark
            # livelocks the driver under a PROC YIELD storm.
            size = os.path.getsize(self.path)
            if size > 1048576:
                with open(self.path, encoding="utf-8", errors="replace") as f:
                    f.seek(size - 1048576)
                    text = f.read()
            else:
                text = open(self.path, encoding="utf-8", errors="replace").read()
            if text:
                return text
        except OSError:
            pass
        return self.buf


def wait_mark(ser, token, marked, timeout=8.0):
    # Count, not prefix: Serial.read() tails the last MiB so `marked`
    # is not a prefix of later snapshots.
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
    q.cmd("screendump", filename=os.path.abspath(path), format="png")
    print("shot", path, "bytes", os.path.getsize(path) if os.path.exists(path) else 0)


def count_refuse_commit(text):
    return len(re.findall(r"WM REFUSE C 17 OP 0+2 .* R F+8", text))


def composite_pair(a, b, dest):
    try:
        from PIL import Image
    except ImportError:
        Image = None
    if Image is None:
        # Side-by-side without PIL: pick the error shot and keep empty beside it.
        if os.path.exists(b):
            import shutil
            shutil.copy2(b, dest)
            print("WARN: no PIL; empty-error is the error shot only")
            return
        raise SystemExit("no empty/error shots to composite")
    ia, ib = Image.open(a), Image.open(b)
    h = max(ia.height, ib.height)
    out = Image.new("RGB", (ia.width + ib.width, h), (20, 28, 32))
    out.paste(ia, (0, 0))
    out.paste(ib, (ia.width, 0))
    out.save(dest)
    print("shot", dest, "bytes", os.path.getsize(dest), "composite")


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: daily-drive-round5.py <qmp-port> <serial> <outdir>")
    port, serial_path, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art = os.environ.get("ARTIFACTS", "/opt/cursor/artifacts")
    os.makedirs(outdir, exist_ok=True)
    q = Qmp(port)
    ser = Serial(serial_path, SERIAL_SOCK)

    deadline = time.time() + 40
    while time.time() < deadline and "M1 END" not in ser.read():
        time.sleep(0.2)
    if "M1 END" not in ser.read():
        raise SystemExit("no M1 END")
    # `file:` serial is block-buffered; the shell is already in idle_once
    # after M1 END even when `oscortex>` has not hit the file yet.
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

    if "DESK READY" not in ser.read():
        wait_mark(ser, "DESK READY", "", 12)

    print("layout start", START_XY, "files_dock", FILES_DOCK_XY,
          "wall", WALL_XY, "panel_y", PANEL_Y)

    press(q, ser, FILES_DOCK_XY[0], FILES_DOCK_XY[1], "left", "FILES CSD", timeout=8)
    time.sleep(0.8)
    press(q, ser, START_XY[0], START_XY[1], "left", "WM DE START", timeout=4)
    time.sleep(0.35)
    press(q, ser, START_ROW1_XY[0], START_ROW1_XY[1], "left", "SET CSD", timeout=10)
    time.sleep(2.0)

    shot(q, os.path.join(art, "oscortex-round5-%dx%d.png" % (SCREEN_W, SCREEN_H)))
    if SCREEN_W == 1280:
        shot(q, os.path.join(art, "oscortex-round5-1280x720.png"))
    shot(q, os.path.join(art, "oscortex-round5-client-identity.png"))
    shot(q, os.path.join(outdir, "%dx%d.png" % (SCREEN_W, SCREEN_H)))

    # Both windows reachable: FILES body then SET title.
    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=3)
    press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left", "WM FOCUS", timeout=3)

    # Wallpaper first — never a SET/FILES hit — then window/dock cards.
    press(q, ser, WALL_XY[0], WALL_XY[1], "right", "WM WALL MENU", timeout=3)
    time.sleep(0.35)
    shot(q, os.path.join(art, "oscortex-round5-menu.png"))
    shot(q, os.path.join(outdir, "menu.png"))
    q.key("esc")
    time.sleep(0.2)
    press(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "right", "WM WIN MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)
    press(q, ser, DOCK_MENU_XY[0], DOCK_MENU_XY[1], "right", "WM DOCK MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)

    # Empty + error sit-ins. Tokens now fire after the painted commit.
    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=3)
    marked = ser.read()
    q.key("v")
    if not wait_mark(ser, "FILES KEY V", marked, 2):
        print("WARN: no FILES KEY V")
    marked = ser.read()
    q.key("ret")
    if not wait_mark(ser, "FILES EMPTY", marked, 4):
        print("WARN: no FILES EMPTY")
    time.sleep(0.45)
    empty_png = os.path.join(outdir, "empty.png")
    shot(q, empty_png)
    marked = ser.read()
    q.key("esc")
    if not wait_mark(ser, "FILES BACK", marked, 3):
        print("WARN: no FILES BACK")
    time.sleep(0.25)
    marked = ser.read()
    q.key("m")
    wait_mark(ser, "FILES KEY M", marked, 2)
    marked = ser.read()
    q.key("ret")
    if not wait_mark(ser, "FILES ERR", marked, 4):
        print("WARN: no FILES ERR")
    time.sleep(0.45)
    error_png = os.path.join(outdir, "error.png")
    shot(q, error_png)
    pair = os.path.join(art, "oscortex-round5-empty-error.png")
    composite_pair(empty_png, error_png, pair)
    shot(q, os.path.join(outdir, "empty-error-live.png"))
    q.key("esc")
    time.sleep(0.25)
    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "right", "FILES MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)

    # Idle frames vs interaction latency (live serial; file: stays empty).
    quiet = ser.read()
    idle_t0 = time.time()
    time.sleep(1.2)
    idle_text = ser.read()[len(quiet):]
    idle_frames = len(re.findall(r"^WM FRAME ", idle_text, re.M))
    idle_ms = (time.time() - idle_t0) * 1000.0

    latencies = []
    guest_lat = []
    for i in range(8):
        x = 80 + i * 30
        y = 140 + (i % 3) * 20
        marked = ser.read()
        t0 = time.time()
        place(q, ser, x, y)
        got = wait_mark(ser, "WM LAT ", marked, 1.5)
        if not got:
            got = wait_mark(ser, "WM FRAME", marked, 0.8)
        if got:
            latencies.append(round((time.time() - t0) * 1000.0, 1))
        time.sleep(0.05)
    for m in re.finditer(r"WM LAT ([0-9A-F]+) D ([0-9A-F]+) S ([0-9A-F]+)",
                         ser.read()):
        kind = int(m.group(1), 16)
        delta = int(m.group(2), 16)
        seq = int(m.group(3), 16)
        guest_lat.append({"kind": kind, "ticks": delta, "seq": seq,
                          "ms_est": round(delta * 10.0, 1)})
    place(q, ser, 120, 180)
    button(q, 120, 180, "wheel-down", True)
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
            press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=1.5)
            press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left", "WM FOCUS", timeout=1.5)

    text = ser.read()
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
        "idle_frames_1s": idle_frames,
        "idle_sample_ms": round(idle_ms, 1),
        "event_to_present_ms": latencies,
        "event_to_present_ms_max": max(latencies) if latencies else None,
        "event_to_present_ms_avg": (
            round(sum(latencies) / len(latencies), 1) if latencies else None),
        "guest_lat": guest_lat[-32:],
        "guest_lat_ticks_max": max((x["ticks"] for x in guest_lat), default=None),
        "guest_lat_ticks_avg": (
            round(sum(x["ticks"] for x in guest_lat) / len(guest_lat), 2)
            if guest_lat else None),
        "serial_live": bool(ser.sock),
        "files_empty": "FILES EMPTY" in text,
        "files_err": "FILES ERR" in text,
        "set_csd": "SET CSD" in text,
        "osgfx_title_set": "OSGFX TITLE SET" in text,
        "wm_lat": "WM LAT " in text,
        "win_menu": "WM WIN MENU" in text,
        "wall_menu": "WM WALL MENU" in text,
        "dock_menu": "WM DOCK MENU" in text,
        "attach_caption": bool(re.search(r"WM ATTACH .* C [12]", text)),
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
