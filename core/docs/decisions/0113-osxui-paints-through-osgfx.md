# ADR-0113 — OSXUI widgets paint through osgfx.h

**Status:** accepted, implemented, verified (`tests/conformance/osxui4/run.sh`)
**Date:** 2026-08-30
**Milestone:** OSXUI-kit (`docs/design/osx-ui.md`, `docs/design/c-modules.md`)
**Files:** `core/plat/osxui/osxui.h`, `osxui.c`, `osgfx_cpu.c`,
`headless_main.c`, `core/scripts/build-osxui.sh`,
`core/scripts/build-kernel.sh`,
`core/tests/conformance/osxui4/`
**Depends on** ADR-0080 (`osgfx.h`), ADR-0104 (`osgfx_sw.c` in
`kernel.elf`). Distinct from policy OSXUI4 (ADR-0106, `wm de`).
**Does not close** leftover glyphs on the label strip.
**Number:** 0113 — 0110–0112 are reserved for parallel rungs.

---

## 1. The question

OSXUI2's `BTN.ELF` blits shm pixels. `osgfx.h` is the UI language.
When Skia replaces `osgfx_sw.c`, a widget that stores pixels itself
does not survive. Widgets must be a C module that only calls the
paint ABI — not a second box toolkit, not Flutter, not a syscall.

## 2. The decision

1. **`osxui.h` is the widget ABI.** `osxui_button` (rrect),
   `osxui_panel` (label strip), `osxui_hit` (AABB). Colours and
   geometry are named constants, same packing as the compositor.
2. **`osxui.c` calls `osgfx_fill_rrect` / `osgfx_fill_rect` only.**
   No `put_px`, no shm, no framebuffer store. The same `.c`
   compiles for the host harness and for `x86_64-unknown-none-elf`
   next to `osgfx_sw.c`.
3. **Host scene, one button.** Click is `osxui_hit` at a derived
   point; a hit selects `OSXUI_BTN_HIT`, a miss leaves
   `OSXUI_BTN_IDLE`. AABB corner is desktop (`OSGFX_DESK`) — a
   `fill_rect` button fails that probe. `--square` is the negative.
4. **Anti-vacuity.** `OSGFX_NO_RRECT=1` omits `osgfx_fill_rrect`;
   `osxui.c` does not link. A binary that never linked osgfx has
   no rrect symbol.
5. **No new syscall. No help line. No virtgpu / shm / osgfx_sw
   edit.** Glyphs on the strip stay leftover.

## 3. What this is not

It is not compositor chrome (ADR-0056 / 0075 / 0106). It is not
`BTN.ELF`. It is not Skia in the image. It is not a widget tree.
It is not Flutter.

## 4. Verification

`core/tests/conformance/osxui4/run.sh` — `nm` names
`osxui_button` / `osxui_panel` / `osxui_hit` / `osgfx_fill_rrect`;
no-rrect link fails; idle AABB is desktop and interior is IDLE;
`--click` interior is HIT; `--miss` stays IDLE; `--square` AABB
is IDLE; the same `osxui.c` compiles for the kernel triple.
