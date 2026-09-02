# ADR-0160 — A named platform ELF may load four FAT DT_NEEDED .so files

**Status:** accepted, implemented, verified (`tests/conformance/plat-need2/run.sh`)
**Date:** 2026-08-30
**Milestone:** grow the DT_NEEDED stand-in chain after ADR-0157
**Files:** `core/kernel/elf.dart` (`dl_fn` / `pt_fn` resolve),
`docs/syscall-registry.md` (no new number), `tests/conformance/plat-need2/`,
GAP-0322
**Depends on** ADR-0124 (platform window), ADR-0127 (`PT_DYNAMIC`),
ADR-0144 (`dlopen`), ADR-0152 (tiny `LIBC.SO` / `write`),
ADR-0157 (two-stand-in walk).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or the remaining 28 CEF `DT_NEEDED`.
**Number:** 0160 — 0159 is desktop Graphite `drawRect`. 0158 is
two-mappers shm. 0157 is the two-stand-in door. Do not reuse those.
Syscall 11 stays `fdwait`. No new syscall — 29 is still `dlopen`.

---

## 1. The question

ADR-0157 walked **two** FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO`) and
satisfied **2 of 32** CEF slots. Official `libcef.so` still carries
**32** `DT_NEEDED`. The next binary is to **grow the chain** — walk
**≥4** of OUR FAT-resident stand-ins (add two beyond LIBC/LIBM) with
a derived call from each. Not glibc. Not a pretend CEF `OnPaint`.

A fake success that invents a later line without mapping that file,
or that hardcodes four names while skipping `DT_NEEDED`, fails the
harness. A volume without the fourth `.so` must refuse that name
and must not print the fourth derived line.

## 2. The decision

1. **Syscall 29 still is `dlopen`.** It now also resolves `dl_fn`
   and `pt_fn` (ADR-0160) after `write` (ADR-0152) and `need_fn`
   (ADR-0157), before `so_mark` (ADR-0144). 11 stays `fdwait`. No
   new number.
2. **`PLAT.ELF` carries `PT_DYNAMIC` with four `DT_NEEDED`.** The
   sonames are OUR 8.3 FAT names:
   - `LIBC.SO` — stand-in for CEF `libc.so.6`
   - `LIBM.SO` — stand-in for CEF `libm.so.6`
   - `LIBDL.SO` — stand-in for CEF `libdl.so.2`
   - `LIBPT.SO` — stand-in for CEF `libpthread.so.0`
   The program walks its own `DT_NEEDED` / `DT_STRTAB` and
   `dlopen`s each name. `ASK.ELF` planted as the same bytes is
   still `ELF REFUSED 11` (ADR-0127).
3. **Derived call from each.**
   - `LIBC.SO` exports `write` → `LINE1` is `MARK_C ^ MIX1`
   - `LIBM.SO` exports `need_fn` → `LINE2` is `MARK_M ^ MIX2`
   - `LIBDL.SO` exports `dl_fn` → `LINE3` is `MARK_D ^ MIX3`
   - `LIBPT.SO` exports `pt_fn` → `LINE4` is `MARK_P ^ MIX4`
   X LOADs stay remapped R+X (ADR-0152).
4. **Anti-vacuity.** Missing `LIBPT.SO` is `elfDlopenRetNotFound`
   and cannot invent `LINE4`. Inventing a fourth VA without the
   fourth map fails the XOR.
5. **Count.** This satisfies **4 of 32** CEF `DT_NEEDED` slots with
   OUR stand-ins. **28 remain**, plus `OnPaint`.
6. **Remaining vs CEF's 32** (not yet stand-in'd):
   `libglib-2.0.so.0` `libgobject-2.0.so.0` `libnspr4.so`
   `libnss3.so` `libnssutil3.so` `libsmime3.so` `libdbus-1.so.3`
   `libgio-2.0.so.0` `libatk-1.0.so.0` `libatk-bridge-2.0.so.0`
   `libcups.so.2` `libX11.so.6` `libXcomposite.so.1`
   `libXdamage.so.1` `libXext.so.6` `libXfixes.so.3`
   `libXrandr.so.2` `libgbm.so.1` `libexpat.so.1` `libxcb.so.1`
   `libxkbcommon.so.0` `libcairo.so.2` `libpango-1.0.so.0`
   `libudev.so.1` `libasound.so.2` `libatspi.so.0`
   `libgcc_s.so.1` `ld-linux-x86-64.so.2`.
7. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. Graphite / `osgfx_skia` / MakeVulkan / Venus are
   fenced. Do not break `plat-need` / `plat-huge` / `plat-libc` /
   `plat-dl`.

## 3. What this is not

It is not Content painting in QEMU. It is not real `libc.so.6` /
`libm.so.6` / `libdl.so.2` / `libpthread.so.0` / libcef. It is not
the other 28 `DT_NEEDED`. It is not raising `de-browse` floor 87.
`drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The other **28** of the 32 `DT_NEEDED` (or a static rebuild), and
Content `OnPaint`. This decision is the four-stand-in `DT_NEEDED`
door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-need2/run.sh` — `PLAT.ELF` walks four
`DT_NEEDED`, dlopens `LIBC.SO` / `LIBM.SO` / `LIBDL.SO` / `LIBPT.SO`,
prints derived `LINE1`..`LINE4`. A volume without `LIBPT.SO` prints
`LINE1`..`LINE3` only and `ERR …F9` for the fourth name. `ASK.ELF`
is the same bytes and is `ELF REFUSED 11`. `elfImageMax` is still
65,536. Syscall 11 is still `fdwait`. `de-browse/` stays at floor
87.
