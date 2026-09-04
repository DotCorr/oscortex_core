#!/usr/bin/env python3
"""30–60s guest-only demo: dock apps + pointer/menu, then ffmpeg mp4."""

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

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r26")
SCREEN_W = 1280
ICON_S, ICON_GAP, ICON_PAD, ICON_N = 32, 8, 16, 6
RIGHT_W = ICON_PAD + ICON_N * ICON_S + (ICON_N - 1) * ICON_GAP + ICON_PAD
RIGHT_X = SCREEN_W - 16 - RIGHT_W
PANEL_Y = 720 - 48 + 20


def dock_xy(i):
    return (RIGHT_X + ICON_PAD + i * (ICON_S + ICON_GAP) + ICON_S // 2, PANEL_Y)


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    frames = os.path.join(RUN, "demo-frames")
    os.makedirs(frames, exist_ok=True)
    os.makedirs(ART, exist_ok=True)
    t0 = time.time()
    n = 0

    def snap():
        nonlocal n
        path = os.path.join(frames, "f%04d.png" % n)
        try:
            d15.shot(q, path)
            n += 1
        except Exception as e:
            print("shot miss", e)

    for i, tok in ((0, "SET"), (1, "FILES"), (2, "BROWSE")):
        x, y = dock_xy(i)
        d15.press(q, ser, x, y, "left", "DESK LAUNCH", timeout=6)
        snap()
    for i in range(10):
        d15.place(q, ser, 80 + i * 40, 200 + (i % 4) * 20)
        time.sleep(0.08)
        snap()
    d15.timed_click(q, ser, 48, 520, "right", timeout=2.0)
    snap()
    try:
        q.key("esc")
    except Exception:
        pass
    while time.time() - t0 < 34:
        d15.place(q, ser, 200 + int((time.time() - t0) * 18) % 400, 240)
        snap()
        time.sleep(0.28)
    if n < 8:
        raise SystemExit("demo: too few frames %d" % n)
    mp4 = os.path.join(ART, "oscortex-daily-drive-round26-guest.mp4")
    subprocess.check_call([
        "ffmpeg", "-y", "-framerate", "8",
        "-i", os.path.join(frames, "f%04d.png"),
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22",
        mp4,
    ])
    print("demo frames", n, "mp4", mp4, "sec", round(time.time() - t0, 1))


if __name__ == "__main__":
    sys.exit(main() or 0)
