# ADR-0131 — A decoded frame lands on the sit-in scanout

**Status:** accepted, implemented, verified (`tests/conformance/de-vblit/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0316 leftover after ADR-0116 (serial `OSMEDIA PIX`)
**Files:** `core/plat/media/osmedia_guest.c`, `osmedia.h`,
`core/kernel/fb.dart` (`fbBlitArgb`), `core/kernel/kmedia.dart`,
`core/scripts/build-kernel.sh`, `core/tests/conformance/de-vblit/`
**Depends on** ADR-0116 (hidden `play` decodes planted `CLIP.MP4`).
**Does not close** a `wmsurface` window that plays video, or sit-in
Start as a movie player.
**Number:** 0131 — 0130 is `clone`. Do not reuse 0130.

---

## 1. The question

ADR-0116 linked official FFmpeg into `kernel.elf` and printed a
derived serial pixel. Sit-in does not play video if those RGB
bytes never reach a scanout. A host PPM is not the OS.

## 2. The decision

1. **After `osmedia_decode_frame`, `osmedia_readback` copies the
   64×64 RGB tile and `fbBlitArgb` stores it on the live
   framebuffer** at `OSMEDIA_BLIT_X`, `OSMEDIA_BLIT_Y` (16, 400).
   The stores go through `fbPutPixel` (Volatile MMIO). No dest
   (`fb` not run) skips the stores — that is the skip-blit miss.
2. **Serial `OSMEDIA PIX` is not the floor.** The harness dumps
   the BAR the kernel printed and probes the tile. `OSMEDIA_NO_BLIT=1`
   still decodes and still prints PIX; the tile stays desktop/bg.
3. **No new syscall. No help line. 44 `@extern`s stay 44.**
   11 stays `fdwait`. `wmeventStore` stays last `.bss`.
   `fbBlitArgb` is `@bare`; C calls it by name. Not an `@extern`.

## 3. What this is not

It is not a FRAME ELF stuffed with libavcodec. It is not a
`wmsurface` commit of a client buffer. It is not Graphite / osgfx
Skia. Live chrome paint is untouched.

## 4. Verification

`de-vblit/run.sh` — `OSMEDIA_NO_BLIT=1` kernel prints PIX and the
tile is not FRAME; the blit kernel plants FRAME at (32, 416) on
the sit-in dump; missing `CLIP.MP4` is not FRAME on that pixel.

## 5. Leftover

~~A session / `wmsurface` path that commits the decoder buffer as
a window (ADR-0051). Sit-in Start does not play video.~~
**Closed by ADR-0135** (`de-vwin/`). Graphite video is a later rung.
