# ADR-0155 — A named platform process may mmap the full 189 MiB CEF `.text`

**Status:** accepted, implemented, verified (`tests/conformance/plat-huge/run.sh`)
**Date:** 2026-08-30
**Milestone:** CEF `.text` window complete after ADR-0154
**Files:** `core/boot/boot.S`, `core/kernel/pmm.dart`, `vm.dart`,
`heap.dart`, `shm.dart`, `proc.dart`, `tests/conformance/plat-huge/`,
GAP-0322
**Depends on** ADR-0154 (112 MiB fraction), ADR-0128 (`mmap`),
ADR-0124 (platform window), ADR-0011 (PMM / identity invariant).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or the 32 `DT_NEEDED`.
**Number:** 0155 — 0154 is the 112 MiB fraction under the old 128 MiB
PMM floor. Do not reuse that. Syscall 11 stays `fdwait`. No new
syscall — 27 is still `mmap`.

---

## 1. The question

ADR-0154 planted 112 MiB under a 128 MiB PMM / `boot.S` identity
floor and left **77 MiB of 189 MiB** as leftover. Official
`libcef.so` `.text` is measured at **189,095,087 bytes** (ADR-0123);
this decision plants the rounded **189 MiB** window
(`189 << 20` = 198,180,864) so a named platform process can hold
that map. Half an apple is not the exit.

## 2. The decision

1. **Raise `MAP_2MIB_PAGES` and `pmmMaxFrames` together.**
   `MAP_2MIB_PAGES` = 128; `pmmMaxFrames` = 65536; `pmmBoundMib` =
   256; `vmMapBytes` / `vmBigLastEx` match. The bitmap grows to
   8192 bytes (two pages); `shmPlaneFrames` stays equal to
   `pmmMaxFrames`. m7-frames still asserts the product invariant.
2. **Raise the platform window to 189 MiB.**
   `[vmPlatBase, vmPlatEnd)` is now
   `[0x10400000, 0x1C100000)` — 189 MiB, PD[130..224]
   (`vmPlatPdCount` = 95). `vmUserEnd` / `heapPlatTop` /
   `heapPlatMaxInc` match. TAP/FILES stay 64 KiB / 2 MiB.
3. **Syscall 27 still is `mmap(len) -> va`.** Only `PLAT.ELF`
   may honour it. `ASK.ELF` planted as the same bytes is
   `heapRetBadArg`. Length 0 is refused.
4. **The pages are real.** Platform `mmap` maps through
   `heapSbrk` / `vmPlatMap`, zeroes them, and returns the old
   break. The harness touches every page, `write()`s a string
   from that VA, and requires `PROC KILL FREED` for PLAT to be
   ninety-five page tables plus 48384 mapped pages above ASK.
5. **Anti-vacuity.** `plat-huge/` asserts
   `heapPlatMaxInc == 198180864`, `pmmMaxFrames > 32768`, and
   rejects a lingering 112 MiB `WIN` / 128 MiB PMM. Shrinking
   either bound fails the harness.
6. **No help line.** `elfImageMax` stays 65,536.
   `wmeventStore` stays last `.bss`. Graphite / `osgfx_skia` /
   MakeVulkan / Venus are fenced.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or the
32 `DT_NEEDED`. It is not raising `de-browse` floor 87. It is not
POSIX `mmap` (no fd, no `munmap`).

## 4. What remains (GAP-0322 leftovers)

The rest of the 32 `DT_NEEDED` libraries (or a static rebuild),
and Content `OnPaint`. The 189 MiB plant is closed.

## 5. Verification

`core/tests/conformance/plat-huge/run.sh` — `PLAT.ELF` prints
`PROC PLAT … WIN 000000000BD00000`, `mmap(189 MiB)` returns
`0x10400000`, `write()` reads `PLAT HUGE PAGE` out of that VA,
XOR matches `derive.py`. `ASK.ELF` is the same bytes and prints
`ASKED FFFFFFFFFFFFFFFE`. `PROC KILL FREED` delta is
95 + 48384. `elfImageMax` is still 65,536. Syscall 11 is still
`fdwait`. `de-browse/` stays at floor 87. QEMU `-m 256M`.
