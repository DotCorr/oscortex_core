# ADR-0084 — The framebuffer console runs on VirtIO-GPU

**Status:** accepted, implemented, verified (`tests/conformance/g5-virtgpu/run.sh`)
**Date:** 2026-08-30
**Milestone:** G5 (`docs/design/gpu.md` §5)
**Files:** `core/kernel/virtgpu.dart` (console walk, per-cell flush),
`core/kernel/fb.dart` (flush call after `fbDrawGlyph`),
`core/kernel/shell.dart` (`virtgpuc` / `virtgpue` dispatch),
`core/tests/conformance/g5-virtgpu/run.sh`
**Depends on** ADR-0079 (one pixel / SET_SCANOUT).
**Does not close** scrolling or double buffering (G6), or
`virtio-gpu-pci` without VGA (G7).
**Number:** 0084 — 0082 is Graphite; 0083 is Chromium Content. Do not
reuse 0074 or 0082 (parallel agents collided on 0082).

---

## 1. The question

G4 put one derived colour on host scanout. The framebuffer console
still wrote the Bochs BAR. After SET_SCANOUT, that BAR is no longer
what the host displays (VIRTIO §5.7.7). G5 is the move: glyphs land
in the resource backing store, and a flush takes them to the host.

## 2. The decision

1. **The console form is `virtgpuc`.** Bare `virtgpu` and
   `virtgpu <hex>` stay the G3 / G4 walks so g0–g4 keep their
   line counts. `virtgpuInit` stays a no-op. An absent device still
   prints `VIRTIO NONE`.
2. **`fb` is not this path.** ADR-0064 stays GOP → Bochs → `FB NONE`.
   G5 is an explicit command. `virtgpuCell` no-ops when
   `fbStateBase` is in the PCI hole (a BAR or GOP aperture).
3. **Drawing is untouched.** `fbDrawGlyph` / `fbPutPixel` still
   write a linear buffer. G5 points `fbStateBase` at the first
   backing frame and sets pitch from GET_DISPLAY_INFO. Backing
   frames must be contiguous so that linear address is honest;
   a hole prints `VIRTIO NOFRM`.
4. **One flush per glyph cell.** The 52-byte banner has 51 drawn
   cells (newline draws nothing). Each cell is
   `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of the 8×16 rect.
   The kernel prints `VIRTIO FLUSH` with that count.
5. **`virtgpue` omits the cell flush.** Backing pixels stay
   correct; `VIRTIO FLUSH` prints 0. That is the negative control:
   the count measures the device round trip, not the blit.
6. **No help line, no syscall, no `.bss`.** `shellStrHelp` stays
   2511 bytes. D7 still owns the last `@bss` block. Queue
   leftovers hold the flush-enable flag and the count. The tokens
   `RESOURCE_CREATE_2D`, `VIRTIO_GPU_CMD` and `queue_enable=` stay
   out of this file so g0–g3 remain green.

## 3. What this is not

It is not scrolling. It is not double buffering. It is not
`virtio-gpu-pci` without a VGA-class device. Those are G6 and G7.

## 4. Binary

`g5-virtgpu/run.sh`:

* boot `-vga none -device virtio-vga,xres=1008,yres=720`, type
  `virtgpuc`;
* require `VIRTIO BACK` in low RAM, `FRAMES` equal to
  `ceil(1008*720*4/4096)`, and `FLUSH` equal to 51;
* `xp` of the sixteen banner scanlines at that BACK address
  matches `fbFont8x16` from the built ELF (m5 form, not a PNG);
* `virtgpue` matches the same pixels and prints `FLUSH 0`;
* `fb` on the same device still prints `FB BAR … MODE 0320x0258x20 OK`;
* `-vga std` still prints `VIRTIO NONE`.

Anti-vacuity is a zero-foreground font, a flush count of zero on
the positive boot, and a mode that is none of 1280×800, 800×600,
1024×768, or G4's 1136×848. 1008×720 does not appear in
`virtgpu.dart`.
