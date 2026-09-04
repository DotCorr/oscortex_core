#!/usr/bin/env python3
"""Type the sit-in door on a live Round 31 QEMU. Wait FB VIRTIO before Venus."""

import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "d15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)

RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r31")


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


if __name__ == "__main__":
    sys.exit(main() or 0)
