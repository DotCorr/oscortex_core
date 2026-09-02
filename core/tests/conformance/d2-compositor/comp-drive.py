#!/usr/bin/env python3
"""core/tests/conformance/d2-compositor/comp-drive.py

Drives a running QEMU over QMP for the compositor harness, and **reads the
framebuffer back out of guest physical memory as BYTES**.

WHY THIS IS NOT m2-console/qmp-drive.py
---------------------------------------------------------------------------
That driver does everything this one does except the one thing this milestone's
exit criterion is made of. Three differences, and each is load-bearing:

  1. **It waits for a marker the KERNEL prints, not for silence.** `qmp-drive`
     ends its key script and then waits for the serial line to go quiet for half
     a second. A composition pass is 480,000 pixel stores and prints nothing
     until it finishes, so on a loaded host the quiet inside a compose is
     indistinguishable from the quiet after the last one -- and the harness would
     photograph a half-drawn screen and blame the kernel. `--settle-for` is a
     string that must APPEAR, so the wait ends on an event rather than on a
     timeout that happened not to fire.

  2. **It reads pixels with `pmemsave`, not with `xp`.** `xp/<n>wx` renders
     memory as monitor text, four words to a line; a full 800x600x32 frame is
     480,000 words and roughly 120,000 lines of it. `pmemsave` writes the same
     bytes to a file. The frame is 1,920,000 bytes either way and one of the two
     forms is 1.9 MB.

  3. **The address comes from the kernel, and so does the pitch.** `--fb-from`
     is a regex with TWO capture groups matched against the serial capture: the
     base the kernel found by reading BAR0, and the pitch it computed. A harness
     that assumed 0xFD000000 would still pass on a machine where the BAR moved
     and would be asserting nothing about discovery. m5-pci established this and
     d1-mouse kept it.

It deliberately does NOT re-implement `xp`, `--screen-text`, or the VGA text
decode. Nothing here needs them: while the compositor owns the framebuffer the
0xB8000 text buffer is not what is on the screen.

Exit status: 0 on success, 3 on any QMP/timeout failure (run.sh maps that to a
harness FAIL, never a skip).
"""

import argparse
import json
import os
import re
import socket
import sys
import time

FAIL = 3


def die(msg):
    print(f"comp-drive: {msg}", file=sys.stderr)
    sys.exit(FAIL)


class Qmp:
    """The line-oriented JSON handshake, in the shape m2-console/qmp-drive.py
    established. Copied rather than imported: these harnesses are standalone by
    design, and `sys.path` surgery to reach a sibling test directory is a worse
    dependency than forty lines."""

    def __init__(self, host, port, connect_timeout):
        deadline = time.time() + connect_timeout
        sock = None
        while time.time() < deadline:
            try:
                sock = socket.create_connection((host, port), timeout=5)
                break
            except OSError:
                time.sleep(0.1)
        if sock is None:
            die(f"could not connect to QMP at {host}:{port} in {connect_timeout}s")
        self.sock = sock
        self.buf = b""
        greeting = self.recv()
        if "QMP" not in greeting:
            die(f"the first QMP message was not a greeting: {greeting!r}")
        self.version = greeting["QMP"]["version"]["qemu"]
        self.cmd("qmp_capabilities")

    def recv(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                die("QEMU closed the QMP socket")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.sock.sendall((json.dumps(msg) + "\n").encode())
        while True:
            reply = self.recv()
            if "event" in reply:
                continue
            if "error" in reply:
                die(f"{name} failed: {reply['error']}")
            return reply.get("return")


def wait_for(path, needle, timeout, what):
    """Waits for `needle` to appear in the file at `path`. Returns True/False."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(path, "rb") as fh:
                if needle in fh.read():
                    return True
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    return False


def inject(qmp, keys):
    """The key/pointer vocabulary d1-mouse's driver defined, unchanged.

    `rel:<dx>:<dy>` is a POINTER MOTION in device units, delivered as ONE
    `input-send-event` so that a two-axis motion is one PS/2 packet rather than
    two. QEMU's axis convention: +x moves right and reaches the guest as
    `mouse_dx += v`; +y moves DOWN the screen and reaches the guest as
    `mouse_dy -= v`, because a PS/2 mouse reports Y positive UPWARD. So the byte
    the guest decodes for a downward motion is negative, and `derive.py`
    computes the guest-side position with that sign flip in it.
    """
    typed = pointed = 0
    for el in keys.split(","):
        if not el:
            continue
        if el.startswith("abs:"):
            # Tablet SET in screen pixels. QEMU abs axes are 0..32767.
            # abs:x:y or abs:x:y:gw:gh (default 800x600).
            parts = el.split(":")
            if len(parts) not in (3, 5):
                die(f"malformed pointer element {el!r} -- want abs:<x>:<y>")
            x, y = int(parts[1]), int(parts[2])
            gw = int(parts[3]) if len(parts) == 5 else 800
            gh = int(parts[4]) if len(parts) == 5 else 600
            ax = x * 32767 // max(1, gw - 1)
            ay = y * 32767 // max(1, gh - 1)
            qmp.cmd("input-send-event", events=[
                {"type": "abs", "data": {"axis": "x", "value": ax}},
                {"type": "abs", "data": {"axis": "y", "value": ay}},
            ])
            pointed += 1
            time.sleep(0.05)
            continue
        if el.startswith("rel:"):
            parts = el.split(":")
            if len(parts) != 3:
                die(f"malformed pointer element {el!r} -- want rel:<dx>:<dy>")
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
        if el.startswith("btn:"):
            parts = el.split(":")
            if len(parts) != 3 or parts[2] not in ("down", "up"):
                die(f"malformed button element {el!r} -- want btn:<name>:<down|up>")
            qmp.cmd("input-send-event", events=[
                {"type": "btn", "data": {"button": parts[1],
                                         "down": parts[2] == "down"}}])
            pointed += 1
            time.sleep(0.05)
            continue
        if el.startswith("wait:"):
            time.sleep(int(el.split(":", 1)[1]) / 1000.0)
            continue
        qmp.cmd("send-key", keys=[{"type": "qcode", "data": el}])
        time.sleep(0.05)
        typed += 1
    return typed, pointed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--serial", required=True)
    ap.add_argument("--wait-for", required=True,
                    help="byte string that means the kernel is interactive")
    ap.add_argument("--keys", required=True)
    ap.add_argument("--settle-for", default=None,
                    help="byte string that must APPEAR in the serial capture "
                         "after the keys are injected and before anything is "
                         "read back. This is the difference between "
                         "photographing a finished frame and photographing a "
                         "compose in progress.")
    ap.add_argument("--settle-timeout", type=float, default=90.0)
    ap.add_argument("--keys2", default=None,
                    help="a SECOND key/pointer script, injected only after "
                         "--settle-for has been seen. This is what makes a "
                         "drag testable: the clients are inside a bounded busy "
                         "hold with both surfaces live, the shell is not "
                         "running, and the only thing that can act is the IRQ12 "
                         "path. Phase two has to start when the frame it drags "
                         "is on the screen, and `wait:` cannot know when that "
                         "is.")
    ap.add_argument("--settle2-for", default=None,
                    help="byte string that must appear after --keys2 and "
                         "before the framebuffer is read back.")
    ap.add_argument("--fb-out2", default=None,
                    help="a SECOND framebuffer dump, taken after --settle2-for. "
                         "Both dumps come from one boot, so 'the windows were "
                         "here and then the pointer moved one of them' is two "
                         "readings of the same machine rather than two runs.")
    ap.add_argument("--png2", default=None)
    ap.add_argument("--finish-for", default=None,
                    help="byte string that must appear AFTER the framebuffer "
                         "has been read back and before QEMU is told to quit. "
                         "This is what lets one boot serve two purposes: the "
                         "pixels are read while both surfaces are LIVE, and the "
                         "run then continues to its end so the transcript "
                         "carries what each client exited with. Without it the "
                         "harness would have to choose between photographing a "
                         "live screen and reading two exit codes.")
    ap.add_argument("--finish-timeout", type=float, default=120.0)
    ap.add_argument("--fb-from", required=True,
                    help="regex with TWO capture groups -- the framebuffer base "
                         "and the pitch, both hex, both as THE KERNEL REPORTED "
                         "THEM")
    ap.add_argument("--fb-out", required=True,
                    help="file to write the framebuffer bytes to")
    ap.add_argument("--fb-height", type=int, default=600)
    ap.add_argument("--png", required=True)
    ap.add_argument("--no-quit", action="store_true",
                    help="leave QEMU running so a later QMP stage can drive it")
    args = ap.parse_args()

    qmp = Qmp(args.host, args.port, connect_timeout=20)
    print(f"comp-drive: connected, QEMU {qmp.version['major']}."
          f"{qmp.version['minor']}.{qmp.version['micro']}")

    marker = args.wait_for.encode("utf-8").decode("unicode_escape").encode("latin-1")
    if not wait_for(args.serial, marker, 25, "boot"):
        die(f"kernel never printed {args.wait_for!r} -- it did not reach the "
            f"interactive console")
    print(f"comp-drive: kernel reached {args.wait_for!r}")
    # The marker appears the instant the byte hits COM1, which is BEFORE
    # m2Enter() has drained the 8042 and unmasked IRQ1. Keys injected into that
    # window are read by the drain and thrown away. m2-console's note, and its
    # settle.
    time.sleep(0.5)

    typed, pointed = inject(qmp, args.keys)
    print(f"comp-drive: injected {typed} keystroke(s) and {pointed} pointer event(s)")

    if args.settle_for:
        needle = args.settle_for.encode("utf-8").decode(
            "unicode_escape").encode("latin-1")
        if not wait_for(args.serial, needle, args.settle_timeout, "settle"):
            die(f"the kernel never printed {args.settle_for!r} within "
                f"{args.settle_timeout}s -- the screen this harness is about to "
                f"read back was never finished")
        print(f"comp-drive: kernel reached {args.settle_for!r}")

    blob = open(args.serial, "rb").read().decode("latin-1")
    m = re.search(args.fb_from, blob)
    if not m:
        die(f"--fb-from {args.fb_from!r} matched nothing in the serial capture "
            f"-- the kernel never reported where the framebuffer is")
    base = int(m.group(1), 16)
    pitch = int(m.group(2), 16)
    size = pitch * args.fb_height
    print(f"comp-drive: framebuffer base 0x{base:X} pitch {pitch} "
          f"({size} bytes) -- from the serial capture, not assumed")

    def capture(fb_out, png):
        # pmemsave, not xp. See this file's header, point 2. The path must be
        # absolute: QEMU resolves it in ITS working directory, not this
        # script's.
        out = os.path.abspath(fb_out)
        qmp.cmd("pmemsave", val=base, size=size, filename=out)
        if not os.path.exists(out):
            die(f"pmemsave reported success but wrote no {out}")
        got = os.path.getsize(out)
        if got != size:
            die(f"pmemsave wrote {got} bytes, expected {size}")
        print(f"comp-drive: wrote {fb_out} ({got} bytes)")
        qmp.cmd("screendump", filename=os.path.abspath(png), format="png")
        print(f"comp-drive: wrote {png}")

    capture(args.fb_out, args.png)

    if args.keys2:
        t2, p2 = inject(qmp, args.keys2)
        print(f"comp-drive: phase 2 injected {t2} keystroke(s) and "
              f"{p2} pointer event(s)")
        if args.settle2_for:
            needle = args.settle2_for.encode("utf-8").decode(
                "unicode_escape").encode("latin-1")
            if not wait_for(args.serial, needle, args.settle_timeout, "settle2"):
                die(f"the kernel never printed {args.settle2_for!r} within "
                    f"{args.settle_timeout}s after phase 2")
            print(f"comp-drive: kernel reached {args.settle2_for!r}")
        if args.fb_out2:
            if not args.png2:
                die("--fb-out2 requires --png2")
            capture(args.fb_out2, args.png2)

    if args.finish_for:
        needle = args.finish_for.encode("utf-8").decode(
            "unicode_escape").encode("latin-1")
        if not wait_for(args.serial, needle, args.finish_timeout, "finish"):
            die(f"the kernel never printed {args.finish_for!r} within "
                f"{args.finish_timeout}s -- the run did not reach its end and "
                f"the transcript is missing what the clients exited with")
        print(f"comp-drive: kernel reached {args.finish_for!r}")

    if args.no_quit:
        print("comp-drive: leaving QEMU running (--no-quit)")
        return 0
    qmp.cmd("quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
