#!/usr/bin/env python3
"""Drive kernel.elf on plain qemu64, type shell keys, dump serial + RIP.

Root-cause tool for the "Skia AA hangs on qemu64" report (ADR-0161). QMP
`human-monitor-command info registers` names the RIP the image is stuck at,
which x86_64-elf-nm then resolves to a symbol -- no gdb needed.

Usage: probe-run.py <qmp-port> <serial-path> <keys> [--fb-png PATH]
                    [--size WxH] [--fb-qemu-dir DIR]
"""
import json
import os
import re
import socket
import struct
import sys
import time
import zlib


class Qmp:
    def __init__(self, port):
        deadline = time.time() + 25
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=3)
                self.f = self.s.makefile("rw", encoding="utf-8")
                json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("no QMP: %s" % last)

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "error" in msg:
                raise SystemExit("QMP %s: %s" % (execute, msg["error"]))
            if "return" in msg:
                return msg["return"]

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})


def count(path, marker):
    if not os.path.exists(path):
        return 0
    return open(path, "rb").read().count(marker.encode("latin-1"))


def wait_marker(path, marker, timeout=45, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False


def write_png(path, width, height, pitch, bgra):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        off = y * pitch
        row = bgra[off:off + width * 4]
        if len(row) < width * 4:
            row = row + bytes(width * 4 - len(row))
        for x in range(width):
            b, g, r = row[x * 4], row[x * 4 + 1], row[x * 4 + 2]
            raw.extend((r, g, b))

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(blob)


def main():
    port = int(sys.argv[1])
    serial = sys.argv[2]
    keys = sys.argv[3]
    png = None
    qemu_dir = None
    width, height = 800, 600
    args = sys.argv[4:]
    while args:
        if args[0] == "--fb-png":
            png = args[1]
            args = args[2:]
        elif args[0] == "--size":
            width, height = (int(v) for v in args[1].split("x"))
            args = args[2:]
        elif args[0] == "--fb-qemu-dir":
            # pmemsave's filename is resolved by QEMU, not by us. When QEMU
            # is in a container the two disagree, so the caller names the
            # directory QEMU should write into; we still read our own path.
            qemu_dir = args[1]
            args = args[2:]
        else:
            args = args[1:]

    q = Qmp(port)
    if not wait_marker(serial, "M1 END\n", timeout=90):
        raise SystemExit("kernel never reached the prompt")
    time.sleep(0.5)
    for item in [k for k in keys.split(",") if k]:
        if item.startswith("wait:"):
            time.sleep(int(item.split(":", 1)[1]) / 1000.0)
            continue
        if item.startswith("until:"):
            marker = item.split(":", 1)[1]
            if not wait_marker(serial, marker + "\n", timeout=25):
                print("probe-run: NEVER SAW %r" % marker)
            continue
        q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
        time.sleep(0.05)

    # Sample RIP three times a second apart. A wedged image repeats one
    # address (or two, for a fault loop); a live one wanders.
    for i in range(3):
        regs = q.hmp("info registers")
        m = re.search(r"RIP=([0-9a-fA-F]+)", regs)
        print("probe-run: RIP[%d]=%s" % (i, m.group(1) if m else "?"))
        time.sleep(1.0)

    if png:
        text = open(serial, "r", encoding="latin-1").read()
        m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
        # Bochs prints WM ON BASE. The virtgpuk GL scanout does not: the
        # compose target is the resource backing named by VIRTIO BACK, and the
        # geometry comes from VIRTIO SCAN. Same fallback order as
        # scripts/sit-in-view.sh.
        back = re.search(r"^VIRTIO BACK ([0-9A-Fa-f]+)", text, re.M)
        mode = re.search(r"^VIRTIO MODE ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)",
                         text, re.M)
        scan = re.search(r"^VIRTIO SCAN [0-9A-Fa-f]+ [0-9A-Fa-f]+ "
                         r"([0-9A-Fa-f]+) ([0-9A-Fa-f]+)", text, re.M)
        if m or back:
            addr = int(m.group(1), 16) if m else int(back.group(1), 16)
            pitch = int(m.group(2), 16) if m else 0
            # VIRTIO MODE is the mode the driver drove SET_SCANOUT at and sized
            # the backing for, so it outranks both --size (only what we asked
            # QEMU for) and VIRTIO SCAN (only the device's GET_DISPLAY_INFO
            # readback, which the UI frontend can pin to a placeholder --
            # GAP-0328).
            if mode:
                width = int(mode.group(1), 16)
                height = int(mode.group(2), 16)
            elif scan:
                width = int(scan.group(1), 16)
                height = int(scan.group(2), 16)
            elif pitch:
                width = pitch // 4
            if not pitch:
                pitch = width * 4
            fb_bin = png + ".bin"
            where = os.path.abspath(fb_bin)
            if qemu_dir:
                where = qemu_dir.rstrip("/") + "/" + os.path.basename(fb_bin)
            q.cmd("pmemsave", val=addr, size=height * pitch, filename=where)
            for _ in range(60):
                if os.path.exists(fb_bin) and \
                        os.path.getsize(fb_bin) >= height * pitch:
                    break
                time.sleep(0.5)
            write_png(png, width, height, pitch, open(fb_bin, "rb").read())
            print("probe-run: png %s %dx%d (base 0x%X pitch %d)"
                  % (png, width, height, addr, pitch))
        else:
            print("probe-run: no WM ON BASE and no VIRTIO BACK, no png")
    q.cmd("quit")


main()
