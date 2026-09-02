# ADR-0179 — High-traffic UND batch grows to two hundred through OUR libc

**Status:** accepted, implemented, verified (`tests/conformance/cef-und2/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow the measured CEF UND bind set past ADR-0178's one hundred
**Files:** `core/kernel/elf.dart` (`elfCefUnd2BatchWant=200`,
`elfDlopenSymMax=256`, three-page LIBC RX copy, faces 100..199),
`tests/conformance/cef-und2/`, GAP-0322
**Depends on** ADR-0178 (hundred-face batch), ADR-0172 (fifty),
ADR-0171 (twenty), ADR-0170 (five), ADR-0169 (`memset@plt`),
ADR-0168 (full LOADs), ADR-0152 (tiny libc).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not raise `de-browse/` floor 87. Does not ship glibc.
Graphite / Venus fenced.
**Number:** 0179 — 0178 is the hundred-face UND batch. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0178 PASSed **100 of 1,336** high-traffic UND and left **1,236**.
What binary grows the bound set to **≥200** (100+ new), measured from
the official PLT, through OUR libs, with unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT survey (same plant as
ADR-0168/0178). One hundred additional faces present in the PLT and
implementable as freestanding leaf bodies (no cross-calls; bodies
are copied by `st_size` into the face slab). Chosen stubs sit
**outside** the face slab at PLT idx ≥ 511 so trampolines are not
overwritten:

`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `exp`, `log`,
`exp2`, `log2`, `pow`, `hypot`, `sinh`, `cosh`, `tanh`, `asinf`,
`acosf`, `atanf`, `atan2f`, `sinhf`, `coshf`, `tanhf`, `exp2f`,
`log2f`, `log10`, `log10f`, `rint`, `rintf`, `nearbyint`, `fma`,
`fmaf`, `modf`, `modff`, `frexp`, `frexpf`, `ldexp`, `ldexpf`,
`cbrt`, `cbrtf`, `nextafter`, `nextafterf`, `acosh`, `acoshf`,
`asinh`, `asinhf`, `atanh`, `atanhf`, `scalbn`, `remainder`,
`ilogbf`, `erf`, `erff`, `log1p`, `expm1f`, `fread`, `fwrite`,
`fseek`, `ftell`, `fgets`, `fclose`, `fputs`, `printf`, `snprintf`,
`vsnprintf`, `fprintf`, `sprintf`, `fputc`, `getc`, `ungetc`,
`setvbuf`, `rewind`, `setbuf`, `sigaction`, `raise`, `nanosleep`,
`clock_gettime`, `signal`, `strerror`, `strerror_r`, `uname`,
`opendir`, `closedir`, `madvise`, `tzset`, `fork`, `chdir`, `poll`,
`qsort`, `bind`, `listen`, `shutdown`, `connect`, `accept`,
`writev`, `setsockopt`, `getsockopt`, `gmtime`, `gmtime_r`,
`mktime`.

Together with the ADR-0178 hundred: **200 of 1,336**. Remaining
**1,136**. `malloc` still absent. Content `OnPaint` stays leftover.

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` may export two hundred faces.** Bodies
   stay leaf (`-Os`; no cross-calls; math stubs return zero; POSIX
   stubs return `-1` / `0` / NULL).
2. **LIBC RX may span three pages.** Kernel copies page0..page2;
   metadata may occupy page0+page1 (≤8 KiB); body bytes are read by
   file offset across the trio. `elfDlopenSymMax` rises to 256.
   Face slab stays 4 KiB at PLT idx ≥ 511.
3. **Bind policy unchanged:** first five faces required (cef-plt /
   cef-und keep PASSing). Extras bind when present; missing an
   extra leaves that `@plt` unbound → `#PF` / no `LINE`. Harness
   builds `libc-miss.so` without `mktime` (anti-vacuity).
4. **Kernel prints** `CEF UND BATCH <n>` with the actual bound
   count (`00000000000000C8` when all two hundred land).
5. **Honest leftover.** Rest of 1,136 UND, then Content `OnPaint`.
   Floor 87 stays. Graphite / Venus fenced. cef-und / cef-plt /
   cef-load / cef-dl / cef-somap floors held (UND floor raised).

## 4. What this is not

It is not Chromium Content painting. It is not glibc. It is not
binding every UND. It is not raising `de-browse` floor 87.

## 5. What remains (GAP-0322 leftovers)

The remaining 1,136 UND, then Content `OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und2/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`; kernel opens `LIBC.SO`, prints `CEF UND BATCH 200`;
userspace calls through two hundred official PLT addresses and
prints derived `LINE`; `ASK.ELF` is BadArg; cef-und / cef-plt /
cef-load / cef-wire / browse-paint / de-browse floors held.
