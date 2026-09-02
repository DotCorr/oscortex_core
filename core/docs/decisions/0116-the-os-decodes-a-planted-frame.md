# ADR-0116 — The running OS decodes a planted H.264 frame

**Status:** accepted, implemented, verified (`tests/conformance/de-media/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-media (`docs/design/c-modules.md`, `docs/design/de-media.md`)
**Files:** `core/plat/media/osmedia.c`, `osmedia_guest.c`, `osmedia_guest.h`,
`osmedia_snprintf.c`, `core/kernel/kmedia.dart`, `core/scripts/build-ffmpeg-guest.sh`,
`core/scripts/build-kernel.sh`, `core/link/kernel.ld`, `core/boot/isr.S`,
`core/tests/conformance/de-media/`
**Depends on** ADR-0103 (`osmedia.h` / MEDIA0 host module).
**Does not close** a `wmsurface` video window. Sit-in scanout blit is
ADR-0131 (`de-vblit/`). Serial PIX is the floor this slice proved.
**Number:** 0116 — 0114 is osgpu; 0115 is reserved.

---

## 1. The question

MEDIA0 linked brew FFmpeg on the Mac. Android calls the decoder from the
running system. Host `media0` is not done. `kernel.elf` is x86_64; a Mac
dylib is rejected. C can target the same triple the kernel already uses.

## 2. The decision

1. **Official FFmpeg is rebuilt for `x86_64-unknown-none-elf`.**
   `build-ffmpeg-guest.sh` configures H.264 + mov only (`libavcodec`,
   `libavformat`, `libavutil`). Not a Mac `.dylib`. `OSMEDIA_FFMPEG=0`
   omits those `.a` files; `nm` has no `avcodec_`.
2. **`osmedia.c` is compiled for that triple** (`OSMEDIA_GUEST`).
   `osmedia_open_mem` feeds a planted buffer through AVIO.
   `avformat_open_input` / `avcodec_send_packet` / `avcodec_receive_frame`
   stay. YUV420 becomes RGB in C (no `libswscale` on this link).
3. **Hidden `play` copies `CLIP.MP4` into `.osmedia_cmd`.**
   `kmedia.dart` has no `@bss` and no `@extern`. IRQ0
   `osmedia_guest_tick` decodes on a dedicated stack and prints
   `OSMEDIA PIX` / `OSMEDIA BACKEND ffmpeg`. Missing file sets MISS.
4. **No new syscall. No help line. 44 `@extern`s stay 44.**
   11 stays `fdwait`. `wmeventStore` stays last `.bss`.

## 3. What this is not

It is not a FRAME ELF stuffed with libavcodec. It is not sit-in video.
It is not a Mac harness PASS labeled as the OS. Compositor blit of the
decoded buffer is leftover.

## 4. Verification

`core/tests/conformance/de-media/run.sh` — `nm` of the kernel QEMU runs
shows `avcodec_` (and `osmedia_backend_ffmpeg`); `OSMEDIA_FFMPEG=0` does
not; planted `CLIP.MP4` + `play` derives FRAME; a volume without that
file is not FRAME.
