#!/usr/bin/env python3
"""core/tests/conformance/d9-focus/d9-drive.py

Drives QEMU over QMP for D9. Same input vocabulary as d7-drive.py
(rel:, btn:, wait:, qcodes, until:<substring>). Composition is slow; a
click injected before both surfaces exist would be a desktop click and
the keys would go to the shell.

Exit status: 0 on success, 3 on any QMP/timeout failure.
"""

import argparse
import json
import os
import socket
import sys
import time

FAIL = 3


def die(msg):
    print(f"d9-drive: {msg}", file=sys.stderr)
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
            die(f"could not connect to QMP at {host}:{port} within "
                f"{connect_timeout}s -- did QEMU start?")
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
                die("QMP connection closed unexpectedly")
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
            die(f"QMP command {name} failed: {reply['error']}")
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--serial", required=True)
    ap.add_argument("--wait-for", required=True)
    ap.add_argument("--png", required=True)
    ap.add_argument("--keys", required=True)
    ap.add_argument("--until-timeout", type=int, default=120)
    args = ap.parse_args()

    qmp = Qmp(args.host, args.port, connect_timeout=20)
    print(f"d9-drive: connected, QEMU {qmp.version['major']}."
          f"{qmp.version['minor']}.{qmp.version['micro']}")

    marker = args.wait_for.encode("utf-8").decode("unicode_escape").encode("latin-1")
    if not wait_for_marker(args.serial, marker, timeout=25):
        die(f"kernel never printed {args.wait_for!r}")
    print(f"d9-drive: kernel reached {args.wait_for!r}")
    time.sleep(0.5)

    keys = [k for k in args.keys.split(",") if k]
    typed = 0
    pointed = 0
    for qcode in keys:
        if qcode.startswith("until:"):
            want = qcode.split(":", 1)[1]
            if not wait_for_marker(args.serial, want, timeout=args.until_timeout):
                die(f"serial never contained {want!r} within "
                    f"{args.until_timeout}s")
            print(f"d9-drive: saw {want!r}")
            continue
        if qcode.startswith("rel:"):
            parts = qcode.split(":")
            if len(parts) != 3:
                die("malformed pointer element %r -- want rel:<dx>:<dy>" % qcode)
            dx, dy = int(parts[1]), int(parts[2])
            events = []
            if dx:
                events.append({"type": "rel", "data": {"axis": "x", "value": dx}})
            if dy:
                events.append({"type": "rel", "data": {"axis": "y", "value": dy}})
            if not events:
                die("rel:0:0 would send no event at all")
            qmp.cmd("input-send-event", events=events)
            pointed += 1
            time.sleep(0.05)
            continue
        if qcode.startswith("btn:"):
            parts = qcode.split(":")
            if len(parts) != 3 or parts[2] not in ("down", "up"):
                die("malformed button element %r -- want btn:<name>:<down|up>"
                    % qcode)
            qmp.cmd("input-send-event", events=[
                {"type": "btn",
                 "data": {"button": parts[1], "down": parts[2] == "down"}}])
            pointed += 1
            time.sleep(0.05)
            continue
        if qcode.startswith("wait:"):
            time.sleep(int(qcode.split(":", 1)[1]) / 1000.0)
            continue
        qmp.cmd("send-key", keys=[{"type": "qcode", "data": qcode}])
        time.sleep(0.05)
        typed += 1
    print(f"d9-drive: injected {typed} keystroke(s) and {pointed} pointer event(s)")

    if not wait_for_quiet(args.serial, quiet_for=0.5, timeout=30):
        die("serial output never went quiet after the script")

    os.makedirs(os.path.dirname(args.png) or ".", exist_ok=True)
    qmp.cmd("screendump", filename=args.png)
    print(f"d9-drive: screenshot {args.png}")


if __name__ == "__main__":
    main()
