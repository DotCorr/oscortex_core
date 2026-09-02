# ADR-0176 — SOMAP covers all thirty-two official CEF sonames

**Status:** accepted, implemented, verified (`tests/conformance/cef-somap/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow ADR-0174's SOMAP door from 1 → 32 CEF Linux sonames
**Files:** `core/kernel/elf.dart` (`elfDlopenNameMax`, SOMAP-after-NotFound),
`tests/conformance/cef-somap/`, GAP-0322
**Depends on** ADR-0174 (`SOMAP.TXT` / `libdl.so.2`), ADR-0165 (32 FAT
faces / `plat-need5`), ADR-0144 (`dlopen`).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,286 UND. Does not raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0176 — 0175 is the display / QEMU viewer door. 0174 is
one-soname SOMAP (`cef-dl`). Do not reuse.
Syscall 11 stays `fdwait`. No new syscall — 29 is still `dlopen`.

---

## 1. The question

ADR-0174 PASSed real-named `libdl.so.2` via planted `SOMAP.TXT` and
left the other **31** official CEF `DT_NEEDED` Linux sonames as an
honest leftover. FAT 8.3 still cannot store those strings. What
binary proves the **same door** covers **all 32** sonames onto OUR
plat-need5 faces?

## 2. The decision

1. **Planted `SOMAP.TXT` grows to 32 lines.** One mapping per
   official CEF soname → OUR 8.3 face
   (`libdl.so.2=LIBDL.SO` … `ld-linux-x86-64.so.2=LIBLD.SO`).
   Faces reuse `plat-need5` plants. Not LFN. Not a hardcoded kernel
   invent of every soname.
2. **`elfDlopenNameMax = 64`.** `fileNameMax` stays 12 for FAT
   open/rename. `dlopen` alone accepts long Linux sonames (longest
   CEF name is 22). Syscall 29. 11 stays `fdwait`.
3. **SOMAP after accidental 8.3 parse.** `libnspr4.so` /
   `libnss3.so` parse as 8.3 but are not our faces. After a
   NotFound lookup, `elfDlopenSomapApply` still runs on the
   original caller string.
4. **Anti-vacuity.** Volume with all 32 faces but SOMAP missing
   `ld-linux-x86-64.so.2=LIBLD.SO` → first 31 succeed; that name is
   NotFound; no `LINE32`. Mapping alone without the face still
   refuses (ADR-0174 held).
5. **Harness `cef-somap/`.** `PLAT.ELF` carries all 32 real Linux
   `DT_NEEDED` strings, walks `_DYNAMIC`, `dlopen`s each, calls the
   face, prints derived `LINE1`..`LINE32`. `ASK.ELF` is still
   `ELF REFUSED 11`.
6. **Counts held.** UND remains **50 / 1,336** (1,286 remain).
   Satisfies **32 of 32** CEF `DT_NEEDED` under real Linux sonames.
   Content `OnPaint` stays leftover. Graphite / Venus / cef-dl /
   cef-und2 floors held.

## 3. What this is not

It is not FAT LFN. It is not glibc. It is not binding every UND.
It is not OnPaint. It is not raising `de-browse` floor 87.

## 4. What remains (GAP-0322 leftovers)

Rest of **1,286** UND, then Content `OnPaint`.

## 5. Verification

`core/tests/conformance/cef-somap/run.sh` — `PLAT.ELF` dlopens all
32 real CEF sonames; kernel aliases each via `SOMAP.TXT` onto
`LIB*.SO`; derived `LINE1`..`LINE32`; miss-alias refuses
`ld-linux`; `ASK.ELF` is BadArg / REFUSED 11; cef-dl / cef-und2 /
plat-need5 floors held.
