# ADR-0172 — Venus encodes retained SPIR-V

**Status:** accepted, implemented (`tests/conformance/de-graphite6/run.sh`)
**Date:** 2026-08-31
**Milestone:** GAP-0313 leftover after ADR-0161 (curved MakeRectXY)
**Files:** `core/kernel/virtgpu3d.dart` (`osgfx_venus_spirv_wire`),
`core/plat/osgfx/osgfx_vk.c` (`osgfx-venus-spirv`),
`core/tests/conformance/de-graphite6/`
**Depends on** ADR-0161 (host-precompiled SPIR-V retain), ADR-0134
(Venus capset arm).
**Does not close** GAP-0313 (host lavapipe still does not execute the
module as Graphite FS coverage).
**Number:** 0172 — 0171 is CEF UND×20. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. Decision

Retained SPIR-V from ICD `CreateShaderModule` / `osgfx-host-spirv`
crosses the Venus wire:

1. **CONTEXT_INIT.** Negotiate `RESOURCE_BLOB` + `CONTEXT_INIT`.
   `CTX_CREATE` with `context_init = VIRTIO_GPU_CAPSET_VENUS` (4).
2. **Blob.** `RESOURCE_CREATE_BLOB` (`HOST3D` + mappable/shareable)
   is attempted for the retained SPIR-V page. `CTX_ATTACH` when the
   blob lands. Guest-backed blobs are refused on Venus/QEMU
   (`ERR_UNSPEC`); hostmem blob is best-effort.
3. **Submit.** `SUBMIT_3D` on that context carries the same SPIR-V
   bytes (best-effort; raw SPIR-V is not full `vn_cs` CreateShaderModule).
4. **Serial.** `OSGFX VENUS SPIRV <nbytes>` when CONTEXT_INIT succeeds
   and the retained SPIR-V (magic `0x07230203`) is submitted on that
   Venus context. Token `osgfx-venus-spirv`.

Not ICD-side radius fill labelled as host FS. Not a planted token
without Venus.

## 2. Consequences

`de-graphite6` PASS keeps PIX / RRECT / DESK / CURVE. Homebrew never
prints `OSGFX VENUS SPIRV`. Leftover under GAP-0313: full Venus
`vn_encode_vkCreateShaderModule` so host lavapipe executes the module
and Graphite fragment coverage paints without ICD DRAW radius.

## 3. Do not claim

Do not claim lavapipe ran the shader. Do not claim freestanding
AnalyticRRect SkSL works. Do not claim Mesa Venus ring protocol is
complete.
