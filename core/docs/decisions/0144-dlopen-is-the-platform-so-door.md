# ADR-0144 — A named platform process may dlopen our tiny FAT .so

**Status:** accepted, implemented, verified (`tests/conformance/plat-dl/run.sh`)
**Date:** 2026-08-30
**Milestone:** dlopen door after ADR-0130
**Files:** `core/kernel/elf.dart`, `user.dart`,
`docs/syscall-registry.md`, `tests/conformance/plat-dl/`,
GAP-0322
**Depends on** ADR-0124 (16 MiB platform window), ADR-0128
(anonymous mmap / `heapSbrk`), ADR-0014 (FAT ELF load).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc, `futex`, or TLS.
**Number:** 0144 — 0142 is configure-to-client. 0143 is the movie.
Do not reuse 0142 or 0143. Syscall 11 stays `fdwait`.

---

## 1. The question

ADR-0130 opened `clone` for `PLAT.ELF`. Official `libcef.so` still
cannot run: 1,336 UND symbols include `dlopen`. The next binary is
a **dlopen door** for that name — our own tiny FAT `ET_DYN`, not
glibc, and not a pretend CEF `OnPaint`.

A fake return that invents a VA without mapping the file would
print the same parent line. The caller has to read `so_mark` from
the mapped pages and write the derived word. A volume without the
named `.so` is a named refusal and cannot print that line.

## 2. The decision

1. **Syscall 29 is `dlopen(namePtr, nameLen) -> va`.** 11 stays
   `fdwait`. 21 and 22 stay reserved on other lines. 26 is `spawn`,
   27 is `mmap`, 28 is `clone`. No `oslibc.h` name — a libc
   `dlopen()` would be glibc's.
2. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour it. `ASK.ELF` planted as the same bytes is
   `elfDlopenRetBadArg`. LBA spawn and every other 8.3 name keep
   the refusal. The name must be a live user-owned string; the
   file must be a FAT-resident `ET_DYN` with an exported `so_mark`.
3. **Map through `heapSbrk`, resolve one symbol.** LOAD segments
   land in the platform heap. Dynsym is walked for `so_mark`. The
   returned VA is that symbol. Missing file is
   `elfDlopenRetNotFound`. A corrupt `.so` is `elfDlopenRetBadSo`.
4. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. `wmeventStore` stays last `.bss`. This is not a
   guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or the
32 `DT_NEEDED`. It is not a 189 MiB map. It is not raising
`de-browse` floor 87. It is not glibc `dlopen` (no `RTLD_*`, no
constructor, one symbol). It is not `futex`. It is not TLS.
`drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The 32 `DT_NEEDED` libraries (or a static rebuild), POSIX the
1,336 UND symbols still need (`futex`/TLS), and a window that can
hold 231 MiB `.text`. This decision is the dlopen door. It is not
those rungs.

## 5. Verification

`core/tests/conformance/plat-dl/run.sh` — `PLAT.ELF` prints
`PROC DLOPEN` with a VA, then writes the derived `MARK` line from
the mapped `so_mark`. A missing name is `ERR …F9`. `ASK.ELF` is
the same bytes and prints `ERR FFFFFFFFFFFFFFFE`. `elfImageMax` is
still 65,536. Syscall 11 is still `fdwait`. `de-browse/` stays at
floor 87.
