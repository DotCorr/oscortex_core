# DE-media — FFmpeg in the running OS

**Status: DESIGN.** ADR-0116 is the decision. Harness `tests/conformance/de-media/`.

## TODAY

`kernel.elf` links official FFmpeg built for `x86_64-unknown-none-elf`
(`libavcodec` / `libavformat` / `libavutil`, H.264 + mov). Hidden `play`
copies a planted `CLIP.MP4` into `.osmedia_cmd`. IRQ0
`osmedia_guest_tick` calls `osmedia_open_mem` / `osmedia_decode_frame` /
`osmedia_pixel` and prints `OSMEDIA PIX` on serial. After a live `fb`,
`fbBlitArgb` stores the 64×64 RGB tile on the sit-in scanout at
(16, 400) (ADR-0131, `de-vblit/`). After a live `wm`, `wmMediaFill`
commits the same bytes through a shm-backed window at (200, 80)
(ADR-0135, `de-vwin/`). `PLAY.ELF` attaches that surface; Start of
that name kicks `play`. `OSMEDIA_NO_BLIT=1` still prints PIX
and the tile is not FRAME. `OSMEDIA_NO_WIN=1` still blits the raw
tile; the window body is not FRAME. A missing file is `OSMEDIA MISS`
and is not FRAME. `OSMEDIA_FFMPEG=0` is the decode anti-vacuity link.

Host `media0/` still exists. It is a Mac program. It is not this rung.

## NEXT

A movie (more than one still) is ADR-0143 (`de-movie/`). Graphite /
Venus paint of the same buffer. Guest annex-B decode. Not a decode
syscall.

## Not

* A Mac dylib copied into `core/plat/`.
* A Graphite / osgfx Skia paint of the tile.
* Help-line goldens, last `.bss` theft, a decode syscall.
