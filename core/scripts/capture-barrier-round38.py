#!/usr/bin/env python3
"""Round 38 first-frame capture barrier.

Host dumps only after the guest reports a completed framebuffer write
(GOP: VIRTIO SCAN with FRAME generation after memcpy; virtio: SCAN
used-index). Two consecutive QMP dumps must match; a first dump that
still shows stale orange is discarded. Not "use the settled last shot."
"""

import hashlib
import os
import re
import time

SCAN_RE = re.compile(
    r"VIRTIO SCAN ([0-9A-F]{8}) ([0-9A-F]{8}) ([0-9A-F]{8}) "
    r"([0-9A-F]{8}) ([0-9A-F]{8})")
FRAME_RE = re.compile(r"WM FRAME N ([0-9A-F]{8})")
DONE_RE = re.compile(
    r"WM DONE .*K ([0-9A-F]+) .*")
VIS_RE = re.compile(r"WM VIS W ([0-9A-F]) .*G ([0-9A-F]{4})")


def harvest_text(ser):
    live = ""
    try:
        live = ser.read() or ""
    except Exception:
        live = ""
    path = getattr(ser, "path", None)
    blob = ""
    if path:
        try:
            blob = open(path, encoding="latin-1", errors="replace").read()
        except OSError:
            blob = ""
    return blob + "\n" + (getattr(ser, "archive", "") or "") + "\n" + live


def last_scan_gen(blob):
    gens = [int(m.group(5), 16) for m in SCAN_RE.finditer(blob)]
    return gens[-1] if gens else 0


def last_frame_n(blob):
    ns = [int(m.group(1), 16) for m in FRAME_RE.finditer(blob)]
    return ns[-1] if ns else 0


def wait_present(ser, prev_scan, prev_frame, timeout=2.0):
    """Wait until GOP SCAN or WM FRAME advances past the previous mark."""
    t0 = time.time()
    last = {"scan": prev_scan, "frame": prev_frame, "waited_ms": 0}
    while time.time() - t0 < timeout:
        blob = harvest_text(ser)
        scan = last_scan_gen(blob)
        frame = last_frame_n(blob)
        last["scan"] = scan
        last["frame"] = frame
        if scan > prev_scan or frame > prev_frame:
            last["waited_ms"] = round((time.time() - t0) * 1000.0, 2)
            return last
        time.sleep(0.002)
    last["waited_ms"] = round((time.time() - t0) * 1000.0, 2)
    return last


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def shot_barrier(q, shot_fn, dest, ser, retries=4):
    """Capture dest only after a present generation, then double-dump.

    shot_fn(q, path) writes a PNG. Returns metadata including whether
    the first dump matched the second (GTK/guest lag).
    """
    blob = harvest_text(ser)
    prev_scan = last_scan_gen(blob)
    prev_frame = last_frame_n(blob)
    mark = wait_present(ser, prev_scan, prev_frame, timeout=1.2)
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    tmp1 = dest + ".a.png"
    tmp2 = dest + ".b.png"
    shot_fn(q, tmp1)
    shot_fn(q, tmp2)
    sha1 = file_sha(tmp1)
    sha2 = file_sha(tmp2)
    dumps = 2
    chosen = tmp2
    first_stale = sha1 != sha2
    while sha1 != sha2 and dumps < (2 + retries):
        os.replace(tmp2, tmp1)
        sha1 = sha2
        shot_fn(q, tmp2)
        sha2 = file_sha(tmp2)
        dumps += 1
        chosen = tmp2
    os.replace(chosen, dest)
    if os.path.exists(tmp1):
        os.remove(tmp1)
    if os.path.exists(tmp2):
        os.remove(tmp2)
    after = harvest_text(ser)
    return {
        "path": dest,
        "scan_before": prev_scan,
        "frame_before": prev_frame,
        "scan_after": last_scan_gen(after),
        "frame_after": last_frame_n(after),
        "present_wait_ms": mark.get("waited_ms"),
        "dumps": dumps,
        "first_dump_stale": first_stale,
        "sha256": sha2,
        "double_match": sha1 == sha2,
    }
