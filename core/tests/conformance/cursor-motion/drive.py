#!/usr/bin/env python3
"""Exercise a running oscortex DE through its absolute QMP tablet.

Usage: drive.py <qmp-port> <serial-log> <artifact-dir>

The guest must already be at `DESK READY`. The driver checks fast queued
motion, atomic click coordinates, static-scene save-under restoration, menus,
window launch, title drag, diagonals, and all four screen edges.
"""

import json
import os
import re
import socket
import struct
import sys
import time
import zlib

W, H = 800, 600
PTR_W, PTR_H = 16, 20


class Qmp:
    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        # pmemsave can be serialized behind a TCG repaint on loaded CI hosts.
        # A timeout here measures host scheduling, not guest cursor latency.
        self.s.settimeout(60)
        self.f = self.s.makefile("rw", encoding="utf-8")
        json.loads(self.f.readline())
        self.cmd("qmp_capabilities")

    def cmd(self, execute, **arguments):
        msg = {"execute": execute}
        if arguments:
            msg["arguments"] = arguments
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError("QMP closed")
            reply = json.loads(line)
            if "event" in reply:
                continue
            if "error" in reply:
                raise RuntimeError("%s: %s" % (execute, reply["error"]))
            return reply.get("return")

    def input_pipeline(self, batches):
        """Queue input commands without per-command round trips."""
        for ident, events in enumerate(batches):
            msg = {
                "execute": "input-send-event",
                "id": ident,
                "arguments": {"events": events},
            }
            self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        replies = 0
        while replies < len(batches):
            reply = json.loads(self.f.readline())
            if "event" in reply:
                continue
            if "error" in reply:
                raise RuntimeError("input-send-event: %s" % reply["error"])
            replies += 1


def serial_text(path):
    return open(path, encoding="latin-1", errors="replace").read()


def wait_new(path, token, mark, timeout=12):
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = serial_text(path)
        if token in text[mark:]:
            return
        time.sleep(0.03)
    raise RuntimeError("no %r after input" % token)


def abs_events(x, y):
    ax = max(0, min(32767, x * 32767 // (W - 1)))
    ay = max(0, min(32767, y * 32767 // (H - 1)))
    return [
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ]


def place(q, x, y):
    q.cmd("input-send-event", events=abs_events(x, y))


def button(q, x, y, name, down):
    events = abs_events(x, y)
    events.append(
        {"type": "btn", "data": {"button": name, "down": bool(down)}}
    )
    q.cmd("input-send-event", events=events)


def type_line(q, text):
    for ch in text:
        code = {" ": "spc", "\n": "ret"}.get(ch, ch.lower())
        q.cmd("send-key", keys=[{"type": "qcode", "data": code}])
        time.sleep(0.015)
    q.cmd("send-key", keys=[{"type": "qcode", "data": "ret"}])


def mouse_state(q, serial):
    before = len(serial_text(serial))
    type_line(q, "mouse")
    deadline = time.time() + 5
    pattern = re.compile(r"^MOUSE STATE X ([0-9A-F]+) Y ([0-9A-F]+)", re.M)
    while time.time() < deadline:
        match = pattern.search(serial_text(serial)[before:])
        if match:
            return int(match.group(1), 16), int(match.group(2), 16)
        time.sleep(0.03)
    raise RuntimeError("mouse command produced no state")


def announced_state(q, serial, x, y):
    """Read back tablet coordinates from an ignored middle-button edge."""
    before = len(serial_text(serial))
    button(q, x, y, "middle", True)
    deadline = time.time() + 5
    pattern = re.compile(r"^MOUSE ABS  X ([0-9A-F]+) Y ([0-9A-F]+)", re.M)
    while time.time() < deadline:
        match = pattern.search(serial_text(serial)[before:])
        if match:
            button(q, x, y, "middle", False)
            return int(match.group(1), 16), int(match.group(2), 16)
        time.sleep(0.03)
    raise RuntimeError("middle-button edge produced no absolute state")


def fb_geometry(serial):
    match = re.search(
        r"^WM ON BASE ([0-9A-F]+) PITCH ([0-9A-F]+)",
        serial_text(serial),
        re.M,
    )
    if not match:
        raise RuntimeError("no WM ON framebuffer geometry")
    return int(match.group(1), 16), int(match.group(2), 16)


def write_png(path, pitch, data):
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        for x in range(W):
            off = y * pitch + x * 4
            b, g, r = data[off : off + 3]
            raw.extend((r, g, b))

    def chunk(tag, body):
        crc = zlib.crc32(tag + body) & 0xFFFFFFFF
        return (
            struct.pack(">I", len(body))
            + tag
            + body
            + struct.pack(">I", crc)
        )

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(png)


def snapshot(q, base, pitch, out_dir, name):
    raw_path = os.path.join(out_dir, name + ".raw")
    png_path = os.path.join(out_dir, name + ".png")
    q.cmd("pmemsave", val=base, size=pitch * H, filename=raw_path)
    data = open(raw_path, "rb").read()
    if len(data) != pitch * H:
        raise RuntimeError("short framebuffer dump")
    write_png(png_path, pitch, data)
    return data


def rect_bytes(data, pitch, x, y, w=PTR_W, h=PTR_H):
    rows = []
    for yy in range(max(0, y), min(H, y + h)):
        left = max(0, x) * 4
        right = min(W, x + w) * 4
        rows.append(data[yy * pitch + left : yy * pitch + right])
    return b"".join(rows)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    port, serial, out_dir = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    os.makedirs(out_dir, exist_ok=True)
    q = Qmp(port)
    base, pitch = fb_geometry(serial)
    report = {"static_vacated": [], "latency_ms": []}
    frame = 0

    # Static save-under sweeps over wallpaper and dock.
    reserve = (760, 20)
    destination = (650, 430)
    points = [
        (100, 100),
        (380, 260),
        (100, 500),
        (262, 572),
        (592, 572),
        (0, 300),
        (783, 300),
        (400, 0),
        (400, 580),
    ]
    for point in points:
        place(q, *reserve)
        time.sleep(0.04)
        reference = snapshot(q, base, pitch, out_dir, "ref-%02d" % frame)
        t0 = time.monotonic()
        place(q, *point)
        time.sleep(0.025)
        visible = snapshot(q, base, pitch, out_dir, "move-%02d" % frame)
        latency = (time.monotonic() - t0) * 1000.0
        if rect_bytes(reference, pitch, *point) == rect_bytes(
            visible, pitch, *point
        ):
            raise RuntimeError("cursor did not present at %r" % (point,))
        place(q, *destination)
        time.sleep(0.04)
        after = snapshot(q, base, pitch, out_dir, "after-%02d" % frame)
        if rect_bytes(reference, pitch, *point) != rect_bytes(
            after, pitch, *point
        ):
            raise RuntimeError("save-under trail remained at %r" % (point,))
        report["static_vacated"].append(list(point))
        report["latency_ms"].append(round(latency, 2))
        frame += 1

    # Pipeline more than the old 16-event ring without QMP round-trip pacing.
    burst = [
        (40 + i * 32, 80 + i * 21)
        for i in range(20)
    ]
    q.input_pipeline([abs_events(x, y) for x, y in burst])
    time.sleep(0.2)
    got = mouse_state(q, serial)
    want = burst[-1]
    if abs(got[0] - want[0]) > 1 or abs(got[1] - want[1]) > 1:
        raise RuntimeError("fast burst ended at %r, wanted %r" % (got, want))
    report["fast_burst_reports"] = len(burst)
    report["fast_burst_final"] = list(got)

    # Atomic right click: menu classification must use this report's axes.
    mark = len(serial_text(serial))
    button(q, 400, 300, "right", True)
    wait_new(serial, "WM WALL MENU", mark)
    button(q, 400, 300, "right", False)
    time.sleep(0.15)
    place(q, 425, 330)
    time.sleep(0.08)
    snapshot(q, base, pitch, out_dir, "menu-hover")
    button(q, 16, 20, "left", True)
    button(q, 16, 20, "left", False)
    time.sleep(0.2)

    # Launch a window from the dock, then sweep its body/title/corners.
    mark = len(serial_text(serial))
    button(q, 592, 572, "left", True)
    button(q, 592, 572, "left", False)
    try:
        wait_new(serial, "FILES READY", mark, timeout=20)
    except RuntimeError:
        wait_new(serial, "FILES CSD", mark, timeout=2)
    time.sleep(0.5)
    window_points = [(45, 40), (200, 55), (300, 180), (435, 315)]
    for point in window_points:
        place(q, *point)
        time.sleep(0.06)
        snapshot(q, base, pitch, out_dir, "window-%02d" % frame)
        frame += 1

    # Click-drag with intermediate diagonal positions and an atomic release.
    button(q, 200, 55, "left", True)
    for i in range(1, 13):
        place(q, 200 + i * 18, 55 + i * 10)
        time.sleep(0.025)
    button(q, 416, 175, "left", False)
    time.sleep(0.5)
    snapshot(q, base, pitch, out_dir, "after-drag")

    # Exact clipping at every absolute edge and final clean artifact.
    for point in ((0, 0), (799, 0), (0, 599), (799, 599)):
        got = announced_state(q, serial, *point)
        if got != point:
            raise RuntimeError("edge %r became %r" % (point, got))
    place(q, 700, 420)
    time.sleep(0.08)
    final = snapshot(q, base, pitch, out_dir, "oscortex-cursor-motion-clean")
    final_path = os.path.join(out_dir, "oscortex-cursor-motion-clean.png")
    write_png(final_path, pitch, final)

    report["mean_event_to_dump_ms"] = round(
        sum(report["latency_ms"]) / len(report["latency_ms"]), 2
    )
    report["max_event_to_dump_ms"] = max(report["latency_ms"])
    report["artifact"] = final_path
    with open(os.path.join(out_dir, "report.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
