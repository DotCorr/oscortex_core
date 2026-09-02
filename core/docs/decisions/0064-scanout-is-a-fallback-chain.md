# ADR-0064 — Scanout is one fallback chain: GOP, then Bochs, then NONE

**Status:** accepted, implemented, verified (`tests/conformance/p3-fallback/run.sh`;
`p2-gop/run.sh` two-path split unchanged)
**Date:** 2026-08-30
**Milestone:** portable scanout fallback (`docs/design/portable-hardware.md` §4, §7)
**Files:** `core/kernel/gop.dart` (`gopTry` claims GOP only after a successful
map; `gopTagAddr`), `core/kernel/fb.dart` (`shellFb` chain; `fbGeom*` only
trusts GOP geometry when the live base is the GOP aperture),
`core/tests/conformance/p3-fallback/run.sh`
**Does not close** GAP-0001 on real hardware. Does not write amdgpu/i915/nouveau.
Does not add USB HID, NVMe, or a BIOS-MBR path.
**Number:** 0064 — 0061 mapped the GOP aperture; 0062 is keyboard focus
(D9); 0063 is N1's frame. This is the probe that
refuses to hang or page-fault when that aperture is missing or unmappable.

---

## 1. The question

PORT1 and PORT2 (ADR-0060, ADR-0061) proved two boots of one `kernel.elf`:
OVMF+Limine prints `FB GOP …` and paints; `-kernel` prints `FB BAR …` and
paints Bochs. Those were separate *commands* in the sense that each boot
had exactly one working backend. A machine with a GOP tag the kernel
cannot map — or with neither GOP nor Bochs — still has VGA text and COM1.
The owner ask is one kernel on the most machines without a vendor GPU
driver. That is a fallback chain, not a second binary.

ADR-0061's `gopTry` printed `FB GOP` and returned 1 whenever the tag
looked valid, even if `gopMap` refused the range. The paint was skipped,
so that path did not fault — but it also never fell through to Bochs.
A later store through `fbState` (or a compositor clip that trusted GOP
geometry while the live base was still zero / a BAR) is how that becomes
a `#PF`. The rule is: a GOP tag that cannot be mapped is not GOP.

## 2. The decision

1. **One probe order, on `fb`, never at boot.** `fbInit` still only
   zeroes the 32-byte state block. Printing a winner at `kmain` would
   move the m0/m1 serial goldens. The `fb` command is the printer:
   `FB GOP …` / `FB BAR …` / `FB NONE` (existing `fbStrNoDev` line,
   which already begins `FB NONE`). VGA text and COM1 are not a fourth
   linear backend; they remain when the chain ends at NONE.
2. **`gopTry` returns 1 only after `gopMap` writes (or confirms) leaves.**
   Tag present, geometry sane, type RGB — and then the map. Map returns
   0 → return 0, print nothing, leave `fbState` at zero. `shellFb` takes
   Bochs or NONE. No store to the named address. No `#PF`.
3. **GOP geometry is the live aperture, not the leftover tag.**
   `fbGeomWidth` / `fbGeomHeight` compare `fbState(base)` to
   `gopTagAddr`. A Bochs win after a refused GOP tag keeps 800×600.
   No new `.bss`. `wmeventStore` stays last.
4. **No help line, no syscall, no amdgpu.** `shellStrHelp` stays 2511
   bytes. The chain is discovery, not a vendor driver.

## 3. Binary

`p3-fallback/run.sh`:

* **(a)** OVMF+Limine, no `-kernel`: `fb` prints `FB GOP` whose
  width×height equal the resolution the harness wrote into
  `limine.conf`. No `FB BAR`. No `FAULT` / `PF CR2`.
* **(b)** the same `kernel.elf` under `-kernel -vga std`: `FB BAR … MODE
  0320x0258x20 OK`. No `FB GOP`.
* **(c)** `-kernel -vga none`: no GOP tag, no VGA-class BAR. `fb` prints
  `FB NONE`. Serial still has `OSCORTEX M0 OK` and a prompt after `fb`.
  No `FAULT` / `PF CR2`.

Anti-vacuity is the three-way split: the same image must not print the
same winner on (a) and (b), and (c) must be NONE rather than a silent
hang. Negative control for (a)/(b) is the existing `p2-gop` two-path
split, which this ADR must not move.

## 4. What this is not

Not a Ryzen laptop boot. Not USB HID. Not NVMe. Not AHCI. Not amdgpu.
Not a BIOS-MBR path. Metal still has no harness; COM1 is the last-ditch
glass when GOP and Bochs are both absent.
