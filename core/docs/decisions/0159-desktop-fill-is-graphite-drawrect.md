# ADR-0159 — Desktop fill is Graphite drawRect

**Status:** accepted, implemented, leftover recorded (`tests/conformance/de-graphite4/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0313 leftover after ADR-0153 (chrome rrect)
**Files:** `core/plat/osgfx/osgfx_graphite_guest.cpp`, `osgfx_skia.cpp`,
`core/tests/conformance/de-graphite4/`, known-gaps / c-modules
**Depends on** ADR-0153 (Graphite `drawRRect` + ICD DRAW). Does not
replace the RRECT / PIX proofs.
**Does not close** GAP-0313: curved `SkRRect::MakeRectXY` still GPs in
`Recorder::snap` on this ICD; Venus still does not encode SPIR-V to
host lavapipe. Shadows / borders may still be CPU spans.
**Number:** 0159 — 0158 is two-mappers shm. 0157 is DT_NEEDED. 0153 is
chrome-rrect. Do not reuse those. Syscall 11 stays `fdwait`.

---

## 1. The question

ADR-0153 put title-bar chrome through Graphite `drawRRect`. Desktop
and taskbar strips were still CPU `put_px` / `osgfx_fill_rect`.
Graphite is the OS renderer — a former CPU chrome surface must move
onto Graphite with serial proof. Curved `MakeRectXY` still cannot
snap on this ICD; do not stub it.

## 2. The decision

1. **Graphite desktop fill.** When Venus arms and `MakeVulkan` is
   live, a desktop-class solid fill (480×270 proof; live sit-in
   desktop + taskbar strips) goes through Graphite `drawRect` + ICD
   DRAW (`r=0`). Token `graphite-desk-gpu`. Serial
   `OSGFX GRAPHITE DESK 001C6A38`. Colour is not `OSGFX_DESK` /
   `OSGFX_CHROME` / RRECT / PIX — CPU `put_px` cannot plant it.
2. **Taskbar routes through the same door.** `osgfx_fill_rect` for
   `OSGFX_CHROME` / `OSGFX_DESK` calls `osgfx_graphite_fill_desk`
   when Graphite is ready; no CPU fallback for that strip.
3. **Curved leftover named.** `SkRRect::MakeRectXY` still GPs in
   `Recorder::snap` on this ICD. Rect-type `drawRRect` (ADR-0153)
   and solid `drawRect` (this ADR) are the live Graphite paints.
   Next binary for curves: Venus SPIR-V / host FS, or an ICD that
   can snap AnalyticRRect without GP.
4. **Anti-vacuity.** Homebrew `-vga std`: `GRAPHITE NONE`, no
   `DESK 001C6A38`. `OSGFX_SKIA=0` has no `graphite-desk-gpu`.
5. **No new syscall.** 11 stays `fdwait`. No help line.

## 3. What this is not

It is not curved `MakeRectXY` working. It is not Mesa Venus encode
of SPIR-V. Shadow / border spans may still be CPU. It is not Metal.

## 4. Binary

`de-graphite4/run.sh`:

* `nm` names `graphite-desk-gpu`, keeps `graphite-rrect-gpu` /
  MakeVulkan / ICD. `OSGFX_SKIA=0` has none of the Graphite tokens.
* Homebrew: `GRAPHITE NONE`; no `DESK 001C6A38`; no RRECT / PIX.
* Docker `venus=on`: `GRAPHITE OK`, `PIX`, `RRECT 00C45A20`, and
  `OSGFX GRAPHITE DESK 001C6A38`.

## 5. Leftover

Curved `SkRRect::MakeRectXY` / AnalyticRRect still GPs in
`Recorder::snap` on this ICD (`FAULT 0D`; ADR-0161 /
`de-graphite5/` OPEN). Venus `CONTEXT_INIT` + blob + host lavapipe
so Graphite fragment SPIR-V runs on the host. Shadows / borders may
still be CPU until that door opens.
