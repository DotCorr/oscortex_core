#!/usr/bin/env python3
"""Round 33 guest recording: launcher, Alt-Tab, FILES, clipboard, dock."""

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


def combo(q, *names):
    q.cmd("send-key", keys=[{"type": "qcode", "data": n} for n in names])


def key_edge(q, name, down):
    q.cmd("input-send-event", events=[{
        "type": "key",
        "data": {"down": down, "key": {"type": "qcode", "data": name}},
    }])


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: guest-record-round33.py <qmp> <serial> <framedir> <mp4>")
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
    q.key("f4")
    time.sleep(0.25)
    dump("launcher")
    for ch in ("f", "i", "l"):
        q.key(ch)
        time.sleep(0.12)
        dump("type")
    q.key("esc")
    time.sleep(0.15)
    dump("launcher-hide")
    key_edge(q, "alt", True)
    time.sleep(0.05)
    key_edge(q, "tab", True)
    key_edge(q, "tab", False)
    time.sleep(0.25)
    dump("switcher")
    key_edge(q, "tab", True)
    key_edge(q, "tab", False)
    time.sleep(0.2)
    dump("switcher-cycle")
    key_edge(q, "alt", False)
    time.sleep(0.15)
    dump("switcher-go")
    d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", False)
    time.sleep(0.4)
    dump("files")
    d15.place(q, ser, 300, 180)
    d15.button(q, 300, 180, "right", True)
    d15.button(q, 300, 180, "right", False)
    time.sleep(0.2)
    dump("files-menu")
    q.key("esc")
    for i in range(6):
        d15.place(q, ser, 80 + i * 30, 500 + (i % 2) * 8)
        dump("pointer")
        time.sleep(dt * 0.3)
    subprocess.check_call([
        "ffmpeg", "-y", "-framerate", str(int(fps)),
        "-i", os.path.join(framedir, "g%05d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p", mp4,
    ])
    print("guest-record-round33: frames=%d mp4=%s" % (n, mp4))


if __name__ == "__main__":
    raise SystemExit(main() or 0)
