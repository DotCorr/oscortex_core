# ADR-0172 — High-traffic UND batch grows to fifty through OUR libc

**Status:** accepted, implemented, verified (`tests/conformance/cef-und2/run.sh`)
**Date:** 2026-08-31
**Milestone:** grow the measured CEF UND bind set past ADR-0171's twenty
**Files:** `core/kernel/elf.dart` (`elfCefUnd2BatchWant=50`, two-page
LIBC RX copy, faces 20..49), `tests/conformance/cef-und2/`, GAP-0322
**Depends on** ADR-0171 (twenty-face batch), ADR-0170 (five-face batch),
ADR-0169 (`memset@plt`), ADR-0168 (full LOADs), ADR-0152 (tiny libc).
**Does not close** Content `OnPaint`. Does not bind the rest of
1,336 UND. Does not load real-named `libdl.so.2` as a linker face
(FAT is 8.3; `LIBDL.SO` / `dl_fn` stay the prior door). Does not
raise `de-browse/` floor 87. Does not ship glibc.
**Number:** 0172 — 0171 is the twenty-face batch. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0171 PASSed **20 of 1,336** high-traffic UND and left **1,316**.
What binary grows the bound set to **≥50** (30+ new), measured from
the official PLT, through OUR libs, with unbound → fail?

## 2. The measurement

Official linux64 `libcef.so` JUMP_SLOT survey (same plant as
ADR-0168/0171). Thirty additional faces present in the PLT and
implementable as freestanding leaf bodies (no cross-calls; bodies
are copied by `st_size` into the face slab):

`strncasecmp`, `wcsncmp`, `wcslen`, `wmemchr`, `wcscmp`, `wmemcmp`,
`wcschr`, `iswdigit`, `iswalnum`, `wcspbrk`, `wcscpy`, `towupper`,
`towlower`, `strtol`, `strtoul`, `strtoll`, `strtoull`,
`sched_yield`, `getpid`, `getpagesize`, `nanf`, `nan`, `getenv`,
`getauxval`, `time`, `usleep`, `getuid`, `isatty`, `rand`, `geteuid`.

Together with the ADR-0171 twenty: **50 of 1,336**. Remaining
**1,286**. `malloc` still absent. Real-named `libdl.so.2` stays
leftover (FAT 8.3 cannot plant that soname).

## 3. The decision

1. **OUR tiny FAT `LIBC.SO` may export fifty faces.** Bodies stay
   leaf (`-Os`; no cross-calls; `strto*` are base-10-only; `nan`/
   `nanf` use immediate bit patterns, not `.rodata`).
2. **LIBC RX may span two pages.** Kernel copies page0 + page1 into
   two scratch frames; metadata stays on page0; body bytes are read
   by file offset across the pair. `elfDlopenSymMax` rises to 64.
3. **Face slab stays at PLT idx ≥ 511** (4 KiB). Chosen PLT stubs
   all sit outside the slab so trampolines are not overwritten.
4. **Bind policy unchanged:** first five faces required (cef-plt /
   cef-und keep PASSing). Extras bind when present; missing an
   extra leaves that `@plt` unbound → `#PF` / no `LINE`. Harness
   builds `libc-miss.so` without `geteuid` (anti-vacuity).
5. **Kernel prints** `CEF UND BATCH <n>` with the actual bound
   count (`0000000000000032` when all fifty land).
6. **Honest leftover.** Rest of 1,286 UND, real-named `libdl.so.2`,
   and Content `OnPaint`. Floor 87 stays. Graphite / Venus fenced.
   cef-und / cef-plt / cef-load floors held.

## 4. What this is not

It is not Chromium Content painting. It is not glibc. It is not
binding every UND. It is not real `libdl.so.2`. It is not raising
`de-browse` floor 87.

## 5. What remains (GAP-0322 leftovers)

Real-named `libdl.so.2` (and the other 31 `DT_NEEDED` faces under
their Linux sonames), the remaining 1,286 UND, then Content
`OnPaint`.

## 6. Verification

`core/tests/conformance/cef-und2/run.sh` — `PLAT.ELF` dlopens
`CEF.SO`; kernel opens `LIBC.SO`, prints `CEF UND BATCH 50`;
userspace calls through fifty official PLT addresses and prints
derived `LINE`; `ASK.ELF` is BadArg; cef-und / cef-plt / cef-load /
cef-wire / browse-paint / de-browse floors held.
