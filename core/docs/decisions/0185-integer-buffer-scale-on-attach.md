# ADR-0185 — Integer buffer scale on attach and compose

**Status:** accepted, implemented (scale in high bits of
`wmWinStride`, sampling in `wmBlitRow` / `wmWindowPixel`, harness
`core/tests/conformance/wm-scale`)
**Date:** 2026-08-31
**Depends on** ADR-0051, ADR-0184.
**Closes** integer buffer scale from `display-protocol.md` §5.1.
Fractional scale is leftover.
**Number:** 0185. No new syscall. 11 stays `fdwait`.

---

## 1. Decision

1. **ATTACH word 6 high 32 bits are the scale.** 0 means 1. Stride low
   32 bits; 0 means `(w * scale) * 4`.
2. **Surface size stays w×h.** Buffer is `(w*scale)×(h*scale)`. Compose
   samples `buffer[(y*scale)*stride + (x*scale)*4]` (nearest).
3. **Region must cover the scaled buffer.** Same refuse-not-clamp rule.

## 2. Binary

`wm-scale/`: attach 40×40 at scale 2 with a checker buffer; probes at
surface (0,0) and (1,0) match the two checker colours. Serial carries
`SCL 2`.
