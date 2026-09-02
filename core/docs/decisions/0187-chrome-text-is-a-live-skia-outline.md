# ADR-0187 — Chrome text is a live Skia outline

**Status:** accepted, implemented (`osgfx_text` in `osgfx_skia.cpp`,
`osgfx_font.h` / `osgfx_font_data.c`, `core/scripts/gen-osgfx-font.py`,
harnesses `de-skia-text/run.sh` 35 checks + `de-skia-text/shot-venus.sh`
+ `de-session/` 60 checks)
**Date:** 2026-08-31
**Depends on** ADR-0110, ADR-0117, ADR-0153, ADR-0161, ADR-0183.
**Corrects** the belief that *CPU raster* AA `drawRRect(MakeRectXY)`
hangs on `-cpu qemu64`. It does not; the cause was our `sqrtf` (§2.1).
ADR-0161's own narrower finding — that **Graphite** `Recorder::snap` of
an AA rrect faults in freestanding AnalyticRRect SkSL — is untouched
here (§4).
**Closes** the 8x16 bitmap cell as the DE's text path.
**Number:** 0187. No new syscall. 11 stays `fdwait`. Two new mailbox
words (`tone0`, `tone1`) at offsets 104/112; `wmStore` unchanged.

---

## 1. Decision

1. **Chrome labels are real TrueType outlines, scan-converted live by
   Skia, in the OS.** `core/scripts/gen-osgfx-font.py` reads the `glyf`
   table of Roboto Regular/Medium at build time and emits each ASCII
   glyph's quadratic outline as move/line/quad/close verbs **in font
   units**, plus its real `hmtx` advance and the face's real vertical
   metrics, into `osgfx_font_data.c`. `osgfx_text` replays those verbs
   into an `SkPathBuilder` — one `SkPath` per run, not per glyph — and
   hands it to `SkCanvas::drawPath` with antialiasing on.

   **Say this precisely, because it is the thing most easily overstated.
   This is NOT baked Skia glyph masks and it is NOT live `SkFont`.**
   What is baked is the outline, which is what a `.ttf` is; the size is
   a caller argument and the rasterisation happens in the OS at paint
   time. There is no cell, no fixed advance, no pre-rendered coverage.
   What is absent is `SkTypeface` / `SkFont` / `SkTextBlob`: the
   guest-elf Skia is built `skia_use_freetype=false` and
   `skia_enable_fontmgr_empty=true`, so the image has no scaler context,
   no font manager and no TrueType parser. Shaping, hinting, kerning
   (GPOS) and subpixel positioning are therefore absent (GAP-0311).

2. **Chrome shapes are Skia draws.** `osgfx_fill_rrect`,
   `osgfx_fill_rrect_vgrad`, `osgfx_card`, `osgfx_card_stroke`,
   `osgfx_card_corners`, `osgfx_shadow` and `osgfx_elevate` all reach
   `SkCanvas::drawRRect` / `drawPath` with `setAntiAlias(true)`,
   `SkShaders::LinearGradient` and `SkMaskFilter::MakeBlur`. The
   `rrect_cover` span walker stays as the no-canvas fallback only.

3. **A window is one card, not four strips.** `osgfx_card_stroke` draws
   a single AA outline around the whole window; the title band is one
   top-rounded card with a vertical gradient. The four square border
   strips plus a stamped "sheen" rectangle inside a rounded band are
   gone — they could not follow the curve and notched every corner.

4. **The compositor tells chrome the client's edge tone.**
   `wmBlitRow` insets a client's blit by `wmGfxRadius` on the window's
   first and last rows, so the rounded corners are chrome's to paint.
   Chrome cannot sample them from the scanout, because within a frame
   the osgfx tick paints *before* the blit lands and a window mapped
   this frame has no previous frame at all. So `wmGfxEdgeTone`
   (`wmgfx.dart`) reads the client's own shm one pixel inside each
   corner and packs both into mailbox words `tone0` / `tone1`.

5. **`kOpaque_SkAlphaType`, not `kUnpremul`.** The scanout stores
   `0x00RRGGBB`, i.e. the alpha byte is always 0. Under `kUnpremul`
   every antialiased edge blended against a "fully transparent"
   destination, which is why AA never looked like AA on this surface.

6. **Soft coverage AA is not called Skia.** `osgfx_glyph.c` keeps its
   `osgfx-glyph-aa` door for the packed scanout label path, and the
   `osgfx-glyph-aa` token stays greppable, but nothing in the DE chrome
   text path goes through it.

## 2. Two root causes, both ours

### 2.1 `sqrtf` recursed into itself — the "qemu64 AA hang"

AA `drawRRect(MakeRectXY)` and AA path fills hung on `-cpu qemu64`, and
a previous attempt was reverted rather than diagnosed. The hang was not
a CPU feature, a shader compile or `SkOpts` dispatch.

`osgfx_guest_crt.c` defined `float sqrtf(float x) { return
__builtin_sqrtf(x); }`. Built with `-fno-builtin` and without
`-fno-math-errno`, the compiler must preserve `errno` semantics, so it
did **not** emit `sqrtss`: it lowered `__builtin_sqrtf` back to a call
to `sqrtf`, i.e. to a self-recursive jump. Any Skia path that measures a
curve — every AA rrect corner, every glyph outline — entered it and
never came back. It is now inline `sqrtss` / `sqrtsd`.

The verdict is on serial every boot: `OSGFX SKIA OPS OK 16` means all
sixteen probe ops completed, including the two ADR-0161 called
unreachable. The probe names the op it is entering, so a regression
prints an op, not a hang.

### 2.2 A Skia global cache outlived the bump heap

With curves working, a second elevated window `#GP`'d at
`RIP F000FF54F000FF53`. That address is not random: it is eight bytes
read from physical 0, i.e. two real-mode IVT entries, which is what a
virtual call through a garbage vptr looks like when low memory is
identity-mapped.

`SkMaskFilter::MakeBlur`'s raster path parks blurred rrect masks in the
global `SkResourceCache`, whose entries are bump-heap pointers.
`osgfx_heap_frame_begin` rewinds that bump pointer every tick, while the
global kept referring to the reclaimed bytes; the next lookup walked a
reused entry. `tick_body` now calls `SkGraphics::PurgeAllCaches()`
**before** the rewind, so no global holds a pointer below the watermark
when the bytes go back.

While chasing it, `paint_stack` was also given a canaried
`PAINT_GUARD` low band checked every tick, and the caller's RSP moved
from a `.bss` word to the top of `paint_stack` itself — parked in `.bss`
an overflow could zero it, and restoring `RSP = 0` produces exactly the
same IVT `ret`. Measured high-water is 13 KiB of 3 MiB
(`OSGFX PAINT STACK HI`).

## 3. Binary

`core/tests/conformance/de-skia-text` — 35 checks, PASS. It proves the
text claim from three independent sides:

- `outline.py` on the generated C: two faces, upem 2048, 95 glyphs,
  778 of ~1740 verbs are quadratics, advances span 346..1832 with
  `'W'` 1802 vs `'i'` 523. A cell font has one advance; a traced
  bitmap has no quadratics.
- `check-osgfx-font.py` re-rasterises the **generated C** (not the TTF)
  with its own non-Skia scanline filler. Two independent rasterisers
  agreeing is the point.
- In-OS: `OSGFX TEXT OUTLINE PROPORTIONAL` (`"Start"` at 14px is
  neither 40px nor 0), then `caption.py` on the framebuffer —
  `"FILES"` is 245 ink pixels in 111 shades, 180 of them at
  intermediate coverage, in a 37x11 box; `"Start"` is 30x11. Five
  glyphs on an 8x16 grid would be exactly 40x16 at one flat ink colour.

`core/tests/conformance/de-session` — 60 checks, PASS. Its two
assertions that could only be satisfied by stamps were replaced, and
the replacements are the stronger claim:

- the caption check counted pixels *exactly equal* to `0x00202830` and
  required 20 of them. It passed **because** the caption was an opaque
  bitmap blit. Now almost no pixel reaches full coverage, so it is
  `caption.py`: AA ramp, fringe mass, and off-grid metrics.
- the title check probed one pixel for `== 0x00E8E0D0`. The band is now
  one Skia gradient, so it is `derive.py title_gradient`: ends plus at
  least four shades travelled (measured: 27 over 32 rows).

`core/tests/conformance/de-skia-text/shot-venus.sh` — PASS. The same
chrome on the Venus / Graphite scanout, where the compose target is a
virtio-gpu resource backing rather than a Bochs aperture:
`VIRTIO VENUS OK`, `OSGFX GRAPHITE OK`, `OSGFX SESSION CHROME`,
`OSGFX SKIA OPS OK 16`, `OSGFX PAINT STACK HI 13 KIB`, two
`D3S COMMIT`s, no `WM REFUSE`, no `FAULT 0D`/`0E`.

Two things that path taught, both recorded rather than papered over:

- **It is 640x480, not the 1200x720 asked for.** `xres=`/`yres=` on
  `virtio-gpu-gl-pci` did not move what `GET_DISPLAY_INFO` reports
  (`VIRTIO SCAN … 00000280 000001E0`) on this command line, so a capture
  cannot assume the size it requested; `probe-run.py` now reads geometry
  from `VIRTIO SCAN`. This is not a claim about every launch — the
  door's `tigervnc-live-now.png` is 1280x720 with chrome reaching all
  four edges — and what differs between the two is open. GAP-0328.
- **`wm on` must come after `virtgpuk`.** `virtgpuv` arms Venus but
  publishes no scanout, so `wm on` first prints `FB NONE`, the
  compositor stays off, and every client is refused `wmRetOff`. Serial
  still shows `WM GFX ON` / `WM DE ON` / `OSGFX SESSION CHROME`, so a
  marker-only harness passes on a windowless screen — which is what
  `de-session`'s Venus block does. `shot-venus.sh` therefore counts
  `D3S COMMIT` and rejects `WM REFUSE`.

Screenshots the owner can open:

| path | what |
|---|---|
| `core/build/de-skia-text/de-skia-text.png` | 800x600, `-vga std`, the run.sh assertions' own framebuffer |
| `core/build/de-skia-text/zoom-title.png` | 4x crop of the `FILES` caption — the stem shapes and the corner arc |
| `core/build/de-skia-text/zoom-taskbar.png` | 4x crop of the Start pill and slots |
| `core/build/de-chrome-venus.png` | 640x480, Venus + Graphite armed |
| `core/build/de-skia-text/host-face-medium.png` | the outline table re-rasterised on the host by a non-Skia filler |

## 4. What is NOT claimed

- Not live `SkFont` / `SkTypeface` / `SkTextBlob` (§1.1). No shaping,
  hinting, kerning or subpixel positioning. (GAP-0327.)
- Graphite is still armed-and-noted, not the chrome rasteriser. Chrome
  AA is Skia **CPU** raster. ADR-0161's fault — Graphite
  `Recorder::snap` of an AA rrect entering freestanding AnalyticRRect
  SkSL — was **not retested** here and must be assumed to stand; the
  `sqrtf` fix is necessary for any Skia curve code but is not evidence
  about an SkSL→SPIR-V compile. The ADR-0161 ICD-radius stamp keeps its
  binary coverage and stays off live DE chrome.
- ASCII 0x20..0x7E only. One size pair (14px label, 15px title) and two
  weights.
- `osgfx_sw.c`, `osgfx_metal.m` and `osgfx_graphite.mm` do not
  implement `osgfx_text` / `osgfx_elevate` / `osgfx_card*`. They are not
  linked into `kernel.elf`; a host harness that links them and calls
  the session paint would fail to link.
- ADR-0183's direction is unchanged and unfinished: the DE strip is
  still painted by `osgfx_session.c` as a fallback rather than owned by
  `DESK.ELF` through `osxui`. `osxui_label` now routes to `osgfx_text`
  when it has an `OsGfx`, which is the door, not the move. And with
  `DESK.ELF` attached the two strips paint simultaneously — DESK's slot
  is hardcoded to the 800x600 bottom, so it floats mid-desk at any other
  size. That is visible in the owner's `tigervnc-live-now.png` and is
  now GAP-0329 with a three-step next move, the first of which is giving
  a FRAME client a way to ask for its screen rect at all.
