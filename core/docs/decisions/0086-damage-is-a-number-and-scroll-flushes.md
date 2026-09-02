# ADR-0086 — Damage is a number, and console scroll flushes

**Status:** accepted, implemented, verified (`tests/conformance/g6-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G6 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (`virtgpuRect`, `virtgpus` /
`virtgpux`, leftover DAMAGE word), `core/kernel/fb.dart` (`fbScroll`
+ newline-past-last-row on VirtIO backing), `core/kernel/shell.dart`
(hidden dispatch), `core/tests/conformance/g6-virtgpu/run.sh`
**Depends on** ADR-0084 (G5 console on VirtIO).
**Does not close** `virtio-gpu-pci` without VGA (G7), or two-resource
double buffering. Those stay leftover.
**Number:** 0086 — 0082 is Graphite; 0083 is Chromium Content; 0084
is G5; 0085 is USB3. Do not reuse 0074 or 0082.

---

## 1. The question

G5 paints glyphs into VirtIO backing and issues one
`RESOURCE_FLUSH` per 8×16 cell. The printed count is always 51 for
the banner. The console still stops at the last row, and a guest
`memcpy` of the backing would not move host scanout. G6 is the
move: damage is a number that changes when more than one cell is
dirty, and a real scroll flushes the moved rectangle.

## 2. The decision

1. **The scroll form is `virtgpus`.** `virtgpuc` / `virtgpue` stay
   the G5 walks so g5 keeps one `FLUSH 51` line. Bare `virtgpu` and
   `virtgpu <hex>` stay G3 / G4. `virtgpuInit` stays a no-op.
2. **`virtgpuRect` is the flush.** `virtgpuCell` is the 8×16 form
   (G5 contract). A scroll issues `TRANSFER_TO_HOST_2D` +
   `RESOURCE_FLUSH` of `(0, 0, fbWidth, fbHeight - glyphHeight)`.
   The leftover word after the flush count is the last rectangle's
   pixel count, printed as `VIRTIO DAMAGE`.
3. **Scroll is VirtIO-only.** `fbScroll` no-ops when `fbStateBase`
   is in the PCI hole. The Bochs / GOP `fb` path still stops at the
   last row (GAP-0070 item 1). sit-in / d2 goldens do not grow a
   467,000-store scroll.
4. **`virtgpus` paints the banner twice, then scrolls.** After the
   first banner the kernel prints `FLUSH 51` and `DAMAGE 128`. After
   the scroll it prints `FLUSH 103` and `DAMAGE 00072000`
   (`800 × 584`). The second banner is now on row 0, so the G5
   glyph read-back still holds.
5. **`virtgpux` omits every flush.** Guest memcpy still puts the
   banner on row 0; `FLUSH` and `DAMAGE` stay 0. That is the
   negative control: the count measures the device round trip, not
   the blit.
6. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block. Queue leftovers
   hold the flag, the flush count, and the damage word.

## 3. What this is not

It is not two resources and a `SET_SCANOUT` flip. It is not
`virtio-gpu-pci` without a VGA-class device. Those are leftover
with G7. G5 cell-flush contracts are not rewritten.

## 4. Binary

`g6-virtgpu/run.sh`:

* boot `-vga none -device virtio-vga,xres=912,yres=688`, type
  `virtgpus`;
* require two `FLUSH` lines, `51` then `103`, and last `DAMAGE`
  equal to `800 × 584`;
* `xp` of the sixteen banner scanlines at `BACK` matches
  `fbFont8x16` (m5 form, not a PNG);
* `virtgpux` matches the same pixels and prints `FLUSH 0` /
  `DAMAGE 0` twice;
* `fb` on the same device still prints `FB BAR … MODE 0320x0258x20 OK`;
* `-vga std` still prints `VIRTIO NONE`.

Anti-vacuity is a post-scroll flush of 51, a damage of 0, a damage
of 51, and a full-frame `800 × 600` transfer. 912×688 does not
appear in `virtgpu.dart`.
