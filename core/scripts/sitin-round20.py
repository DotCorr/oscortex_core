#!/usr/bin/env python3
"""Sit in a fresh Round 20 UEFI boot: fb/wm/de/desk + FILES + SET."""

import importlib.util
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "drive15", os.path.join(HERE, "daily-drive-round15.py"))
d15 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d15)


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: sitin-round20.py <qmp> <serial>")
    port = int(sys.argv[1])
    serial_path = sys.argv[2]
    sock = int(os.environ.get("DRIVE_SERIAL_PORT", "0"))
    if sock <= 0:
        sib = os.path.join(os.path.dirname(serial_path), "serial.port")
        try:
            sock = int(open(sib).read().strip())
        except (OSError, ValueError):
            sock = 0
    ser = d15.Serial(serial_path, sock)
    q = d15.Qmp(port)
    try:
        already = open(serial_path).read()
    except OSError:
        already = ""
    if "M1 END" not in already:
        deadline = time.time() + 50
        while time.time() < deadline:
            blob = ser.read()
            if "M1 END" in blob:
                break
            time.sleep(0.2)
        else:
            raise SystemExit("M1 END never printed")
    time.sleep(1.0)
    for cmd, wait in (("fb", 1.5), ("wm on", 2.5), ("wm gfx", 1.0),
                      ("wm de", 1.0), ("wm pace", 0.5), ("vtab", 0.4),
                      ("proc spawn desk.elf", 2.0)):
        q.type_line(cmd)
        time.sleep(wait)
    marked = ser.read()
    if "DESK READY" not in marked:
        d15.wait_mark(ser, "DESK READY", marked, 14)
    time.sleep(0.5)
    d15.press(q, ser, d15.FILES_DOCK_XY[0], d15.FILES_DOCK_XY[1],
              "left", "FILES CSD", timeout=8)
    d15.wait_mark(ser, "FILES READY", ser.read(), 8)
    d15.press(q, ser, d15.SET_DOCK_XY[0], d15.SET_DOCK_XY[1],
              "left", "SET CSD", timeout=8)
    d15.wait_mark(ser, "SET READY", ser.read(), 8)
    print("sitin-round20: DESK+FILES+SET ready")
    return 0


if __name__ == "__main__":
    sys.exit(main())
