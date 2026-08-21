#!/usr/bin/env python3
"""core/tests/conformance/m7-frames/derive.py

Recomputes, from OUTSIDE the kernel, everything the physical memory manager
claims: which frames are free, how many, their sum and xor folds, and the exact
contents of the frame bitmap.

WHY THIS FILE EXISTS. `run.sh` could compare the kernel's output against a
golden and stop there, and a golden proves the kernel is CONSISTENT with
itself. It does not prove the numbers are RIGHT — a bitmap built from the wrong
predicate produces a stable, reproducible, wrong answer, and regenerating the
golden would bless it forever. So every number in `expected.txt` is also
derived here from two sources the kernel does not control:

  * the Multiboot memory map, parsed out of the boot's own `MB E` lines (which
    m1-interrupts' 544-byte golden already pins byte-for-byte, so they cannot
    drift silently);
  * `__kernel_start` / `__kernel_end`, read out of `kernel.elf` with readelf.

This is m6-disk's discipline applied to memory instead of to a disk: there, the
expected hexdump is computed by the image generator rather than quoted from a
capture. Here, the expected free count, bitmap and folds are computed by this
file. **Updating the golden cannot make a wrong allocator pass**, because the
derived checks run against the same capture.

THE RULES THIS FILE ENCODES are core/kernel/pmm.dart's, restated
independently rather than imported (there is nothing to import from — the
kernel is not Python):

  1. every frame starts RESERVED;
  2. a frame is freed only if it lies WHOLLY inside a type-1 region;
  3. frames above the bound are COUNTED and never freed;
  4. the first `LOW_RESERVED` frames are taken back unconditionally;
  5. the frames the kernel image occupies are taken back;
  6. the `VM_FRAMES` lowest frames still free after all of that are the kernel's
     own page tables (M8), taken at boot and never returned.

If pmm.dart and this file disagree, one of them is wrong and run.sh says so.
That is the point of writing it twice.
"""

import re
import sys

# Must match core/kernel/pmm.dart. run.sh asserts these against the source
# rather than trusting the copy.
FRAME_BYTES = 4096
MAX_FRAMES = 32768
LOW_RESERVED = 256

# M8 (ADR-0012). The kernel's own page tables come out of THIS allocator, at
# boot, before any command can run -- so the allocator a `frames` report
# describes has already spent this many frames and can never get them back
# (`pmmAllocatable` refuses them, `vmHoldsFrame`). They are the LOWEST
# allocatable frames, because `vmInit` runs on an untouched allocator whose
# next-fit cursor is 0.
#
# It is reserved here rather than subtracted from a count, so that everything
# derived from the free SET -- the first `alloc`'s address, the drain's
# SUM/XOR/LOW/HIGH, and the bitmap compared bit-for-bit -- follows automatically
# instead of each needing its own fudge. m8-paging/run.sh asserts this number
# against `vmFrameCount` in core/kernel/vm.dart.
VM_FRAMES = 6


def parse_mmap(serial_text):
    """Every `MB E <base:16> <length:16> <type:8>` line of a serial capture.

    Returns a list of (base, length, type). The kernel prints these at boot
    from the structure the loader handed it; m1-interrupts' golden asserts the
    whole block byte-for-byte, so a machine whose map changed would fail there
    first.
    """
    out = []
    for m in re.finditer(r"^MB E ([0-9A-F]{16}) ([0-9A-F]{16}) ([0-9A-F]{8})$",
                         serial_text, re.M):
        out.append((int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)))
    return out


def build(entries, kernel_start, kernel_end):
    """The bitmap the kernel should have built, plus the counts it should report.

    `used` is a list of MAX_FRAMES booleans, True = used or reserved, which is
    the same polarity as the kernel's bit (1 = used).
    """
    used = [True] * MAX_FRAMES
    over = 0
    for base, length, typ in entries:
        if typ != 1:
            continue
        first = (base + FRAME_BYTES - 1) // FRAME_BYTES
        last_ex = (base + length) // FRAME_BYTES
        if last_ex <= first:
            continue
        if first >= MAX_FRAMES:
            over += last_ex - first
            continue
        if last_ex > MAX_FRAMES:
            over += last_ex - MAX_FRAMES
            last_ex = MAX_FRAMES
        for f in range(first, last_ex):
            used[f] = False
    for f in range(0, min(LOW_RESERVED, MAX_FRAMES)):
        used[f] = True
    k_first = kernel_start // FRAME_BYTES
    k_last_ex = min((kernel_end + FRAME_BYTES - 1) // FRAME_BYTES, MAX_FRAMES)
    for f in range(k_first, k_last_ex):
        used[f] = True
    # 6. M8: the kernel's page tables, which are the first VM_FRAMES frames
    #    still free after everything above. Marked used because they are taken
    #    at boot and can never be handed out or freed again.
    taken = 0
    for f in range(MAX_FRAMES):
        if taken == VM_FRAMES:
            break
        if not used[f]:
            used[f] = True
            taken += 1
    if taken != VM_FRAMES:
        raise RuntimeError("only %d frames were free for the page tables" % taken)
    return used, over


def free_frames(used):
    """Indices of every free frame, ascending. This IS the allocatable set."""
    return [f for f, u in enumerate(used) if not u]


def to_bytes(used):
    """The bitmap as the kernel stores it: bit f in byte f>>3, bit f&7."""
    blob = bytearray(MAX_FRAMES // 8)
    for f, u in enumerate(used):
        if u:
            blob[f >> 3] |= 1 << (f & 7)
    return bytes(blob)


def from_qwords(qwords):
    """The bitmap as read back with the monitor's `xp/<n>gx`.

    Each quadword holds eight consecutive bitmap bytes, little-endian, so bit f
    is bit (f & 63) of quadword (f >> 6). Written out rather than assumed:
    getting this wrong would make a broken bitmap compare equal to a correct
    one after a byte swap.
    """
    blob = bytearray()
    for q in qwords:
        for i in range(8):
            blob.append((q >> (8 * i)) & 0xFF)
    return bytes(blob)


def main():
    if len(sys.argv) != 4:
        print("usage: derive.py <serial-capture> <kernel_start_hex> "
              "<kernel_end_hex>", file=sys.stderr)
        return 2
    entries = parse_mmap(open(sys.argv[1], "rb").read().decode("latin-1"))
    used, over = build(entries, int(sys.argv[2], 16), int(sys.argv[3], 16))
    free = free_frames(used)
    print("entries      %d" % len(entries))
    print("free frames  %d (0x%X)" % (len(free), len(free)))
    print("used frames  %d (0x%X)" % (MAX_FRAMES - len(free), MAX_FRAMES - len(free)))
    print("over         %d (0x%X)" % (over, over))
    if free:
        print("lowest free  0x%X" % (free[0] * FRAME_BYTES))
        print("highest free 0x%X" % (free[-1] * FRAME_BYTES))
        print("sum          0x%X" % sum(free))
        x = 0
        for f in free:
            x ^= f
        print("xor          0x%X" % x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
