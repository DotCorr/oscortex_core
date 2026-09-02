# ADR-0153 — Chrome rrect is Graphite drawRRect

**Status:** accepted, implemented, leftover recorded (`tests/conformance/de-graphite3/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0313 leftover after ADR-0134 (MakeVulkan + clear PIX)
**Files:** `core/plat/osgfx/osgfx_graphite_guest.cpp`, `osgfx_vk.c`,
`osgfx_vk.h`, `osgfx_skia.cpp`, `osgfx.h`,
`core/tests/conformance/de-graphite3/`, known-gaps / c-modules
**Depends on** ADR-0134 (VkDevice / Venus arm / ICD). Does not
revert MakeVulkan or the clear PIX.
**Does not close** GAP-0313: Venus command stream still does not
encode SPIR-V to host lavapipe.
**Number:** 0153 — 0149 is FILES move. 0150 is shmgrow. 0151 is OTA
TCP. 0152 is plat-libc. 0148 is setfs. Do not reuse those.
Syscall 11 stays `fdwait`.

---

## 1. The question

ADR-0134 made `MakeVulkan` return a live context and stamped one
Graphite GPU **clear** (`PIX 00E24A18`). Sit-in chrome title bars
still went through CPU Skia `drawRect` spans. A clear PIX is not
Graphite chrome. Graphite is the OS renderer — chrome rrects must
go through Graphite `drawRRect`, and that pixel must not be a CPU
`drawRect` span.

## 2. The decision

1. **Graphite `drawRRect` for chrome.** When Venus arms and
   `MakeVulkan` is live, sit-in paints a title-bar-class rrect
   (and live `OSGFX_TITLE` fills) through
   `canvas->drawRRect` on a Graphite `RenderTarget`. Token
   `graphite-rrect-gpu`. Serial `OSGFX GRAPHITE RRECT 00C45A20`.
   Colour `0x00C45A20` is not `OSGFX_TITLE` / desktop — CPU
   spans cannot plant it.
2. **ICD `vkCmdDraw` applies the queued solid rrect.** Graphite
   records the draw; the kernel ICD fills the rounded coverage on
   the live colour image. Not a planted blit that skips DRAW.
   `osgfx_vk_rrect_draws` must increase. AABB corner stays clear.
3. **No CPU fallback for that chrome pixel.** If Graphite fill
   fails, `osgfx_fill_rrect` does not call `draw_rrect_spans` for
   the title / proof colour.
4. **Anti-vacuity.** Homebrew `-vga std`: `GRAPHITE NONE`, no
   `RRECT 00C45A20`. `OSGFX_SKIA=0` has no `graphite-rrect-gpu`.
5. **No new syscall.** 11 stays `fdwait`. No help line.

## 3. What this is not

It is not Mesa Venus encode of SPIR-V to host lavapipe. The ICD
still software-fills DRAW from the queued rrect Graphite asked
for. Shadow / border spans may still be CPU until the next rung.
It is not Metal. It is not G10/G11 relabelled.

## 4. Binary

`de-graphite3/run.sh`:

* `nm` names `graphite-rrect-gpu`, `drawRRect` path, ICD queue.
  `OSGFX_SKIA=0` has none.
* Homebrew: `GRAPHITE NONE`; no `OSGFX GRAPHITE RRECT 00C45A20`.
* Docker `venus=on`: `GRAPHITE OK`, `PIX 00E24A18`, and
  `OSGFX GRAPHITE RRECT 00C45A20`. Screen (124, 62) is that
  colour; AABB corner (64, 48) is not.

## 5. Leftover

Venus `CONTEXT_INIT` + blob + host lavapipe so Graphite's fragment
SPIR-V runs on the host. Curved `SkRRect::MakeRectXY` still GPs in
`Recorder::snap` on this ICD, so the proof records a rect-type
`drawRRect` and the ICD applies radius on END_RP/DRAW. Shadows /
borders may still be CPU spans. Next binary: host FS paints every
chrome rrect without ICD-side coverage.
