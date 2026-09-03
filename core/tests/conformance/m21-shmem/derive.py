#!/usr/bin/env python3
"""core/tests/conformance/m21-shmem/derive.py

THE HOST'S INDEPENDENT MODEL OF M21's SHARED REGION.

Everything here is computed from the protocol's own formulas, on the host,
BEFORE the machine boots. Nothing is read back out of the guest and then
asserted against itself.

The load-bearing output is `consumer_hash()`: the 64-bit FNV-1a of every byte
the CONSUMER should read through its shared mapping. The consumer exits with
that number. A kernel that mapped the wrong frame, mapped a zero page, mapped
one page four times, mapped the pages in the wrong order, or handed the bytes
to the wrong side produces a different 64-bit number and the harness fails.

`producer_hash()` is the same bytes with a different role tag, and the two are
REQUIRED TO DIFFER -- so one exit status cannot satisfy both checks.

Usage:
    derive.py            # print the model as JSON
"""

import json
import sys

# ---------------------------------------------------------------------------
# The window. These are `vm.dart`'s constants and run.sh checks this copy
# against the kernel's rather than trusting either.
# ---------------------------------------------------------------------------
SHM_BASE = 0x10200000
SHM_END = 0x10600000
SHM_PAGES = 1024
SHM_PD_INDEX = 129
USER_END = 0x17400000
PROG_BASE = 0x10000000
PROG_END = 0x10200000
PAGE_BYTES = 4096

# `shm.dart`'s geometry.
SHM_MAX = 4
SLOT_PAGES = 128
MAX_PAGES = 510

# The test's own protocol. prog.c carries the same numbers.
PAGES = 4
REGION = 0
DESC_MAGIC = 0x4D3231534D454D31  # "M21SMEM1"

FNV_OFF = 0xCBF29CE484222325
FNV_PRM = 0x00000100000001B3
MASK = (1 << 64) - 1


def region_va(r):
    """`shmRegionVa`, recomputed. A region's address is a function of its SLOT,
    so it is the same number in every address space."""
    return SHM_BASE + r * SLOT_PAGES * PAGE_BYTES


def patbyte(p, i):
    """prog.c's `patbyte`. Depends on BOTH the page and the offset, so a kernel
    that mapped the right number of pages in the wrong order produces different
    bytes rather than the same ones rearranged."""
    return (0x5A + p * 31 + i * 17 + ((i >> 4) * 7)) & 0xFF


def fold1(h, b):
    h ^= b & 0xFF
    return (h * FNV_PRM) & MASK


def region_hash(tag):
    h = fold1(FNV_OFF, tag)
    for p in range(PAGES):
        for i in range(PAGE_BYTES):
            h = fold1(h, patbyte(p, i))
    return h


def producer_hash():
    return region_hash(ord("P"))


def consumer_hash():
    return region_hash(ord("C"))


def expected_pages(writable):
    """The `SHM PAGE` lines one address space must print, as (va, W, X) triples.

    X IS 0 ON EVERY PAGE IN BOTH ADDRESS SPACES, and that is the W^X assertion:
    a shared page is never executable, whoever maps it and however it is
    mapped. `vmShmMap` has no `exec` parameter at all, so there is no argument
    that could produce a different answer -- and run.sh checks the live page
    tables the kernel walked rather than taking that on trust.
    """
    return [(region_va(REGION) + i * PAGE_BYTES, 1 if writable else 0, 0)
            for i in range(PAGES)]


def main():
    model = {
        "shm_base": SHM_BASE,
        "shm_end": SHM_END,
        "shm_pd_index": SHM_PD_INDEX,
        "user_end": USER_END,
        "max_pages": MAX_PAGES,
        "pages": PAGES,
        "region": REGION,
        "region_va": region_va(REGION),
        "desc_magic": DESC_MAGIC,
        "producer_hash": "%016X" % producer_hash(),
        "consumer_hash": "%016X" % consumer_hash(),
        "producer_pages": [["%016X" % va, w, x] for va, w, x in expected_pages(True)],
        "consumer_pages": [["%016X" % va, w, x] for va, w, x in expected_pages(False)],
        # 4 region pages + 1 frame-vector page.
        "frames_per_region": PAGES + 1,
    }
    if producer_hash() == consumer_hash():
        raise SystemExit("derive: the two hashes are equal; one exit status "
                         "could satisfy both checks")
    json.dump(model, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
