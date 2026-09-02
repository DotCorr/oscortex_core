# ADR-0126 — A named platform ELF may name a FAT interp

**Status:** accepted, implemented, verified (`tests/conformance/plat-dyn/run.sh`)
**Date:** 2026-08-30
**Milestone:** interp door after ADR-0124
**Files:** `core/kernel/elf.dart`, `proc.dart`,
`tests/conformance/plat-dyn/`, GAP-0322
**Depends on** ADR-0124 (16 MiB platform window), ADR-0014 (ELF loader),
ADR-0019 (FAT names).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc, `PT_DYNAMIC`, `libc.so.6`, or a 189 MiB
`.text` map.
**Number:** 0126 — 0124 is the platform window. 0125 may be drawRRect.
Do not reuse 0124.

---

## 1. The question

ADR-0124 opened a 16 MiB `sbrk` window for `PLAT.ELF`. The loader
still refused `PT_INTERP` by name (`ELF REFUSED 11`). Official
`libcef.so` cannot run without an interpreter. The next binary is
the **interp door**, not `libc.so.6` and not a pretend CEF
`OnPaint`.

A TAP/FILES ELF that carries `PT_INTERP` must stay 11. A platform
ELF whose named interp is missing must stay 11 — not a silent
static run of the same bytes.

## 2. The decision

1. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour `PT_INTERP`. `ASK.ELF` planted as the same bytes
   is `ELF REFUSED 11`. LBA spawn and every other 8.3 name keep
   the refusal. `PT_DYNAMIC` is still 11 on every path.
2. **The interp is ours, on the FAT.** `PT_INTERP` names an 8.3
   file (`LD.SO`). That file is a freestanding ET_EXEC this repo
   built — not `ld-linux-x86-64.so.2`, not glibc. The kernel
   opens it, maps its `PT_LOAD`s in the 2 MiB window (linked at
   `0x10100000`), restores the program file, and maps the dyn
   ELF's `PT_LOAD`s at their own `p_vaddr`s (`0x10000000`).
3. **Enter the interp, jump to `e_entry`.** `elfMetaEntry` is the
   interp's entry. The dyn `e_entry` is parked in `elfMetaExit`
   and handed to ring 3 in `RDI` (the existing `procSlotProbe`
   channel). The interp writes `INTERP MAP` and jumps. The dyn
   program writes the derived line. A missing `LD.SO` returns 11
   before any program `PT_LOAD` is mapped.
4. **No new syscall. No help line.** 11 stays `fdwait`.
   `elfImageMax` stays 65,536. TAP/FILES stay 64 KiB / 2 MiB.
   `wmeventStore` stays last `.bss`. This is not a guest OS and
   not libc.

## 3. What this is not

It is not Content painting in QEMU. It is not `PT_DYNAMIC`.
It is not `libc.so.6` or the 32 `DT_NEEDED`. It is not a 189 MiB
map. It is not raising `de-browse` floor 87. It is not `mmap`.

## 4. What remains (GAP-0322 leftovers)

`PT_DYNAMIC`, the 32 `DT_NEEDED` libraries (or a static rebuild),
POSIX the 1,336 UND symbols need (`mmap`/`clone`/`futex`/TLS/
`dlopen`), and a window that can hold 231 MiB `.text`. This
decision is the interp door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-dyn/run.sh` — `PLAT.ELF` prints
`ELF INTERP LD      .SO`, `INTERP MAP`, then the derived
`DYN LINE` from `derive.py`. `ASK.ELF` is the same bytes and
prints `ELF REFUSED 11`. A volume with `PLAT.ELF` and no `LD.SO`
prints 11 and never `DYN START`. `elfImageMax` is still 65,536.
Syscall 11 is still `fdwait`. `de-browse/` stays at floor 87.
