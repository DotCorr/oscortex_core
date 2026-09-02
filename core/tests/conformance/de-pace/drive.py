#!/usr/bin/env python3
"""core/tests/conformance/de-pace/drive.py

Drives the de-pace boot over QMP and derives the numbers ADR-0188 claims.

    drive.py <qmp-port> <serial> <fb.bin> <png> <lba-A-hex> <report.json>

FOUR PHASES, and each one exists because the number it produces cannot be got
from the others:

  1. `fb`, `wm on`, `wm gfx`, `wm de` -- the compositor with the session's
     Skia chrome and the generative desk. `WM DESK PX ... FRM ... AT ...` is
     printed here by the allocator, once.

  2. `proc spawn A`, then a WINDOW OF UNPACED FLOODING. The client commits a
     16x16 rectangle in a loop; the pacer is not armed, so every commit
     presents inside its own syscall and prints `WM FRAME N ... PX 00000100`.
     That is the "damage is honoured under `wm gfx`" measurement, and the
     0x100 is 16*16 exactly -- a full compose of this screen is 0x75300 plus
     the windows.

  3. `wm pace`, a MEASURED WALL-CLOCK WINDOW, `wm pace`. The two report lines
     bracket it, so PRES and COAL are deltas over a known number of seconds
     and the frame rate is a division the harness can do. This is also where
     `WM FRAME` and `WM COMMIT` go quiet, which is the point.

  4. `wm pace off`, a QUIET WINDOW, `wm pace off`. With the clock disarmed the
     presented count must not move even though the client is still committing
     as fast as it can -- that is "idle costs nothing", stated as two numbers
     that are equal.

Then the framebuffer comes out of guest physical memory with `pmemsave`, so
what run.sh probes is what the OS actually left on the screen after all of it.
"""

import json
import os
import re
import socket
import struct
import sys
import time
import zlib

# The client's stable patch. `client.c` cycles eight overlapping 16x16
# rectangles down the surface, each in a colour that is a function of its row.
# Rows 1..7 start at surface y 56 and below, so surface rows 48..55 are
# written by row 0's commit and by NOTHING ELSE -- the one patch whose colour
# does not depend on where in the cycle the dump landed.
WIN_X, WIN_Y = 100, 120
DMG_X, DMG_Y0 = 16, 48
PATCH_RGB = 0x0040F0A0
PATCH_X = WIN_X + DMG_X + 4
PATCH_Y = WIN_Y + DMG_Y0 + 2

PACED_SECS = 8.0
PACED4_SECS = 5.0
UNPACED_SECS = 3.0
IDLE_SECS = 2.5


class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("could not connect to QMP: %s" % last)

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    raise SystemExit("QMP %s: %s" % (execute, msg["error"]))
                return msg["return"]

    def keys(self, text):
        for ch in text:
            code = {" ": "spc", "\n": "ret"}.get(ch, ch.lower())
            self.cmd("send-key", keys=[{"type": "qcode", "data": code}])
            time.sleep(0.03)

    def line(self, text):
        self.keys(text + "\n")


def read_serial(path):
    if not os.path.exists(path):
        return ""
    return open(path, "r", encoding="latin-1", errors="replace").read()


def wait_marker(path, marker, timeout=60, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if read_serial(path).count(marker) >= at_least:
            return True
        time.sleep(0.1)
    return False


PACE_RE = re.compile(
    r"^WM PACE ([0-9A-F]{2}) HZ ([0-9A-F]{4}) P ([0-9A-F]{4}) "
    r"PRES ([0-9A-F]{8}) COAL ([0-9A-F]{8}) LATE ([0-9A-F]{8})",
    re.M,
)


def pace_lines(path):
    """Every `WM PACE` report so far, oldest first, as dicts of ints."""
    out = []
    for m in PACE_RE.finditer(read_serial(path)):
        out.append(
            {
                "armed": int(m.group(1), 16),
                "hz": int(m.group(2), 16),
                "period": int(m.group(3), 16),
                "pres": int(m.group(4), 16),
                "coal": int(m.group(5), 16),
                "late": int(m.group(6), 16),
            }
        )
    return out


def await_pace(path, want, timeout=25):
    """Waits for the `want`-th `WM PACE` report and returns it with the host
    clock reading taken at the moment it was OBSERVED. The interval between
    two such readings is an over-estimate of the interval between the two
    prints, never an under-estimate, so a frame rate derived from it cannot
    come out higher than the rate the OS actually achieved."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = pace_lines(path)
        if len(got) >= want:
            return got[want - 1], time.time()
        time.sleep(0.05)
    raise SystemExit("only %d WM PACE reports after %ds, wanted %d"
                     % (len(pace_lines(path)), timeout, want))


DESK_RE = re.compile(
    r"^WM DESK PX ([0-9A-F]{8}) FRM ([0-9A-F]{8}) "
    r"REGEN ([0-9A-F]{8}) BLIT ([0-9A-F]{8}) READ ([0-9A-F]{8})",
    re.M,
)

# Where the pointer starts (`wm on` composes it at the origin) and how far it
# is moved. The compositor now restores pointer save-under directly, so pointer
# motion no longer exercises `wmDeskPixel`; phase 1b opens and dismisses a
# desktop popover to force an explicit Dart damage restore through the cache.
CURSOR_W, CURSOR_H = 12, 16
CURSOR_TO = (520, 300)


def write_png(path, width, height, pitch, bgra):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        off = y * pitch
        row = bgra[off:off + width * 4]
        for x in range(width):
            b, g, r = row[x * 4], row[x * 4 + 1], row[x * 4 + 2]
            raw.extend((r, g, b))

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(blob)


def main():
    if len(sys.argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    serial, fb_bin, png, lba_a, report = sys.argv[2:7]

    q = Qmp(port)
    if not wait_marker(serial, "M1 END\n"):
        raise SystemExit("kernel never reached the prompt")
    time.sleep(0.5)

    # ---- phase 1: the compositor, the Skia session, the generative desk ----
    q.line("fb")
    time.sleep(1.5)
    q.line("wm on")
    time.sleep(2.5)
    q.line("wm gfx")
    time.sleep(3.0)
    q.line("wm de")
    time.sleep(2.0)
    if not wait_marker(serial, "OSGFX DESK GEN\n"):
        raise SystemExit("the generative desk never ran")

    # ---- phase 1b: move the pointer off the origin ------------------------
    # Small steps, because a single huge relative motion is one PS/2 packet
    # with a saturated delta and the repaint it produces is one rectangle.
    # Twenty steps are twenty damage repaints over the desktop.
    step_x = CURSOR_TO[0] // 20
    step_y = CURSOR_TO[1] // 20
    for _ in range(20):
        q.cmd("input-send-event", events=[
            {"type": "rel", "data": {"axis": "x", "value": step_x}},
            {"type": "rel", "data": {"axis": "y", "value": step_y}},
        ])
        time.sleep(0.06)
    time.sleep(0.5)

    # Open the wallpaper menu on empty desktop, move outside it, and dismiss
    # it. Hiding the card repaints its old rectangle through
    # wmPopDamageRestore -> wmRepaintRect -> wmDeskPixel, providing runtime
    # evidence that Dart damage repair reads the generated cache.
    q.cmd("input-send-event", events=[
        {"type": "btn", "data": {"button": "right", "down": True}},
    ])
    if not wait_marker(serial, "WM WALL MENU\n", timeout=10):
        raise SystemExit("desktop right-click did not open the wallpaper menu")
    q.cmd("input-send-event", events=[
        {"type": "btn", "data": {"button": "right", "down": False}},
    ])
    for _ in range(8):
        q.cmd("input-send-event", events=[
            {"type": "rel", "data": {"axis": "x", "value": 10}},
            {"type": "rel", "data": {"axis": "y", "value": 10}},
        ])
        time.sleep(0.04)
    q.cmd("input-send-event", events=[
        {"type": "btn", "data": {"button": "left", "down": True}},
    ])
    q.cmd("input-send-event", events=[
        {"type": "btn", "data": {"button": "left", "down": False}},
    ])
    time.sleep(0.5)

    # ---- phase 2: the client floods, UNPACED ------------------------------
    q.line("proc spawn " + lba_a)
    if not wait_marker(serial, "DPC COMMIT\n", timeout=45):
        raise SystemExit("the client never committed its surface")
    time.sleep(UNPACED_SECS)
    unpaced = read_serial(serial)
    small = len(re.findall(r"^WM FRAME N [0-9A-F]{8} PX 00000100 ", unpaced, re.M))
    if small < 1:
        raise SystemExit("no damage-limited present in %.1fs of flooding — the "
                         "gfx arm is still recomposing" % UNPACED_SECS)

    # ---- phase 3: the frame clock, over a measured window -----------------
    q.line("wm pace")
    first, t0 = await_pace(serial, 1)
    if first["armed"] != 1:
        raise SystemExit("`wm pace` did not arm the clock")
    time.sleep(PACED_SECS)
    q.line("wm pace")
    second, t1 = await_pace(serial, 2)
    pres = second["pres"] - first["pres"]
    coal = second["coal"] - first["coal"]
    late = second["late"] - first["late"]
    secs = t1 - t0

    # ---- phase 3b: HALVE THE CAP AND WATCH THE RATE HALVE -----------------
    # This is what says the CAP is what bounds the rate rather than the cost
    # of a present. If a paced frame were simply taking 20 ms, `wm pace` and
    # `wm pace 4` would report the same rate and the "50 fps cap" would be a
    # coincidence. The client's commit rate does not change between the two
    # windows, so the only difference is the period.
    q.line("wm pace 4")
    p4a, t2 = await_pace(serial, 3)
    if p4a["period"] != 4:
        raise SystemExit("`wm pace 4` set period %d" % p4a["period"])
    if p4a["hz"] != 25:
        raise SystemExit("`wm pace 4` reports %d Hz, not 25" % p4a["hz"])
    time.sleep(PACED4_SECS)
    q.line("wm pace 4")
    p4b, t3 = await_pace(serial, 4)
    pres4 = p4b["pres"] - p4a["pres"]
    coal4 = p4b["coal"] - p4a["coal"]
    secs4 = t3 - t2

    # ---- phase 4: disarmed, and the counter holds still -------------------
    q.line("wm pace off")
    off1, _ = await_pace(serial, 5)
    if off1["armed"] != 0:
        raise SystemExit("`wm pace off` left the clock armed")
    time.sleep(IDLE_SECS)
    q.line("wm pace off")
    off2, _ = await_pace(serial, 6)

    # ---- the screen, out of guest physical memory ------------------------
    time.sleep(1.0)
    text = read_serial(serial)
    m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
    if not m:
        raise SystemExit("never saw WM ON BASE")
    addr = int(m.group(1), 16)
    pitch = int(m.group(2), 16)
    q.cmd("pmemsave", val=addr, size=600 * pitch,
          filename=os.path.abspath(fb_bin))
    data = open(fb_bin, "rb").read()
    write_png(png, 800, 600, pitch, data)

    desks = DESK_RE.findall(text)
    if not desks:
        raise SystemExit("no `WM DESK ... REGEN ... BLIT ...` report — the "
                         "wallpaper cache never reported itself")
    last_desk = desks[-1]

    frames_total = len(re.findall(r"^WM FRAME ", text, re.M))
    small_total = len(re.findall(r"^WM FRAME N [0-9A-F]{8} PX 00000100 ",
                                text, re.M))
    commits = len(re.findall(r"^WM COMMIT ", text, re.M))
    batches = text.count("DPC BATCH\n")

    out = {
        "pitch": pitch,
        "base": addr,
        "desk_px": int(last_desk[0], 16),
        "desk_frames": int(last_desk[1], 16),
        "desk_regen": int(last_desk[2], 16),
        "desk_blit": int(last_desk[3], 16),
        "desk_read": int(last_desk[4], 16),
        "cursor_w": CURSOR_W,
        "cursor_h": CURSOR_H,
        "pres": pres,
        "coal": coal,
        "late": late,
        "paced_secs": round(secs, 3),
        "hz_reported": first["hz"],
        "period": first["period"],
        "pres4": pres4,
        "coal4": coal4,
        "paced4_secs": round(secs4, 3),
        "hz4_reported": p4a["hz"],
        "period4": p4a["period"],
        "idle_pres_before": off1["pres"],
        "idle_pres_after": off2["pres"],
        "idle_secs": IDLE_SECS,
        "unpaced_small": small,
        "frames_total": frames_total,
        "small_total": small_total,
        "commits": commits,
        "batches": batches,
        "patch_x": PATCH_X,
        "patch_y": PATCH_Y,
        "patch_rgb": "0x%06X" % PATCH_RGB,
    }
    open(report, "w").write(json.dumps(out, indent=2) + "\n")
    q.cmd("quit")
    print("DE-pace: fb @ 0x%X pitch %d; REGEN %d BLIT %d READ %d; "
          "P2 PRES %d COAL %d over %.2fs; P4 PRES %d COAL %d over %.2fs; "
          "batches %d"
          % (addr, pitch, out["desk_regen"], out["desk_blit"],
             out["desk_read"], pres, coal, secs, pres4, coal4, secs4,
             batches))
    return 0


if __name__ == "__main__":
    sys.exit(main())
