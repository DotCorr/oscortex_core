# ADR-0167 — Measured official libcef.so slice is the first load door

**Status:** accepted, implemented, verified (`tests/conformance/cef-wire/run.sh`)
**Date:** 2026-08-30
**Milestone:** first real wire of official `libcef.so` after ADR-0166
**Files:** `core/scripts/pack-cef-slice.py`, `core/kernel/elf.dart`
(`elfStrCefInit`, DYNAMIC ≤2 KiB, `cef_initialize` resolve),
`tests/conformance/cef-wire/`, GAP-0322
**Depends on** ADR-0122 (official extract), ADR-0123 (blocker measure),
ADR-0144 (`dlopen`), ADR-0155 (189 MiB plat window), ADR-0165
(32/32 stand-in NEEDED), ADR-0166 (OnPaint stand-in).
**Does not close** Content `OnPaint`. Does not map the full 1.5 GiB
`libcef.so`. Does not raise `de-browse/` floor 87. Does not ship
glibc.
**Number:** 0167 — 0166 is OnPaint stand-in. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0166 PASSed an OnPaint-shaped stand-in (`oschrome_on_paint`) and
named the leftover **wire official `libcef.so`**. Full Blink still
needs 189 MiB `.text`, 32 real `.so` faces, 1,336 UND, packs, and a
multi-process shape. What binary is the **first real door** that is
not a rename of the stand-in and not another `nm` of a 558-byte
extract linked into `BROWSE.ELF`?

## 2. The decision

1. **Pack a measured official slice as FAT `CEF.SO`.**
   `pack-cef-slice.py` reads Spotify CEF linux64 `libcef.so` and
   emits a ≤64 KiB `ET_DYN` whose:
   - 32 `DT_NEEDED` **names are verbatim** from official `.dynstr`
     (blob sha1 `36d038b5…`);
   - `.text` is the **558 official `cef_initialize` bytes** (sha1
     `82f0dac2…`, same pin as ADR-0122);
   - one `R_X86_64_64` carries an **addend equal to the first 8
     official text bytes**.
2. **`dlopen("CEF.SO")` on `PLAT.ELF` maps and resolves
   `cef_initialize`.** Syscall 29. ASK.ELF of the same bytes is
   BadArg. DYNAMIC size door raised to 2 KiB so 32 `DT_NEEDED` tags
   fit (old 512 refused the list).
3. **Userspace proves map / NEEDED / reloc.** `PLAT.ELF` walks the
   mapped `PT_DYNAMIC`, requires `NEED == 32`, folds official name
   bytes into `NHASH`, applies the RELA, and prints `PIXEL` /
   `RELOC` from the official text. A handwritten `xor %eax,%eax;ret`
   cannot match `PIXEL`.
4. **Honest leftover.** This is not OnPaint. Full `libcef.so` LOADs
   (~42 MiB RO + ~189 MiB RX), real `libdl.so.2`…`libc.so.6`, and the
   1,336 UND (first call site still `memset@plt`) remain. Floor 87
   stays. TAP/FILES stay 64 KiB / 2 MiB. Graphite / Venus fenced.

## 3. What this is not

It is not Chromium Content painting. It is not renaming
`oschrome_on_paint`. It is not linking the 558-byte extract into
`BROWSE.ELF` again (ADR-0122). It is not glibc. It is not raising
`de-browse` floor 87.

## 4. What remains (GAP-0322 leftovers)

Map the **full** official LOADs (FAT/PMM beyond a 12 KiB slice),
satisfy real `DT_NEEDED` (`libdl.so.2`, not `LIBDL.SO` stand-ins),
bind the 1,336 UND starting at `memset@plt` / `clone` / `dlopen`,
plant `*.pak` / ICU, then drive Content `OnPaint`.

## 5. Verification

`core/tests/conformance/cef-wire/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`, prints derived `PIXEL` / `NEED 32` / `NHASH` / `RELOC`;
`MISS.SO` is NotFound; `ASK.ELF` is BadArg; host checks official
sha1 pins; `de-browse` 87 and `browse-paint` 111 floors held.
