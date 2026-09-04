#!/usr/bin/env python3
"""Guest-only Round 23 recording: cold launch + first drag + menu + max + SET.

30–60s mix. Not a warm-desktop-only pointer tour.
"""

import importlib.util
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

cs_spec = importlib.util.spec_from_file_location(
    "chip23", os.path.join(HERE, "chip-scan-round23.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)

SET_TITLE = (464 + 72, 40 + 15)
SET_CARD0 = (464 + 132 + 44, 40 + 84 + 16)
SET_CARD1 = (464 + 228 + 44, 40 + 84 + 16)


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: guest-record-round23.py <qmp> <serial> <framedir> <mp4>")
    port = int(sys.argv[1])
    serial_path = sys.argv[2]
    framedir = sys.argv[3]
    mp4 = sys.argv[4]
    os.makedirs(framedir, exist_ok=True)
    q = d15.Qmp(port)
    sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
    if sock <= 0:
        sib = os.path.join(os.path.dirname(serial_path), "serial.port")
        try:
            sock = int(open(sib).read().strip())
        except (OSError, ValueError):
            sock = 0
    ser = d15.Serial(serial_path, sock)
    fps = float(os.environ.get("DRIVE_GUEST_FPS", "8"))
    dt = 1.0 / fps
    n = 0
    t0 = time.time()
    budget = float(os.environ.get("DRIVE_GUEST_SECS", "48"))

    def dump(_tag):
        nonlocal n
        n += 1
        path = os.path.join(framedir, "g%05d.png" % n)
        d15.shot(q, path)
        return path

    def remaining():
        return budget - (time.time() - t0)

    dump("start")
    # Close a warm FILES if present so the next dock click is a cold launch.
    geom = cs.live_files_xywh(serial_path, ser.archive or "")
    if geom is not None and geom[2] < 1000:
        cx, cy = cs.ctrl_of(geom, "close")
        d15.press(q, ser, cx, cy, "left", "WM CLOSE", timeout=2.5)
        dump("closed")
        time.sleep(dt)
    dump("desk")
    n0 = cs.vis_count(serial_path, ser.archive or "")
    d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
              "left", "FILES CSD", timeout=6)
    cs.wait_vis(ser, serial_path, n0=n0, timeout=6)
    dump("cold-launch")
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or (48, 40, 320, 280)
    ftx, fty = cs.title_of(geom)
    d15.place(q, ser, ftx, fty)
    d15.button(q, ftx, fty, "left", True)
    dump("first-drag-down")
    for dx in (0, 20, 40, 64, 40, 16, 0):
        n1 = cs.vis_count(serial_path, ser.archive or "")
        d15.place(q, ser, ftx + dx, fty)
        if dx:
            cs.wait_vis(ser, serial_path, n0=n1, timeout=1.0)
        dump("first-drag")
        time.sleep(dt * 0.3)
    d15.button(q, ftx, fty, "left", False)
    dump("first-drag-end")
    try:
        d15.press(q, ser, 90, 400, "right", "WM WALL MENU", timeout=2)
        dump("menu")
        time.sleep(dt)
        q.key("esc")
        dump("menu-off")
    except Exception:
        dump("menu-miss")
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or geom
    mx, my = cs.ctrl_of(geom, "max")
    n2 = cs.vis_count(serial_path, ser.archive or "")
    d15.press(q, ser, mx, my, "left", "WM REQ", timeout=2)
    cs.wait_vis(ser, serial_path, n0=n2, pred=lambda g: g[2] >= 1000, timeout=4)
    dump("max")
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or geom
    rx, ry = cs.ctrl_of(geom, "max")
    n3 = cs.vis_count(serial_path, ser.archive or "")
    d15.press(q, ser, rx, ry, "left", "WM REQ", timeout=2)
    cs.wait_vis(ser, serial_path, n0=n3, pred=lambda g: g[2] < 1000, timeout=4)
    dump("restore")
    d15.press(q, ser, SET_TITLE[0], SET_TITLE[1], "left", "WM DEFN", timeout=3)
    dump("set-focus")
    d15.press(q, ser, SET_CARD0[0], SET_CARD0[1], "left", "SET CARD", timeout=2)
    dump("set-card0")
    d15.press(q, ser, SET_CARD1[0], SET_CARD1[1], "left", "SET CARD", timeout=2)
    dump("set-card1")
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or geom
    bx, by = geom[0] + 80, geom[1] + 120
    d15.place(q, ser, bx, by)
    for i in range(6):
        try:
            q.cmd("input-send-event", events=[
                {"type": "abs", "data": {
                    "axis": "x", "value": d15.abs_xy(bx, by)[0]}},
                {"type": "abs", "data": {
                    "axis": "y", "value": d15.abs_xy(bx, by + i * 8)[1]}},
                {"type": "btn", "data": {"button": "wheel-down", "down": True}},
            ])
        except Exception:
            d15.place(q, ser, bx, by + i * 12)
        dump("scroll")
        time.sleep(dt * 0.4)
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or geom
    if geom[2] < 1000:
        cx, cy = cs.ctrl_of(geom, "close")
        d15.press(q, ser, cx, cy, "left", "WM CLOSE", timeout=2.5)
        dump("close")
        n4 = cs.vis_count(serial_path, ser.archive or "")
        d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
                  "left", "FILES CSD", timeout=6)
        cs.wait_vis(ser, serial_path, n0=n4, timeout=6)
        dump("relaunch")
    while remaining() > 2.0:
        d15.place(q, ser, 80 + int((time.time() - t0) * 17) % 200, 160)
        dump("idle")
        time.sleep(dt)
        if time.time() - t0 >= 58:
            break

    elapsed = time.time() - t0
    cmd = [
        "ffmpeg", "-y", "-framerate", str(max(1, int(fps))),
        "-i", os.path.join(framedir, "g%05d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        mp4,
    ]
    subprocess.check_call(cmd)
    print("guest-record frames=%d secs=%.1f out=%s" % (n, elapsed, mp4))
    if elapsed < 30 or elapsed > 70:
        print("WARN: guest record length %.1fs (want 30-60)" % elapsed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
