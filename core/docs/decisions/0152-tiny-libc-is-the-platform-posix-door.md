# ADR-0152 — A named platform process may call through OUR tiny libc

**Status:** accepted, implemented, verified (`tests/conformance/plat-libc/run.sh`)
**Date:** 2026-08-30
**Milestone:** first honest libc door after ADR-0148
**Files:** `core/kernel/elf.dart` (`write` resolve + R+X remap),
`docs/syscall-registry.md` (no new number), `tests/conformance/plat-libc/`,
GAP-0322
**Depends on** ADR-0124 (16 MiB platform window), ADR-0144 (`dlopen`),
ADR-0014 (FAT ELF load).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or the 32 `DT_NEEDED`. Does not open a
189 MiB window.
**Number:** 0152 — 0151 is OTA TCP. 0150 is shmgrow. 0149 is FILES move;
0153 is chrome-rrect. Do not reuse those. 0148 is setfs. Syscall 11 stays `fdwait`. No new syscall — 29 is still `dlopen`.

---

## 1. The question

ADR-0148 opened `setfs` for `PLAT.ELF`. Official `libcef.so` still
cannot run: the 1,336 UND symbols begin with POSIX faces that live
in `libc.so.6`. The next binary is a **libc door** — OUR own tiny
FAT `LIBC.SO` exporting one needed POSIX face (`write`) already
backed by syscall 1. Not glibc, and not a pretend CEF `OnPaint`.

A fake success that returns a VA without mapping the file, or that
leaves the X LOAD NX after `heapSbrk`, cannot hand the program a
live call: the call faults and the derived line never prints. A
volume without `LIBC.SO` is a named refusal and cannot invent that
line.

## 2. The decision

1. **Syscall 29 still is `dlopen`.** It now resolves `write` first
   (ADR-0152), then `so_mark` (ADR-0144). 11 stays `fdwait`. No new
   number. No `oslibc.h` `dlopen()` — that would be glibc's.
2. **The flag is still the name.** `PLAT.ELF` is the only spawn that
   may honour it. `ASK.ELF` planted as the same bytes is
   `elfDlopenRetBadArg`. Missing `LIBC.SO` / `MISS.SO` is
   `elfDlopenRetNotFound`.
3. **X LOAD pages are remapped R+X after the copy.** `heapSbrk`
   maps RW+NX; calling `write` through those pages would #PF on
   NX. `elfDlopenMakeExec` clears W and sets X. W^X stays.
4. **`write(buf, len)` returns MARK on success.** The caller prints
   `LINE` with `MARK ^ MIX`. That is the anti-vacuity for the call
   path. Direct syscall `write` in the program is not enough — the
   return must come from the mapped face.
5. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. `wmeventStore` stays last `.bss`. This is not a
   guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or the
32 `DT_NEEDED`. It is not a 189 MiB map. It is not raising
`de-browse` floor 87. It is not a full POSIX libc (one face).
`drawRRect` still owns `osgfx_skia`. Graphite / MakeVulkan / Venus
are fenced.

## 4. What remains (GAP-0322 leftovers)

The rest of the 32 `DT_NEEDED` libraries (or a static rebuild),
and a window that can hold 231 MiB / 189 MiB `.text`. This decision
is the first honest libc door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-libc/run.sh` — `PLAT.ELF` dlopens
`LIBC.SO`, calls `write`, writes `VIA LIBC` through that face, and
prints the derived `LINE`. A missing name is `ERR …F9`. `ASK.ELF`
is the same bytes and prints `ERR FFFFFFFFFFFFFFFE`. `elfImageMax`
is still 65,536. Syscall 11 is still `fdwait`. `de-browse/` stays
at floor 87.
