# ADR-0170 — High-traffic UND batch binds OUR libc faces

**Status:** accepted, implemented, verified (`tests/conformance/cef-und/run.sh`)
**Date:** 2026-08-31
**Milestone:** first measured CEF UND *batch* after ADR-0169's single
`memset@plt`
**Files:** `core/kernel/elf.dart` (`elfCefWritePltTrampoline`,
`elfCefPlaceLibcMemset` batch, face slab), `tests/conformance/cef-und/`,
GAP-0322
**Depends on** ADR-0169 (`memset@plt`), ADR-0168 (full LOADs),
ADR-0152 (tiny libc door), ADR-0144 (`dlopen`).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not load real-named `libdl.so.2` as a linker face.
Does not raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0170 — 0169 is memset@plt (and ota-tls13 twin). Do not
reuse. Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0169 PASSed one official PLT bind (`memset@plt` → OUR
`LIBC.SO` `memset`) and left **1,336 UND** plus real `libdl.so.2`.
What binary binds a *batch* of the high-traffic UND the official
libcef PLT actually names first (measured), through OUR libs, with
unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT / dynsym UND survey:

| Face | In PLT? | Notes |
|---|---|---|
| `strlen` | yes (early) | idx 3 |
| `memcmp` | yes | idx 7 |
| `memcpy` | yes | idx 1316 |
| `memset` | yes | idx 1343 (ADR-0169) |
| `memmove` | yes | idx 1344 |
| `malloc` / `free` / `calloc` | **no** | Chromium allocator — absent |
| `dlopen` / `dlsym` / `dlclose` | yes | leftover with `libdl.so.2` |

Batch for this door: **memset, memcpy, memmove, strlen, memcmp**
(5 of 1,336). Remaining **1,331**.

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` exports the five faces.** Same freestanding
   byte loops as ADR-0169's `memset`.
2. **On `dlopen("CEF.SO")` plant map, open `LIBC.SO`, copy bodies into
   an RX face slab** planted over unused early PLT slots (idx ≥ 8,
   256 bytes), and write a 12-byte `movabs rax,imm; jmp rax`
   trampoline at each official `@plt`. No spill into the neighbour
   slot (fixes the ADR-0169 body-over-two-slots clash with
   `memmove@plt`).
3. **Userspace calls through all five official PLT VAs.** Derived
   `LINE` folds memmove-buffer ^ strlen ^ batch. Unbound stub still
   `jmp *GOT` into unmapped VA → `#PF` → no `LINE` (anti-vacuity).
   Missing any export refuses the plant bind.
4. **Kernel prints** `CEF PLT MEMSET <va>` (compat with cef-plt/) and
   `CEF UND BATCH 0000000000000005`.
5. **Honest leftover.** Rest of 1,331 UND, real-named `libdl.so.2`
   face, and Content `OnPaint` remain. Floor 87 stays. Graphite /
   Venus fenced. TAP/FILES stay 64 KiB / 2 MiB. cef-plt / cef-load /
   cef-wire / browse-paint floors held.

## 4. What this is not

It is not Chromium Content painting. It is not glibc. It is not
binding every UND. It is not real `libdl.so.2`. It is not raising
`de-browse` floor 87.

## 5. What remains (GAP-0322 leftovers)

Real-named `libdl.so.2` (and the other 31 `DT_NEEDED` faces under
their Linux sonames), the remaining 1,331 UND, then Content
`OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und/run.sh` — `PLAT.ELF` dlopens `CEF.SO`;
kernel opens `LIBC.SO`, prints `CEF UND BATCH 5`; userspace calls
through five official PLT addresses and prints derived `LINE`;
`ASK.ELF` is BadArg; cef-plt / cef-load / cef-wire / browse-paint /
de-browse floors held.
