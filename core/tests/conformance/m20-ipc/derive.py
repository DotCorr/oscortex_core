#!/usr/bin/env python3
"""core/tests/conformance/m20-ipc/derive.py

Computes, ON THE HOST AND WITHOUT BOOTING ANYTHING, every number the two ring-3
processes must produce -- including the two 64-bit exit statuses, each of which
is an FNV-1a hash of every payload byte that process received.

WHY THIS FILE IS THE POINT OF THE HARNESS
---------------------------------------------------------------------------
"Two processes exchanged a message" is satisfied by a kernel that hands the
receiver a zero-filled buffer and returns the right length. What is NOT
satisfied by such a kernel is a 64-bit hash of the bytes.

So this script re-implements the protocol's five formulas independently of
prog.c -- run.sh separately checks that the two implementations agree by reading
prog.c's own constants -- and produces:

  * the length and the exact bytes of every one of the four requests,
  * the reply the responder is REQUIRED to derive from each,
  * the eight burst messages,
  * `a_hash`: FNV-1a over the four replies, which is side 0's exit status,
  * `b_hash`: FNV-1a over the four requests then the eight burst messages,
    which is side 1's exit status,
  * the number of CHAN SEND and CHAN RECV lines the kernel must print, and the
    byte total it must report.

A kernel that delivered a stale slot, a shifted copy, a truncation, or the
right bytes to the wrong side produces a different hash and the harness fails.

    derive.py <kerneldir> <prog.c>

Exit status: 0 and `key=value` lines on stdout.
"""

import re
import sys

PORT = 0
ROUNDS = 4
BURST = 8
MSGMAX = 64

FNV_OFF = 0xCBF29CE484222325
FNV_PRM = 0x00000100000001B3
M64 = (1 << 64) - 1


def reqlen(k):
    return 8 + 13 * k


def replen(k):
    return 64 - reqlen(k)


def reqbyte(k, i):
    return (0x41 + ((k * 7 + i * 11) % 26)) & 0xFF


def burstbyte(j, i):
    return (0xB0 + 3 * j + 5 * i) & 0xFF


def request(k):
    return bytes(reqbyte(k, i) for i in range(reqlen(k)))


def reply(k):
    """What the responder must send back, derived from the request it received."""
    req = request(k)
    n = len(req)
    return bytes((req[i % n] + i + 1) & 0xFF for i in range(replen(k)))


def burst(j):
    return bytes(burstbyte(j, i) for i in range(MSGMAX))


def fold(h, b):
    for x in b:
        h = ((h ^ x) * FNV_PRM) & M64
    return h


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: derive.py <kerneldir> <prog.c>")
    kernel_dir, prog_c = sys.argv[1], sys.argv[2]

    chan = open(kernel_dir + "/chan.dart").read()

    def kconst(name):
        m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(name),
                      chan, re.M)
        if not m:
            raise SystemExit("derive: chan.dart has no %s" % name)
        return int(m.group(1), 0)

    msg_bytes = kconst("chanMsgBytes")
    ring_depth = kconst("chanRingDepth")
    ports = kconst("chanPorts")

    src = open(prog_c).read()

    def pconst(name):
        m = re.search(r"^#define %s (\d+)" % re.escape(name), src, re.M)
        if not m:
            raise SystemExit("derive: prog.c has no %s" % name)
        return int(m.group(1))

    # THE PROTOCOL AND THE KERNEL MUST AGREE, and this is where that is
    # established rather than assumed. `BURST == chanRingDepth` is what makes
    # the burst exactly fill the ring, which is what makes the ninth send a
    # CHAN_FULL rather than a coincidence.
    if pconst("MSGMAX") != msg_bytes:
        raise SystemExit("derive: prog.c MSGMAX=%d but chan.dart chanMsgBytes=%d"
                         % (pconst("MSGMAX"), msg_bytes))
    if pconst("BURST") != ring_depth:
        raise SystemExit("derive: prog.c BURST=%d but chan.dart chanRingDepth=%d -- "
                         "the burst would not exactly fill the ring, so the CHAN_FULL "
                         "assertion would prove nothing" % (pconst("BURST"), ring_depth))
    if pconst("ROUNDS") != ROUNDS:
        raise SystemExit("derive: prog.c ROUNDS=%d but derive.py assumes %d"
                         % (pconst("ROUNDS"), ROUNDS))
    if pconst("PORT") >= ports:
        raise SystemExit("derive: prog.c PORT=%d is not below chanPorts=%d"
                         % (pconst("PORT"), ports))

    # The four request/reply lengths must all be different, or "the length is
    # carried" is not a claim this protocol can support.
    lens = [reqlen(k) for k in range(ROUNDS)] + [replen(k) for k in range(ROUNDS)]
    if len(set(lens)) != len(lens):
        raise SystemExit("derive: two messages in the protocol have the same length: %r"
                         % lens)
    for k in range(ROUNDS):
        if not (1 <= reqlen(k) <= msg_bytes and 1 <= replen(k) <= msg_bytes):
            raise SystemExit("derive: round %d has a length outside [1, %d]" % (k, msg_bytes))
        # A reply must not be byte-equal to its request, or "derived from what
        # arrived" would be satisfied by an echo.
        if reply(k)[:min(reqlen(k), replen(k))] == request(k)[:min(reqlen(k), replen(k))]:
            raise SystemExit("derive: round %d's reply is a prefix-echo of its request" % k)

    a_hash = FNV_OFF
    for k in range(ROUNDS):
        a_hash = fold(a_hash, reply(k))

    b_hash = FNV_OFF
    for k in range(ROUNDS):
        b_hash = fold(b_hash, request(k))
    for j in range(BURST):
        b_hash = fold(b_hash, burst(j))

    if a_hash == b_hash:
        raise SystemExit("derive: the two sides' hashes are equal -- one exit status "
                         "would satisfy both and the test would not distinguish them")

    # What the KERNEL must report, independently of what the programs say.
    #   sends: 4 requests + 4 replies + 8 burst = 16 accepted
    #   recvs: the same 16 delivered
    #   bytes: every delivered payload byte
    sends = ROUNDS * 2 + BURST
    recvs = sends
    total_bytes = (sum(reqlen(k) for k in range(ROUNDS))
                   + sum(replen(k) for k in range(ROUNDS))
                   + BURST * MSGMAX)

    out = {
        "msg_bytes": msg_bytes,
        "ring_depth": ring_depth,
        "ports": ports,
        "rounds": ROUNDS,
        "burst": BURST,
        "a_hash": "%016X" % a_hash,
        "b_hash": "%016X" % b_hash,
        "sends": sends,
        "recvs": recvs,
        "total_bytes": total_bytes,
        "req_lens": ",".join(str(reqlen(k)) for k in range(ROUNDS)),
        "rep_lens": ",".join(str(replen(k)) for k in range(ROUNDS)),
    }
    for k in range(ROUNDS):
        out["req%d_hex" % k] = request(k).hex().upper()
        out["rep%d_hex" % k] = reply(k).hex().upper()
        out["req%d_len" % k] = reqlen(k)
        out["rep%d_len" % k] = replen(k)
    for j in range(BURST):
        out["burst%d_hex" % j] = burst(j).hex().upper()

    # The per-round running hashes, so the transcript's `IPC A ROUND k H ...`
    # and `IPC B ROUND k H ...` lines are each checked rather than only the
    # final one. A kernel that delivered round 2's message twice and round 3's
    # never would still produce... a different final hash, but the round line
    # says WHICH round went wrong.
    h = FNV_OFF
    for k in range(ROUNDS):
        h = fold(h, reply(k))
        out["a_h%d" % k] = "%016X" % h
    h = FNV_OFF
    for k in range(ROUNDS):
        h = fold(h, request(k))
        out["b_h%d" % k] = "%016X" % h
    for j in range(BURST):
        h = fold(h, burst(j))
        out["b_burst_h%d" % j] = "%016X" % h

    for k in sorted(out):
        print("%s=%s" % (k, out[k]))


if __name__ == "__main__":
    main()
