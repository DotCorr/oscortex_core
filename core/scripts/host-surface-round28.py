#!/usr/bin/env python3
"""Prove the host GTK window matches the 1280 guest scanout.

Does not scale or rewrite pixels. Records xwininfo geometry, QMP
screendump outcome, and a pmemsave of the guest backing as integrity.
"""

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

RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r28")
ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
WANT_W = 1280
WANT_H = 720


def xwin_geom(name_re):
    try:
        out = subprocess.check_output(
            ["xwininfo", "-root", "-tree"],
            encoding="utf-8", errors="replace")
    except (OSError, subprocess.CalledProcessError) as e:
        return {"error": str(e)}
    hit = None
    for line in out.splitlines():
        if re.search(name_re, line):
            hit = line
            break
    if not hit:
        return {"error": "no window matching %s" % name_re, "tree_snip": out[-800:]}
    m = re.search(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)", hit)
    geom = {
        "line": hit.strip(),
        "w": int(m.group(1)) if m else None,
        "h": int(m.group(2)) if m else None,
        "x": int(m.group(3)) if m else None,
        "y": int(m.group(4)) if m else None,
    }
    return geom


def main():
    os.makedirs(ART, exist_ok=True)
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser_path = os.path.join(RUN, "serial.txt")
    blob = open(ser_path, encoding="latin-1", errors="replace").read()
    m = re.search(r"FB VIRTIO ([0-9A-Fa-f]+)x([0-9A-Fa-f]+) AT ([0-9A-Fa-f]+)", blob)
    gop = re.search(r"FB GOP ([0-9A-Fa-f]+)x([0-9A-Fa-f]+) AT ([0-9A-Fa-f]+)", blob)
    fb = {}
    if m:
        fb = {
            "kind": "VIRTIO",
            "w": int(m.group(1), 16),
            "h": int(m.group(2), 16),
            "at": m.group(3),
        }
    elif gop:
        fb = {
            "kind": "GOP",
            "w": int(gop.group(1), 16),
            "h": int(gop.group(2), 16),
            "at": gop.group(3),
        }
    gtk = xwin_geom(r"oscortex-daily-drive-round28|QEMU")
    qmp_dump = os.path.join(ART, "oscortex-round28-qmp-screendump.ppm")
    qmp_ok = False
    qmp_err = None
    try:
        q.cmd("screendump", filename=qmp_dump)
        qmp_ok = os.path.isfile(qmp_dump) and os.path.getsize(qmp_dump) > 64
    except Exception as e:
        qmp_err = str(e)
    rawp = os.path.join(RUN, "guest-fb.bgra")
    pngp = os.path.join(ART, "oscortex-round28-host-1280.png")
    pmem_ok = False
    if fb.get("at"):
        addr = int(fb["at"], 16)
        try:
            q.cmd("pmemsave", val=addr, size=WANT_W * WANT_H * 4, filename=rawp)
            data = open(rawp, "rb").read()
            pmem_ok = len(data) >= WANT_W * WANT_H * 4
            if pmem_ok:
                from PIL import Image
                img = Image.frombytes(
                    "RGBX", (WANT_W, WANT_H), data[:WANT_W * WANT_H * 4],
                    "raw", "BGRX")
                img.convert("RGB").save(pngp)
        except Exception as e:
            pmem_ok = False
            fb["pmem_err"] = str(e)
    host_shot = os.path.join(ART, "oscortex-round28-gtk-window.png")
    host_shot_ok = False
    try:
        subprocess.check_call(
            ["import", "-window", "root", host_shot],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        host_shot_ok = os.path.isfile(host_shot)
    except Exception:
        host_shot_ok = False
    gtk_w = gtk.get("w")
    gtk_h = gtk.get("h")
    # Title chrome can add ~20-40px; require the client area to cover 1280×720.
    real_1280 = bool(
        gtk_w and gtk_h
        and gtk_w >= WANT_W
        and gtk_h >= WANT_H
        and fb.get("w") == WANT_W
        and fb.get("h") == WANT_H
        and pmem_ok)
    payload = {
        "round": 28,
        "guest_fb": fb,
        "gtk": gtk,
        "qmp_screendump": qmp_ok,
        "qmp_screendump_error": qmp_err,
        "pmemsave": pmem_ok,
        "host_root_shot": host_shot_ok,
        "real_host_1280": real_1280,
        "note": (
            "real_host_1280 means GTK widget >=1280x720 and guest backing "
            "is 1280x720; pmemsave PNG is integrity, not a scaled fake."
        ),
    }
    dest = os.path.join(ART, "oscortex-round28-host-surface.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    print("wrote", dest)
    return 0 if real_1280 else 1


if __name__ == "__main__":
    sys.exit(main())
