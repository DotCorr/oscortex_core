#!/usr/bin/env python3
"""core/scripts/console.py

AN INTERACTIVE CONSOLE FOR THE RUNNING OPERATING SYSTEM, FROM YOUR OWN TERMINAL.

`demo.sh` boots the OS and leaves it running in a QEMU window. That window is
the only way to type into it, which means you can only drive the machine if you
are sitting at this Mac looking at a GUI. This script removes that: it attaches
to the SAME running machine over QMP, types into its emulated PS/2 keyboard, and
streams the serial console back — so the OS is drivable from a terminal, a pipe,
or a script.

WHAT THIS IS AND IS NOT
---------------------------------------------------------------------------
It IS a remote console: you type a line, the machine executes it, you see the
output. That is the daily-use half of what `ssh` would give you.

It is NOT ssh and does not pretend to be. There is no network stack in this
kernel — no NIC driver, no ARP, no IP, no TCP (`docs/design/net-e1000.md` and
`net-stack.md` are designs, not code). This reaches the machine through the
EMULATOR's control socket, not through the guest's network, so it works only
against a local QEMU and only while `demo.sh` has one running. When the network
stack lands, a real remote console goes over it and this script stops being the
interesting one.

It is also NOT a file-transfer channel. Typing bytes through a PS/2 keyboard is
one QMP round-trip per character, which is fine for a command and absurd for a
binary. Pushing a program into the running machine needs the kernel to be able
to READ its serial port, which today it cannot — `core/kernel/uart.dart` is
transmit-only (`uartPutc` and nothing else). That is the next piece of work, and
it is what turns this into an OTA channel.

USAGE
---------------------------------------------------------------------------
    core/scripts/console.py                  # attach to whatever demo.sh runs
    core/scripts/console.py -c "help"        # run one command, print, exit
    core/scripts/console.py -c "fb" -c "pci" # several, in order
    core/scripts/console.py --qmp 127.0.0.1:57619 --serial /path/serial.txt

Interactive meta-commands (they start with a colon so they cannot collide with
a shell command in the guest):

    :q            quit this console (the machine keeps running)
    :shot [path]  QEMU screendump to a PNG
    :raw a,b,spc  send literal QEMU qcodes, for keys with no character
    :wait [ms]    just read the serial for a while, print anything new

Exit status: 0 normally, 2 if no running machine could be found.
"""

import argparse
import json
import os
import socket
import sys
import time

INFO = "/private/tmp/oscortex-demo/demo.info"
PIDFILE = "/private/tmp/oscortex-demo/demo.pid"

# QEMU qcode for each character this console can type. The guest's shell only
# ever needs lower-case, digits, space and a little punctuation, but upper case
# is here too because a filename could carry it -- FAT16 8.3 names are upper
# case on the volume, and `cat README.TXT` should be typeable.
PLAIN = {
    " ": "spc", ".": "dot", "-": "minus", "/": "slash", ",": "comma",
    ";": "semicolon", "'": "apostrophe", "[": "bracket_left",
    "]": "bracket_right", "\\": "backslash", "=": "equal", "`": "grave_accent",
    "\t": "tab",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", ":": "semicolon",
    '"': "apostrophe", "<": "comma", ">": "dot", "?": "slash", "~": "grave_accent",
    "{": "bracket_left", "}": "bracket_right", "|": "backslash",
}


def die(msg, code=2):
    print("console: %s" % msg, file=sys.stderr)
    sys.exit(code)


def qcodes_for(ch):
    """(keys, shifted) for one character, or None if it cannot be typed."""
    if ch in PLAIN:
        return PLAIN[ch], False
    if ch in SHIFTED:
        return SHIFTED[ch], True
    if "a" <= ch <= "z" or "0" <= ch <= "9":
        return ch, False
    if "A" <= ch <= "Z":
        return ch.lower(), True
    return None


class Qmp:
    """The line-oriented JSON protocol, same shape qmp-drive.py uses."""

    def __init__(self, host, port, timeout=10.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.f = self.sock.makefile("rw", encoding="utf-8", newline="\n")
        self._read()                      # the greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                raise IOError("QMP closed the connection")
            msg = json.loads(line)
            if "event" in msg:            # asynchronous, not our reply
                continue
            return msg

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.f.write(json.dumps(req) + "\n")
        self.f.flush()
        msg = self._read()
        if "error" in msg:
            raise IOError("QMP %s: %s" % (name, msg["error"].get("desc", msg["error"])))
        return msg.get("return")

    def key(self, qcode, shifted=False):
        keys = [{"type": "qcode", "data": qcode}]
        if shifted:
            keys.insert(0, {"type": "qcode", "data": "shift"})
        self.cmd("send-key", keys=keys)


class SerialSocket:
    """COM1 itself: write bytes in, read bytes out.

    This is what a serial console actually is, and it is available because the
    kernel can now RECEIVE (B1: IRQ4 -> shellSerialIrq). It sends `\n` because
    the shell's line editor speaks the PS/2 alphabet where Return is LF -- the
    kernel also translates CR, so either would work, and LF is the one that
    needs no translation.
    """

    def __init__(self, host, port, timeout=10.0):
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)

    def send_line(self, text):
        self.sock.sendall(text.encode("latin-1", "replace") + b"\n")

    def drain(self, quiet_ms=350, max_ms=8000):
        out, waited, silent = [], 0, 0
        self.sock.settimeout(0.05)
        while waited < max_ms:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                chunk = b""
            except OSError:
                break
            if chunk:
                out.append(chunk.decode("latin-1"))
                silent = 0
            else:
                silent += 50
                if silent >= quiet_ms and out:
                    break
                if silent >= quiet_ms * 4 and not out:
                    break
            waited += 50
        return "".join("".join(out).replace("\r", ""))


class Serial:
    """Tails the file QEMU is writing its COM1 output into."""

    def __init__(self, path):
        self.path = path
        self.pos = os.path.getsize(path) if os.path.exists(path) else 0

    def read_new(self):
        if not os.path.exists(self.path):
            return ""
        with open(self.path, "rb") as fh:
            fh.seek(self.pos)
            data = fh.read()
            self.pos = fh.tell()
        # The guest writes raw bytes, including a few non-text ones from
        # programs that print their .data. Keep it readable rather than
        # crashing on a stray 0x88.
        return "".join(chr(b) if (b == 10 or b == 9 or 32 <= b < 127) else "."
                       for b in data)

    def drain(self, quiet_ms=350, max_ms=8000):
        """Read until the guest has been silent for `quiet_ms`."""
        out, waited, silent = [], 0, 0
        while waited < max_ms:
            chunk = self.read_new()
            if chunk:
                out.append(chunk)
                silent = 0
            else:
                silent += 50
                if silent >= quiet_ms and out:
                    break
                if silent >= quiet_ms * 4 and not out:
                    break
            time.sleep(0.05)
            waited += 50
        return "".join(out)


def discover():
    """(qmp_host, qmp_port, serial_path) from demo.sh's own state files."""
    if not os.path.exists(INFO):
        die("no running machine: %s does not exist.\n"
            "          Start one with:  core/scripts/demo.sh" % INFO)
    # demo.info is `key<spaces>value`, and ONE of its keys contains a space
    # ("run dir"), so the known keys are matched by prefix rather than split on
    # the first gap -- which silently produced a key of "run" and lost the path.
    info = {}
    for line in open(INFO):
        line = line.rstrip("\n")
        for key in ("run dir", "commit", "worktree", "display", "qmp", "serial"):
            if line.startswith(key):
                info[key] = line[len(key):].strip()
                break
    if "qmp" not in info or "run dir" not in info:
        die("%s does not name a qmp endpoint and a run dir" % INFO)
    host, port = info["qmp"].split(":")
    serial = os.path.join(info["run dir"], "serial.txt")
    # B1: a demo launched after the serial line became bidirectional records a
    # socket for COM1. When it is there this console uses it directly, which is
    # both faster and more honest -- bytes go into the guest's UART instead of
    # being mimed through a PS/2 keyboard one QMP round-trip at a time.
    sersock = info.get("serial")
    if os.path.exists(PIDFILE):
        pid = open(PIDFILE).read().strip()
        try:
            os.kill(int(pid), 0)
        except (OSError, ValueError):
            die("demo.pid says %s but that process is gone.\n"
                "          Start one with:  core/scripts/demo.sh" % pid)
    return host, int(port), serial, sersock


def send_line(qmp, text):
    """Type `text` then Return. Unmappable characters are reported, not dropped."""
    for ch in text:
        got = qcodes_for(ch)
        if got is None:
            print("console: cannot type %r, skipping it" % ch, file=sys.stderr)
            continue
        qcode, shifted = got
        qmp.key(qcode, shifted)
        time.sleep(0.012)   # the 8042 needs a gap; qmp-drive.py uses one too
    qmp.key("ret")


def main():
    ap = argparse.ArgumentParser(description="interactive console for the running oscortex machine")
    ap.add_argument("--qmp", help="host:port of QEMU's QMP socket (default: from demo.info)")
    ap.add_argument("--serial", help="path to the serial capture (default: from demo.info)")
    ap.add_argument("-c", "--command", action="append", default=[],
                    help="run a command and exit; repeatable, run in order")
    ap.add_argument("--no-serial-socket", action="store_true",
                    help="ignore COM1's socket and mime keystrokes through QMP instead")
    ap.add_argument("--quiet-ms", type=int, default=350,
                    help="how long the guest must be silent before a command is "
                         "considered finished (default 350)")
    args = ap.parse_args()

    sersock = None
    if args.qmp and args.serial:
        host, port = args.qmp.split(":")
        port, serial = int(port), args.serial
    else:
        d_host, d_port, d_serial, d_sersock = discover()
        if args.qmp:
            host, port = args.qmp.split(":"); port = int(port)
        else:
            host, port = d_host, d_port
        serial = args.serial or d_serial
        sersock = d_sersock

    # TWO TRANSPORTS, and the choice is not a preference.
    #
    # If the running machine exposes COM1 as a socket, this console IS a serial
    # console: bytes in, bytes out, one connection. If it does not -- an older
    # demo, or one launched by hand with `-serial file:` -- it falls back to
    # miming keystrokes through QMP and tailing the capture file, which is what
    # this script did before the kernel could receive at all. The fallback is
    # kept because a machine you cannot type into is still worth reading.
    if sersock and not args.no_serial_socket:
        try:
            shost, sport = sersock.split(":")
            link = SerialSocket(shost, sport)
        except Exception as exc:                   # noqa: BLE001 - fall back loudly
            print("console: could not open COM1 at %s (%s); falling back to QMP keystrokes"
                  % (sersock, exc), file=sys.stderr)
            link = None
    else:
        link = None

    qmp = None
    ser = None
    if link is None:
        if not os.path.exists(serial):
            die("serial capture not found at %s" % serial)
        try:
            qmp = Qmp(host, port)
        except Exception as exc:                   # noqa: BLE001 - report and exit
            die("could not attach to QEMU at %s:%d (%s)" % (host, port, exc))
        ser = Serial(serial)

    def run(cmd):
        if link is not None:
            link.send_line(cmd)
            return link.drain(args.quiet_ms)
        send_line(qmp, cmd)
        return ser.drain(args.quiet_ms)

    def read_only(quiet, mx):
        if link is not None:
            return link.drain(quiet, mx)
        return ser.drain(quiet, mx)

    if args.command:
        for cmd in args.command:
            sys.stdout.write(run(cmd))
            sys.stdout.flush()
        return 0

    how = ("COM1 at %s" % sersock) if link is not None else ("QMP keystrokes at %s:%d" % (host, port))
    print("console: attached over %s — the machine keeps running when you leave." % how)
    print("console: type a command, or :q to quit, :shot to screenshot, :raw for qcodes.")
    sys.stdout.write(read_only(200, 1200))
    sys.stdout.flush()
    while True:
        try:
            line = input("")
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if line.strip() in (":q", ":quit"):
            break
        if line.startswith(":shot"):
            parts = line.split(None, 1)
            path = parts[1].strip() if len(parts) > 1 else "/tmp/oscortex-console.png"
            if qmp is None:
                qmp = Qmp(host, port)      # screenshots always need the monitor
            qmp.cmd("screendump", filename=path)
            print("console: wrote %s" % path)
            continue
        if line.startswith(":raw"):
            parts = line.split(None, 1)
            if len(parts) > 1:
                if qmp is None:
                    qmp = Qmp(host, port)  # raw qcodes are a keyboard thing
                for qc in parts[1].split(","):
                    qc = qc.strip()
                    if qc:
                        qmp.key(qc)
                        time.sleep(0.012)
                sys.stdout.write(read_only(args.quiet_ms, 8000))
                sys.stdout.flush()
            continue
        if line.startswith(":wait"):
            parts = line.split(None, 1)
            ms = int(parts[1]) if len(parts) > 1 and parts[1].strip().isdigit() else 2000
            sys.stdout.write(read_only(ms, ms + 2000))
            sys.stdout.flush()
            continue
        sys.stdout.write(run(line))
        sys.stdout.flush()
    print("console: detached; the machine is still running (demo.sh --status).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
