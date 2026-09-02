# ADR-0154 — A named platform process may mmap a 112 MiB CEF-text fraction

**Status:** accepted, implemented, verified (`tests/conformance/plat-huge/run.sh`)
**Date:** 2026-08-30
**Milestone:** CEF `.text` window fraction after ADR-0152
**Files:** `core/kernel/vm.dart`, `heap.dart`, `proc.dart`,
`tests/conformance/plat-huge/`, GAP-0322
**Depends on** ADR-0124 (platform window), ADR-0128 (`mmap`),
ADR-0152 (tiny libc door), ADR-0011 (128 MiB PMM floor).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or the 32 `DT_NEEDED`. Does not raise
`pmmMaxFrames` / `MAP_2MIB_PAGES` past 128 MiB.
**Number:** 0154 — 0153 is chrome-rrect Graphite. 0152 is tiny libc.
Do not reuse those. Syscall 11 stays `fdwait`. No new syscall —
27 is still `mmap`.

---

## 1. The question

ADR-0152 opened OUR tiny `LIBC.SO` `write`. Official `libcef.so`
still cannot run: `.text` is 189 MiB and the platform window was
16 MiB. The next binary is a **window that can hold a CEF-scale
map**, not glibc, and not a pretend `OnPaint`.

The PMM and `boot.S` identity map are still 128 MiB
(`pmmMaxFrames` = 32768). A full 189 MiB plant OOMs that floor.
The largest honest contiguous plant that still leaves headroom
for ELF tables is **112 MiB** (28672 pages, 56 PD entries). The
remaining 77 MiB of `.text` is leftover until the identity /
bitmap bound is raised together.

## 2. The decision

1. **Raise the platform window, not the app sandbox.**
   `[vmPlatBase, vmPlatEnd)` is now
   `[0x10400000, 0x17400000)` — 112 MiB, PD[130..185].
   `vmUserEnd` / `heapPlatTop` / `heapPlatMaxInc` match.
   TAP/FILES stay 64 KiB / 2 MiB. `heapTop` does not move.
2. **Syscall 27 still is `mmap(len) -> va`.** The flag is still
   the name: only `PLAT.ELF` may honour it. `ASK.ELF` planted as
   the same bytes is `heapRetBadArg`. Length 0 is also refused.
3. **The pages are real.** Platform `mmap` maps through
   `heapSbrk` / `vmPlatMap`, zeroes them, and returns the old
   break. The harness touches every page, `write()`s a string
   from that VA, and requires `PROC KILL FREED` for PLAT to be
   fifty-six page tables plus 28672 mapped pages above ASK.
4. **Floor fails below 112 MiB.** `plat-huge/` asserts
   `heapPlatMaxInc == 117440512` and rejects a lingering 16 MiB
   `WIN` line. Shrinking the window fails the harness.
5. **No help line.** `elfImageMax` stays 65,536.
   `wmeventStore` stays last `.bss`. Graphite / `osgfx_skia` /
   MakeVulkan / Venus are fenced.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or the
32 `DT_NEEDED`. It is not a full 189 MiB map. It is not raising
`de-browse` floor 87. It is not raising the 128 MiB PMM bound.
It is not POSIX `mmap` (no fd, no `munmap`).

## 4. What remains (GAP-0322 leftovers)

The remaining **77 MiB of 189 MiB CEF `.text`** (needs
`MAP_2MIB_PAGES` / `pmmMaxFrames` raised past 128 MiB together),
the rest of the 32 `DT_NEEDED` libraries (or a static rebuild),
and Content `OnPaint`. This decision is the largest honest
contiguous plat window under the current PMM floor.

## 5. Verification

`core/tests/conformance/plat-huge/run.sh` — `PLAT.ELF` prints
`PROC PLAT … WIN 0000000007000000`, `mmap(112 MiB)` returns
`0x10400000`, `write()` reads `PLAT HUGE PAGE` out of that VA,
XOR matches `derive.py`. `ASK.ELF` is the same bytes and prints
`ASKED FFFFFFFFFFFFFFFE`. `PROC KILL FREED` delta is
56 + 28672. `elfImageMax` is still 65,536. Syscall 11 is still
`fdwait`. `de-browse/` stays at floor 87.
