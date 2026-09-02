# ADR-0180 — High-traffic UND batch grows to four hundred through OUR libc

**Status:** accepted, implemented, verified (`tests/conformance/cef-und2/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow the measured CEF UND bind set past ADR-0179's two hundred
**Files:** `core/kernel/elf.dart` (`elfCefUnd2BatchWant=400`,
`elfDlopenSymMax=512`, six-page LIBC RX copy, dual face slabs
(4976 B @ PLT idx ≥511 + 2048 B post-PLT @ `0xDCFA800`), split body caps
160/8 for batches 2/3),
`tests/conformance/cef-und2/`, GAP-0322
**Depends on** ADR-0179 (two-hundred-face batch), ADR-0178 (hundred),
ADR-0172 (fifty), ADR-0171 (twenty), ADR-0170 (five), ADR-0169 (`memset@plt`),
ADR-0168 (full LOADs), ADR-0152 (tiny libc).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not raise `de-browse/` floor 87. Does not ship glibc.
Graphite / Venus fenced.
**Number:** 0180 — 0179 is the two-hundred-face UND batch. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0179 PASSed **200 of 1,336** high-traffic UND and left **1,136**.
What binary grows the bound set to **≥400** (200+ new), measured from
the official PLT, through OUR libs, with unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT survey (same plant as
ADR-0168/0179). Two hundred additional POSIX / pthread / locale /
stdio leaf faces present in the PLT and implementable as freestanding
leaf bodies. Examples: `select`, `ioctl`, `strdup`, `strtod`, `strftime`, `fcntl`, `prctl`, `sigemptyset`, `sigfillset`, `sigaddset`, `sigdelset`, `sigprocmask`, `sigaltstack`, `sem_init`, `sem_wait`, `sem_post`, `sem_destroy`, `sem_timedwait`, `mmap64`, `open64`, … `__udivti3`.
Together with the ADR-0179 two hundred: **400 of 1,336**. Remaining
**936**. `malloc` still absent. Content `OnPaint` stays leftover.

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` may export four hundred faces.** Bodies
   stay leaf (`-Os`; no cross-calls).
2. **LIBC RX may span six pages.** Kernel copies page0..page5;
   `elfDlopenSymMax` rises to 512. Batch-2 bodies stay in the **4976 B**
   slab at PLT idx ≥511; batch-3 bodies land in a **2048 B** post-PLT
   slab at `0xDCFA800` (before `heapPlatMaxInc`). Batch 2 faces keep up
   to 160-byte bodies; batch 3 cap at 8 bytes (naked stubs).
3. **Bind policy unchanged:** first five faces required. Extras bind
   when present; missing an extra leaves that `@plt` unbound → `#PF` /
   no `LINE`. Harness builds `libc-miss.so` without `__udivti3`
   (anti-vacuity).
4. **Kernel prints** `CEF UND BATCH <n>` (`0000000000000190` when all
   four hundred land).
5. **Honest leftover.** Rest of 936 UND, then Content `OnPaint`.

## 4. What this is not

Not Chromium Content painting. Not glibc. Not binding every UND.
Not raising `de-browse` floor 87. Not Graphite / Venus.

## 5. What remains (GAP-0322 leftovers)

The remaining 936 UND, then Content `OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und2/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`; kernel opens `LIBC.SO`, prints `CEF UND BATCH 400`;
userspace calls through four hundred official PLT addresses and
prints derived `LINE`; floors held.
