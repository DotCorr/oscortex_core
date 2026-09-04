#!/usr/bin/env python3
"""Type the sit-in door on a live Round 36 QEMU. Wait FB VIRTIO before Venus."""

import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r36")


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    deadline = time.time() + 50
    while time.time() < deadline:
        if "M1 END" in (open(os.path.join(RUN, "serial.txt")).read()):
            break
        time.sleep(0.3)
    else:
        raise SystemExit("boot-sit-in: no M1 END")
    venus = "0"
    try:
        venus = open(os.path.join(RUN, "venus.flag")).read().strip()
    except OSError:
        pass
    q.type_line("fb")
    blob = open(os.path.join(RUN, "serial.txt")).read()
    if "FB VIRTIO " not in blob and "FB GOP " not in blob and "FB BAR " not in blob:
        d15.wait_mark(ser, "FB ", blob, timeout=45)
    blob = open(os.path.join(RUN, "serial.txt")).read()
    if venus == "1":
        if "FB VIRTIO " not in blob:
            raise SystemExit("boot-sit-in: Venus leftover expected FB VIRTIO")
        q.type_line("virtgpuv")
        if "VIRTIO VENUS OK" not in open(os.path.join(RUN, "serial.txt")).read():
            if not d15.wait_mark(ser, "VIRTIO VENUS OK", blob, timeout=20):
                raise SystemExit("boot-sit-in: no VIRTIO VENUS OK")
    for line in ("wm on", "wm gfx", "wm de", "wm pace", "vtab",
                 "proc spawn desk.elf"):
        q.type_line(line)
        time.sleep(1.2 if line in ("wm on", "wm gfx") else 0.6)
    blob = open(os.path.join(RUN, "serial.txt")).read()
    if "DESK READY" not in blob:
        if not d15.wait_mark(ser, "DESK READY", blob, timeout=16):
            raise SystemExit("boot-sit-in: no DESK READY")
    oom = blob.count("OSGFX OOM")
    print("boot-sit-in: DESK READY venus=%s fb=%s oom=%d" % (
        venus,
        "VIRTIO" if "FB VIRTIO " in blob else (
            "GOP" if "FB GOP " in blob else "other"),
        oom))
    if oom:
        raise SystemExit("boot-sit-in: OSGFX OOM during sit-in")
    # Fresh attach: FILES at default title/geom for R31 proof.
    d15.place(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1])
    time.sleep(0.05)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", True)
    time.sleep(0.04)
    d15.button(q, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1], "left", False)
    t1 = time.time()
    while time.time() - t1 < 4.0:
        blob = open(os.path.join(RUN, "serial.txt"), encoding="latin-1",
                    errors="replace").read()
        if "FILES SLOT" in blob or "FILES CSD" in blob:
            print("boot-sit-in: FILES attached")
            return
        time.sleep(0.1)
    print("boot-sit-in: WARN no FILES token (measure will dock-click)")


if __name__ == "__main__":
    sys.exit(main() or 0)
