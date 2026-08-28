#!/usr/bin/env python3
"""core/tests/conformance/d1-mouse/script-to-keys.py

Turns one of this harness's event scripts into a `--keys` string for
`m2-console/qmp-drive.py`.

The SAME file also feeds `derive.py`, which is the whole point: the sequence
that is injected and the sequence that is expected are one text, so they cannot
drift apart. This half knows how to make each element happen; that half knows
what each element must produce.

    rel <dx> <dy>            -> rel:<dx>:<dy>
    btn <name> <down|up>     -> btn:<name>:<down|up>
    feed <hex> ...           -> the characters of `mouse feed <hex> ...`, typed,
                                then Enter
    state <label>            -> the characters of `mouse`, typed, then Enter

Usage: script-to-keys.py <script-file> [--settle-ms N] [--command-ms N]
"""

import sys

QCODE = {" ": "spc", ".": "dot", "-": "minus"}


def typed(text):
    return [QCODE.get(c, c.lower()) for c in text] + ["ret"]


def main():
    argv = sys.argv[1:]
    settle = 400
    command = 900
    if "--settle-ms" in argv:
        i = argv.index("--settle-ms")
        settle = int(argv[i + 1])
        del argv[i:i + 2]
    if "--command-ms" in argv:
        i = argv.index("--command-ms")
        command = int(argv[i + 1])
        del argv[i:i + 2]
    if len(argv) != 1:
        raise SystemExit("usage: script-to-keys.py <script-file> "
                         "[--settle-ms N] [--command-ms N]")

    out = []
    for raw in open(argv[0]):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if parts[0] == "rel":
            out.append("rel:%s:%s" % (parts[1], parts[2]))
            out.append("wait:%d" % settle)
        elif parts[0] == "btn":
            out.append("btn:%s:%s" % (parts[1], parts[2]))
            out.append("wait:%d" % settle)
        elif parts[0] == "feed":
            out += typed("mouse feed " + " ".join(parts[1:]))
            out.append("wait:%d" % command)
        elif parts[0] == "state":
            out += typed("mouse")
            out.append("wait:%d" % command)
        else:
            raise SystemExit("script-to-keys: unknown element %r" % parts[0])
    print(",".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
