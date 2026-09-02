# ADR-0178 — High-traffic UND batch grows to one hundred through OUR libc

**Status:** accepted, implemented, verified (`tests/conformance/cef-und2/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow the measured CEF UND bind set past ADR-0172's fifty
**Files:** `core/kernel/elf.dart` (`elfCefUnd2BatchWant=100`,
`elfDlopenSymMax=128`, faces 50..99), `tests/conformance/cef-und2/`,
GAP-0322
**Depends on** ADR-0172 (fifty-face batch), ADR-0171 (twenty),
ADR-0170 (five), ADR-0169 (`memset@plt`), ADR-0168 (full LOADs),
ADR-0152 (tiny libc).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not raise `de-browse/` floor 87. Does not ship glibc.
Graphite / Venus fenced.
**Number:** 0178 — 0177 is OTA TLS 1.3 (sibling). 0172 is the fifty-face UND batch. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0172 PASSed **50 of 1,336** high-traffic UND and left **1,286**.
What binary grows the bound set to **≥100** (50+ new), measured from
the official PLT, through OUR libs, with unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT survey (same plant as
ADR-0168/0172). Fifty additional faces present in the PLT and
implementable as freestanding leaf bodies (no cross-calls; bodies
are copied by `st_size` into the face slab). Chosen stubs sit
**outside** the face slab at PLT idx ≥ 511 so trampolines are not
overwritten:

`floorf`, `ceilf`, `truncf`, `roundf`, `floor`, `ceil`, `trunc`,
`round`, `putchar`, `puts`, `srand`, `getppid`, `sleep`, `write`,
`read`, `abort`, `exit`, `_exit`, `unlink`, `rename`, `mkdir`,
`rmdir`, `access`, `chmod`, `fileno`, `feof`, `ferror`, `fflush`,
`gethostname`, `munmap`, `mprotect`, `alarm`, `pause`, `kill`,
`dup`, `dup2`, `pipe`, `getpriority`, `setpriority`, `sinf`,
`cosf`, `tanf`, `expf`, `logf`, `powf`, `fmodf`, `socket`,
`sysconf`, `hypotf`, `nearbyintf`.

Together with the ADR-0172 fifty: **100 of 1,336**. Remaining
**1,236**. `malloc` still absent. Content `OnPaint` stays leftover.

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` may export one hundred faces.** Bodies
   stay leaf (`-Os`; no cross-calls; math stubs are identity or
   zero; POSIX stubs return `-1` / `0`).
2. **LIBC RX stays within two pages.** `elfDlopenSymMax` rises to
   128. Face slab stays 4 KiB at PLT idx ≥ 511.
3. **Bind policy unchanged:** first five faces required (cef-plt /
   cef-und keep PASSing). Extras bind when present; missing an
   extra leaves that `@plt` unbound → `#PF` / no `LINE`. Harness
   builds `libc-miss.so` without `nearbyintf` (anti-vacuity).
4. **Kernel prints** `CEF UND BATCH <n>` with the actual bound
   count (`0000000000000064` when all one hundred land).
5. **Honest leftover.** Rest of 1,236 UND, then Content `OnPaint`.
   Floor 87 stays. Graphite / Venus fenced. cef-und / cef-plt /
   cef-load / cef-dl / cef-somap floors held (UND floor raised).

## 4. What this is not

It is not Chromium Content painting. It is not glibc. It is not
binding every UND. It is not raising `de-browse` floor 87.

## 5. What remains (GAP-0322 leftovers)

The remaining 1,236 UND, then Content `OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und2/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`; kernel opens `LIBC.SO`, prints `CEF UND BATCH 100`;
userspace calls through one hundred official PLT addresses and
prints derived `LINE`; `ASK.ELF` is BadArg; cef-und / cef-plt /
cef-load / cef-wire / browse-paint / de-browse floors held.
