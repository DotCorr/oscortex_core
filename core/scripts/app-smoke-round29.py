#!/usr/bin/env python3
"""Round 29 PLAY/STUDIO smoke: fresh PLAY HIT + STUDIO focus then e."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r29")
ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")

PLAY_XY = (
    d15.RIGHT_X + d15.ICON_PAD + 3 * (d15.ICON_S + d15.ICON_GAP) + d15.ICON_S // 2,
    d15.PANEL_Y,
)
STUDIO_XY = (
    d15.RIGHT_X + d15.ICON_PAD + 4 * (d15.ICON_S + d15.ICON_GAP) + d15.ICON_S // 2,
    d15.PANEL_Y,
)
START_XY = d15.START_XY
# PLAY attaches at (200,80); CTL0 is (96,48) 64×28 inside the card.
PLAY_CTL = (200 + 96 + 32, 80 + 48 + 14)
# STUDIO attaches at place-client origin; body click focuses before `e`.
STUDIO_BODY = (280, 140)


def harvest():
    return open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                errors="replace").read()


def click(q, xy, btn="left"):
    d15.place(q, ser, xy[0], xy[1])
    time.sleep(0.05)
    d15.button(q, xy[0], xy[1], btn, True)
    time.sleep(0.04)
    d15.button(q, xy[0], xy[1], btn, False)


def wait_re(pat, t0, timeout=8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        blob = harvest()[t0:]
        if re.search(pat, blob):
            return True
        time.sleep(0.1)
    return False


def close_near(q, xy):
    """Title-context Close so a leftover PLAY/STUDIO is not already armed."""
    click(q, xy, btn="right")
    time.sleep(0.15)
    try:
        q.key("down")
        time.sleep(0.05)
        q.key("ret")
    except Exception:
        try:
            q.key("esc")
        except Exception:
            pass
    time.sleep(0.2)


def main():
    global ser
    os.makedirs(ART, exist_ok=True)
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    marks = {}
    # Fresh PLAY lifecycle: close a leftover card, then dock-launch.
    t_prep = len(harvest())
    if re.search(r"PLAY READY", harvest()):
        close_near(q, (220, 90))
        time.sleep(0.3)
    t0 = len(harvest())
    click(q, PLAY_XY)
    marks["play_ready"] = wait_re(r"PLAY READY", t0)
    marks["play_csd"] = wait_re(r"PLAY CSD", t0)
    click(q, PLAY_CTL)
    marks["play_hit"] = wait_re(r"PLAY HIT", t0)
    if re.search(r"STUDIO2 READY", harvest()[:t0]):
        close_near(q, STUDIO_BODY)
        time.sleep(0.3)
    t1 = len(harvest())
    click(q, STUDIO_XY)
    marks["studio_ready"] = wait_re(r"STUDIO2 READY", t1)
    marks["studio_view"] = wait_re(r"STUDIO VIEW", t1)
    # Focus the card (attach also focuses under wm de) then prove EDIT.
    click(q, STUDIO_BODY)
    time.sleep(0.15)
    try:
        q.key("e")
    except Exception:
        pass
    marks["studio_edit"] = wait_re(r"STUDIO EDIT", t1)
    t2 = len(harvest())
    click(q, START_XY)
    time.sleep(0.4)
    marks["start_names"] = len(re.findall(
        r"FILES\.ELF|SET\.ELF|PING\.ELF|STUDIO\.ELF|PLAY\.ELF|BROWSE\.ELF|TAP\.ELF",
        harvest()))
    shot = os.path.join(ART, "oscortex-round29-app-smoke.png")
    gtk = None
    try:
        tree = subprocess.check_output(
            ["xwininfo", "-root", "-tree"], encoding="utf-8", errors="replace")
        name = os.environ.get("DRIVE_GTK_NAME", "oscortex-daily-drive-round29")
        for line in tree.splitlines():
            if name in line or "oscortex-daily-drive-round2" in line:
                gtk = line
                break
    except Exception:
        gtk = None
    if gtk:
        m = re.search(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)\s+\+(-?\d+)\+(-?\d+)", gtk)
        if m:
            w, h, ax, ay = int(m.group(1)), int(m.group(2)), int(m.group(5)), int(m.group(6))
            subprocess.call([
                "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                "-f", "x11grab", "-video_size", "%dx%d" % (w, h),
                "-i", "%s+%d,%d" % (os.environ.get("DISPLAY", ":1"), ax, ay),
                "-frames:v", "1", shot,
            ])
    dest = os.path.join(ART, "oscortex-round29-apps.json")
    payload = {
        "round": 29,
        "play_xy": PLAY_XY,
        "studio_xy": STUDIO_XY,
        "play_ctl": PLAY_CTL,
        "studio_body": STUDIO_BODY,
        "marks": marks,
        "play_ok": bool(marks.get("play_ready") and marks.get("play_hit")),
        "studio_ok": bool(marks.get("studio_ready") and marks.get("studio_edit")),
        "shot": shot if os.path.isfile(shot) else None,
        "prep": t_prep,
    }
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    print("wrote", dest)
    return 0 if payload["play_ok"] and payload["studio_ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
