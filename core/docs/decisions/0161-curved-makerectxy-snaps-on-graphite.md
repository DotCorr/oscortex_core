# ADR-0161 — Curved MakeRectXY snaps on Graphite

**Status:** accepted, implemented (`tests/conformance/de-graphite5/run.sh`)
**Date:** 2026-08-30
**Milestone:** GAP-0313 leftover after ADR-0159 (desktop fill)
**Files:** `core/plat/osgfx/osgfx_graphite_guest.cpp`, `osgfx_vk.c`
(`osgfx-host-spirv`), `core/tests/conformance/de-graphite5/`
**Depends on** ADR-0153 (chrome rrect), ADR-0159 (desktop fill).
**Does not close** GAP-0313 (Venus encode of SPIR-V to host lavapipe).
**Number:** 0161 — 0160 is DT_NEEDED-four / shm partial (parallel).
Syscall 11 stays `fdwait`.

---

## 1. Decision

Curved `SkRRect::MakeRectXY` paints on Venus without freestanding
AnalyticRRect SkSL. Guest `Recorder::snap` of `drawRRect(MakeRectXY)`
#GPs (`FAULT 0D OP 4C8B`) before `CreateShaderModule`. The curve path
instead:

1. Builds a non-rect-type `MakeRectXY` and reads its radii (`osgfx-vk-spirv`
   retain + `osgfx-host-spirv` plant).
2. Plants **host-precompiled SPIR-V** through ICD `CreateShaderModule`.
3. Records a Graphite pixel-aligned rect pass (same nonAABounds door as
   RRECT — snaps without AnalyticRRect SkSL).
4. ICD DRAW applies the MakeRectXY radius (mid filled, AABB corner clear).

Not a stub `MakeRect` as the curve proof — `MakeRectXY` remains the
geometry source. Not another stack bump. `paint_stack` stays 1MiB and
CRT heap 4MiB so `kernel_end` fits under `vmFineBytes` (16MiB); the
prior 8MiB+8MiB BSS made `vmInit` refuse and broke Homebrew
`proc spawn`.

## 2. Consequences

`de-graphite5` PASS: `CURVE 00A87C14`, PIX / RRECT / DESK kept, Homebrew
NONE. Venus encode of retained SPIR-V to host lavapipe is still leftover
under GAP-0313.

## 3. Do not claim

Do not claim freestanding AnalyticRRect SkSL→SPIR-V works. Do not claim
Mesa Venus / lavapipe executes the module on the host yet.
