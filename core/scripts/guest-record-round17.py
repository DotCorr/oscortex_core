#!/usr/bin/env python3
"""Guest-only recording: QMP screendump sequence → ffmpeg.

Host Cursor/GTK chrome is never in the frames. Each dump is a fresh
scanout; stale copies are refused by writing a new filename every time.
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


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: guest-record-round17.py <qmp> <serial> <framedir> <mp4>")
    port = int(sys.argv[1])
    serial_path = sys.argv[2]
    framedir = sys.argv[3]
    mp4 = sys.argv[4]
    os.makedirs(framedir, exist_ok=True)
    q = d15.Qmp(port)
    ser = d15.Serial(serial_path, int(os.environ.get("DRIVE_SERIAL_PORT", "0")))
    fps = float(os.environ.get("DRIVE_GUEST_FPS", "8"))
    dt = 1.0 / fps
    n = 0
    t0 = time.time()

    def dump(tag):
        nonlocal n
        n += 1
        path = os.path.join(framedir, "g%05d.png" % n)
        d15.shot(q, path)
        return path

    dump("start")
    d15.place(q, ser, 200, 200)
    dump("mouse")
    d15.press(q, ser, d15.FILES_BODY_XY[0], d15.FILES_BODY_XY[1],
              "right", "WM WIN MENU", timeout=3)
    for _ in range(4):
        dump("menu")
        time.sleep(dt)
    q.key("esc")
    time.sleep(0.1)
    dump("menu-off")
    d15.place(q, ser, 120, 55)
    d15.button(q, 120, 55, "left", True)
    for dx in (0, 16, 32, 48, 64, 48, 32, 16, 0):
        d15.place(q, ser, 120 + dx, 55)
        dump("drag")
        time.sleep(dt)
    d15.button(q, 120, 55, "left", False)
    dump("drag-end")
    d15.press(q, ser, d15.FILES_MAX_XY[0], d15.FILES_MAX_XY[1],
              "left", "WM MAX", timeout=4)
    d15.wait_mark(ser, "FILES PHZ PAINT E", ser.read(), 2)
    dump("max")
    time.sleep(dt)
    dump("max2")
    d15.press(q, ser, d15.FILES_MAX_MAXED_XY[0], d15.FILES_MAX_MAXED_XY[1],
              "left", "WM MAX", timeout=4)
    dump("restore")
    time.sleep(dt)
    dump("restore2")
    d15.press(q, ser, 720, 55,
              "left", "WM DEFN", timeout=3)
    dump("set")
    d15.press(q, ser, d15.FILES_TITLE_XY[0], d15.FILES_TITLE_XY[1],
              "left", "WM DEFN", timeout=3)
    dump("files")

    elapsed = time.time() - t0
    pace = n / elapsed if elapsed > 0 else 0
    cmd = [
        "ffmpeg", "-y", "-framerate", str(int(fps)),
        "-i", os.path.join(framedir, "g%05d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        mp4,
    ]
    subprocess.check_call(cmd)
    print("guest-record frames=%d secs=%.1f paced=%.2f fps out=%s" %
          (n, elapsed, pace, mp4))
    return 0


if __name__ == "__main__":
    sys.exit(main())
