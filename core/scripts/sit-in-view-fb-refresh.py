#!/usr/bin/env python3
"""Poll serial for FB base, then pmemsave into view-fb.bin for x11vnc -rawfb.

Writes in-place (no truncate) so x11vnc's mmap stays valid.

Usage: sit-in-view-fb-refresh.py <qemu-pid> <qmp-port> <view_w> <view_h>
Paths are container-side: /work/serial.txt, /work/view-fb.bin.
"""
import json
import os
import re
import socket
import sys
import time

qpid = int(sys.argv[1])
qmp_port = int(sys.argv[2])
want_w, want_h = int(sys.argv[3]), int(sys.argv[4])
ser_path = "/work/serial.txt"
fb_path = "/work/view-fb.bin"
fb_tmp = "/work/view-fb.tmp"


def alive():
    try:
        os.kill(qpid, 0)
        return True
    except OSError:
        return False


def parse_geom(text):
    # VIRTIO MODE is the mode the driver actually drove SET_SCANOUT at and
    # sized the backing for; VIRTIO SCAN is only the device's GET_DISPLAY_INFO
    # readback, which the UI frontend can pin to a placeholder (GAP-0328).
    mode = re.search(
        r"^VIRTIO MODE ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)", text, re.M
    )
    scan = re.search(
        r"^VIRTIO SCAN [0-9A-Fa-f]+ [0-9A-Fa-f]+ ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)",
        text,
        re.M,
    )
    base = re.search(
        r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M
    )
    back = re.search(r"^VIRTIO BACK ([0-9A-Fa-f]+)", text, re.M)
    w = h = pitch = addr = None
    if mode:
        w, h = int(mode.group(1), 16), int(mode.group(2), 16)
    elif scan:
        w, h = int(scan.group(1), 16), int(scan.group(2), 16)
    if base:
        addr, pitch = int(base.group(1), 16), int(base.group(2), 16)
    elif back:
        addr = int(back.group(1), 16)
    if w is None:
        w, h = want_w, want_h
    if pitch is None and w is not None:
        pitch = w * 4
    return w, h, pitch, addr


def qmp_pmemsave(addr, size, filename):
    # 15s: Venus GL load can stall QMP briefly; 2s read as "stale FB".
    s = socket.create_connection(("127.0.0.1", qmp_port), timeout=5)
    s.settimeout(15)
    f = s.makefile("rw", encoding="utf-8")
    json.loads(f.readline())
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
    f.flush()
    json.loads(f.readline())
    f.write(
        json.dumps(
            {
                "execute": "pmemsave",
                "arguments": {
                    "val": addr,
                    "size": size,
                    "filename": filename,
                },
            }
        )
        + "\n"
    )
    f.flush()
    msg = json.loads(f.readline())
    s.close()
    if "error" in msg:
        raise OSError(str(msg["error"]))


def install_fb(size):
    """pmemsave to tmp, then overwrite mapped file in-place (no truncate)."""
    qmp_pmemsave(addr, size, fb_tmp)
    data = open(fb_tmp, "rb").read(size)
    if len(data) < size:
        raise OSError("short pmemsave %d < %d" % (len(data), size))
    # Ensure target exists at full size for the initial mmap.
    if not os.path.isfile(fb_path) or os.path.getsize(fb_path) < size:
        open(fb_path, "wb").write(b"\0" * size)
    with open(fb_path, "r+b") as out:
        out.seek(0)
        out.write(data)
        out.flush()
        os.fsync(out.fileno())


addr = pitch = width = height = None
while alive() and addr is None:
    if os.path.isfile(ser_path):
        text = open(ser_path, encoding="latin-1").read()
        width, height, pitch, addr = parse_geom(text)
        if addr is not None:
            print(
                "fb-refresh: %dx%d pitch %d @ 0x%X"
                % (width, height, pitch, addr),
                flush=True,
            )
            break
    time.sleep(0.3)

if addr is None:
    sys.exit(0)

size = height * pitch
while alive():
    try:
        install_fb(size)
    except (OSError, json.JSONDecodeError, ValueError) as e:
        print("fb-refresh: %s" % e, flush=True)
        time.sleep(0.5)
        continue
    time.sleep(0.35)
