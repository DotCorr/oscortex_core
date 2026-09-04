#!/usr/bin/env python3
"""Guest-pixel Round 35 recording: QMP screendump sequence → ffmpeg.

Shows wallpaper-miss park, launcher (F4), switcher (Alt-Tab), dock apps,
FILES+STUDIO, and SET. Writes oscortex-daily-drive-round35-guest.mp4.
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


def dock_xy(i):
    return (d15.RIGHT_X + d15.ICON_PAD + i * (d15.ICON_S + d15.ICON_GAP)
            + d15.ICON_S // 2, d15.PANEL_Y)


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: guest-record-round35.py <qmp> <serial> <framedir> <mp4>")
    port = int(sys.argv[1])
    serial_path = sys.argv[2]
    framedir = sys.argv[3]
    mp4 = sys.argv[4]
    os.makedirs(framedir, exist_ok=True)
    q = d15.Qmp(port)
    sock = 0
    sib = os.path.join(os.path.dirname(serial_path), "serial.port")
    try:
        sock = int(open(sib).read().strip())
    except (OSError, ValueError):
        sock = 0
    if str(serial_path).isdigit():
        sock = int(serial_path)
        serial_path = os.environ.get(
            "DRIVE_SERIAL_FILE",
            "/workspace/core/build/daily-drive-r35/serial.txt")
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

    def click(x, y):
        d15.place(q, ser, x, y)
        time.sleep(0.03)
        d15.button(q, x, y, "left", True)
        time.sleep(0.03)
        d15.button(q, x, y, "left", False)

    def key_edge(code, down):
        q.cmd("input-send-event", events=[{
            "type": "key",
            "data": {"down": down, "key": {"type": "qcode", "data": code}},
        }])

    t0 = time.time()
    dump("start")
    # Wallpaper-miss park (400,500 stays clear of leftover windows).
    click(400, 500)
    time.sleep(0.12)
    dump("park")
    # Launcher catalog.
    q.key("f4")
    time.sleep(0.25)
    dump("launcher")
    time.sleep(dt)
    dump("launcher2")
    q.key("esc")
    time.sleep(0.12)
    dump("launcher-off")
    # Switcher.
    key_edge("alt", True)
    time.sleep(0.04)
    key_edge("tab", True)
    key_edge("tab", False)
    time.sleep(0.18)
    dump("switcher")
    key_edge("tab", True)
    key_edge("tab", False)
    time.sleep(0.12)
    dump("switcher2")
    key_edge("alt", False)
    time.sleep(0.1)
    dump("switcher-off")
    # Dock apps: SET FILES BROWSE PLAY STUDIO TAP.
    for i, tag in enumerate(("set", "files", "browse", "play", "studio", "tap")):
        x, y = dock_xy(i)
        click(x, y)
        time.sleep(0.35)
        dump(tag)
    click(400, 500)
    time.sleep(0.1)
    dump("all-apps")
    # FILES focus + STUDIO dock.
    fx, fy = dock_xy(1)
    click(fx, fy)
    time.sleep(0.2)
    dump("files")
    sx, sy = dock_xy(4)
    click(sx, sy)
    time.sleep(0.25)
    dump("files-studio")
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
