# ADR-0128 — A named platform process may mmap anonymous pages

**Status:** accepted, implemented, verified (`tests/conformance/plat-map/run.sh`)
**Date:** 2026-08-30
**Milestone:** mmap door after ADR-0127
**Files:** `core/kernel/heap.dart`, `user.dart`,
`docs/syscall-registry.md`, `tests/conformance/plat-map/`,
GAP-0322
**Depends on** ADR-0124 (16 MiB platform window), ADR-0127 (RELA
door), ADR-0016 (`sbrk` maps the frames).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc, `clone`, `futex`, or `dlopen`.
**Number:** 0128 — 0127 is the RELA door. 0125 is drawRRect.
Do not reuse 0127.

---

## 1. The question

ADR-0127 opened `PT_DYNAMIC` for `PLAT.ELF`. Official `libcef.so`
still cannot run: 1,336 UND symbols include `mmap64`. The next
binary is an **anonymous mmap door** for that name, not POSIX
`mmap`, not a DRM map, and not a pretend CEF `OnPaint`.

`sbrk` already maps the 16 MiB window. Returning the platform
heap base without taking frames would print the same VA. The
pages have to be real: `write()` walks live tables, and teardown
must free the extra frames.

## 2. The decision

1. **Syscall 27 is `mmap(len) -> va`.** 11 stays `fdwait`. 21 and
   22 stay reserved on other lines. 26 is `spawn`. No `oslibc.h`
   name — a libc `mmap()` would be the POSIX six-argument call.
2. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour it. `ASK.ELF` planted as the same bytes is
   `heapRetBadArg`. LBA spawn and every other 8.3 name keep the
   refusal. Length 0 is also `heapRetBadArg`.
3. **The pages are `sbrk`'s frames.** Platform `mmap` maps through
   `heapSbrk` / `vmPlatMap`, zeroes them, and returns the old
   break. `write()` of a string living on that VA is `elfOwns`
   walking the live tables. A print without present user pages
   is a fail.
4. **Teardown frees them.** `procSpaceFree` already walks present
   plat leaves. `PROC KILL … FREED` for `PLAT.ELF` is eight page
   tables plus the mapped pages above `ASK.ELF` of the same
   bytes. A no-op return of heap base without new frames fails
   that delta.
5. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. `wmeventStore` stays last `.bss`. This is not a
   guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or
the 32 `DT_NEEDED`. It is not a 189 MiB map. It is not raising
`de-browse` floor 87. It is not POSIX `mmap` (no fd, no
`munmap`, no `MAP_SHARED`). It is not GAP-0159 closed. It is
not `clone` / `futex` / `dlopen`. `drawRRect` still owns
`osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The 32 `DT_NEEDED` libraries (or a static rebuild), POSIX the
1,336 UND symbols still need (`clone`/`futex`/TLS/`dlopen`),
and a window that can hold 231 MiB `.text`. This decision is
the mmap door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-map/run.sh` — `PLAT.ELF` prints
`PROC MAP` with VA `0x10400000` and the derived page count,
`write()` reads `PLAT MAP PAGE` out of that VA, XOR matches
`derive.py`. `ASK.ELF` is the same bytes and prints
`ERR FFFFFFFFFFFFFFFE`. `PROC KILL FREED` for PLAT is
`vmPlatPdCount` plus the mapped pages above ASK. `elfImageMax`
is still 65,536. Syscall 11 is still `fdwait`. `de-browse/`
stays at floor 87.
