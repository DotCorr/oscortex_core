#!/usr/bin/env python3
"""Drive the Round 8 daily-drive QEMU: host event→present wall-time.

Live UART is sock-only. The logfile is a token harvest after the run,
never mixed into lat_seq. Pairing: record last present seq, inject QMP,
wait for sock seq > last. That wall_ms is the deliverable.
"""

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
LAT_REPS = int(os.environ.get("DRIVE_LAT_REPS", "8"))
PTR_SAMPLES = int(os.environ.get("DRIVE_PTR_SAMPLES", "32"))
SERIAL_SOCK = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
LAT_TICK_BOUND = int(os.environ.get("DRIVE_LAT_BOUND", "24"))
FOCUS_TICK_BOUND = int(os.environ.get("DRIVE_FOCUS_BOUND", "5"))
MAX_TICK_BOUND = int(os.environ.get("DRIVE_MAX_BOUND", "48"))
WALL_HITCH_MS = float(os.environ.get("DRIVE_WALL_HITCH_MS", "2000"))

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

SEQ_MASK = 0xFFFFFFFF
SEQ_RE = re.compile(r" S ([0-9A-F]+)")
PRES_RE = re.compile(r"^WM PRES S ([0-9A-F]+)")
LAT_RE = re.compile(
    r"WM LAT ([0-9A-F]+) D ([0-9A-F]+) S ([0-9A-F]+)"
    r"(?: G ([0-9A-F]+))?(?: A ([0-9A-F]+))?"
)


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


def seq_fwd(prev, cur):
    """Unsigned 32-bit forward distance. Wrap is not a gap."""
    return (cur - prev) & SEQ_MASK


def seq_after(prev, cur):
    d = seq_fwd(prev, cur)
    return d != 0 and d < (SEQ_MASK // 2)


class Serial:
    """sock-only live ingest. File harvest is a separate token scan."""

    def __init__(self, path, sock_port=0):
        self.path = path
        self.buf = ""
        self.archive = ""
        self.off = 0
        try:
            self.off = os.path.getsize(path)
        except OSError:
            self.off = 0
        self.sock = None
        self.yield_dropped = 0
        self.shm_dropped = 0
        self.preempt_dropped = 0
        self.recv_bytes = 0
        self.archive_truncated = 0
        self.lat_seq = []
        self.pres_seq = []
        self.last_pres_seq = None
        self.abs_n = 0
        self.last_abs = (None, None)
        self._partial = ""
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
        "FILES KEY", "FILES SLOT", "WM LAT ", "WM PRES", "WM COMMIT",
        "WM ATTACH", "WM MAX", "WM WALL MENU", "WM WIN MENU", "WM DOCK MENU",
        "WM FRAME", "WM FOCUS", "MOUSE ABS", "FB GOP", "VIEW MODE", "WM RAISE",
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

    def _note_seq(self, n):
        # PRES is the single present seq. LAT shares the number but is
        # not ingested here — mixing invented wrap/gap counts.
        if self.last_pres_seq is None or seq_after(self.last_pres_seq, n):
            self.last_pres_seq = n
        if self.pres_seq and self.pres_seq[-1] == n:
            return
        self.pres_seq.append(n)

    def _ingest(self, text, into_seq=True):
        if not text:
            return
        text = self._partial + text
        if "\n" not in text and "\r" not in text:
            self._partial = text
            return
        if text.endswith("\n") or text.endswith("\r"):
            self._partial = ""
        else:
            text, self._partial = text.rsplit("\n", 1)
        kept = []
        arch = []
        for ln in text.splitlines():
            if not self._keep_line(ln):
                continue
            kept.append(ln)
            if self._interesting(ln):
                arch.append(ln)
            if into_seq:
                if ln.startswith("WM LAT "):
                    m = SEQ_RE.search(ln)
                    if m:
                        self.lat_seq.append(int(m.group(1), 16))
                pm = PRES_RE.match(ln)
                if pm:
                    self._note_seq(int(pm.group(1), 16))
                if ln.startswith("MOUSE ABS"):
                    self.abs_n += 1
                    m = re.search(r"X ([0-9A-F]+) Y ([0-9A-F]+)", ln)
                    if m:
                        self.last_abs = (int(m.group(1), 16), int(m.group(2), 16))
        if kept:
            self.buf = (self.buf + "\n" + "\n".join(kept))[-262144:]
        if arch:
            joined = (getattr(self, "archive", "") + "\n" + "\n".join(arch))
            if len(joined) > 1048576:
                self.archive_truncated += 1
                joined = joined[-1048576:]
            self.archive = joined

    def read(self):
        # sock-only while the live UART socket is up. File ingest here
        # invented lat_seq_gaps and a 22s host hitch in Round 7.
        if self.sock is not None:
            self._drain_sock()
        else:
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
                        self._ingest(chunk.decode("utf-8", "replace"),
                                     into_seq=self.sock is None)
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
                self._ingest(chunk.decode("utf-8", "replace"), into_seq=True)
                got += len(chunk)
        except (socket.timeout, BlockingIOError):
            pass

    def lat_seq_gaps(self):
        # PRES is the single present seq; LAT may drop on a busy sock.
        # Gaps are missing presents, not UART-kind splits.
        seqs = self.pres_seq if len(self.pres_seq) >= 2 else self.lat_seq
        if len(seqs) < 2:
            return 0
        gaps = 0
        prev = seqs[0]
        for cur in seqs[1:]:
            if cur == prev:
                continue
            d = seq_fwd(prev, cur)
            if d == 0:
                continue
            if d >= (SEQ_MASK // 2):
                continue
            if d > 1:
                gaps += d - 1
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


def wait_present(ser, last_seq, timeout=2.5):
    """Wait for a sock present/LAT seq after last_seq. Returns wall_ms or None."""
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        ser.read()
        cur = ser.last_pres_seq
        if cur is None:
            time.sleep(0.008)
            continue
        if last_seq is None or seq_after(last_seq, cur):
            return True
        time.sleep(0.008)
    return False


def abs_xy(x, y):
    return x * 32767 // max(1, SCREEN_W - 1), y * 32767 // max(1, SCREEN_H - 1)


def place(q, ser, x, y, slop=12):
    """Bare motion does not print MOUSE ABS (virtab announces on button edge)."""
    ax, ay = abs_xy(x, y)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}}])
    ser.read()
    time.sleep(0.03)
    return True


def button(q, x, y, btn, down):
    ax, ay = abs_xy(x, y)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"button": btn, "down": down}}])


def pair_inject(q, ser, events, timeout=2.5):
    """Single-source wall-time: last seq → QMP → next present seq."""
    ser.read()
    last = ser.last_pres_seq
    t0 = time.perf_counter()
    q.cmd("input-send-event", events=events)
    ok = wait_present(ser, last, timeout)
    ms = (time.perf_counter() - t0) * 1000.0
    if not ok:
        return None
    return round(ms, 1)


def timed_place(q, ser, x, y, timeout=2.0):
    ax, ay = abs_xy(x, y)
    return pair_inject(q, ser, [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ], timeout)


def timed_click(q, ser, x, y, btn="left", timeout=3.0):
    ax, ay = abs_xy(x, y)
    place(q, ser, x, y)
    time.sleep(0.06)
    ms = pair_inject(q, ser, [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
        {"type": "btn", "data": {"button": btn, "down": True}},
    ], timeout)
    time.sleep(0.04)
    button(q, x, y, btn, False)
    time.sleep(0.12)
    return ms


def place_announce(q, ser, x, y, slop=8, timeout=4.0):
    """Drive (x,y) and force a button-edge ABS announce (not last-menu coords)."""
    # Park off-target first so the next edge cannot reuse last-menu ABS.
    place(q, ser, 8, 8)
    time.sleep(0.06)
    button(q, 8, 8, "left", False)
    time.sleep(0.04)
    place(q, ser, x, y)
    time.sleep(0.10)
    button(q, x, y, "left", False)
    time.sleep(0.08)
    n = ser.abs_n
    button(q, x, y, "left", True)
    deadline = time.time() + timeout
    while time.time() < deadline:
        ser.read()
        px, py = ser.last_abs
        if px is not None and abs(px - x) <= slop and abs(py - y) <= slop:
            button(q, x, y, "left", False)
            time.sleep(0.08)
            return True
        if ser.abs_n > n:
            pass
        time.sleep(0.04)
    button(q, x, y, "left", False)
    print("WARN: announce(%s,%s) last ABS %s" % (x, y, ser.last_abs))
    return False


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
    for m in LAT_RE.finditer(text):
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


def assert_probe(q, ser, x, y, slop=8):
    """Drive (x,y) AFTER menus and assert the last ABS is that probe."""
    marked = ser.read()
    n_frame = marked.count("WM FRAME")
    ok = False
    for attempt in range(3):
        if place_announce(q, ser, x, y, slop=slop, timeout=4.0):
            ok = True
            break
        print("WARN: probe attempt %d last ABS %s" % (attempt + 1, ser.last_abs))
        time.sleep(0.2)
    if not ok:
        raise SystemExit("probe (%d,%d): place did not land (last ABS %s)"
                         % (x, y, ser.last_abs))
    ax, ay = ser.last_abs
    if ax is None:
        raise SystemExit("probe (%d,%d): no MOUSE ABS after place" % (x, y))
    if abs(ax - x) > slop or abs(ay - y) > slop:
        raise SystemExit("probe ABS %s,%s != target %s,%s (menu coords?)"
                         % (ax, ay, x, y))
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


def wall_stats(values):
    v = [x for x in values if x is not None]
    return {
        "n": len(v),
        "p50": pct(v, 50),
        "p95": pct(v, 95),
        "max": max(v) if v else None,
        "avg": round(sum(v) / len(v), 2) if v else None,
    }


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: daily-drive-round8.py <qmp-port> <serial> <outdir>")
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
            if not file_has_token(serial_path, "M1 END"):
                raise SystemExit("no M1 END")
            print("M1 END from logfile (socket attached after boot)")
        time.sleep(1.5)

    if skip_boot:
        print("skip boot; desk already up")
        q.key("esc")
        time.sleep(0.15)
        q.key("esc")
        time.sleep(0.2)
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
          "gop", gop_w, gop_h, "artifacts", art, "sock", bool(ser.sock))

    if not skip_boot:
        press(q, ser, FILES_DOCK_XY[0], FILES_DOCK_XY[1], "left", "FILES CSD", timeout=8)
        time.sleep(0.8)
        press(q, ser, SET_DOCK_XY[0], SET_DOCK_XY[1], "left", "SET CSD", timeout=12)
        time.sleep(2.0)

    walls = {
        "pointer": [], "menu": [], "focus": [], "drag": [],
        "max_cold": [], "max_warm": [], "restore_cold": [], "restore_warm": [],
    }

    press(q, ser, FILES_BODY_XY[0], FILES_BODY_XY[1], "left", "FILES SEL", timeout=3)
    walls["focus"].append(timed_click(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1]))
    walls["menu"].append(timed_click(q, ser, WALL_XY[0], WALL_XY[1], "right"))
    time.sleep(0.2)
    q.key("esc")
    time.sleep(0.15)
    walls["menu"].append(timed_click(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "right"))
    q.key("esc")
    time.sleep(0.12)
    walls["menu"].append(timed_click(q, ser, DOCK_MENU_XY[0], DOCK_MENU_XY[1], "right"))
    q.key("esc")
    time.sleep(0.12)

    probe_abs = assert_probe(q, ser, PROBE_XY[0], PROBE_XY[1])

    # First maximize / restore are the cold path.
    press(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "left", "WM FOCUS", timeout=2)
    walls["max_cold"].append(timed_click(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1],
                                         timeout=4.0))
    time.sleep(0.25)
    walls["restore_cold"].append(timed_click(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1],
                                             timeout=4.0))
    time.sleep(0.2)

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

    for i, (x, y) in enumerate(walks):
        ms = timed_place(q, ser, x, y)
        if ms is not None:
            walls["pointer"].append(ms)
        if i == 4:
            walls["menu"].append(timed_click(q, ser, WALL_XY[0], WALL_XY[1], "right",
                                             timeout=2.5))
            q.key("esc")
            time.sleep(0.08)

    for i in range(LAT_REPS):
        walls["focus"].append(timed_click(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1]))
        time.sleep(0.08)
        walls["focus"].append(timed_click(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1]))
        time.sleep(0.08)
        bucket = "max_warm" if i > 0 else "max_warm"
        walls[bucket].append(timed_click(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1],
                                         timeout=3.5))
        time.sleep(0.12)
        walls["restore_warm"].append(timed_click(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1],
                                                 timeout=3.5))
        time.sleep(0.12)

    # Drag: title grab then move.
    place(q, ser, FILES_TITLE_XY[0], FILES_TITLE_XY[1])
    time.sleep(0.08)
    button(q, FILES_TITLE_XY[0], FILES_TITLE_XY[1], "left", True)
    time.sleep(0.05)
    for dx in (40, 80, 120, 160, 200, 240):
        ms = timed_place(q, ser, FILES_TITLE_XY[0] + dx, FILES_TITLE_XY[1] + 20)
        if ms is not None:
            walls["drag"].append(ms)
    button(q, FILES_TITLE_XY[0] + 240, FILES_TITLE_XY[1] + 20, "left", False)
    time.sleep(0.15)

    shot(q, os.path.join(art, "oscortex-round8-no-hitch.png"),
         os.path.join(fallback, "oscortex-round8-no-hitch.png"))
    shot(q, os.path.join(outdir, "no-hitch.png"))

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
        walls["max_warm"].append(timed_click(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1],
                                             timeout=3.0))
        time.sleep(0.06)
        walls["restore_warm"].append(timed_click(q, ser, FILES_MAX_XY[0], FILES_MAX_XY[1],
                                                 timeout=3.0))
        time.sleep(0.06)
        ms = timed_place(q, ser, 80 + (cycles % 20) * 12, 160)
        if ms is not None:
            walls["pointer"].append(ms)
        button(q, min(SCREEN_W - 20, 440), min(SCREEN_H - 40, 312), "left", True)
        ms = timed_place(q, ser, SCREEN_W - 10, SCREEN_H - 10)
        if ms is not None:
            walls["drag"].append(ms)
        button(q, SCREEN_W - 10, SCREEN_H - 10, "left", False)
        cycles += 1
        if cycles % 8 == 0:
            walls["focus"].append(timed_click(q, ser, SET_TITLE_XY[0], SET_TITLE_XY[1],
                                              timeout=2.0))
        if cycles % 12 == 0:
            walls["menu"].append(timed_click(q, ser, WALL_XY[0], WALL_XY[1], "right",
                                             timeout=2.0))
            q.key("esc")

    for _ in range(3):
        q.key("esc")
        time.sleep(0.08)
    place(q, ser, 400, 400)
    time.sleep(0.1)
    button(q, 400, 400, "left", True)
    time.sleep(0.05)
    button(q, 400, 400, "left", False)
    time.sleep(0.12)
    probe_abs = assert_probe(q, ser, PROBE_XY[0], PROBE_XY[1])
    shot(q, os.path.join(art, "oscortex-round8-no-hitch.png"),
         os.path.join(fallback, "oscortex-round8-no-hitch.png"))

    text = ser.read()
    guest_lat = parse_lat(text)
    file_lat = harvest_lat(serial_path)
    if len(file_lat) > len(guest_lat):
        guest_lat = file_lat
    for tok in ("SET CSD", "SET READY", "DESK LAUNCH SET.ELF", "FILES EMPTY",
                "WM LAT ", "WM PRES", "WM WALL MENU", "WM WIN MENU", "WM DOCK MENU"):
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

    wall_by = {k: wall_stats(v) for k, v in walls.items()}
    all_wall = []
    for v in walls.values():
        all_wall.extend([x for x in v if x is not None])
    hitch = [x for x in all_wall if x >= WALL_HITCH_MS]

    metrics = {
        "round": 8,
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
        "wall_ms_by_kind": wall_by,
        "wall_ms_all": wall_stats(all_wall),
        "wall_hitch_ms": WALL_HITCH_MS,
        "wall_hitch_n": len(hitch),
        "wall_hitch_samples": hitch[:12],
        "event_to_present_ms": all_wall[-64:],
        "event_to_present_ms_max": max(all_wall) if all_wall else None,
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
        "lat_seq_n": len(ser.lat_seq),
        "lat_seq_gaps": ser.lat_seq_gaps(),
        "pres_seq_n": len(ser.pres_seq),
        "archive_truncated": ser.archive_truncated,
        "set_csd": "SET CSD" in text,
        "set_ready": "SET READY" in text,
        "files_empty": "FILES EMPTY" in text,
        "desk_launch_set": "DESK LAUNCH SET.ELF" in text,
        "wm_lat": "WM LAT " in text,
        "wm_pres": "WM PRES" in text,
        "wall_menu": "WM WALL MENU" in text,
        "win_menu": "WM WIN MENU" in text,
        "dock_menu": "WM DOCK MENU" in text,
        "commits": len(re.findall(r"^WM COMMIT ", text, re.M)),
        "frames": len(re.findall(r"^WM FRAME ", text, re.M)),
    }
    payload = json.dumps(metrics, indent=2) + "\n"
    open(os.path.join(outdir, "metrics.json"), "w").write(payload)
    lat_path = os.path.join(art, "oscortex-round8-wall-latency.json")
    try:
        open(lat_path, "w").write(payload)
    except OSError:
        open(os.path.join(fallback, "oscortex-round8-wall-latency.json"), "w").write(payload)
        print("WARN: latency JSON written to fallback")
    print(payload)

    if not metrics["desk_launch_set"] and not skip_boot:
        raise SystemExit("dock never launched SET.ELF")
    if not metrics["set_csd"] and not skip_boot:
        raise SystemExit("SET CSD never printed")
    if k1["n"] < 30:
        raise SystemExit("kind-1 pointer samples %s < 30" % k1["n"])
    if k5["n"] < 4:
        print("WARN: kind-5 focus/max samples only", k5["n"])
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
    if hitch:
        raise SystemExit("multi-second wall-time hitch remains: %s" % hitch[:6])
    cold_max = wall_by["max_cold"]["max"]
    cold_rest = wall_by["restore_cold"]["max"]
    if cold_max is not None and cold_max >= WALL_HITCH_MS:
        raise SystemExit("cold maximize wall-time %s ms" % cold_max)
    if cold_rest is not None and cold_rest >= WALL_HITCH_MS:
        raise SystemExit("cold restore wall-time %s ms" % cold_rest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
