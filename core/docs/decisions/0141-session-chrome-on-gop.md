# ADR-0141 — Session chrome composes onto the live GOP aperture

**Status:** accepted, implemented, verified (`tests/conformance/gop-sess/run.sh`)
**Date:** 2026-08-30
**Milestone:** portable panel path (`docs/design/portable-hardware.md` §6.2 leftover)
**Files:** `core/kernel/gop.dart` (`gopIsLive`, `gopSessAnnounce`, still no
`@bss`), `core/kernel/fb.dart` (`fbGeom*` trust GOP only while live),
`core/kernel/wm.dart` / `wmchrome.dart` (announce after compose),
`core/tests/conformance/gop-sess/run.sh`
**Depends on** ADR-0060 (tag), ADR-0061 (map), ADR-0064 (fallback),
ADR-0056 (chrome strip).
**Does not close** GAP-0001 on real hardware. Does not write amdgpu /
i915 / nouveau. Does not take virtio-gpu-gl, Graphite, or MakeVulkan.
**Number:** 0141 — 0064 is the probe order; this is the session that
uses the GOP winner. 11 stays `fdwait`.

---

## 1. The question

PORT1/PORT2 proved a derived 16×16 on the OVMF GOP aperture. ADR-0064
proved the probe order: GOP (tag + map), then Bochs, then `FB NONE`.
Sit-in and `d8-chrome` still photograph chrome on the Bochs BAR
(`-kernel`). A UEFI machine — the Dell Pro 14 panel path — has no
Bochs. Pixels on GOP are not a session until `wm on` / `wm chrome`
compose through that same aperture.

The product is the **scanout fallback class**, not a vendor iGPU
driver. GOP is any UEFI linear framebuffer the loader named. virtio-gpu
is a later winner in that class (not this file). Bochs is the `-kernel`
stand-in. Graphite / Venus / MakeVulkan are other agents.

## 2. The decision

1. **Live GOP is a predicate, not a leftover tag.** `gopIsLive` is 1
   only when `fbState(base)` equals the mapped tag address.
   `fbGeomWidth` / `fbGeomHeight` already used that test; they now call
   the predicate. A refused map still falls through (ADR-0064).
2. **Session compose is the paint.** `wm on` fills the desktop through
   `fbFill` (GOP geometry). `wm chrome` paints the strip at
   `fbGeomHeight() - wmChromeH`. Both announce `WM GOP <w>x<h> <addr>`
   only when live. No help line. No syscall. No `@bss`.
3. **Unmapped GOP is a miss.** `wm on` without `fb` never claims the
   aperture. A `pmemsave` of the firmware GOP address after that boot
   must not contain the chrome colour. That is the anti-vacuity: a
   dump of unmapped guest RAM cannot satisfy the session.
4. **`-kernel` is still Bochs.** Same `kernel.elf`. `fb` prints
   `FB BAR`. `wm chrome` strip pixel count is 800 × 24, not GOP
   width × 24. No `WM GOP` line.

## 3. Binary

`gop-sess/run.sh`:

* OVMF+Limine, no `-kernel`: `fb`, `wm on`, `wm chrome`. Serial
  `FB GOP` and `WM GOP` whose width×height equal the resolution the
  harness wrote into `limine.conf` (1024×768, not 800×600).
  `pmemsave` at the printed GOP address has the derived desktop colour
  outside the compiled-in 800×600 and the chrome colour on the bottom
  strip (y ≥ 600). Address is not the Bochs BAR.
* Same ISO, no `fb`: `wm on` / `wm chrome` do not print `WM GOP`.
  `pmemsave` of the GOP address from the first boot does not contain
  the chrome colour.
* Same `kernel.elf` under `-kernel`: `FB BAR … MODE 0320x0258x20 OK`,
  chrome `PX 00004B00` (800×24), no `WM GOP`.

Anti-vacuity is the GOP-only coordinates plus the unmapped miss.

## 4. What this is not

Not a Dell metal boot. Not amdgpu. Not an iGPU modeset. Not Graphite.
Not Venus. Not USB HID. Not `usb-kbd` on 8042. A laptop panel after
this ADR is still the same chain (GOP winner) plus HID and storage
already named in `portable-hardware.md`.
