# ADR-0093 — Two resources, and SET_SCANOUT flips between them

**Status:** accepted, implemented, verified (`tests/conformance/g8-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G8 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (`virtgpuf` / `virtgpuy`, two
`RESOURCE_CREATE_2D` + attach, SET_SCANOUT swap),
`core/kernel/shell.dart` (hidden dispatch),
`core/tests/conformance/g8-virtgpu/run.sh`
**Depends on** ADR-0084 (G5 console on VirtIO) and ADR-0079
(SET_SCANOUT).
**Closes** GAP-0070 item 6 on the VirtIO console path. Bochs still
blits into the scanned-out BAR.
**Number:** 0093 — 0091 is G7; 0092 is nvm6. Do not reuse 0091.

---

## 1. The question

G4–G7 scan out one resource. Glyphs land in that backing, and a
flush takes them to the host. That is still single-buffered: the
host is scanning the same pages the console writes. G8 is the
move `gpu.md` §4.2 item 2 named: two resources, `SET_SCANOUT`
alternating between them. No VRAM arithmetic, no Y-offset.

## 2. The decision

1. **The flip form is `virtgpuf`.** `virtgpuc` / `virtgpue` stay
   G5. `virtgpus` / `virtgpux` stay G6. Bare `virtgpu` and
   `virtgpu <hex>` stay G3 / G4. `virtgpuInit` stays a no-op.
2. **Two guest-chosen ids, 1 and 2.** Each gets its own contiguous
   `allocFrame()` run and its own `RESOURCE_ATTACH_BACKING`. Both
   ids and both backing bases print (`VIRTIO RES`, `VIRTIO BACK`).
3. **Paint the back buffer, then flip.** Resource 1 is scanned out
   first. The banner is painted there. Resource 2 is filled and
   painted independently at the next glyph row — a memcpy of
   resource 1 cannot put those glyphs on row 1. Then
   `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of those cells, then
   `SET_SCANOUT` of resource 2. The kernel prints
   `VIRTIO FLIP 00000001 00000002`.
4. **`virtgpuy` paints both and never flips.** Scanout stays on
   resource 1. Both backings are still correct. The FLIP line
   must not print. That is the negative control: the line
   measures the second `SET_SCANOUT`, not the blit.
5. **`virtgpuRect` reads the leftover resource id.** G5 writes 1
   so cell flush is unchanged. G8 writes 2 before the second
   paint. A BAR / GOP base still no-ops (G5 contract).
6. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block. Queue
   leftovers hold the resource id, the helper's head/slot, the
   flush flag, the flush count, and the damage word.

## 3. What this is not

It is not amdgpu. It is not a Bochs scroll or a Bochs page-flip
via dispi Y-offset. sit-in / d2 goldens do not change. G5 cell
flush, G6 damage, and G7 `FB NONE` contracts are not rewritten.

## 4. Binary

`g8-virtgpu/run.sh`:

* boot `-vga none -device virtio-vga,xres=880,yres=656`, type
  `virtgpuf`;
* require two `VIRTIO RES` lines (`00000001` then `00000002`) and
  two distinct `VIRTIO BACK` addresses in low RAM;
* require `VIRTIO FLIP 00000001 00000002`;
* `xp` of the sixteen banner scanlines at the second BACK, offset
  one glyph row, matches `fbFont8x16` (m5 form, not a PNG);
* `virtgpuy` matches the same pixels on resource 2 and prints no
  FLIP line;
* `fb` on the same device still prints `FB BAR … MODE 0320x0258x20 OK`;
* `-vga std` still prints `VIRTIO NONE`.

Anti-vacuity is one BACK address, a FLIP of `1 1`, and a row-0
read-back of resource 2 (that would pass a memcpy of resource 1).
880×656 does not appear in `virtgpu.dart`.
