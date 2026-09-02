# ADR-0103 — FFmpeg is the platform media module

**Status:** accepted, implemented, verified (`tests/conformance/media0/run.sh`)
**Date:** 2026-08-30
**Milestone:** MEDIA0 (`docs/design/c-modules.md`)
**Files:** `core/plat/media/osmedia.h`, `osmedia.c`, `osmedia_ffi.c`,
`osmedia.dart`, `headless_main.c`, `ffi_main.c`,
`core/scripts/build-osmedia.sh`,
`core/tests/conformance/media0/`
**Depends on** ADR-0080 (`osgfx.h` is a sibling module, not this one)
and ADR-0083 (`oschrome.h` is the same shape).
**Does not close** Graphite / Content / FFmpeg **in the running OS image**.
**Number:** 0103 — 0098 is virgl CLEAR+BLIT; 0099–0102 are reserved
for parallel rungs. This is FFmpeg behind `osmedia.h`.

---

## 1. The question

GFX0/GFX1 painted `osgfx.h`. BROWSER0 put Chromium Content behind
`oschrome.h`. MEDIA0 is the decoder the way Android has MediaCodec:
FFmpeg as a **platform** C module. Not an app ELF. Not Flutter. Not
in `kernel.elf` this slice. `exec-format.md` sized ffmpeg as an
app that would not fit the 64 KiB window. That was the wrong box.

## 2. The decision

1. **Link real FFmpeg** from brew / official (`libavcodec`,
   `libavformat`, `libavutil`; `libswscale` converts the decoded
   frame to RGB). A stub that only exports
   `osmedia_backend_ffmpeg` and fills a rect is a fail.
2. **`osmedia.h` is the C ABI** a later Studio / DCDart caller
   `@extern`s: `osmedia_init`, `osmedia_open`,
   `osmedia_decode_frame`, `osmedia_pixel` /
   `osmedia_readback` / `osmedia_ppm_write`,
   `osmedia_close`, `osmedia_backend_ffmpeg`,
   `osmedia_version`.
3. **`osmedia.c` calls `avformat_open_input`,
   `avcodec_send_packet`, `avcodec_receive_frame`.** The harness
   greps those names and requires `nm` `avcodec_` / `avformat_`.
4. **A planted H.264 clip** (lavfi solid `0xC04088`, not 0, not
   desktop `0x184060`) decodes to that colour. `--no-init` /
   `OSMEDIA_NO_FFMPEG=1` and `--missing` are the negatives:
   pixels are not FRAME. FFmpeg symbols stay in the image (`nm`).
5. **`osmedia.dart` `@extern`s `osmedia_ffi_*`** (u64 handles,
   GAP-0025 / GAP-0035). The C harness is the floor; DCDart is
   the sibling file.
6. **No syscall, no `.bss`, no `help` line, no kernel.elf link.**
   FRAME apps still do not contain libavcodec.

## 3. What this is not

It is not Flutter. It is not an app ELF. It is not in the
running OS image. The compositor does not play video yet. A later
DE blits a surface the decoder filled. It is not a "guest OS"
FFmpeg. It is a host platform module with a real address space
(Android `libstagefright` class).

## 4. Verification

`core/tests/conformance/media0/run.sh` — Mach-O arm64, `nm` has
`osmedia_backend_ffmpeg` and `avcodec_` / `avformat_`, default PPM
`BACKEND ffmpeg` and derived pixel is FRAME, `--no-init` and
`--missing` are `BACKEND none` and not FRAME, FFmpeg symbols remain.
