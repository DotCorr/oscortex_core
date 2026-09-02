# ADR-0168 — Full official libcef.so LOADs are mapped

**Status:** accepted, implemented, verified (`tests/conformance/cef-load/run.sh`)
**Date:** 2026-08-30
**Milestone:** full official RO+RX LOAD map after ADR-0167
**Files:** `core/scripts/pack-cef-loads.py`, `core/kernel/elf.dart`
(`elfDlopenMapPlant`, plant PA, RO/RX pins), `core/kernel/vm.dart` /
`heap.dart` (platform window = RO+RX span), `tests/conformance/cef-load/`,
GAP-0322
**Depends on** ADR-0167 (measured slice), ADR-0155 (189 MiB plat / 256 MiB
PMM), ADR-0144 (`dlopen`).
**Does not close** Content `OnPaint`. Does not bind real `libdl.so.2` /
`memset@plt`. Does not raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0168 — 0167 is the measured slice. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0167 PASSed a 12 KiB measured official `CEF.SO` slice and named the
leftover **full libcef LOADs**. Official linux64 `libcef.so` carries
LOAD R ≈ 42 MiB and LOAD R X ≈ 189 MiB. The full 1.5 GiB file cannot
sit on FAT (`fatChainMax` = 256 KiB). What binary maps those LOAD
`p_filesz` ranges honestly?

## 2. The decision

1. **Host-backed plant of RO+RX file bytes.**
   `pack-cef-loads.py` extracts the contiguous official file range
   covering LOAD R + LOAD R X (`p_filesz` 42593760 + 189117488 =
   231711248 bytes) from Spotify CEF linux64 `libcef.so`. QEMU
   `-device loader` plants it at PA `0x1000000`. Documented: not on
   FAT.
2. **Raise the platform window to the RO+RX VA span.**
   `vmPlatBytes` / `heapPlatMaxInc` = `0xDCFC000` (231718912). PMM /
   identity stay 256 MiB (ADR-0155). TAP/FILES stay 64 KiB / 2 MiB.
3. **`dlopen("CEF.SO")` on `PLAT.ELF` alias-maps the plant.**
   When the plant magic is present and the open name is `CEF.SO`,
   `elfDlopenMapPlant` walks official PHDRs, refuses sizes that are
   not the readelf pins, alias-maps plant PAs into the platform
   window, remaps RX to R+X, prints `CEF LOAD RO <filesz> RX
   <filesz>`, and returns `bias + cef_initialize`. FAT still holds a
   tiny ticket name (the ADR-0167 slice). ASK.ELF is BadArg.
4. **Anti-vacuity.** Harness requires RO/RX pins above the 12 KiB
   slice ceiling. A map of only the measured slice fails.
5. **Honest leftover.** Real `libdl.so.2` / `memset@plt` (1,336 UND)
   and Content `OnPaint` remain. Floor 87 stays. Graphite / Venus
   fenced.

## 3. What this is not

It is not Chromium Content painting. It is not glibc. It is not
raising `de-browse` floor 87. It is not putting 1.5 GiB on FAT.

## 4. What remains (GAP-0322 leftovers)

Bind real `DT_NEEDED` starting at `libdl.so.2` / remaining UND
after `memset@plt` (ADR-0169), then Content `OnPaint`.

## 5. Verification

`core/tests/conformance/cef-load/run.sh` — host plant loaded; `PLAT.ELF`
dlopens; kernel and userspace print official RO/RX sizes; PIXEL from
`cef_initialize`; ASK refused; cef-wire / browse-paint / de-browse
floors held.
