#!/usr/bin/env python3
"""core/tests/conformance/hid-sess/hid-drive.py

QMP pointer + send-key setup, then COM1 lines for usb feed / mfeed.
Exit 0 on success, 3 on failure.
"""

import argparse
import json
import os
import socket
import sys
import time

FAIL = 3


def die(msg):
    print(f"hid-drive: {msg}", file=sys.stderr)
    sys.exit(FAIL)


class Qmp:
    def __init__(self, host, port, connect_timeout):
        deadline = time.time() + connect_timeout
        sock = None
        while time.time() < deadline:
            try:
                sock = socket.create_connection((host, port), timeout=2)
                break
            except OSError:
                sock = None
                time.sleep(0.1)
        if sock is None:
            die(f"could not connect to QMP at {host}:{port}")
        self.sock = sock
        self.f = sock.makefile("rw", encoding="utf-8", newline="\n")
        greeting = self._read()
        if "QMP" not in greeting:
            die(f"unexpected QMP greeting: {greeting!r}")
        self.version = greeting["QMP"]["version"]["qemu"]
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                die("QMP connection closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        reply = self._read()
        if "error" in reply:
            die(f"QMP {name} failed: {reply['error']}")
        return reply.get("return")


def wait_for_marker(path, marker, timeout):
    deadline = time.time() + timeout
    if isinstance(marker, str):
        marker = marker.encode("latin-1")
    while time.time() < deadline:
        try:
            with open(path, "rb") as fh:
                if marker in fh.read():
                    return True
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    return False


def wait_for_quiet(path, quiet_for, timeout):
    deadline = time.time() + timeout
    last_size = -1
    stable_since = time.time()
    while time.time() < deadline:
        size = os.path.getsize(path) if os.path.exists(path) else 0
        if size != last_size:
            last_size = size
            stable_since = time.time()
        elif time.time() - stable_since >= quiet_for:
            return True
        time.sleep(0.05)
    return False


def serial_send(port, line, ser_path, expect, timeout=15):
    end = time.time() + 10
    sock = None
    last = None
    while time.time() < end:
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=1)
            break
        except OSError as e:
            last = e
            time.sleep(0.05)
    if sock is None:
        die(f"serial connect failed: {last}")
    payload = (line + "\n").encode("latin-1")
    off = 0
    while off < len(payload):
        sock.sendall(payload[off:off + 8])
        off += 8
        time.sleep(0.03)
    end = time.time() + timeout
    want = expect.encode("latin-1") if isinstance(expect, str) else expect
    while time.time() < end:
        data = open(ser_path, "rb").read()
        if want in data:
            time.sleep(0.3)
            sock.close()
            return
        time.sleep(0.05)
    sock.close()
    die(f"serial line {line!r} never produced {expect!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp-port", type=int, required=True)
    ap.add_argument("--ser-port", type=int, required=True)
    ap.add_argument("--serial", required=True)
    ap.add_argument("--wait-for", required=True)
    ap.add_argument("--png", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--feed", required=True)
    ap.add_argument("--mfeed", required=True)
    ap.add_argument("--until-timeout", type=int, default=120)
    args = ap.parse_args()

    qmp = Qmp("127.0.0.1", args.qmp_port, connect_timeout=20)
    print(f"hid-drive: connected, QEMU {qmp.version['major']}."
          f"{qmp.version['minor']}.{qmp.version['micro']}")

    marker = args.wait_for.encode("utf-8").decode("unicode_escape").encode("latin-1")
    if not wait_for_marker(args.serial, marker, timeout=25):
        die(f"kernel never printed {args.wait_for!r}")
    print(f"hid-drive: kernel reached {args.wait_for!r}")
    time.sleep(0.5)

    typed = 0
    pointed = 0
    for qcode in [k for k in args.keys.split(",") if k]:
        if qcode.startswith("until:"):
            want = qcode.split(":", 1)[1]
            if not wait_for_marker(args.serial, want, timeout=args.until_timeout):
                die(f"serial never contained {want!r}")
            print(f"hid-drive: saw {want!r}")
            continue
        if qcode.startswith("rel:"):
            parts = qcode.split(":")
            dx, dy = int(parts[1]), int(parts[2])
            events = []
            if dx:
                events.append({"type": "rel", "data": {"axis": "x", "value": dx}})
            if dy:
                events.append({"type": "rel", "data": {"axis": "y", "value": dy}})
            qmp.cmd("input-send-event", events=events)
            pointed += 1
            time.sleep(0.05)
            continue
        if qcode.startswith("btn:"):
            parts = qcode.split(":")
            qmp.cmd("input-send-event", events=[
                {"type": "btn",
                 "data": {"button": parts[1], "down": parts[2] == "down"}}])
            pointed += 1
            time.sleep(0.05)
            continue
        if qcode.startswith("wait:"):
            time.sleep(int(qcode.split(":", 1)[1]) / 1000.0)
            continue
        if qcode.startswith("ser:"):
            # ser:FEED / ser:MFEED / ser:MOUSE — handled after keys loop below
            continue
        qmp.cmd("send-key", keys=[{"type": "qcode", "data": qcode}])
        time.sleep(0.05)
        typed += 1
    print(f"hid-drive: injected {typed} keystroke(s) and {pointed} pointer event(s)")

    # Focus is live; shell is idle (proc spawn). COM1 can run usb seams.
    serial_send(args.ser_port, args.feed, args.serial, "USB FEED")
    print(f"hid-drive: sent {args.feed!r}")
    if not wait_for_marker(args.serial, b"HID SESS SEQ", timeout=args.until_timeout):
        die("focused client never printed HID SESS SEQ")
    print("hid-drive: saw HID SESS SEQ")

    serial_send(args.ser_port, args.mfeed, args.serial, "USB MOUSE")
    print(f"hid-drive: sent {args.mfeed!r}")

    serial_send(args.ser_port, "mouse", args.serial, "MOUSE STATE")
    print("hid-drive: sent mouse")

    if not wait_for_quiet(args.serial, quiet_for=0.5, timeout=30):
        die("serial never went quiet")
    os.makedirs(os.path.dirname(args.png) or ".", exist_ok=True)
    qmp.cmd("screendump", filename=args.png)
    print(f"hid-drive: screenshot {args.png}")


if __name__ == "__main__":
    main()
