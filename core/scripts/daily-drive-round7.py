#!/usr/bin/env python3
"""Drive the Round 7 daily-drive QEMU: focus/max LAT, 30+ kind-1 walks."""

import json
import os
import re
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from artifacts import copy_file, resolve_artifacts

SCREEN_W = int(os.environ.get("DRIVE_W", "1280"))
SCREEN_H = int(os.environ.get("DRIVE_H", "720"))
STRESS_SECS = float(os.environ.get("DRIVE_STRESS_SECS", "300"))
LAT_REPS = int(os.environ.get("DRIVE_LAT_REPS", "6"))
PTR_SAMPLES = int(os.environ.get("DRIVE_PTR_SAMPLES", "32"))
SERIAL_SOCK = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
LAT_TICK_BOUND = int(os.environ.get("DRIVE_LAT_BOUND", "24"))
FOCUS_TICK_BOUND = int(os.environ.get("DRIVE_FOCUS_BOUND", "5"))
MAX_TICK_BOUND = int(os.environ.get("DRIVE_MAX_BOUND", "48"))

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
PROBE_XY = (120, 180)
FILES_MAX_XY = (min(SCREEN_W - 24, 379), 57)
SET_MAX_XY = (min(SCREEN_W - 24, 728), 20)


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
    """Live UART socket ingest. Drops YIELD/SHM/PREEMPT; counts drops."""

    def __init__(self, path, sock_port=0):
        self.path = path
        self.buf = ""
        self.archive = ""
        self.off = 0
        self.sock = None
        self.yield_dropped = 0
        self.shm_dropped = 0
        self.preempt_dropped = 0
        self.recv_bytes = 0
        self.archive_truncated = 0
        self.lat_seq = []
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
        "WM FOCUS", "MOUSE ABS", "FB GOP", "VIEW MODE", "WM RAISE",
    )

    def _keep_line(self, line):
        if line.startswith("PROC YIELD"):
            self.yield_dropped += 1
            return False
        if line.startswith("SHM PAGE"):
            self.shm_dropped += 1
            return False
        if line.startswith("PROC PREEMPT"):
            self.preempt_dropped += 1
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
                if ln.startswith("WM LAT "):
                    m = re.search(r" S ([0-9A-F]+)", ln)
                    if m:
                        self.lat_seq.append(int(m.group(1), 16))
        if kept:
            self.buf = (self.buf + "\n" + "\n".join(kept))[-262144:]
        if arch:
            joined = (getattr(self, "archive", "") + "\n" + "\n".join(arch))
            if len(joined) > 1048576:
                self.archive_truncated += 1
                joined = joined[-1048576:]
            self.archive = joined

    def read(self):
        self._drain_sock()
        if self.sock is None:
            self._ingest_file()
        return (getattr(self, "archive", "") + "\n" + self.buf)

    def _ingest_file(self):
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

    def _drain_sock(self):
        if self.sock is None:
            return
        got = 0
        try:
            while got < 262144:
                chunk = self.sock.recv(8192)
                if not chunk:
                    break
                self.recv_bytes += len(chunk)
                self._ingest(chunk.decode("utf-8", "replace"))
                got += len(chunk)
        except (socket.timeout, BlockingIOError):
            pass

    def lat_seq_gaps(self):
        if len(self.lat_seq) < 2:
            return 0
        gaps = 0
        prev = self.lat_seq[0]
        for cur in self.lat_seq[1:]:
            if cur > prev + 1:
                gaps += cur - prev - 1
            prev = cur
        return gaps


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


def shot(q, path, also=None):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    last = None
    for _ in range(3):
        try:
            q.cmd("screendump", filename=os.path.abspath(path), format="png")
            print("shot", path, "bytes",
                  os.path.getsize(path) if os.path.exists(path) else 0)
            if also and also != path:
                try:
                    copy_file(path, also)
                except OSError as e:
                    print("WARN: fallback shot copy failed:", e)
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


def harvest_lat(path):
    lines = []
    try:
        with open(path, "rb") as f:
            buf = b""
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                buf += chunk
                parts = buf.split(b"\n")
                buf = parts[-1]
                for ln in parts[:-1]:
                    if ln.startswith(b"WM LAT "):
                        lines.append(ln.decode("utf-8", "replace"))
            if buf.startswith(b"WM LAT "):
                lines.append(buf.decode("utf-8", "replace"))
    except OSError:
        return []
    return parse_lat("\n".join(lines))


def file_has_token(path, token):
    needle = token.encode("utf-8")
    try:
        with open(path, "rb") as f:
            prev = b""
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    return False
                if needle in prev[-len(needle):] + chunk:
                    return True
                prev = chunk[-64:]
    except OSError:
        return False


def last_pointer_xy(text):
    matches = re.findall(
        r"^WM FRAME [0-9A-F]+ PX [0-9A-F]+ TOP [0-9A-F]+ CUR X ([0-9A-F]+) Y ([0-9A-F]+)",
        text, re.M)
    if not matches:
        return None, None
    x, y = matches[-1]
    return int(x, 16), int(y, 16)


def last_abs_xy(text):
    matches = re.findall(
        r"^MOUSE ABS  X ([0-9A-F]+) Y ([0-9A-F]+)",
        text, re.M)
    if not matches:
        return None, None
    x, y = matches[-1]
    return int(x, 16), int(y, 16)


def assert_probe(q, ser, x, y, slop=8):
    """Drive (x,y) AFTER menus and assert the last ABS is that probe."""
    marked = ser.read()
    n_abs = marked.count("MOUSE ABS")
    n_frame = marked.count("WM FRAME")
    place(q, ser, x, y)
    deadline = time.time() + 2.0
    text = marked
    while time.time() < deadline:
        text = ser.read()
        if text.count("MOUSE ABS") > n_abs:
            break
        time.sleep(0.04)
    ax, ay = last_abs_xy(text)
    if ax is None:
        raise SystemExit("probe (%d,%d): no MOUSE ABS after place" % (x, y))
    if abs(ax - x) > slop or abs(ay - y) > slop:
        raise SystemExit("probe ABS %s,%s != target %s,%s (menu coords?)"
                         % (ax, ay, x, y))
    # FRAME is optional on a sprite-only move; if one arrives it must match.
    deadline = time.time() + 0.6
    while time.time() < deadline:
        text = ser.read()
        if text.count("WM FRAME") > n_frame:
            break
        time.sleep(0.04)
    fx, fy = last_pointer_xy(text)
    if text.count("WM FRAME") > n_frame and fx is not None:
        if abs(fx - x) > slop or abs(fy - y) > slop:
            raise SystemExit("probe FRAME %s,%s != target %s,%s"
                             % (fx, fy, x, y))
    print("probe ok ABS", ax, ay, "FRAME", fx, fy, "target", x, y)
    return ax, ay, fx, fy


def kind_stats(recs, kind):
    v = [r["ticks"] for r in recs if r["kind"] == kind]
    return {
        "n": len(v),
        "p50": pct(v, 50),
        "p95": pct(v, 95),
        "max": max(v) if v else None,
        "avg": round(sum(v) / len(v), 2) if v else None,
    }


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: daily-drive-round7.py <qmp-port> <serial> <outdir>")
    port, serial_path, outdir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    art, art_warn = resolve_artifacts()
    if art_warn:
        print("WARN:", art_warn)
    fallback = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "build", "artifacts")
    fallback = os.path.abspath(fallback)
    os.makedirs(outdir, exist_ok=True)
    os.makedirs(art, exist_ok=True)
    q = Qmp(port)
    ser = Serial(serial_path, SERIAL_SOCK)
    skip_boot = os.environ.get("DRIVE_SKIP_BOOT", "0") == "1"

    if not skip_boot:
        deadline = time.time() + 40
        while time.time() < deadline and "M1 END" not in ser.read():
            time.sleep(0.2)
        if "M1 END" not in ser.read():
            raise SystemExit("no M1 END")
        time.sleep(1.5)

    if skip_boot:
        print("skip boot; desk already up")
    else:
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
    if gop is None:
        try:
            with open(serial_path, "rb") as fh:
                head = fh.read(65536).decode("utf-8", "replace")
            gop = re.search(r"FB GOP ([0-9A-Fa-f]+)x([0-9A-Fa-f]+)", head)
        except OSError:
            gop = None
    gop_w = int(gop.group(1), 16) if gop else None
    gop_h = int(gop.group(2), 16) if gop else None
    print("layout start", START_XY, "set_dock", SET_DOCK_XY,
          "files_dock", FILES_DOCK_XY, "wall", WALL_XY, "panel_y", PANEL_Y,
          "gop", gop_w, gop_h, "artifacts", art)

    if not skip_boot:
        press(q, ser, FILES_DOCK_XY[0], FILES_DOCK_XY[1], "left", "FILES CSD", timeout=8)
        time.sleep(0.8)
        press(q, ser, SET_DOCK_XY[0], SET_DOCK_XY[1], "left", "SET CSD", timeout=12)
        time.sleep(2.0)

    # Menus first so the probe cannot accidentally be last-menu coords.
    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=3)
    press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left", "WM FOCUS", timeout=3)
    press(q, ser, WALL_XY[0], WALL_XY[1], "right", "WM WALL MENU", timeout=3)
    time.sleep(0.35)
    q.key("esc")
    time.sleep(0.2)
    press(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "right", "WM WIN MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)
    press(q, ser, DOCK_MENU_XY[0], DOCK_MENU_XY[1], "right", "WM DOCK MENU", timeout=3)
    q.key("esc")
    time.sleep(0.15)

    probe_abs = assert_probe(q, ser, PROBE_XY[0], PROBE_XY[1])
    shot(q, os.path.join(art, "oscortex-round7-pointer-proof.png"),
         os.path.join(fallback, "oscortex-round7-pointer-proof.png"))
    shot(q, os.path.join(outdir, "pointer-proof.png"))

    # Cold chrome: maximize once, then walk the pointer.
    press(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "left", "WM FOCUS", timeout=2)
    press(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1], "left", "WM MAX", timeout=3)
    time.sleep(0.3)

    walks = [
        (16, 40), (16, 336), (400, 400), (800, 300), (1200, 200),
        (100, 160), (200, 80), (500, 80), (400, 200), (90, 90),
        SET_DOCK_XY, FILES_DOCK_XY, DOCK_MENU_XY, (RIGHT_X + 20, PANEL_Y),
        (0, 0), (SCREEN_W - 1, 0), (0, SCREEN_H - 1),
        (SCREEN_W - 1, SCREEN_H - 1), (SCREEN_W // 2, 0),
        (SCREEN_W // 2, SCREEN_H - 1), (640, 360), (32, 700),
        (1260, 700), (16, 180), (200, 500), (900, 80),
        (1100, 400), (300, 250), (700, 140), (50, 600),
        (PROBE_XY[0], PROBE_XY[1]), (WALL_XY[0], WALL_XY[1]),
    ]
    while len(walks) < PTR_SAMPLES:
        walks.append((40 + (len(walks) * 37) % (SCREEN_W - 80),
                      40 + (len(walks) * 19) % (SCREEN_H - 80)))
    walks = walks[: max(PTR_SAMPLES, 32)]

    host_ms = []
    for i, (x, y) in enumerate(walks):
        marked = ser.read()
        t0 = time.time()
        place(q, ser, x, y)
        if i == 4:
            press(q, ser, WALL_XY[0], WALL_XY[1], "right", "WM WALL MENU",
                  timeout=2)
            q.key("esc")
            time.sleep(0.1)
        got = wait_mark(ser, "WM LAT ", marked, 1.6)
        if got:
            host_ms.append(round((time.time() - t0) * 1000.0, 1))
        time.sleep(0.03)

    # Focus / maximize anti-vacuity: several real interactions.
    for _ in range(LAT_REPS):
        press(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "left",
              "WM FOCUS", timeout=2)
        time.sleep(0.12)
        press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left",
              "WM FOCUS", timeout=2)
        time.sleep(0.12)
        press(q, ser, WALL_XY[0], WALL_XY[1], "left", "WM FOCUS", timeout=2)
        time.sleep(0.12)
        press(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1], "left",
              "WM MAX", timeout=2.5)
        time.sleep(0.2)
        press(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1], "left",
              "WM MAX", timeout=2.5)
        time.sleep(0.2)

    shot(q, os.path.join(art, "oscortex-round7-focus-latency.png"),
         os.path.join(fallback, "oscortex-round7-focus-latency.png"))
    shot(q, os.path.join(outdir, "focus-latency.png"))

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

    stress_start = time.time()
    cycles = 0
    while time.time() - stress_start < STRESS_SECS:
        press(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1], "left", "WM MAX", timeout=2.5)
        time.sleep(0.1)
        press(q, ser, SET_MAX_XY[0], SET_MAX_XY[1], "left", "WM MAX", timeout=2.5)
        time.sleep(0.1)
        place(q, ser, 80 + (cycles % 20) * 12, 160)
        time.sleep(0.04)
        button(q, min(SCREEN_W - 20, 440), min(SCREEN_H - 40, 312), "left", True)
        place(q, ser, SCREEN_W - 10, SCREEN_H - 10)
        time.sleep(0.06)
        button(q, SCREEN_W - 10, SCREEN_H - 10, "left", False)
        cycles += 1
        if cycles % 8 == 0:
            press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left",
                  "FILES SEL", timeout=1.5)
            press(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1], "left",
                  "WM FOCUS", timeout=1.5)
        if cycles % 12 == 0:
            press(q, ser, WALL_XY[0], WALL_XY[1], "right", "WM WALL MENU",
                  timeout=1.5)
            q.key("esc")

    # Re-drive the known probe after stress so the final assert is not a menu.
    probe_abs = assert_probe(q, ser, PROBE_XY[0], PROBE_XY[1])

    text = ser.read()
    guest_lat = parse_lat(text)
    file_lat = harvest_lat(serial_path)
    if len(file_lat) > len(guest_lat):
        guest_lat = file_lat
    for tok in ("SET CSD", "SET READY", "DESK LAUNCH SET.ELF", "FILES EMPTY",
                "WM LAT ", "WM WALL MENU", "WM WIN MENU", "WM DOCK MENU"):
        if tok not in text and file_has_token(serial_path, tok):
            text = text + "\n" + tok
    ticks = [x["ticks"] for x in guest_lat]
    kinds = {}
    for rec in guest_lat:
        kinds.setdefault(rec["kind"], []).append(rec["ticks"])
    by_kind = {
        str(k): {"n": len(v), "p50": pct(v, 50), "p95": pct(v, 95),
                 "max": max(v) if v else None}
        for k, v in sorted(kinds.items())
    }
    k1 = kind_stats(guest_lat, 1)
    k5 = kind_stats(guest_lat, 5)
    serial_bytes = 0
    try:
        serial_bytes = os.path.getsize(serial_path)
    except OSError:
        pass

    metrics = {
        "round": 7,
        "screen": [SCREEN_W, SCREEN_H],
        "fb_gop": [gop_w, gop_h],
        "artifacts_dir": art,
        "artifacts_warn": art_warn,
        "stress_cycles": cycles,
        "stress_secs": round(time.time() - stress_start, 1),
        "lat_reps": LAT_REPS,
        "ptr_walks": len(walks),
        "guest_lat": guest_lat[-96:],
        "guest_lat_n": len(ticks),
        "guest_lat_ticks_p50": pct(ticks, 50),
        "guest_lat_ticks_p95": pct(ticks, 95),
        "guest_lat_ticks_max": max(ticks) if ticks else None,
        "guest_lat_ticks_avg": (
            round(sum(ticks) / len(ticks), 2) if ticks else None),
        "guest_lat_by_kind": by_kind,
        "kind1": k1,
        "kind5_focus_or_max": k5,
        "event_to_present_ms": host_ms,
        "event_to_present_ms_max": max(host_ms) if host_ms else None,
        "pointer_target": [PROBE_XY[0], PROBE_XY[1]],
        "pointer_final_abs": [probe_abs[0], probe_abs[1]],
        "pointer_final_frame": [probe_abs[2], probe_abs[3]],
        "lat_tick_bound": LAT_TICK_BOUND,
        "focus_tick_bound": FOCUS_TICK_BOUND,
        "max_tick_bound": MAX_TICK_BOUND,
        "serial_live": bool(ser.sock),
        "serial_recv_bytes": ser.recv_bytes,
        "serial_file_bytes": serial_bytes,
        "yield_dropped": ser.yield_dropped,
        "shm_dropped": ser.shm_dropped,
        "preempt_dropped": ser.preempt_dropped,
        "lat_seq_gaps": ser.lat_seq_gaps(),
        "archive_truncated": ser.archive_truncated,
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
    lat_path = os.path.join(art, "oscortex-round7-latency.json")
    try:
        open(lat_path, "w").write(payload)
    except OSError:
        open(os.path.join(fallback, "oscortex-round7-latency.json"), "w").write(payload)
        print("WARN: latency JSON written to fallback")
    report_path = os.path.join(art, "oscortex-round7-latency-report.json")
    try:
        open(report_path, "w").write(payload)
    except OSError:
        open(os.path.join(fallback, "oscortex-round7-latency-report.json"), "w").write(payload)
    print(payload)

    if not metrics["desk_launch_set"] and not skip_boot:
        raise SystemExit("dock never launched SET.ELF")
    if not metrics["set_csd"] and not skip_boot:
        raise SystemExit("SET CSD never printed")
    if k1["n"] < 30:
        raise SystemExit("kind-1 pointer samples %s < 30" % k1["n"])
    if k5["n"] < 4:
        print("WARN: kind-5 focus/max samples only", k5["n"])
    if k5["max"] is not None and k5["max"] > 80:
        print("WARN: kind-5 max %d ticks still a stall" % k5["max"])
    if ticks and max(ticks) > LAT_TICK_BOUND:
        late = [r for r in guest_lat
                if r["ticks"] > LAT_TICK_BOUND
                and r.get("chrome_regen", 1) == 0
                and r["kind"] == 1]
        if late:
            raise SystemExit("pointer LAT scheduling stall: %s" % late[:4])
        print("WARN: LAT max %d ticks exceeds bound %d"
              % (max(ticks), LAT_TICK_BOUND))
    if ser.lat_seq_gaps() > 8:
        print("WARN: LAT sequence gaps", ser.lat_seq_gaps())
    return 0


if __name__ == "__main__":
    sys.exit(main())
