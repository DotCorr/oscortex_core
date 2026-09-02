# ADR-0174 — Real-named `libdl.so.2` resolves via planted SOMAP

**Status:** accepted, implemented, verified (`tests/conformance/cef-dl/run.sh`)
**Date:** 2026-08-31
**Milestone:** close the FAT 8.3 leftover after ADR-0172's UND×50
**Files:** `core/kernel/elf.dart` (`elfDlopenSomapApply`),
`tests/conformance/cef-dl/`, GAP-0322
**Depends on** ADR-0144 (`dlopen`), ADR-0160 (`dl_fn` / `LIBDL.SO`),
ADR-0172 (UND×50 floor held).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,286 UND. Does not resolve the other 31 CEF `DT_NEEDED` Linux
sonames. Does not raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0174 — 0173 is sit-in BROWSE/PLAY/TAP plant. 0172 is
Venus SPIR-V / CEF UND×50 (siblings). Do not reuse.
Syscall 11 stays `fdwait`. No new syscall — 29 is still `dlopen`.

---

## 1. The question

ADR-0172 PASSed **50 of 1,336** UND and left real-named
`libdl.so.2` as an honest leftover: FAT 8.3 cannot store that
string as a short directory name (`libdl.so.2` has two dots /
extension longer than three). Prior doors planted `LIBDL.SO` and
lied about the soname. What binary loads and binds the **real**
`DT_NEEDED` string `libdl.so.2` onto OUR libdl face?

## 2. The decision

1. **Planted mapping table `SOMAP.TXT`.** One line per mapping:
   `libdl.so.2=LIBDL.SO\n`. The table lives on the FAT volume as
   an 8.3 file. It is not LFN (LFN stays skipped). It is not a
   hardcoded kernel invent of every soname.
2. **`dlopen` of a non-8.3 name consults SOMAP.** When
   `fatParseAt` refuses the caller string, `elfDlopenSomapApply`
   opens `SOMAP.TXT`, finds an exact line-start match, parses the
   8.3 target into the name buffer, prints
   `PROC DLOPEN ALIAS <8.3>`, then the ordinary `fatLookup` /
   map / `dl_fn` path runs. Syscall 29. 11 stays `fdwait`.
3. **Anti-vacuity.**
   - Volume with `LIBDL.SO` but **no** `SOMAP.TXT` →
     `elfDlopenRetNotFound`. No `LINE`. No invented alias.
   - Volume with `SOMAP.TXT` but **no** `LIBDL.SO` → alias
     prints, then `NotFound`. No `LINE`.
4. **Harness `cef-dl/`.** `PLAT.ELF` carries `DT_NEEDED` of
   verbatim `libdl.so.2` (link `-soname=libdl.so.2`). It walks
   `_DYNAMIC`, `dlopen`s that string, calls `dl_fn`, prints
   derived `LINE`. `ASK.ELF` of the same bytes is still
   `ELF REFUSED 11`. Face bytes plant as FAT `LIBDL.SO`.
5. **Counts held.** UND remains **50 / 1,336** (1,286 remain).
   This door satisfies **1** CEF `DT_NEEDED` under its **real**
   Linux soname. The other **31** sonames and Content `OnPaint`
   stay leftover. Graphite / Venus / cef-und2 / cef-plt /
   cef-load floors held.

## 3. What this is not

It is not FAT LFN support. It is not glibc `libdl`. It is not
binding every UND. It is not the other 31 sonames. It is not
OnPaint. It is not raising `de-browse` floor 87.

## 4. What remains (GAP-0322 leftovers)

Rest of **1,286** UND, the other **31** CEF `DT_NEEDED` under
their Linux sonames (same SOMAP door can grow), then Content
`OnPaint`.

## 5. Verification

`core/tests/conformance/cef-dl/run.sh` — `PLAT.ELF` dlopens
`libdl.so.2`; kernel opens `SOMAP.TXT`, aliases to `LIBDL.SO`,
prints derived `LINE`; miss-map and miss-so refuse; `ASK.ELF` is
BadArg / REFUSED 11; cef-und2 / cef-plt / cef-load floors held.
