# ADR-0157 — A named platform ELF may load two FAT DT_NEEDED .so files

**Status:** accepted, implemented, verified (`tests/conformance/plat-need/run.sh`)
**Date:** 2026-08-30
**Milestone:** second DT_NEEDED stand-in after ADR-0152 / ADR-0155
**Files:** `core/kernel/elf.dart` (`need_fn` resolve),
`docs/syscall-registry.md` (no new number), `tests/conformance/plat-need/`,
GAP-0322
**Depends on** ADR-0124 (platform window), ADR-0127 (`PT_DYNAMIC`),
ADR-0144 (`dlopen`), ADR-0152 (tiny `LIBC.SO` / `write`).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or the remaining 30 CEF `DT_NEEDED`.
**Number:** 0157 — 0156 is `shmshrink`. 0155 is the 189 MiB plant.
Do not reuse those. Syscall 11 stays `fdwait`. No new syscall — 29
is still `dlopen`.

---

## 1. The question

ADR-0155 planted the full 189 MiB CEF `.text` window. ADR-0152 opened
OUR tiny `LIBC.SO` through a hardcoded `dlopen("LIBC.SO")`. Official
`libcef.so` still carries **32** `DT_NEEDED`. The next binary is a
**DT_NEEDED walk** that loads **more than one** of OUR FAT-resident
stand-ins — `LIBC.SO` plus a second tiny `.so` (`LIBM.SO`) — with a
derived call from each. Not glibc. Not a pretend CEF `OnPaint`.

A fake success that invents the second line without mapping the
second file, or that hardcodes two names while skipping `DT_NEEDED`,
fails the harness. A volume without the second `.so` must refuse that
name and must not print the second derived line.

## 2. The decision

1. **Syscall 29 still is `dlopen`.** It now also resolves `need_fn`
   (ADR-0157) after `write` (ADR-0152) and before `so_mark`
   (ADR-0144). 11 stays `fdwait`. No new number.
2. **`PLAT.ELF` carries `PT_DYNAMIC` with two `DT_NEEDED`.** The
   sonames are OUR 8.3 FAT names `LIBC.SO` and `LIBM.SO` — stand-ins
   for CEF's `libc.so.6` and `libm.so.6`, not those files. The
   program walks its own `DT_NEEDED` / `DT_STRTAB` and `dlopen`s
   each name. `ASK.ELF` planted as the same bytes is still
   `ELF REFUSED 11` (ADR-0127).
3. **Derived call from each.** `LIBC.SO` exports `write` → `LINE1`
   is `MARK_C ^ MIX1`. `LIBM.SO` exports `need_fn` → `LINE2` is
   `MARK_M ^ MIX2`. X LOADs stay remapped R+X (ADR-0152).
4. **Anti-vacuity.** Missing `LIBM.SO` is `elfDlopenRetNotFound`
   and cannot invent `LINE2`. Inventing a second VA without the
   second map fails the XOR.
5. **Count.** This satisfies **2 of 32** CEF `DT_NEEDED` slots with
   OUR stand-ins. **30 remain**, plus `OnPaint`.
6. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. Graphite / `osgfx_skia` / MakeVulkan / Venus are
   fenced. Do not break `plat-huge` / `plat-libc` / `plat-dl`.

## 3. What this is not

It is not Content painting in QEMU. It is not real `libc.so.6` /
`libm.so.6` / libcef. It is not the other 30 `DT_NEEDED`. It is not
raising `de-browse` floor 87. `drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The other **30** of the 32 `DT_NEEDED` (or a static rebuild), and
Content `OnPaint`. This decision is the two-stand-in `DT_NEEDED`
door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-need/run.sh` — `PLAT.ELF` walks two
`DT_NEEDED`, dlopens `LIBC.SO` and `LIBM.SO`, prints derived `LINE1`
and `LINE2`. A volume without `LIBM.SO` prints `LINE1` only and
`ERR …F9` for the second name. `ASK.ELF` is the same bytes and is
`ELF REFUSED 11`. `elfImageMax` is still 65,536. Syscall 11 is still
`fdwait`. `de-browse/` stays at floor 87.
