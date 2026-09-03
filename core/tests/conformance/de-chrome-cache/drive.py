#!/usr/bin/env python3
"""core/tests/conformance/de-chrome-cache/drive.py

    drive.py <qmp-port> <serial> <fb.bin> <png> <lba-A-hex> <report.json>

Drives the boot ADR-0191's claims are read out of, and the shape of it is
chosen so that the two halves of a cache are proved SEPARATELY. A cache that
never serves is merely slow; a cache that never INVALIDATES is wrong, and a
harness that only measures speed cannot tell the second from a correct one.
Every pixel probe de-session owns would pass against a chrome cache frozen at
the first frame for ever.

So there are six report windows and each one answers exactly one question.

  1. Bring the compositor up: `fb`, `wm on`, `wm gfx`, `wm de`. The generative
     desk runs and `WM CHROME PX ... FRM ... AT ...` prints once, from the
     allocator. REPORT 1 is the baseline.

  2. `wm draw` x N. Each is a FULL compose -- wm.dart says so in as many
     words: "`wm on` and `wm draw` still compose a full frame: they have no
     damage to honour" -- so each reaches the Skia session tick with every
     input to the key unchanged. REPORT 2 against REPORT 1 is THE SERVE, and
     the assertion is that REGEN moved by ZERO. Not "by little": a single
     rasterisation across N identical composes would mean the key folds
     something that changes per tick, which is the one bug that would make
     the whole cache a slower way of not caching.

     This window is also the CONTROL for windows 3, 4 and 6: it establishes
     that a `wm draw` on its own does not rasterise, so a REGEN that moves
     after one can only be the state change that preceded it.

  3. A left click on the Start pill. `wmDeGrab` -> `wmDeStartShow` sets
     `wmMetaPop`, which `wmgfx.dart` packs into the mailbox `pop` word, and
     prints `WM DE START nn` -- so the harness waits for the OS to say the
     popover opened rather than assuming the click landed. Then one
     `wm draw`. REPORT 3 must move REGEN: THE POPOVER INVALIDATES.

  4. A left click on empty desktop. `wmDeGrab` finds no launch-popover hit and
     calls `wmDePopHide`, which clears `wmMetaPop` through a DAMAGE repaint
     rather than a compose -- so this also proves the key, not the compose
     path, is what notices: the state went back and the next full frame had
     to be rasterised again. REPORT 4 must move REGEN.

  5. `wm fps`, which prints the before/after ladder in one binary at one
     resolution seconds apart. `K D` rasterises chrome AND taskbar gradient
     every iteration -- the pre-ADR-0191 tick, reconstructed -- `K B`
     rasterises chrome and blits the band, `K 4` blits both. `K C` and `K 5`
     are the same for a full compose. REPORT 5 follows.

  6. `proc spawn A`. A window maps: `win0` gains a slot, geometry and focus,
     and the mailbox tone words start carrying the client's edge colours.
     One `wm draw`, then REPORT 6 must move REGEN: GEOMETRY INVALIDATES.

     Only ONE client is spawned. Two leave two resident processes
     round-robin-preempting with IRQ0 unmasked, the serial fills with
     `PROC PREEMPT`, and the shell never gets to read the next line -- which
     is a real property of the OS at this rung and not something to work
     around by typing harder.

Then `pmemsave` takes the framebuffer out of guest physical memory, so what
run.sh probes for ADR-0187's AA fringes, gradient and outline caption is what
the OS left on the screen after all of the above -- through the cache.
"""

import json
import os
import re
import socket
import struct
import sys
import time
import zlib

TICK_MS = 10.0  # the PIT is 100 Hz (pitInit)

# How many full composes the serve window asks for. Twelve rather than three
# because the claim is "REGEN does not move at all", and a stray rasterisation
# is easier to catch over more ticks.
DRAWS = 12

# The Start pill: `wmStartHit` accepts x < wmStartW (96) and y >= wmStartY
# (fbGeomHeight - wmChromeH). At 800x600 that is the bottom-left corner.
START_XY = (20, 580)
# Empty desktop, clear of the launch popover, the notify button and any window.
DESK_XY = (400, 300)
# Window A's origin, from d3-session's client, carried into the report so that
# run.sh's probe coordinates and this file's cannot drift apart.
WIN_X, WIN_Y = 100, 120


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
                self.at = (0, 0)
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

    def line(self, text):
        for ch in text + "\n":
            code = {" ": "spc", "\n": "ret"}.get(ch, ch.lower())
            self.cmd("send-key", keys=[{"type": "qcode", "data": code}])
            time.sleep(0.03)

    def move_to(self, x, y, steps=20):
        """Walks the PS/2 pointer to (x, y) in small relative steps.

        Small steps because a single huge relative motion is one PS/2 packet
        with a saturated delta, and the pointer would stop short of the target
        with no way for this file to tell. `wmPointerTick` integrates 1:1
        (de-pace asserts that), so twenty steps of a twentieth land on it.
        """
        dx, dy = x - self.at[0], y - self.at[1]
        for i in range(steps):
            sx = dx // steps if i < steps - 1 else dx - (dx // steps) * (steps - 1)
            sy = dy // steps if i < steps - 1 else dy - (dy // steps) * (steps - 1)
            events = []
            if sx:
                events.append({"type": "rel", "data": {"axis": "x", "value": sx}})
            if sy:
                events.append({"type": "rel", "data": {"axis": "y", "value": sy}})
            if events:
                self.cmd("input-send-event", events=events)
            time.sleep(0.04)
        self.at = (x, y)

    def click(self, button="left"):
        for down in (True, False):
            self.cmd("input-send-event", events=[
                {"type": "btn", "data": {"button": button, "down": down}}])
            time.sleep(0.08)


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


CHROME_RE = re.compile(
    r"^WM CHROME PX ([0-9A-F]{8}) FRM ([0-9A-F]{8}) REGEN ([0-9A-F]{8}) "
    r"BLIT ([0-9A-F]{8}) GLYPH ([0-9A-F]{8}) HIT ([0-9A-F]{8})",
    re.M,
)
BAND_RE = re.compile(
    r"^WM BAND PX ([0-9A-F]{8}) FILL ([0-9A-F]{8}) HIT ([0-9A-F]{8})", re.M
)
DESK_RE = re.compile(
    r"^WM DESK PX ([0-9A-F]{8}) FRM ([0-9A-F]{8}) "
    r"REGEN ([0-9A-F]{8}) BLIT ([0-9A-F]{8}) READ ([0-9A-F]{8})",
    re.M,
)
FPS_RE = re.compile(r"^WM FPS K ([0-9A-F]) N ([0-9A-F]{8}) T ([0-9A-F]{8})", re.M)


def chrome_reports(path):
    """Every `WM CHROME` report so far, oldest first, with its `WM BAND` line.

    `wmChromeReportLine` emits the two back to back, so the n-th of each belong
    to the same report and are paired by index rather than by proximity in the
    text. The allocator's own `WM CHROME PX ... AT ...` line does not match
    CHROME_RE (no `REGEN`), which is what keeps it out of this list.
    """
    text = read_serial(path)
    ch = [
        {
            "px": int(m.group(1), 16),
            "frames": int(m.group(2), 16),
            "regen": int(m.group(3), 16),
            "blit": int(m.group(4), 16),
            "glyph_fill": int(m.group(5), 16),
            "glyph_hit": int(m.group(6), 16),
        }
        for m in CHROME_RE.finditer(text)
    ]
    bd = [
        {
            "px": int(m.group(1), 16),
            "fill": int(m.group(2), 16),
            "hit": int(m.group(3), 16),
        }
        for m in BAND_RE.finditer(text)
    ]
    dk = [
        {
            "px": int(m.group(1), 16),
            "frames": int(m.group(2), 16),
            "regen": int(m.group(3), 16),
            "blit": int(m.group(4), 16),
            "read": int(m.group(5), 16),
        }
        for m in DESK_RE.finditer(text)
    ]
    for i, c in enumerate(ch):
        c["band"] = bd[i] if i < len(bd) else None
        c["desk"] = dk[i] if i < len(dk) else None
    return ch


def report(q, path, want, what, timeout=30):
    """Asks for a report and waits for the `want`-th one to land.

    `wm pace off` rather than `wm pace`, because arming the frame clock would
    put IRQ0-driven composes between two windows and every count in them would
    then include frames this harness did not ask for. Disarming prints the same
    line and leaves the clock where it already was.
    """
    q.line("wm pace off")
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = chrome_reports(path)
        if len(got) >= want:
            if got[want - 1]["band"] is None:
                raise SystemExit("report %d has no WM BAND line" % want)
            if got[want - 1]["desk"] is None:
                raise SystemExit("report %d has no WM DESK line" % want)
            r = got[want - 1]
            print("  report %d (%s): REGEN %d BLIT %d DESK regen %d blit %d"
                  % (want, what, r["regen"], r["blit"], r["desk"]["regen"],
                     r["desk"]["blit"]))
            return r
        time.sleep(0.05)
    raise SystemExit(
        "only %d WM CHROME reports after %ds, wanted %d (%s). `WM CHROME NONE` "
        "in the serial means the run was never allocated; no line at all means "
        "the shell never read the command."
        % (len(chrome_reports(path)), timeout, want, what)
    )


def fps_stages(path):
    """Per-iteration milliseconds for every `wm fps` stage.

    The LAST run of a kind wins. `wmFpsCmd` deliberately runs `K 5` twice, at
    opposite ends of the command, to separate a real cost outside the tick from
    drift across the run; the later one is the one taken beside `K C`.
    """
    out = {}
    for m in FPS_RE.finditer(read_serial(path)):
        kind, n, t = m.group(1), int(m.group(2), 16), int(m.group(3), 16)
        out[kind] = {
            "iters": n,
            "ticks": t,
            "ms": (t * TICK_MS) / n if n else None,
        }
    return out


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
    serial, fb_bin, png, lba_a, report_path = sys.argv[2:7]

    q = Qmp(port)
    if not wait_marker(serial, "M1 END\n"):
        raise SystemExit("kernel never reached the prompt")
    time.sleep(0.5)

    # ---- 1: the compositor, the Skia session, the generative desk ---------
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
    r1 = report(q, serial, 1, "baseline")

    # ---- 2: N full composes with every key input unchanged ---------------
    for _ in range(DRAWS):
        q.line("wm draw")
        time.sleep(0.12)
    time.sleep(0.4)
    r2 = report(q, serial, 2, "after %d x wm draw" % DRAWS)

    # ---- 3: the popover opens, and the key moves ------------------------
    q.move_to(*START_XY)
    q.click()
    if not wait_marker(serial, "WM DE START ", timeout=20):
        raise SystemExit(
            "the Start pill click did not open the launcher (no `WM DE START`); "
            "the pointer is at %r and wmStartHit wants x < 96, y >= 552"
            % (START_XY,))
    time.sleep(0.3)
    q.line("wm draw")
    time.sleep(0.5)
    r3 = report(q, serial, 3, "popover open")

    # ---- 4: the popover closes, and the key moves back ------------------
    q.move_to(*DESK_XY)
    q.click()
    time.sleep(0.3)
    q.line("wm draw")
    time.sleep(0.5)
    r4 = report(q, serial, 4, "popover closed")

    # ---- 5: the before/after ladder -------------------------------------
    # `K 6` (TickSolid) is printed LAST by `wmFpsCmd`, so its arrival is the
    # command's own statement that every number above it is already out.
    q.line("wm fps")
    if not wait_marker(serial, "WM FPS K 6 ", timeout=300):
        raise SystemExit("`wm fps` never reached its last stage")
    time.sleep(1.0)
    stages = fps_stages(serial)
    r5 = report(q, serial, 5, "after wm fps")

    # ---- 6: a window maps, and geometry moves the key -------------------
    q.line("proc spawn " + lba_a)
    if not wait_marker(serial, "D3S COMMIT\n", timeout=45):
        raise SystemExit("client A never committed its surface")
    time.sleep(1.0)
    q.line("wm draw")
    time.sleep(0.8)
    r6 = report(q, serial, 6, "window A mapped")

    # ---- the screen, out of guest physical memory -----------------------
    time.sleep(1.0)
    text = read_serial(serial)
    m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
    if not m:
        raise SystemExit("never saw WM ON BASE")
    addr = int(m.group(1), 16)
    pitch = int(m.group(2), 16)
    q.cmd("pmemsave", val=addr, size=600 * pitch, filename=os.path.abspath(fb_bin))
    write_png(png, 800, 600, pitch, open(fb_bin, "rb").read())

    alloc = re.search(
        r"^WM CHROME PX ([0-9A-F]{8}) FRM ([0-9A-F]{8}) AT ([0-9A-F]+)", text, re.M
    )
    out = {
        "base": addr,
        "pitch": pitch,
        "draws": DRAWS,
        "win_x": WIN_X,
        "win_y": WIN_Y,
        "alloc_px": int(alloc.group(1), 16) if alloc else None,
        "alloc_frames": int(alloc.group(2), 16) if alloc else None,
        "alloc_at": alloc.group(3) if alloc else None,
        "r1": r1, "r2": r2, "r3": r3, "r4": r4, "r5": r5, "r6": r6,
        "fps": stages,
        "tick_ms": TICK_MS,
    }
    open(report_path, "w").write(json.dumps(out, indent=2) + "\n")
    q.cmd("quit")
    print(
        "DE-chrome-cache: REGEN %d -> %d over %d unchanged composes; popover "
        "took it to %d then %d; window A to %d. BLIT %d. DESK REGEN %d BLIT %d."
        % (r1["regen"], r2["regen"], DRAWS, r3["regen"], r4["regen"],
           r6["regen"], r6["blit"], r6["desk"]["regen"], r6["desk"]["blit"])
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
