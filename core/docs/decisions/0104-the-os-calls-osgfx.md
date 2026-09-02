# ADR-0104 — The running OS calls the osgfx C ABI

**Status:** accepted, implemented, verified (`tests/conformance/de-osgfx/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-osgfx (`docs/design/c-modules.md`, `docs/design/osx-ui.md`)
**Files:** `core/plat/osgfx/osgfx_sw.c`, `osgfx.h`, `osgfx_scene.c`,
`core/kernel/wmgfx.dart`, `core/scripts/build-kernel.sh`,
`core/scripts/sit-in.sh`, `core/link/kernel.ld` (`.osgfx_cmd` already),
`core/tests/conformance/de-osgfx/`
**Depends on** ADR-0080 (`osgfx.h`), ADR-0094 (compose policy).
**Does not close** GAP-0313 leftover: swap `osgfx_sw.c` for Skia Graphite
/ GPU behind the same header.
**Number:** 0104 — 0103 is FFmpeg; 0099–0102 are reserved.

---

## 1. The question

Host Graphite/CEF in `core/plat` is a Mac program. Android calls Skia
from the running system. `kernel.elf` is x86_64; copying arm64
`libskia.a` / Metal into it is rejected. C can target the same triple
the kernel already uses. Sit-in must show rounded chrome.

## 2. The decision

1. **`osgfx_sw.c` implements `osgfx.h` for `x86_64-unknown-none-elf`.**
   Software rrect / compose. Same clang flags as user ELFs. Linked
   into `kernel.elf` next to `boot.o` / `kmain.o`. Not Graphite, not
   Metal. `osgfx_backend_name` is `"software"`.
2. **The compositor calls those symbols.** `wm gfx` (sit-in) sets
   spare word 23, skips the square blit, fills the `.osgfx_cmd`
   mailbox. IRQ0 `osgfx_guest_tick` calls `osgfx_fill_rrect`. No new
   `@extern` (44 stay 44). `wm chrome` stays the old blit (d2 / d8).
3. **No Mac `libskia.a`. No new syscall.** 11 stays `fdwait`. No
   help line. `wmeventStore` stays last `.bss`.
4. **Anti-vacuity.** `OSGFX_SW=0` omits the `.o`; `nm` has no
   `osgfx_fill_rrect` and the corner does not round.

## 3. What this is not

It is not Skia Graphite in the image. It is not Metal. It is not a
Dart `fill_rect` labeled as osgfx. Host `gfx0` / `gfx1` / `gfx2-compose`
are unchanged.

## 4. Verification

`core/tests/conformance/de-osgfx/run.sh` — `nm` / `kernel.map` name
`osgfx_fill_rrect` in `kernel.elf`; `OSGFX_SW=0` does not; sit-in /
`wm gfx` AABB (100,120) is desktop `0x184060`, title interior is title.
