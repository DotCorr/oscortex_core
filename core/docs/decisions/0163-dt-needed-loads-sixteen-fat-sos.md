# ADR-0163 — A named platform ELF may load sixteen FAT DT_NEEDED .so files

**Status:** accepted, implemented, verified (`tests/conformance/plat-need4/run.sh`)
**Date:** 2026-08-30
**Milestone:** grow the DT_NEEDED stand-in chain after ADR-0162
**Files:** `core/kernel/elf.dart` (`nu_fn` / `sm_fn` / `db_fn` / `gi_fn` /
`at_fn` / `ab_fn` / `cu_fn` / `x1_fn` resolve), `docs/syscall-registry.md`
(no new number), `tests/conformance/plat-need4/`, GAP-0322
**Depends on** ADR-0124 (platform window), ADR-0127 (`PT_DYNAMIC`),
ADR-0144 (`dlopen`), ADR-0152 (tiny `LIBC.SO` / `write`),
ADR-0157 (two-stand-in walk), ADR-0160 (four-stand-in walk),
ADR-0162 (eight-stand-in walk).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not ship glibc or the remaining 16 CEF `DT_NEEDED`.
**Number:** 0163 — 0162 is DT_NEEDED-eight. 0161 is curved Graphite
`MakeRectXY`. Do not reuse those. Syscall 11 stays `fdwait`. No new
syscall — 29 is still `dlopen`.

---

## 1. The question

ADR-0162 walked **eight** FAT `DT_NEEDED` and satisfied **8 of 32**
CEF slots. Official `libcef.so` still carries **32** `DT_NEEDED`. The
next binary is to **grow the chain** — walk **≥16** of OUR FAT-resident
stand-ins (add eight beyond the ADR-0162 set) with a derived call from
each. Not glibc. Not a pretend CEF `OnPaint`.

A fake success that invents a later line without mapping that file, or
that hardcodes sixteen names while skipping `DT_NEEDED`, fails the
harness. A volume without the sixteenth `.so` must refuse that name and
must not print the sixteenth derived line.

## 2. The decision

1. **Syscall 29 still is `dlopen`.** It now also resolves `nu_fn`,
   `sm_fn`, `db_fn`, `gi_fn`, `at_fn`, `ab_fn`, `cu_fn`, and `x1_fn`
   (ADR-0163) after `write` / `need_fn` / `dl_fn` / `pt_fn` /
   `gb_fn` / `go_fn` / `np_fn` / `ns_fn`, before `so_mark`
   (ADR-0144). 11 stays `fdwait`. No new number.
2. **`PLAT.ELF` carries `PT_DYNAMIC` with sixteen `DT_NEEDED`.** The
   sonames are OUR 8.3 FAT names:
   - `LIBC.SO` — stand-in for CEF `libc.so.6`
   - `LIBM.SO` — stand-in for CEF `libm.so.6`
   - `LIBDL.SO` — stand-in for CEF `libdl.so.2`
   - `LIBPT.SO` — stand-in for CEF `libpthread.so.0`
   - `LIBGB.SO` — stand-in for CEF `libglib-2.0.so.0`
   - `LIBGO.SO` — stand-in for CEF `libgobject-2.0.so.0`
   - `LIBNP.SO` — stand-in for CEF `libnspr4.so`
   - `LIBNS.SO` — stand-in for CEF `libnss3.so`
   - `LIBNU.SO` — stand-in for CEF `libnssutil3.so`
   - `LIBSM.SO` — stand-in for CEF `libsmime3.so`
   - `LIBDB.SO` — stand-in for CEF `libdbus-1.so.3`
   - `LIBGI.SO` — stand-in for CEF `libgio-2.0.so.0`
   - `LIBAT.SO` — stand-in for CEF `libatk-1.0.so.0`
   - `LIBAB.SO` — stand-in for CEF `libatk-bridge-2.0.so.0`
   - `LIBCU.SO` — stand-in for CEF `libcups.so.2`
   - `LIBX1.SO` — stand-in for CEF `libX11.so.6`
   The program walks its own `DT_NEEDED` / `DT_STRTAB` and
   `dlopen`s each name. `ASK.ELF` planted as the same bytes is
   still `ELF REFUSED 11` (ADR-0127).
3. **Derived call from each.**
   - `LIBC.SO` exports `write` → `LINE1` is `MARK_C ^ MIX1`
   - `LIBM.SO` exports `need_fn` → `LINE2` is `MARK_M ^ MIX2`
   - `LIBDL.SO` exports `dl_fn` → `LINE3` is `MARK_D ^ MIX3`
   - `LIBPT.SO` exports `pt_fn` → `LINE4` is `MARK_P ^ MIX4`
   - `LIBGB.SO` exports `gb_fn` → `LINE5` is `MARK_GB ^ MIX5`
   - `LIBGO.SO` exports `go_fn` → `LINE6` is `MARK_GO ^ MIX6`
   - `LIBNP.SO` exports `np_fn` → `LINE7` is `MARK_NP ^ MIX7`
   - `LIBNS.SO` exports `ns_fn` → `LINE8` is `MARK_NS ^ MIX8`
   - `LIBNU.SO` exports `nu_fn` → `LINE9` is `MARK_NU ^ MIX9`
   - `LIBSM.SO` exports `sm_fn` → `LINE10` is `MARK_SM ^ MIX10`
   - `LIBDB.SO` exports `db_fn` → `LINE11` is `MARK_DB ^ MIX11`
   - `LIBGI.SO` exports `gi_fn` → `LINE12` is `MARK_GI ^ MIX12`
   - `LIBAT.SO` exports `at_fn` → `LINE13` is `MARK_AT ^ MIX13`
   - `LIBAB.SO` exports `ab_fn` → `LINE14` is `MARK_AB ^ MIX14`
   - `LIBCU.SO` exports `cu_fn` → `LINE15` is `MARK_CU ^ MIX15`
   - `LIBX1.SO` exports `x1_fn` → `LINE16` is `MARK_X1 ^ MIX16`
   X LOADs stay remapped R+X (ADR-0152).
4. **Anti-vacuity.** Missing `LIBX1.SO` is `elfDlopenRetNotFound`
   and cannot invent `LINE16`. Inventing a sixteenth VA without the
   sixteenth map fails the XOR.
5. **Count.** This satisfies **16 of 32** CEF `DT_NEEDED` slots with
   OUR stand-ins. **16 remain**, plus `OnPaint`.
6. **Remaining vs CEF's 32** (not yet stand-in'd):
   `libXcomposite.so.1` `libXdamage.so.1` `libXext.so.6`
   `libXfixes.so.3` `libXrandr.so.2` `libgbm.so.1`
   `libexpat.so.1` `libxcb.so.1` `libxkbcommon.so.0`
   `libcairo.so.2` `libpango-1.0.so.0` `libudev.so.1`
   `libasound.so.2` `libatspi.so.0` `libgcc_s.so.1`
   `ld-linux-x86-64.so.2`.
7. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. Graphite / `osgfx_skia` / MakeVulkan / Venus are
   fenced. Do not break `plat-need` / `plat-need2` / `plat-need3` /
   `plat-huge` / `plat-libc` / `plat-dl`.

## 3. What this is not

It is not Content painting in QEMU. It is not real `libc.so.6` /
`libm.so.6` / `libdl.so.2` / `libpthread.so.0` / `libglib-2.0.so.0` /
`libgobject-2.0.so.0` / `libnspr4.so` / `libnss3.so` /
`libnssutil3.so` / `libsmime3.so` / `libdbus-1.so.3` /
`libgio-2.0.so.0` / `libatk-1.0.so.0` / `libatk-bridge-2.0.so.0` /
`libcups.so.2` / `libX11.so.6` / libcef. It is not the other 16
`DT_NEEDED`. It is not raising `de-browse` floor 87. `drawRRect`
still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The other **16** of the 32 `DT_NEEDED` (or a static rebuild), and
Content `OnPaint`. This decision is the sixteen-stand-in `DT_NEEDED`
door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-need4/run.sh` — `PLAT.ELF` walks sixteen
`DT_NEEDED`, dlopens `LIBC.SO` … `LIBX1.SO`, prints derived
`LINE1`..`LINE16`. A volume without `LIBX1.SO` prints `LINE1`..`LINE15`
only and `ERR …F9` for the sixteenth name. `ASK.ELF` is the same bytes
and is `ELF REFUSED 11`. `elfImageMax` is still 65,536. Syscall 11
is still `fdwait`. `de-browse/` stays at floor 87.
