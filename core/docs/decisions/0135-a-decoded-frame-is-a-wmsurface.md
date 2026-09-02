# ADR-0135 — A decoded frame is a wmsurface

**Status:** accepted, implemented, verified (`tests/conformance/de-vwin/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0316 leftover after ADR-0131 (raw Bochs tile)
**Files:** `core/kernel/kmedia.dart` (`wmMediaFill`),
`core/plat/media/osmedia_guest.c`, `osmedia.h`,
`core/kernel/wmde.dart` (Start `PLAY.ELF` kicks play),
`core/user/frame/play.c` (`PLAY.ELF`),
`core/tests/conformance/de-vwin/`
**Depends on** ADR-0131 (sit-in blit), ADR-0051 (surface protocol),
ADR-0116 (hidden `play`).
**Does not close** Graphite / osgfx video, a movie player beyond one
still, or a decode syscall.
**Number:** 0135 — 0134 is Venus. Do not reuse 0131.

---

## 1. The question

ADR-0131 planted a 64×64 FRAME tile on the Bochs scanout at (16, 400).
Sit-in Start still did not play. A raw MMIO store is not a window.
A host PPM is not the OS.

## 2. The decision

1. **After `osmedia_readback`, `wmMediaFill` copies the tile into a
   shm region and `wmComposeCommit`s it.** Geometry is
   `OSMEDIA_WIN_X/Y` (200, 80), 64×64. The compositor reads the frame
   vector (ADR-0051). No dest (`wm` off) skips — that is the
   no-attach miss.
2. **A live 64×64 client surface is preferred.** `PLAY.ELF`
   `shmcreate`s and `wmsurface` attaches at that geom. If none exists,
   the kernel creates the same records `wmAttach` would. IRQ0 retries
   the fill so a Start spawn that attaches after decode still lands.
3. **Start plays.** `wmDeSpawnRow` of 8.3 `PLAY.ELF` calls
   `shellMediaPlayDefault`. Hidden `play` is unmoved. `OSMEDIA_NO_WIN=1`
   still decodes and still blits the raw tile; the window body stays
   desktop. Missing `CLIP.MP4` is not FRAME.
4. **No new syscall. No help line. 44 `@extern`s stay 44.**
   11 stays `fdwait`. `wmeventStore` stays last `.bss`.
   `wmMediaFill` is `@bare`; C calls it by name. Not an `@extern`.
   Not libavcodec in a FRAME ELF.

## 3. What this is not

It is not Graphite video. It is not osgfx Skia. It is not a
second blit of the (16, 400) tile sampled as a window. Live chrome
paint is untouched.

## 4. Verification

`de-vwin/run.sh` — `OSMEDIA_NO_WIN=1` plus `PLAY.ELF` prints PIX and
BLIT; the window body at (216, 112) is not FRAME. The win kernel
after `fb` + `wm on` + `go PLAY.ELF` + `play` plants FRAME on that
body pixel and keeps the raw tile at (32, 416). Missing file is not
FRAME.

## 5. Leftover

A movie (more than one still). Graphite / Venus paint of the same
buffer. Not this file.
