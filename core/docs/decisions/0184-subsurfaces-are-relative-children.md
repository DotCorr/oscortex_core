# ADR-0184 — Subsurfaces are relative children in the wm tree

**Status:** accepted, implemented (`wmOpSub` / `wmOpMove` in
`wmext.dart`, parent packed in `wmWinState`, harness
`core/tests/conformance/wm-sub`)
**Date:** 2026-08-31
**Depends on** ADR-0051, ADR-0183 (shared `wmext.dart`).
**Closes** one-level subsurfaces from `display-protocol.md` §5.1.
Deep trees and child drag are leftover.
**Number:** 0184. No new syscall. 11 stays `fdwait`. `wmStore` stays 448.

---

## 1. Decision

1. **`wmOpSub = 5`.** Child handle, parent handle, relative ox/oy, w, h.
   Geom stores the relative pose; [wmAbsX]/[wmAbsY] add the parent's
   absolute origin at compose and hit.
2. **Parent in bits 8..15 of `wmWinState`.** Low byte stays live/min/free
   so [wmWindowHeld] / [wmWindowUsable] mask `0xFF`.
3. **`wmOpMove = 7`.** Repositions a root (or a child's relative offset).
   Moving a parent carries children because abs is computed each pass.
4. **One level.** A parent that is itself a child is refused.

## 2. Binary

`wm-sub/`: PROG attaches parent+child, moves parent to (200,100),
framebuffer probes show child fill at the new absolute centre and
parent fill outside the child; old child location is not child fill.
