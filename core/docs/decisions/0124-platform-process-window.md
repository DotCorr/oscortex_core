# ADR-0124 — A named platform process may use a 16 MiB window

**Status:** accepted, implemented, verified (`tests/conformance/plat-proc/run.sh`)
**Date:** 2026-08-30
**Milestone:** process ABI door after ADR-0123
**Files:** `core/kernel/vm.dart`, `heap.dart`, `proc.dart`,
`tests/conformance/plat-proc/`, GAP-0322
**Depends on** ADR-0123 (OnPaint blocker), ADR-0016 (`sbrk`),
ADR-0014 (ELF loader), ADR-0041 (SHM window split).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc, `PT_INTERP`, or a 189 MiB `.text` map.
**Number:** 0124 — 0123 is the measured blocker. Do not reuse 0123.

---

## 1. The question

ADR-0123 recorded that official `libcef.so` cannot run: 189 MiB
`.text`, `PT_INTERP`, glibc, 2 MiB process window. The next binary
is a **platform process** window, not every app ELF, and not a
pretend CEF `OnPaint`.

The 64 KiB / 2 MiB numbers are the **app** sandbox. A later Content
host needs a larger user window than TAP/FILES get. Widening
`vmProgEnd` in place would move `heapTop`, the guard page, the
stack, and m12-heap's goldens. `vmFineBytes` is the kernel map and
is not this decision.

## 2. The decision

1. **A third region, not a bigger app window.** SHM stays at
   `[0x10200000, 0x10400000)`. The platform window is
   `[0x10400000, 0x11400000)` — 16 MiB, PD[130..137].
   `vmUserEnd` is one past that. App load stays
   `[0x10000000, 0x10200000)`. `heapTop` stays `0x101FE000`.
2. **The flag is a name.** `PLAT.ELF` (8.3) is the only spawn that
   installs the eight page tables and sets `procSlotPlat`. LBA
   spawn and every other 8.3 name keep the 2 MiB `sbrk` cap.
   Same ELF bytes planted as `ASK.ELF` are refused a 3 MiB
   increment (`heapRetBadArg`). That is the anti-vacuity.
3. **Growth is real `sbrk`.** Platform `sbrk` maps frames through
   `vmPlatMap`, zeroes them, and returns the old break. `write()`
   of a string living on that heap is `elfOwns` walking the live
   tables. A print without present user pages is a fail.
4. **No new syscall.** 11 stays `fdwait`. `sbrk` is still 4.
   `elfImageMax` stays 65,536. No help line. `wmeventStore` stays
   last `.bss`. This is not a guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `PT_INTERP` /
`PT_DYNAMIC`. It is not `libc.so.6`. It is not a 189 MiB map.
It is not raising `de-browse` floor 87. It is not shrinking
`vmFineBytes`.

## 4. What remains (GAP-0322 leftovers)

`PT_INTERP`, the 32 `DT_NEEDED` libraries (or a static rebuild),
POSIX the 1,336 UND symbols need (`mmap`/`clone`/`futex`/TLS/
`dlopen`), and a window that can hold 231 MiB `.text`. This
decision is the door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-proc/run.sh` — `PLAT.ELF` prints
`PROC PLAT … WIN 0000000001000000`, `sbrk(3 MiB)` returns
`0x10400000`, `write()` reads `PLAT HEAP PAGE` out of that
heap, XOR matches `derive.py`. `ASK.ELF` is the same bytes and
prints `ASKED FFFFFFFFFFFFFFFE` plus `CAP 0000000000200000`.
`elfImageMax` is still 65,536. Syscall 11 is still `fdwait`.
