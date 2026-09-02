#!/usr/bin/env python3
"""Bridge x11vnc -pipeinput → QEMU QMP input-send-event / send-key.

rawfb discards pointer/keyboard (display-only). This helper is the input
half of the Venus door: Tiger moves → guest PS/2 mouse + keys.

Usage (stdin = x11vnc pipeinput stream):
  sit-in-view-input-bridge.py <qmp-port> <guest_w> <guest_h> <vnc_w> <vnc_h>

Coordinate space: pipeinput x/y are in the RFB desktop (after -scale).
We map into guest SCAN, then emit QMP abs 0..32767 for virtio-tablet
(ADR-0193). Not relative PS/2.
"""
from __future__ import print_function

import json
import os
import socket
import sys
import time

qmp_port = int(sys.argv[1])
guest_w, guest_h = int(sys.argv[2]), int(sys.argv[3])
vnc_w, vnc_h = int(sys.argv[4]), int(sys.argv[5])
if vnc_w < 1:
    vnc_w = guest_w
if vnc_h < 1:
    vnc_h = guest_h

log_path = os.environ.get("SITIN_INPUT_LOG", "/work/input-bridge.log")
try:
    logf = open(log_path, "a", buffering=1)
except OSError:
    logf = sys.stderr


def log(msg):
    print("input-bridge: %s" % msg, file=logf, flush=True)


# Name → QEMU qcode (send-key / input-send-event).
KEYSYM_QCODE = {
    "Return": "ret",
    "Linefeed": "ret",
    "KP_Enter": "kp_enter",
    "Escape": "esc",
    "BackSpace": "backspace",
    "Tab": "tab",
    "space": "spc",
    "Space": "spc",
    "Delete": "delete",
    "Home": "home",
    "End": "end",
    "Page_Up": "pgup",
    "Page_Down": "pgdn",
    "Left": "left",
    "Right": "right",
    "Up": "up",
    "Down": "down",
    "Insert": "insert",
    "Shift_L": "shift",
    "Shift_R": "shift_r",
    "Control_L": "ctrl",
    "Control_R": "ctrl_r",
    "Alt_L": "alt",
    "Alt_R": "alt_r",
    "Meta_L": "meta_l",
    "Meta_R": "meta_r",
    "Super_L": "meta_l",
    "Super_R": "meta_r",
    "Caps_Lock": "caps_lock",
    "minus": "minus",
    "equal": "equal",
    "bracketleft": "bracket_left",
    "bracketright": "bracket_right",
    "semicolon": "semicolon",
    "apostrophe": "apostrophe",
    "grave": "grave_accent",
    "backslash": "backslash",
    "comma": "comma",
    "period": "dot",
    "slash": "slash",
    "F1": "f1",
    "F2": "f2",
    "F3": "f3",
    "F4": "f4",
    "F5": "f5",
    "F6": "f6",
    "F7": "f7",
    "F8": "f8",
    "F9": "f9",
    "F10": "f10",
    "F11": "f11",
    "F12": "f12",
}

BTN_BITS = (
    (0x01, "left"),
    (0x02, "middle"),
    (0x04, "right"),
)


class Qmp:
    """Short-lived QMP client — open, one command, close (share with fb-refresh)."""

    def __init__(self, port):
        self.port = port

    def cmd(self, execute, **args):
        last = None
        for attempt in range(8):
            s = None
            try:
                s = socket.create_connection(("127.0.0.1", self.port), timeout=3)
                s.settimeout(8)
                f = s.makefile("rw", encoding="utf-8")
                json.loads(f.readline())
                f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
                f.flush()
                json.loads(f.readline())
                f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
                f.flush()
                while True:
                    line = f.readline()
                    if not line:
                        raise OSError("QMP closed")
                    msg = json.loads(line)
                    if "return" in msg or "error" in msg:
                        if "error" in msg:
                            raise OSError("%s: %s" % (execute, msg["error"]))
                        return msg["return"]
            except (OSError, json.JSONDecodeError, ValueError) as e:
                last = e
                time.sleep(0.05 * (attempt + 1))
            finally:
                if s is not None:
                    try:
                        s.close()
                    except OSError:
                        pass
        raise OSError("QMP %s failed: %s" % (execute, last))


def clamp(v, lo, hi):
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


def map_xy(x, y):
    gx = int(x * guest_w / float(vnc_w))
    gy = int(y * guest_h / float(vnc_h))
    return clamp(gx, 0, guest_w - 1), clamp(gy, 0, guest_h - 1)


def guest_to_abs(gx, gy):
    """QEMU tablet logical range is 0..32767."""
    ax = gx * 32767 // max(1, guest_w - 1)
    ay = gy * 32767 // max(1, guest_h - 1)
    return clamp(ax, 0, 32767), clamp(ay, 0, 32767)


def keysym_to_qcode(name, keysym):
    if name in KEYSYM_QCODE:
        return KEYSYM_QCODE[name]
    if len(name) == 1:
        c = name
        if "A" <= c <= "Z":
            return c.lower()
        if "a" <= c <= "z" or "0" <= c <= "9":
            return c
    # Printable ASCII keysym
    if 32 <= keysym <= 126:
        ch = chr(keysym)
        if ch == " ":
            return "spc"
        if ch == ".":
            return "dot"
        if "A" <= ch <= "Z":
            return ch.lower()
        if ch.isalnum():
            return ch
    return None


def main():
    q = Qmp(qmp_port)
    buttons = 0
    events = 0
    # Wait until QEMU QMP answers (boot can lag on apt/xdotool).
    for _ in range(120):
        try:
            q.cmd("query-status")
            break
        except OSError:
            time.sleep(0.5)
    else:
        raise SystemExit("input-bridge: QMP never came up")
    log(
        "ready guest=%dx%d vnc=%dx%d (virtio-tablet abs, short QMP)"
        % (guest_w, guest_h, vnc_w, vnc_h)
    )

    for raw in sys.stdin:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if not parts:
            continue
        try:
            if parts[0] == "Pointer" and len(parts) >= 5:
                # Pointer <client> <x> <y> <mask> <hint...>
                client = int(parts[1])
                if client < 0:
                    continue
                x, y, mask = int(parts[2]), int(parts[3]), int(parts[4])
                gx, gy = map_xy(x, y)
                ev = []
                ax, ay = guest_to_abs(gx, gy)
                ev.append({"type": "abs", "data": {"axis": "x", "value": ax}})
                ev.append({"type": "abs", "data": {"axis": "y", "value": ay}})
                changed = buttons ^ mask
                for bit, name in BTN_BITS:
                    if changed & bit:
                        ev.append(
                            {
                                "type": "btn",
                                "data": {
                                    "button": name,
                                    "down": bool(mask & bit),
                                },
                            }
                        )
                if ev:
                    for i in range(0, len(ev), 16):
                        q.cmd("input-send-event", events=ev[i : i + 16])
                    events += 1
                    if events <= 3 or events % 50 == 0:
                        log(
                            "ptr #%d vnc=%d,%d → guest=%d,%d mask=%d"
                            % (events, x, y, gx, gy, mask)
                        )
                buttons = mask
            elif parts[0] == "Keysym" and len(parts) >= 5:
                client = int(parts[1])
                if client < 0:
                    continue
                down = int(parts[2])
                keysym = int(parts[3])
                name = parts[4]
                qcode = keysym_to_qcode(name, keysym)
                if not qcode:
                    continue
                q.cmd(
                    "input-send-event",
                    events=[
                        {
                            "type": "key",
                            "data": {
                                "down": bool(down),
                                "key": {"type": "qcode", "data": qcode},
                            },
                        }
                    ],
                )
                events += 1
                if events <= 5 or name in ("Return", "Escape"):
                    log("key %s %s" % (qcode, "down" if down else "up"))
        except (OSError, ValueError, IndexError, json.JSONDecodeError) as e:
            log("event error %r on %r" % (e, line[:80]))
            time.sleep(0.05)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
