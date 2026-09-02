#!/usr/bin/env python3
"""Sample RIP/RSP from a running qemu over QMP. No gdb on this machine.

Usage: rip.py <qmp-port> [samples] [delay-seconds]
"""
import json
import re
import socket
import sys
import time


class Qmp:
    def __init__(self, port):
        deadline = time.time() + 30
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


port = int(sys.argv[1])
n = int(sys.argv[2]) if len(sys.argv) > 2 else 6
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.7
q = Qmp(port)
for i in range(n):
    regs = q.hmp("info registers")
    rip = re.search(r"RIP=([0-9a-fA-F]+)", regs)
    rsp = re.search(r"RSP=([0-9a-fA-F]+)", regs)
    print("RIP=%s RSP=%s" % (rip.group(1) if rip else "?",
                             rsp.group(1) if rsp else "?"))
    sys.stdout.flush()
    time.sleep(delay)
q.cmd("quit")
