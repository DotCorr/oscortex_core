# ADR-0171 — High-traffic UND batch grows to twenty through OUR libc

**Status:** accepted, implemented, verified (`tests/conformance/cef-und2/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow the measured CEF UND bind set past ADR-0170's five
**Files:** `core/kernel/elf.dart` (`elfCefUnd2BatchWant`, face slab at
PLT idx ≥ 511, optional extras), `tests/conformance/cef-und2/`,
GAP-0322
**Depends on** ADR-0170 (five-face batch), ADR-0169 (`memset@plt`),
ADR-0168 (full LOADs), ADR-0152 (tiny libc door).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not load real-named `libdl.so.2` as a linker face
(FAT is 8.3; `LIBDL.SO` / `dl_fn` stay the prior door). Does not
raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0171 — 0170 is the five-face batch. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0170 PASSed **5 of 1,336** high-traffic UND
(`memset`/`memcpy`/`memmove`/`strlen`/`memcmp`) and left **1,331**.
What binary grows the bound set to **≥20** (15+ new), measured from
the official PLT, through OUR libs, with unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT survey (same plant as
ADR-0168/0170). Fifteen additional faces present early in the PLT
and implementable as freestanding byte loops:

`bcmp`, `memchr`, `strncmp`, `strcpy`, `strcmp`, `strnlen`,
`strncpy`, `strchr`, `strrchr`, `strstr`, `strcat`, `strspn`,
`strcspn`, `strncat`, `strcasecmp`.

Together with the ADR-0170 five: **20 of 1,336**. Remaining
**1,316**. `malloc` still absent. `dlopen`/`dlsym`/`dlclose` stay
with the real-named `libdl.so.2` leftover.

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` may export twenty faces.** Bodies stay
   small (`-Os`, volatile loops; strncpy zero-fill is volatile so
   clang does not emit a SIMD memset).
2. **Face slab moves to unused PLT idx ≥ 511** (past `strncat@plt`),
   4 KiB — enough for twenty bodies without colliding trampoline
   slots. 12-byte `movabs rax,imm; jmp rax` trampolines unchanged.
3. **Bind policy:** the first five faces remain **required**
   (cef-plt / cef-und keep PASSing with the five-export `LIBC.SO`).
   Extras bind when present; missing an extra leaves that `@plt`
   unbound → userspace `#PF` / no `LINE` (anti-vacuity). Harness
   also builds a `libc-miss.so` without `strcasecmp` to prove the
   export gap is observable.
4. **Kernel prints** `CEF UND BATCH <n>` with the actual bound
   count (`0000000000000014` when all twenty land).
5. **Honest leftover.** Rest of 1,316 UND, real-named `libdl.so.2`,
   and Content `OnPaint`. Floor 87 stays. Graphite / Venus fenced.
   cef-und / cef-plt / cef-load floors held.

## 4. What this is not

It is not Chromium Content painting. It is not glibc. It is not
binding every UND. It is not real `libdl.so.2`. It is not raising
`de-browse` floor 87.

## 5. What remains (GAP-0322 leftovers)

Real-named `libdl.so.2` (and the other 31 `DT_NEEDED` faces under
their Linux sonames), the remaining 1,316 UND, then Content
`OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und2/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`; kernel opens `LIBC.SO`, prints `CEF UND BATCH 20`;
userspace calls through twenty official PLT addresses and prints
derived `LINE`; `ASK.ELF` is BadArg; cef-und / cef-plt / cef-load /
cef-wire / browse-paint / de-browse floors held.
