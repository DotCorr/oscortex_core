# ADR-0146 — A named platform process may futex-wait and wake on a word

**Status:** accepted, implemented, verified (`tests/conformance/plat-futex/run.sh`)
**Date:** 2026-08-30
**Milestone:** futex door after ADR-0144
**Files:** `core/kernel/proc.dart`, `user.dart`,
`docs/syscall-registry.md`, `tests/conformance/plat-futex/`,
GAP-0322
**Depends on** ADR-0130 (clone / shared page tables), ADR-0124
(16 MiB platform window).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc or TLS.
**Number:** 0146 — 0145 is VirtIO-net. 0144 is dlopen.
Do not reuse 0144 or 0145. Syscall 11 stays `fdwait`.

---

## 1. The question

ADR-0144 opened `dlopen` for `PLAT.ELF`. Official `libcef.so`
still cannot run: 1,336 UND symbols include `futex`. Two
clones already share page tables (ADR-0130). The next binary
is a **futex door** for that name — wait and wake on one word
so two clones can sync a derived line. Not Linux `futex`, not
TLS, and not a pretend CEF `OnPaint`.

A fake return that never blocks cannot hand the child the CPU
while the parent waits, so the parent's derived SYNC line
would stay the zero mix.

## 2. The decision

1. **Syscall 30 is `futex(op, addr, val)`.** Op 0 waits while
   `*addr == val`; op 1 wakes up to `val` waiters on `addr`.
   11 stays `fdwait`. 21 and 22 stay reserved on other lines.
   26 is `spawn`, 27 is `mmap`, 28 is `clone`, 29 is `dlopen`.
   No `oslibc.h` name — a libc `futex()` would be Linux's.
2. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour it. `ASK.ELF` planted as the same bytes is
   `futexRetBadArg`. LBA spawn and every other 8.3 name keep
   the refusal. `addr` must be an 8-byte-aligned user-owned
   word. Wait with no READY peer is `futexRetAlone`.
3. **BLOCKED is a fifth state.** `procSlotWaitAddr` (word 28)
   holds the VA. The process table is the wait queue
   (`blocking-and-threads.md` §1.3(b)). A wake scans four
   slots. Shared PML4 siblings match on VA.
4. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. `wmeventStore` stays last `.bss`. This is not a
   guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or
the 32 `DT_NEEDED`. It is not a 189 MiB map. It is not raising
`de-browse` floor 87. It is not Linux `futex` (no `FUTEX_*`
flags, no timeout). It is not TLS. It is not `fdwait`.
`drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The 32 `DT_NEEDED` libraries (or a static rebuild), POSIX the
1,336 UND symbols still need (TLS / libc), and a window that
can hold 231 MiB `.text`. This decision is the futex door. It
is not those rungs.

## 5. Verification

`core/tests/conformance/plat-futex/run.sh` — `PLAT.ELF` clones
a sibling, the parent `futex`-waits on a shared word, the child
stores the derived SIG and wakes, the parent writes `SYNC`
with `gate ^ MIX`. Kernel prints `PROC FUTEX WAIT` and
`PROC FUTEX WAKE`. `ASK.ELF` is the same bytes and prints
`ERR FFFFFFFFFFFFFFFE`. `elfImageMax` is still 65,536.
Syscall 11 is still `fdwait`. `de-browse/` stays at floor 87.
