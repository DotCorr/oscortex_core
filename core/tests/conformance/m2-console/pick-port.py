#!/usr/bin/env python3
"""core/tests/conformance/m2-console/pick-port.py

Prints a TCP port on 127.0.0.1 that is free RIGHT NOW.

WHY THIS EXISTS
---------------------------------------------------------------------------
Every harness that drives QEMU through QMP picked its port arithmetically:

    port=$(( 47000 + ($$ % 8000) + portoff ))

which is a HASH OF A PROCESS ID, not a free port. It collides in three ways
that all show up as QEMU dying with `Failed to find an available port: Address
already in use` and a harness reporting a failure that has nothing to do with
the kernel:

  * two harnesses run at once and their PIDs are 8000 apart;
  * a harness is re-run and the OS recycled the PID;
  * a previous boot's socket is still in TIME_WAIT.

This asks the KERNEL for a free port instead: bind to port 0, read back what
was assigned, close, and print it. That is not race-free -- the port is
released before QEMU claims it, and something else can take it in between --
so it is HALF the fix. The other half is in the harnesses: `drive_session`
retries the launch, up to five times, when and only when QEMU's log says the
address was in use. Together they turn an intermittent failure into a
one-line note. GAP-0150 records the residual race and what closing it fully
would take (passing QEMU an already-bound fd, which its `-qmp` does not
accept in the `tcp:` form these harnesses use).

SO_REUSEADDR is deliberately NOT set: with it, `bind` succeeds on a port that
is in TIME_WAIT, and QEMU -- which does set it -- would then also succeed, but
a port this script hands out should be one that is genuinely idle rather than
one that merely can be re-bound.

Usage:
    pick-port.py            # one port
    pick-port.py <n>        # n distinct ports, one per line

Exit status: 0 and the port(s) on stdout, 2 if no port could be found.
"""

import socket
import sys


def one(taken):
    for _ in range(64):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        finally:
            s.close()
        if port not in taken:
            taken.add(port)
            return port
    print("pick-port: could not find a free port after 64 tries", file=sys.stderr)
    raise SystemExit(2)


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    taken = set()
    for _ in range(n):
        print(one(taken))


if __name__ == "__main__":
    main()
