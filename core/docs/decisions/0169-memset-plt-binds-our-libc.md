# ADR-0169 — Official memset@plt binds OUR libc memset

**Status:** accepted, implemented, verified (`tests/conformance/cef-plt/run.sh`)
**Date:** 2026-08-30
**Milestone:** first official CEF PLT / UND bind after ADR-0168
**Files:** `core/kernel/elf.dart` (`elfCefPlaceLibcMemset`, `memset`
resolve), `core/kernel/proc.dart` (`procSlotCefMemset`),
`tests/conformance/cef-plt/`, GAP-0322
**Depends on** ADR-0168 (full LOADs), ADR-0152 (tiny libc door),
ADR-0144 (`dlopen`).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not load real-named `libdl.so.2` as a linker face.
Does not raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0169 — 0168 is full LOAD map (and ota-cert twin). Do not
reuse. Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0168 PASSed full official RO+RX LOAD alias maps and named the
leftover **real `libdl.so.2` / `memset@plt` (1,336 UND)**. Official
`cef_initialize` with non-null args reaches `memset@plt` then
faults: the GOT slot lives in the unmapped RW LOAD. What binary
binds at least that first PLT so a derived call through the
official CEF text's PLT address works?

## 2. The decision

1. **OUR tiny FAT `LIBC.SO` exports `memset`.** Same door shape as
   ADR-0152's `write`. Built at `-Os` so the body is ≤32 bytes.
2. **On `dlopen("CEF.SO")` plant map, open `LIBC.SO` and plant the
   body over official `memset@plt`.** The RO+RX span already fills
   `heapPlatMaxInc`; a second ET_DYN map cannot fit. The PLT stub
   (and the next 16-byte PLT entry) are overwritten with the libc
   body at plant PA. Mapped RX aliases those frames.
3. **Userspace calls through `bias + 0xdcfb1e0`.** Derived `LINE`
   is the fill signature `^ MIX`. Unbound stub still does
   `jmp *GOT` into unmapped VA → `#PF` → no `LINE` (anti-vacuity).
   Missing `LIBC.SO` refuses the plant bind.
4. **Honest leftover.** Rest of 1,336 UND, real `libdl.so.2` face,
   and Content `OnPaint` remain. Floor 87 stays. Graphite / Venus
   fenced. TAP/FILES stay 64 KiB / 2 MiB. cef-load / cef-wire /
   browse-paint floors held.

## 3. What this is not

It is not Chromium Content painting. It is not glibc. It is not
binding every UND. It is not raising `de-browse` floor 87.

## 4. What remains (GAP-0322 leftovers)

Real-named `libdl.so.2` (and the other 31 `DT_NEEDED`), the rest of
the 1,336 UND, then Content `OnPaint`.

## 5. Verification

`core/tests/conformance/cef-plt/run.sh` — `PLAT.ELF` dlopens `CEF.SO`;
kernel opens `LIBC.SO`, prints `CEF PLT MEMSET <va>`; userspace
calls through the official PLT address and prints derived `LINE`;
`ASK.ELF` is BadArg; cef-load / cef-wire / browse-paint / de-browse
floors held.
