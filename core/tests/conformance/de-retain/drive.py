#!/usr/bin/env python3
"""core/tests/conformance/de-retain/drive.py

ADR-0190 / GAP-0333: A WINDOW'S BODY SURVIVES TIME.

    drive.py <qmp-port> <serial> <fbdir> <png> <lba-A> <lba-B> <mailbox-hex> <report.json>

WHAT THIS DRIVES, AND WHY EACH STAGE IS HERE
--------------------------------------------

Two resident clients attach, paint, commit ONCE and then yield forever. That
is DESK.ELF/FILES.ELF/SET.ELF on the live door, and it is every application
between one redraw and the next. de-pace's client floods the compositor, so
its window is re-blitted hundreds of times a second and could never be seen to
lose its body — which is why de-pace was green while the door was throwing
window bodies away.

  T0     both clients have committed. This is the frame the door had at boot.
  MOVE   twenty pointer packets across bare desktop. Nothing else. Before
         ADR-0190 this alone emptied every window on the screen, because
         `wmPointerTick` bumped the osgfx generation on every packet and
         `isr_common` handed the whole scanout to Skia on the next interrupt.
  MENU   ten open/close cycles of the wallpaper popover, far from both
         windows. Each transition MOVES `wmGfxChromeSig`, so each is a session
         present that is legitimately required and that no compose stands
         behind — the case `wmSessionRestore` exists for, as opposed to the
         case the `wmPointerTick` gate removes.
  SETTLE thirty seconds with the frame clock armed and no input at all.
  IDLE   ninety more. The door was an empty card inside two minutes.

The screen is dumped out of guest physical memory with `pmemsave` at T0 and
after every stage, and the two clients' INTERIOR BLOCKS are compared BYTE FOR
BYTE against T0. Not "still roughly there". Identical.

WHY THE COUNTERS COME OUT OF MEMORY AND NOT OFF THE SERIAL LINE. Two resident
clients ping-pong through `procTick` and the shell never runs again, so no
command can be typed after the second spawn and `wm pace` cannot be asked for
its report. The numbers are therefore read the way the compositor holds them:
`osgfx_guest_cmd.wmpage` (mailbox offset 120) is the address of the ADR-0188
state page, and the page's words are the pacer's, the wallpaper cache's, the
chrome cache's and — words 39..42 — this ADR's. Which is a better source than
a printed line in any case: it is the compositor's own state rather than its
account of it.
"""

import json
import os
import re
import socket
import struct
import sys
import time
import zlib

SCREEN_W, SCREEN_H = 800, 600

# d3-session/client.c: 240x160 surfaces at these origins, an INK_INSET of 40
# and two flat colours. A_INK/B_INK fill the inset rectangle.
A_X, A_Y = 100, 120
B_X, B_Y = 260, 220
A_INK = 0x00F0C020
B_INK = 0x0020E0E0

# The probe blocks: pure client shm, and nothing else.
#
# A's ink rectangle is screen x 140..300, y 160..240, and B's DECORATED
# rectangle starts at (260, 220) — so the bottom-right corner of A's ink is
# behind B and belongs to B. A's block is cut back to the part that is A's
# under any stacking order, which is what makes "byte-identical" a statement
# about retention rather than about who happens to be on top.
A_BLOCK = (A_X + 40, A_Y + 40, 120, 60)
B_BLOCK = (B_X + 40, B_Y + 40, 160, 80)

# Bare desktop: right of both windows, above the 48-row taskbar, and clear of
# the 96x64 popover this parks at (+8, +8) from the click.
POINT_X, POINT_Y = 620, 460
MENU_CYCLES = 10
SETTLE_SECS = 30.0
IDLE_SECS = 90.0

# core/kernel/wmpace.dart owns this layout; osgfx_guest.h names a few of them.
W_FLAGS = 1
W_PRESENTED = 8
W_COALESCED = 9
W_DESK_BLITS = 18
W_CHROME_BLITS = 28
W_SESSION_OWED = 39
W_RESTORES = 40
W_RESTORE_PX = 41
W_RESTORE_SKIP = 42
WMPAGE_MAIL_OFF = 120
WMPAGE_MAGIC = 0x00574D5041474531


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

    def rel(self, dx, dy):
        self.cmd("input-send-event", events=[
            {"type": "rel", "data": {"axis": "x", "value": dx}},
            {"type": "rel", "data": {"axis": "y", "value": dy}},
        ])

    def click(self, button):
        self.cmd("input-send-event", events=[
            {"type": "btn", "data": {"down": True, "button": button}}])
        time.sleep(0.10)
        self.cmd("input-send-event", events=[
            {"type": "btn", "data": {"down": False, "button": button}}])
        time.sleep(0.10)

    def abs_xy(self, x, y, gw=SCREEN_W, gh=SCREEN_H):
        ax = x * 32767 // max(1, gw - 1)
        ay = y * 32767 // max(1, gh - 1)
        self.cmd("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}])

    def abs_click(self, x, y, button):
        self.abs_xy(x, y)
        time.sleep(0.12)
        self.click(button)


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


def block_of(blob, pitch, rect):
    x, y, w, h = rect
    out = bytearray()
    for row in range(h):
        off = (y + row) * pitch + x * 4
        out += blob[off:off + w * 4]
    return bytes(out)


def colours_of(block):
    seen = {}
    for i in range(0, len(block), 4):
        c = int.from_bytes(block[i:i + 4], "little") & 0x00FFFFFF
        seen[c] = seen.get(c, 0) + 1
    return seen


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

    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(blob)


def main():
    if len(sys.argv) != 9:
        print(__doc__, file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    serial, fbdir, png, lba_a, lba_b, mailbox_hex, report = sys.argv[2:9]
    mailbox = int(mailbox_hex, 16)
    os.makedirs(fbdir, exist_ok=True)

    q = Qmp(port)
    if not wait_marker(serial, "M1 END\n"):
        raise SystemExit("kernel never reached the prompt")
    time.sleep(0.5)

    def dump(tag, addr, size):
        path = os.path.abspath(os.path.join(fbdir, tag))
        q.cmd("pmemsave", val=addr, size=size, filename=path)
        return open(path, "rb").read()

    def page_words():
        """The ADR-0188 state page, read the way the compositor holds it."""
        mail = dump("mailbox.bin", mailbox, 128)
        addr = int.from_bytes(mail[WMPAGE_MAIL_OFF:WMPAGE_MAIL_OFF + 8], "little")
        if addr == 0:
            raise SystemExit("osgfx_guest_cmd.wmpage is 0 — no state page")
        page = dump("wmpage.bin", addr, 4096)
        words = [int.from_bytes(page[i * 8:i * 8 + 8], "little")
                 for i in range(512)]
        if words[0] != WMPAGE_MAGIC:
            raise SystemExit("state page at 0x%X has magic 0x%X, not 'WMPAGE1'"
                             % (addr, words[0]))
        return addr, words

    # ---- the compositor, the Skia session, the generative desk ------------
    #
    # EVERY COMMAND THIS BOOT WILL EVER TYPE GOES HERE, before the second
    # spawn: two resident clients ping-pong through procTick and the shell
    # does not run again. `wm pace` is armed now so the frame clock is running
    # for the whole of the interval measured below.
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
    q.line("wm pace")
    if not wait_marker(serial, "WM PACE 01 ", timeout=15):
        raise SystemExit("`wm pace` did not arm the frame clock")
    q.line("vtab")
    if not wait_marker(serial, "VTAB OK", timeout=8):
        raise SystemExit("vtab did not arm the tablet")
    time.sleep(1.0)

    text = read_serial(serial)
    m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
    if not m:
        raise SystemExit("never saw WM ON BASE")
    base, pitch = int(m.group(1), 16), int(m.group(2), 16)

    # ---- two clients, one commit each, and then silence -------------------
    q.line("proc spawn " + lba_a)
    if not wait_marker(serial, "USER WRITE D3S COMMIT\n", timeout=60):
        raise SystemExit("client A never committed")
    time.sleep(1.5)
    q.line("proc spawn " + lba_b)
    if not wait_marker(serial, "USER WRITE D3S COMMIT\n", timeout=60, at_least=2):
        raise SystemExit("client B never committed")
    time.sleep(3.0)

    stages = []
    t_zero = time.time()
    fb0 = dump("fb-t0.bin", base, SCREEN_H * pitch)
    a0 = block_of(fb0, pitch, A_BLOCK)
    b0 = block_of(fb0, pitch, B_BLOCK)
    page_addr, w0 = page_words()

    # T0 HAS TO BE RIGHT BEFORE "UNCHANGED" MEANS ANYTHING. Two identical
    # blocks of wallpaper would satisfy every later comparison in this file.
    a_seen, b_seen = colours_of(a0), colours_of(b0)
    if list(a_seen) != [A_INK]:
        raise SystemExit("client A's interior is not its ink at T0: %s"
                         % {"0x%06X" % k: v for k, v in a_seen.items()})
    if list(b_seen) != [B_INK]:
        raise SystemExit("client B's interior is not its ink at T0: %s"
                         % {"0x%06X" % k: v for k, v in b_seen.items()})

    def stage(tag, note):
        blob = dump("fb-%s.bin" % tag, base, SCREEN_H * pitch)
        a, b = block_of(blob, pitch, A_BLOCK), block_of(blob, pitch, B_BLOCK)
        _, w = page_words()
        rec = {
            "stage": tag,
            "note": note,
            "secs_since_t0": round(time.time() - t_zero, 2),
            "a_same": a == a0,
            "b_same": b == b0,
            "a_diff_px": sum(1 for i in range(0, len(a0), 4)
                             if a[i:i + 4] != a0[i:i + 4]),
            "b_diff_px": sum(1 for i in range(0, len(b0), 4)
                             if b[i:i + 4] != b0[i:i + 4]),
            "a_colours": {"0x%06X" % k: v for k, v in colours_of(a).items()},
            "b_colours": {"0x%06X" % k: v for k, v in colours_of(b).items()},
            "desk_blits": w[W_DESK_BLITS],
            "chrome_blits": w[W_CHROME_BLITS],
            "restores": w[W_RESTORES],
            "restore_px": w[W_RESTORE_PX],
            "restore_skip": w[W_RESTORE_SKIP],
            "owed": w[W_SESSION_OWED],
            "presented": w[W_PRESENTED],
            "coalesced": w[W_COALESCED],
        }
        stages.append(rec)
        return blob

    # ---- MOVE: twenty pointer packets over bare desktop -------------------
    # Small steps: one huge relative motion is one packet with a saturated
    # delta. Twenty steps are twenty trips through wmPointerTick, which was
    # twenty chances to hand the scanout to the session.
    steps = 20
    for _ in range(steps):
        q.rel(POINT_X // steps, POINT_Y // steps)
        time.sleep(0.06)
    time.sleep(1.5)
    stage("move", "%d pointer packets across bare desktop" % steps)

    # ---- MENU: session presents that no compose stands behind -------------
    # Absolute tablet. Relative PS/2 loses the burst while a menu paints
    # (the same IF-clear window de-desk already switched off).
    for _ in range(MENU_CYCLES):
        q.abs_click(POINT_X, POINT_Y, "right")
        time.sleep(0.70)
        q.abs_click(POINT_X, POINT_Y, "left")
        time.sleep(0.70)
    time.sleep(2.0)
    stage("menu", "%d popover open/close cycles" % MENU_CYCLES)

    # ---- SETTLE and IDLE: the interval out of the bug report ---------------
    time.sleep(SETTLE_SECS)
    stage("settle", "%.0fs paced, no input" % SETTLE_SECS)
    time.sleep(IDLE_SECS)
    fbN = stage("idle", "%.0fs more of nothing at all" % IDLE_SECS)

    write_png(png, SCREEN_W, SCREEN_H, pitch, fbN)

    text = read_serial(serial)
    last = stages[-1]
    out = {
        "base": base,
        "pitch": pitch,
        "mailbox": mailbox,
        "page_addr": page_addr,
        "a_block": list(A_BLOCK),
        "b_block": list(B_BLOCK),
        "a_ink": "0x%06X" % A_INK,
        "b_ink": "0x%06X" % B_INK,
        "stages": stages,
        "total_secs": round(time.time() - t_zero, 2),
        "restores": last["restores"],
        "restore_px": last["restore_px"],
        "restore_skip": last["restore_skip"],
        "owed_at_end": last["owed"],
        "desk_blits_t0": w0[W_DESK_BLITS],
        "desk_blits": last["desk_blits"],
        "chrome_blits_t0": w0[W_CHROME_BLITS],
        "chrome_blits": last["chrome_blits"],
        "restores_t0": w0[W_RESTORES],
        "paced": w0[W_FLAGS] & 1,
        "commits": len(re.findall(r"^WM COMMIT ", text, re.M)),
        "frames": len(re.findall(r"^WM FRAME ", text, re.M)),
        "reaps": len(re.findall(r"^WM REAP ", text, re.M)),
        "wall_menus": text.count("WM WALL MENU\n"),
        "mouse_packets": len(re.findall(r"^MOUSE (?:PKT|ABS) ", text, re.M)),
    }
    open(report, "w").write(json.dumps(out, indent=2) + "\n")
    q.cmd("quit")
    print("DE-retain: state page at 0x%X, paced=%d" % (page_addr, out["paced"]))
    for s in stages:
        print("DE-retain: %-6s +%6.1fs  A %-12s B %-12s  session blits %d  "
              "restores %d (skip %d)"
              % (s["stage"], s["secs_since_t0"],
                 "intact" if s["a_same"] else "LOST %d px" % s["a_diff_px"],
                 "intact" if s["b_same"] else "LOST %d px" % s["b_diff_px"],
                 s["desk_blits"], s["restores"], s["restore_skip"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
