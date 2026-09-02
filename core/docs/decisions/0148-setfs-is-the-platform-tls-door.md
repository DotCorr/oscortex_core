# ADR-0148 — A named platform process may plant FS.base (TLS door)

**Status:** accepted, implemented, verified (`tests/conformance/plat-tls/run.sh`)
**Date:** 2026-08-30
**Milestone:** TLS door after ADR-0146
**Files:** `core/kernel/proc.dart`, `user.dart`, `core/boot/isr.S`
(`msr_write`), `docs/syscall-registry.md`, `tests/conformance/plat-tls/`,
GAP-0322
**Depends on** ADR-0124 (16 MiB platform window), ADR-0146 (futex /
BLOCKED — unrelated, but the platform name flag is the same).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc or the 32 `DT_NEEDED`.
**Number:** 0148 — 0147 is unlink/rename. 0146 is futex.
Do not reuse 0146 or 0147. Syscall 11 stays `fdwait`.
31/32 stay `unlink`/`rename`.

---

## 1. The question

ADR-0146 opened `futex` for `PLAT.ELF`. Official `libcef.so`
still cannot run: 1,336 UND symbols include TLS/`errno` through
`%fs`. `boot.S` writes EFER and nothing else — there is no
`FS.base` write, no `wrfsbase`, no `arch_prctl`. A `%fs:0`
access uses whatever the CPU left, usually 0, and faults.
The next binary is a **TLS door** for that name — plant
`IA32_FS_BASE` so a derived `%fs:` read/write works. Not Linux
`arch_prctl`, not glibc, and not a pretend CEF `OnPaint`.

A fake success that leaves the MSR at 0 cannot hand the program
a live TLS block: the store faults at VA 0 and the derived
line never prints.

## 2. The decision

1. **Syscall 33 is `setfs(base)`.** Plants `procSlotFsBase` and
   writes MSR `0xC0000100` (`IA32_FS_BASE`) via a narrow
   `msr_write` stub in `isr.S`. 11 stays `fdwait`. 21 and 22
   stay reserved on other lines. 30 is `futex`, 31/32 are
   `unlink`/`rename`. No `oslibc.h` name — a libc
   `arch_prctl()` would be Linux's.
2. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour it. `ASK.ELF` planted as the same bytes is
   `setfsRetBadArg`. LBA spawn and every other 8.3 name keep
   the refusal. `base` must be an 8-byte-aligned user-owned
   word (`elfOwns`).
3. **Every enter/switch installs the slot's base.**
   `procStart`, `procResume`, and `procSwitchTo` call
   `procInstallFs` after CR3/FPU. A clone starts with FS.base
   0 — the child must call `setfs` itself.
4. **No help line.** TAP/FILES stay 64 KiB / 2 MiB. `elfImageMax`
   stays 65,536. `wmeventStore` stays last `.bss`. This is not a
   guest OS and not glibc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or
the 32 `DT_NEEDED`. It is not a 189 MiB map. It is not raising
`de-browse` floor 87. It is not Linux `arch_prctl` (no
`ARCH_SET_GS`, no get). It is not `PT_TLS` relocation. It is
not `fdwait`. `drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

The 32 `DT_NEEDED` libraries (or a static rebuild), POSIX the
1,336 UND symbols still need (libc), and a window that can hold
231 MiB `.text`. This decision is the TLS door. It is not those
rungs.

## 5. Verification

`core/tests/conformance/plat-tls/run.sh` — `PLAT.ELF` calls
`setfs` on a local block, stores SIG at `%fs:0`, loads it back,
and writes `TLS` with `SIG ^ MIX`. Kernel prints
`PROC SETFS … ADDR …`. `ASK.ELF` is the same bytes and prints
`ERR FFFFFFFFFFFFFFFE`. Without the MSR write the store faults
and the derived line is missing. `elfImageMax` is still 65,536.
Syscall 11 is still `fdwait`. `de-browse/` stays at floor 87.
