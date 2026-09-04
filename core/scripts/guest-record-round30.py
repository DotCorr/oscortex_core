#!/usr/bin/env python3
"""Guest GOP recording: pointer, layered drag, first body click, menu."""

import importlib.util
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

cs_spec = importlib.util.spec_from_file_location(
    "cs", os.path.join(HERE, "chip-scan-round24.py"))
cs = importlib.util.module_from_spec(cs_spec)
cs_spec.loader.exec_module(cs)


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: guest-record-round30.py <qmp> <serial> <framedir> <mp4>")
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

    def dump(_tag):
        nonlocal n
        n += 1
        path = os.path.join(framedir, "g%05d.png" % n)
        d15.shot(q, path)
        return path

    dump("start")
    for i in range(8):
        d15.place(q, ser, 60 + i * 22, 480 + (i % 3) * 8)
        dump("pointer")
        time.sleep(dt * 0.3)
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or (48, 40, 400, 280)
    ftx, fty = cs.title_of(geom)
    d15.place(q, ser, ftx, fty)
    d15.button(q, ftx, fty, "left", True)
    for dx in (0, 12, 24, 36, 48, 36, 24):
        d15.place(q, ser, ftx + dx, fty)
        dump("drag")
        time.sleep(dt * 0.35)
    d15.button(q, ftx + 24, fty, "left", False)
    dump("drag-end")
    time.sleep(0.08)
    geom = cs.live_files_xywh(serial_path, ser.archive or "") or geom
    bx, by = geom[0] + 48, geom[1] + 100
    d15.place(q, ser, bx, by)
    d15.button(q, bx, by, "left", True)
    d15.button(q, bx, by, "left", False)
    dump("cold-body")
    d15.button(q, bx, by, "wheel-down", True)
    d15.button(q, bx, by, "wheel-down", False)
    dump("scroll")
    d15.place(q, ser, 48, 520)
    d15.button(q, 48, 520, "right", True)
    d15.button(q, 48, 520, "right", False)
    dump("menu")
    time.sleep(0.06)
    try:
        q.key("esc")
    except Exception:
        pass
    dump("menu-off")

    elapsed = time.time()
    cmd = [
        "ffmpeg", "-y", "-framerate", str(max(1, int(fps))),
        "-i", os.path.join(framedir, "g%05d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        mp4,
    ]
    subprocess.check_call(cmd)
    print("guest-record frames=%d out=%s" % (n, mp4))
    return 0


if __name__ == "__main__":
    sys.exit(main())
