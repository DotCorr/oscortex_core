#!/usr/bin/env python3
"""Guest-only Round 19 recording: QMP screendump sequence → ffmpeg.

Host Cursor/GTK chrome is never in the frames. Target a 20–60s
pointer/drag/scroll/focus sequence to show dirty-region present.
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

SET_CARD0 = (584 + 132 + 44, 40 + 84 + 16)
SET_CARD1 = (584 + 228 + 44, 40 + 84 + 16)


def main():
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: guest-record-round19.py <qmp> <serial> <framedir> <mp4>")
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
        if str(serial_path).isdigit():
            sock = int(serial_path)
            serial_path = os.environ.get(
                "DRIVE_SERIAL_FILE",
                "/workspace/core/build/daily-drive-r19/serial.txt")
    ser = d15.Serial(serial_path, sock)
    fps = float(os.environ.get("DRIVE_GUEST_FPS", "8"))
    dt = 1.0 / fps
    n = 0
    t0 = time.time()
    loops = int(os.environ.get("DRIVE_GUEST_LOOPS", "4"))

    def dump(_tag):
        nonlocal n
        n += 1
        path = os.path.join(framedir, "g%05d.png" % n)
        d15.shot(q, path)
        return path

    dump("start")
    for i in range(12):
        d15.place(q, ser, 80 + i * 20, 140 + (i % 4) * 10)
        dump("pointer")
        time.sleep(dt * 0.4)
    for _lp in range(loops):
        d15.press(q, ser, d15.FILES_BODY_XY[0], d15.FILES_BODY_XY[1],
                  "right", "WM WIN MENU", timeout=3)
        for _ in range(2):
            dump("menu")
            time.sleep(dt)
        q.key("esc")
        time.sleep(0.06)
        dump("menu-off")
        d15.place(q, ser, 120, 55)
        d15.button(q, 120, 55, "left", True)
        for dx in (0, 16, 32, 48, 64, 48, 32, 16, 0):
            d15.place(q, ser, 120 + dx, 55)
            dump("drag")
            time.sleep(dt * 0.5)
        d15.button(q, 120, 55, "left", False)
        dump("drag-end")
        d15.press(q, ser, 200, 180, "left", "WM DEFN", timeout=2)
        dump("scroll-body")
        d15.press(q, ser, 720, 55, "left", "WM DEFN", timeout=3)
        dump("set-focus")
        d15.press(q, ser, SET_CARD0[0], SET_CARD0[1], "left", "SET CARD",
                  timeout=2)
        dump("card0")
        d15.press(q, ser, SET_CARD1[0], SET_CARD1[1], "left", "SET CARD",
                  timeout=2)
        dump("card1")
        d15.press(q, ser, d15.FILES_TITLE_XY[0], d15.FILES_TITLE_XY[1],
                  "left", "WM DEFN", timeout=3)
        dump("files-focus")
        if _lp == 0:
            d15.press(q, ser, d15.FILES_MAX_XY[0], d15.FILES_MAX_XY[1],
                      "left", "WM MAX", timeout=4)
            dump("max")
            time.sleep(dt)
            d15.press(q, ser, d15.FILES_MAX_MAXED_XY[0],
                      d15.FILES_MAX_MAXED_XY[1], "left", "WM MAX", timeout=4)
            dump("restore")

    elapsed = time.time() - t0
    pace = n / elapsed if elapsed > 0 else 0
    cmd = [
        "ffmpeg", "-y", "-framerate", str(max(1, int(fps))),
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
