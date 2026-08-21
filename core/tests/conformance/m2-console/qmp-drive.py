#!/usr/bin/env python3
"""core/tests/conformance/m2-console/qmp-drive.py

Drives a running QEMU over QMP for the M2 console harness: wait for the kernel
to reach its interactive phase, inject a fixed key sequence into the emulated
PS/2 keyboard, then capture BOTH a PNG screenshot and a mechanically
comparable text rendering of the VGA text buffer.

Why a Python file rather than a heredoc inside run.sh: QMP is a line-oriented
JSON protocol over a socket, and doing that in bash means nc/socat plus manual
framing, which is more fragile than the thing it is testing. Python 3 is
already required on any machine that can run the DCDart toolchain.

The three artefacts this produces are deliberately different KINDS of evidence:

  serial capture   written by QEMU itself (-serial file:...), asserted
                   byte-for-byte by run.sh. Deterministic and diffable.
  monitor dump     (optional, --monitor-command/--monitor-capture) QEMU's own
                   answer to a question the kernel also answered -- e.g.
                   `info pci`, or an `xp` dump of the linear framebuffer. A
                   SECOND, independent description of the machine, so a
                   harness can compare the kernel against the emulator's
                   device model instead of only against a golden the kernel
                   itself produced. With --addr-from-serial, the dump can be
                   taken at an address THE KERNEL reported, which is what
                   makes reading pixels back out of a discovered BAR possible
                   without the harness assuming where it is.
  screen text      the VGA text buffer read out of GUEST PHYSICAL MEMORY via
                   the monitor's `xp` command and decoded here. This is the
                   framebuffer assertion -- it is what the video hardware would
                   actually display, not a re-render of what the kernel meant.
  PNG              QEMU's own `screendump`, for a human to look at. NOT
                   asserted; a pixel comparison would be brittle against font
                   and palette changes that say nothing about the kernel.

Exit status: 0 on success, 3 on any QMP/timeout failure (run.sh maps that to a
harness FAIL, never a skip).
"""

import argparse
import json
import re
import os
import socket
import sys
import time

FAIL = 3


def die(msg):
    print(f"qmp-drive: {msg}", file=sys.stderr)
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
        # Asynchronous EVENTS (RESET, SHUTDOWN, ...) are interleaved with
        # command replies on the same stream and must be skipped, or the very
        # first reply read would be a RESET event and every subsequent read
        # would be off by one.
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

    def hmp(self, command_line):
        return self.cmd("human-monitor-command", **{"command-line": command_line})


def wait_for_marker(path, marker, timeout):
    """Blocks until the serial capture contains `marker`."""
    deadline = time.time() + timeout
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
    """Blocks until the serial capture has stopped growing for `quiet_for`."""
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


def read_text_buffer(qmp, base, cells):
    """Reads the VGA text buffer out of guest physical memory.

    `xp` is the monitor's physical-memory dump. `/<n>hx` asks for n halfwords
    in hex, which is exactly one VGA cell each (character byte in the low half,
    attribute byte in the high half). The reply is the monitor's own text, e.g.

        00000000000b8000: 0x0f4f 0x0f53 0x0f43 0x0f4f

    so it is parsed rather than trusted to any particular column layout: every
    0x-prefixed token on every line, in order.
    """
    out = qmp.hmp(f"xp/{cells}hx 0x{base:x}")
    words = []
    for line in out.splitlines():
        if ":" not in line:
            continue
        for token in line.split(":", 1)[1].split():
            if token.startswith("0x"):
                words.append(int(token, 16))
    if len(words) != cells:
        die(f"expected {cells} VGA cells from `xp`, parsed {len(words)}")
    return words


def render(words, cols, rows):
    """Renders cells as text: one line per screen row, trailing blanks stripped.

    Only the character byte is rendered. The attribute byte is deliberately NOT
    asserted -- this kernel writes one fixed attribute everywhere, so including
    it would add 2000 constants to the golden and check nothing. A
    non-printable character byte becomes '?' so a corrupt cell is visible
    rather than mangling the golden file's encoding.
    """
    lines = []
    for r in range(rows):
        row = words[r * cols:(r + 1) * cols]
        text = "".join(
            chr(w & 0xFF) if 0x20 <= (w & 0xFF) < 0x7F else "?" for w in row
        )
        lines.append(text.rstrip())
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--serial", required=True,
                    help="path QEMU is writing the COM1 capture to")
    ap.add_argument("--wait-for", required=True,
                    help="byte string that means the kernel is interactive")
    ap.add_argument("--png", required=True)
    ap.add_argument("--screen-text", required=True)
    ap.add_argument("--keys", required=True,
                    help="comma-separated QEMU qcodes to inject, in order; "
                         "a `wait:<ms>` element pauses instead of typing")
    ap.add_argument("--monitor-command", action="append", default=None,
                    help="optional HMP command to run after the keystrokes "
                         "(e.g. 'info pci', or an `xp` memory dump). May be "
                         "repeated; every output goes to --monitor-capture, "
                         "each preceded by a `=== <command> ===` line. A "
                         "command may contain the placeholder {addr}, which is "
                         "replaced by the hex number --addr-from-serial "
                         "matched in the serial capture. Purely additive -- "
                         "omitted by every harness that does not need it.")
    ap.add_argument("--monitor-capture", default=None,
                    help="file to write --monitor-command's output to")
    ap.add_argument("--addr-from-serial", default=None,
                    help="regex with ONE capture group, matched against the "
                         "serial capture; the captured hex number replaces "
                         "{addr} in every --monitor-command. This is how a "
                         "harness dumps memory at an address THE KERNEL "
                         "CHOSE -- reading back from wherever the kernel says "
                         "it wrote, rather than from an address the harness "
                         "assumed.")
    ap.add_argument("--vga-base", default="0xb8000")
    ap.add_argument("--cols", type=int, default=80)
    ap.add_argument("--rows", type=int, default=25)
    args = ap.parse_args()

    qmp = Qmp(args.host, args.port, connect_timeout=20)
    print(f"qmp-drive: connected, QEMU {qmp.version['major']}."
          f"{qmp.version['minor']}.{qmp.version['micro']}")

    marker = args.wait_for.encode("utf-8").decode("unicode_escape").encode("latin-1")
    if not wait_for_marker(args.serial, marker, timeout=25):
        die(f"kernel never printed {args.wait_for!r} -- it did not reach the "
            f"interactive console")
    print(f"qmp-drive: kernel reached {args.wait_for!r}")

    # The marker appears the instant the byte hits COM1, which is BEFORE
    # m2Enter() has drained the 8042 and unmasked IRQ1. Keys injected into that
    # window are read by the drain and thrown away. A short settle is the
    # honest fix; the alternative (a second serial marker printed after
    # unmasking) would put M2 bytes on COM1 and break M1's byte-exact golden.
    time.sleep(0.5)

    keys = [k for k in args.keys.split(",") if k]
    typed = 0
    for qcode in keys:
        # `wait:<ms>` is a PAUSE, not a key. It exists because a shell runs
        # commands, and a command that takes longer than the inter-key gap
        # would otherwise have keys injected into it while it runs. The M3
        # kernel drops those keys on purpose (there is no input queue --
        # docs/known-gaps.md GAP-0055 item 4), so without an explicit pause the
        # harness would be silently testing a shorter sequence than it wrote.
        if qcode.startswith("wait:"):
            time.sleep(int(qcode.split(":", 1)[1]) / 1000.0)
            continue
        qmp.cmd("send-key", keys=[{"type": "qcode", "data": qcode}])
        # send-key synthesizes make AND break; a small gap keeps the 8042's
        # one-byte output buffer from being overrun before IRQ1 is serviced.
        time.sleep(0.05)
        typed += 1
    print(f"qmp-drive: injected {typed} keystroke(s)")

    if not wait_for_quiet(args.serial, quiet_for=0.5, timeout=10):
        die("serial output never went quiet after the keystrokes")

    # An INDEPENDENT description of the same machine, when a harness asks for
    # one. m5-pci uses `info pci` to compare the kernel's own enumeration
    # against QEMU's device model -- two different programs walking the same
    # bus, rather than a golden the kernel wrote and then agreed with.
    if args.monitor_command:
        if args.monitor_capture is None:
            die("--monitor-command requires --monitor-capture")
        addr = None
        if args.addr_from_serial is not None:
            blob = open(args.serial, "rb").read().decode("latin-1")
            m = re.search(args.addr_from_serial, blob)
            if not m:
                die(f"--addr-from-serial {args.addr_from_serial!r} matched "
                    f"nothing in the serial capture -- the kernel never "
                    f"reported the address the monitor commands need")
            addr = "0x" + m.group(1)
            print(f"qmp-drive: {{addr}} = {addr} (from the serial capture)")
        with open(args.monitor_capture, "w", encoding="utf-8") as fh:
            for raw in args.monitor_command:
                if "{addr}" in raw:
                    if addr is None:
                        die("a --monitor-command uses {addr} but "
                            "--addr-from-serial was not given")
                    cmdline = raw.replace("{addr}", addr)
                else:
                    cmdline = raw
                fh.write(f"=== {cmdline} ===\n")
                fh.write(qmp.hmp(cmdline))
                fh.write("\n")
        print(f"qmp-drive: wrote {args.monitor_capture} "
              f"({len(args.monitor_command)} monitor command(s))")

    qmp.cmd("screendump", filename=os.path.abspath(args.png), format="png")
    print(f"qmp-drive: wrote {args.png}")

    words = read_text_buffer(qmp, int(args.vga_base, 16), args.cols * args.rows)
    with open(args.screen_text, "w", encoding="utf-8") as fh:
        fh.write(render(words, args.cols, args.rows))
    print(f"qmp-drive: wrote {args.screen_text}")

    qmp.cmd("quit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
