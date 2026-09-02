# ADR-0130 — A named platform process may clone a sibling on its page tables

**Status:** accepted, implemented, verified (`tests/conformance/plat-clone/run.sh`)
**Date:** 2026-08-30
**Milestone:** clone door after ADR-0128
**Files:** `core/kernel/proc.dart`, `user.dart`,
`docs/syscall-registry.md`, `tests/conformance/plat-clone/`,
GAP-0322
**Depends on** ADR-0124 (16 MiB platform window), ADR-0128
(anonymous mmap), ADR-0015 (process table).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc, `futex`, TLS, or `dlopen`.
**Number:** 0130 — 0129 is Graphite MakeVulkan. 0128 is mmap.
GAP-0130 is a historical FAT-write gap, not this ADR.
Do not reuse 0128 or 0129.

---

## 1. The question

ADR-0128 opened anonymous `mmap` for `PLAT.ELF`. Official
`libcef.so` still cannot run: 1,336 UND symbols include `clone`.
`spawn` (syscall 26) loads a *different* ELF into a *new* address
space. A Content thread starts at a function that already lives
here. The next binary is a **clone door** for that name, not Linux
`clone`, not a futex, and not a pretend CEF `OnPaint`.

A tid without a READY slot would print the same parent line.
The child has to run: `write()` of a derived `CHILD` line, and
the first `PROC KILL FREED` must be zero because the survivor
still walks those tables.

## 2. The decision

1. **Syscall 28 is `clone(fn, stack) -> slot`.** 11 stays `fdwait`.
   21 and 22 stay reserved on other lines. 26 is `spawn`. 27 is
   `mmap`. No `oslibc.h` name — a libc `clone()` would be the
   Linux flags call.
2. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour it. `ASK.ELF` planted as the same bytes is
   `cloneRetBadArg`. LBA spawn and every other 8.3 name keep the
   refusal. `fn` must be a user-executable mapped page in the
   2 MiB window. `stack` must be 16 user-owned writable bytes
   below the given top.
3. **The child shares the caller's page tables.** Same PML4, PDPT,
   PD, PT. `PROC CLONE` prints that PML4. A new `procCreate` is
   `spawn` and would not run `fn`. The first sharer to exit
   leaves the frames; `PROC KILL FREED` is zero. The last one
   frees as today. A double-free of the shared tables fails the
   second kill or the ASK delta.
4. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. `wmeventStore` stays last `.bss`. This is not a
   guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or
the 32 `DT_NEEDED`. It is not a 189 MiB map. It is not raising
`de-browse` floor 87. It is not Linux `clone` (no flags, no TLS,
no `CLONE_CHILD_CLEARTID`). It is not `futex`. It is not
`dlopen`. `drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The 32 `DT_NEEDED` libraries (or a static rebuild), POSIX the
1,336 UND symbols still need (`futex`/TLS/`dlopen`), and a
window that can hold 231 MiB `.text`. This decision is the
clone door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-clone/run.sh` — `PLAT.ELF` prints
`PROC CLONE` with the child's slot and the parent's PML4,
then `PARENT` and `CAP`. The child writes the derived `CHILD`
line. First `PROC KILL FREED` is 0; the last is `ASK.ELF`'s
single free plus eight platform PD tables. `ASK.ELF` is the same bytes and prints
`ERR FFFFFFFFFFFFFFFE`. `elfImageMax` is still 65,536.
Syscall 11 is still `fdwait`. `de-browse/` stays at floor 87.
