# ADR-0166 — OnPaint stand-in delivers a derived pixel buffer

**Status:** accepted, implemented, verified (`tests/conformance/browse-paint/run.sh`)
**Date:** 2026-08-30
**Milestone:** Content OnPaint door after ADR-0165 (32/32 DT_NEEDED stand-ins)
**Files:** `core/plat/chrome/oschrome_guest.c` (`oschrome_on_paint`, BGRA staging),
`oschrome.h` (`OSCHROME_PET_VIEW`, `oschrome_on_paint`),
`core/user/frame/browse.c` (`BROWSE_NO_ONPAINT`),
`tests/conformance/browse-paint/`, GAP-0322
**Depends on** ADR-0122 (official extract), ADR-0123 (process-ABI block),
ADR-0115 (BROWSE.ELF), ADR-0165 (32/32 DT_NEEDED stand-ins).
**Does not close** official `libcef.so` Content OnPaint. Does not raise
the `de-browse/` floor. Does not ship glibc or Blink.
**Number:** 0166 — 0165 is DT_NEEDED-thirty-two. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall. No help line.

---

## 1. The question

ADR-0165 finished **32 of 32** CEF `DT_NEEDED` stand-ins. The leftover
named was Content `OnPaint`. Official `libcef.so` still cannot execute
(ADR-0123: 189 MiB `.text`, 1,336 UND, POSIX). The owner refuses
`nm` of `cef_initialize` as success and refuses renaming the old
`parse_rgb`→pixels plant as `OnPaint`.

What binary proves an **OnPaint-shaped** path delivers a derived pixel
buffer the compositor can show, with anti-vacuity when the callback is
disabled?

## 2. The decision

1. **`oschrome_on_paint` is the CEF OSR callback ABI.** Signature and
   contract match `cef_render_handler_t.on_paint`: `PET_VIEW` (0),
   BGRA buffer, width×height×4, top-left origin. Host `oschrome.mm`
   `OnPaint` already converts BGRA→`0x00RRGGBB`; the guest stand-in
   does the same.
2. **`load_url` stages BGRA only.** `parse_rgb` of the `data:` HTML
   fills a BGRA staging buffer. It clears pixels and sets `pending`.
   It does **not** set `painted = 1`. That is the anti-rename: the old
   plant wrote pixels in `load_url`; this door does not.
3. **`pump` invokes `oschrome_on_paint`.** With the callback enabled,
   pump delivers the staging buffer into the callback; pixels become
   PAGE; the FRAME client blits to shm and the compositor shows it.
4. **Anti-vacuity: `--no-onpaint` / `BROWSE_NO_ONPAINT`.** Callback
   disabled → `pump` cannot paint → probe is not PAGE. Same binary
   family as PAINT.ELF; not a second rgb painter.
5. **Honest label.** Comments and the ADR state this is OUR Content
   stand-in. Leftover: **wire official libcef.so**. `de-browse/`
   floor stays 87. TAP ELFs stay ≤ `elfImageMax` (65,536). PLAT may
   be large. Graphite / Venus fenced.

## 3. What this is not

It is not official Chromium Content painting. It is not `nm` of
`cef_initialize`. It is not a rename of the ADR-0122 `parse_rgb`
pixel plant. It is not raising `de-browse` floor 87. It is not
glibc. `drawRRect` still owns `osgfx_skia`.

## 4. What remains (GAP-0322 leftovers)

Wire official `libcef.so` so real Content `OnPaint` runs. The
process ABI doors (ADR-0124…0165) are open; the blob still needs
POSIX faces, resource packs, and a multi-process shape. This
decision is the OnPaint-shaped pixel door with an honest stand-in.

## 5. Verification

`core/tests/conformance/browse-paint/run.sh` — `PAINT.ELF` walks
`load_url` → BGRA stage → `oschrome_on_paint` → PAGE on the
compositor probe. `NOPAIN.ELF` (`--no-onpaint`) is not PAGE.
`oschrome_on_paint` is a defined text symbol. `load_url` does not
set `painted = 1`. Syscall 11 is still `fdwait`. `de-browse/` stays
at floor 87. Leftover named: wire official `libcef.so`.
