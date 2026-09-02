# ADR-0061 — The GOP aperture is identity-mapped; a derived pixel is painted

**Status:** accepted, implemented, verified (`tests/conformance/p2-gop/run.sh`)
**Date:** 2026-08-30
**Milestone:** PORT2 paint (`docs/design/portable-hardware.md` §7)
**Files:** `core/kernel/gop.dart` (map + marker, still no `@bss`),
`core/kernel/fb.dart` (`fbGeomWidth` / `fbGeomHeight`),
`core/kernel/wm.dart` (scanout clips use those),
`core/tests/conformance/p2-gop/run.sh`
**Does not close** GAP-0001 on real hardware. Does not write amdgpu/i915/nouveau.
Does not add USB HID or NVMe.
**Number:** 0061 — 0060 is the UEFI+Limine probe; this is the map that probe
said was still a page fault.

---

## 1. The question

ADR-0060 printed `FB GOP 0400x0300 00001000 0000000080000000` under
OVMF+Limine. That physical address is outside `boot.S`'s 0–128 MiB identity
map and outside the 3–4 GiB PCI hole. A store was a page fault. PORT2's
criterion is a pixel, not a print.

## 2. The decision

1. **Map in `gop.dart`, not in `vm.dart` or `boot.S`.** The live tables
   already have `PDPT[0]` (low gigabyte) and `PDPT[3]` (PCI hole). A GOP
   at `0x80000000` needs `PDPT[2]`. Writing that slot from `gopTry` — and
   only when the Multiboot1 framebuffer tag is present — keeps every
   `-kernel` vm.dart golden still. Three page-table writes on the OVMF
   1024×768 case: one PDPT entry plus two 2 MiB leaves. The page directory
   is one `allocFrame`, not a donated `.bss` block. `wmeventStore` stays last.
2. **2 MiB present+writable+NX leaves, identity, GOP range only.** Same
   leaf style as the PCI hole. Already-mapped ranges (0–128 MiB, 3–4 GiB)
   are left alone. `PDPT[0]` and `PDPT[3]` are refused so this path cannot
   smash the tables m8-paging walks.
3. **`fbState` is the scanout.** After the map, base and pitch come from
   the tag the way Bochs fills them from BAR0 and `fbWidth * 4`. Width and
   height are re-read from the tag (`fbGeomWidth` / `fbGeomHeight`) rather
   than extending the 32-byte state block. The compositor's clips use those.
4. **One derived rectangle, not a banner.** A 16×16 at
   `(width-32, height-32)` in colour
   `((width>>4)<<16) | ((height>>4)<<8) | 0xA5`. The harness recomputes
   both from the resolution it wrote into `limine.conf`. The origin is
   outside the compiled-in 800×600 so a Bochs-sized fill cannot pass.
5. **No help line, no syscall, no `0x1CE`/`0x1CF`.** The two-path split
   stays: UEFI prints `FB GOP …` and paints; `-kernel` still prints
   `FB BAR … MODE 0320x0258x20 OK`.

## 3. Binary

`p2-gop/run.sh` keeps the PORT1/PORT2 serial split, then `pmemsave`s the
aperture the kernel printed and requires the derived colour at the derived
coordinate (and at the opposite corner of the 16×16), with a pixel just
outside the rectangle that must *not* match.

## 4. What this is not

Not a Ryzen laptop boot. Not USB HID. Not NVMe. Not AHCI. Not amdgpu.
OVMF+Limine can paint; metal is still unverified.
