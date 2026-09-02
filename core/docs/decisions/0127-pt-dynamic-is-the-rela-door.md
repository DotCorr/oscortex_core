# ADR-0127 — A named platform ELF may carry PT_DYNAMIC; LD.SO applies RELA

**Status:** accepted, implemented, verified (`tests/conformance/plat-rel/run.sh`)
**Date:** 2026-08-30
**Milestone:** reloc door after ADR-0126
**Files:** `core/kernel/elf.dart`, `tests/conformance/plat-rel/`, GAP-0322
**Depends on** ADR-0126 (interp door), ADR-0124 (16 MiB platform window),
ADR-0014 (ELF loader), ADR-0019 (FAT names).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. Does not add glibc, `libc.so.6`, or a 189 MiB `.text` map.
**Number:** 0127 — 0126 is the interp door. 0125 is drawRRect.
Do not reuse 0126.

---

## 1. The question

ADR-0126 opened `PT_INTERP` for `PLAT.ELF` → our `LD.SO`. The
loader still refused `PT_DYNAMIC` by name (`ELF REFUSED 11`).
A relocated symbol cannot become the derived line if the
dynamic segment is illegal. The next binary is the **RELA
door**, not `libc.so.6` and not a pretend CEF `OnPaint`.

A TAP/FILES ELF that carries `PT_DYNAMIC` must stay 11.
`ASK.ELF` planted as the same bytes must stay 11. A platform
ELF without `PT_DYNAMIC` must still run as today (interp
then a static derived write).

## 2. The decision

1. **The flag is still the name.** `PLAT.ELF` is the only spawn
   that may honour `PT_DYNAMIC` (the same [elfInterpPermit]
   ADR-0126 used for `PT_INTERP`). `ASK.ELF` planted as the
   same bytes is `ELF REFUSED 11`. LBA spawn and every other
   8.3 name keep the refusal.
2. **The reloc is ours, in the file.** `PLAT.ELF` is a
   freestanding `ET_EXEC` this repo built. It carries
   `PT_INTERP` → `LD.SO` and a `PT_DYNAMIC` whose `DT_RELA`
   names one `R_X86_64_64` against a dynsym whose `st_value`
   is `SIG`. The target word is **0 in the file**. Not
   `libc.so.6`. Not a 32-`DT_NEEDED` walk.
3. **LD.SO applies RELA.** The interp walks the mapped dyn
   ELF's `PT_DYNAMIC`, writes `dynsym[1].st_value + addend`
   into `reloc_word`, prints `RELA OK`, and jumps to
   `e_entry`. The dyn program writes
   `DYN LINE` + hex(`reloc_word ^ MIX`). If the interp skips
   the reloc, the line is `MIX` alone and does not match.
4. **No-DYNAMIC still works.** A second `PLAT.ELF` with only
   `PT_INTERP` still prints `INTERP MAP` and a compile-time
   `NOD LINE`. That is today's interp door, not a refusal.
5. **No new syscall. No help line.** 11 stays `fdwait`.
   `elfImageMax` stays 65,536. TAP/FILES stay 64 KiB / 2 MiB.
   `wmeventStore` stays last `.bss`. This is not a guest OS
   and not libc.

## 3. What this is not

It is not Content painting in QEMU. It is not `libc.so.6` or
the 32 `DT_NEEDED`. It is not a 189 MiB map. It is not
raising `de-browse` floor 87. It is not `mmap`. It is not
`ET_DYN`.

## 4. What remains (GAP-0322 leftovers)

The 32 `DT_NEEDED` libraries (or a static rebuild), POSIX the
1,336 UND symbols need (`mmap`/`clone`/`futex`/TLS/`dlopen`),
and a window that can hold 231 MiB `.text`. This decision is
the RELA door. It is not those rungs.

## 5. Verification

`core/tests/conformance/plat-rel/run.sh` — `PLAT.ELF` prints
`ELF INTERP LD      .SO`, `INTERP MAP`, `RELA OK`, then the
derived `DYN LINE` from `derive.py`. `ASK.ELF` is the same
bytes and prints `ELF REFUSED 11`. A volume whose `PLAT.ELF`
has no `PT_DYNAMIC` still prints `INTERP MAP` and `NOD LINE`.
`reloc_word` is 0 in the file. `elfImageMax` is still 65,536.
Syscall 11 is still `fdwait`. `de-browse/` stays at floor 87.
