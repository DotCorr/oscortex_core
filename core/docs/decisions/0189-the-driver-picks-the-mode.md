# ADR-0189 — The driver picks the mode, not the hint

**Status:** accepted, implemented (`virtgpuModeWantW`/`H`,
`virtgpuModeFits`, `virtgpuModeFloor`, `virtgpuReportMode` in
`virtgpu.dart`; the floor applied in `virtgpu3d.dart`; `vmFineBytes`
grown in `vm.dart`)
**Date:** 2026-08-31
**Depends on** ADR-0059, ADR-0064, ADR-0074, ADR-0079, ADR-0093,
ADR-0097, ADR-0098, ADR-0187.
**Corrects** the belief recorded in ADR-0187 §3 and GAP-0328 that
`xres=`/`yres=` on `virtio-gpu-gl-pci` "did not move what
`GET_DISPLAY_INFO` reports". They move it. A UI frontend then moves it
back.
**Closes** GAP-0328.
**Number:** 0189. No new syscall. 11 stays `fdwait`.

---

## 1. Decision

**`pmodes[0]` is a hint about the host window. It is not a mode list,
and it is not permission.** The driver chooses the scanout mode, sizes
`RESOURCE_CREATE_3D` and the backing from that choice, and puts that
choice in `SET_SCANOUT`'s rect. The device's answer to
`GET_DISPLAY_INFO` is recorded as a readback (`VIRTIO SCAN`) and is
allowed to disagree with it.

A second serial line now states the mode the OS actually drove:

    VIRTIO MODE wwwwwwww hhhhhhhh ssssssss

`src` is 0 when the device's `pmodes[0]` was taken as-is and 1 when the
driver overrode it. Every consumer of geometry —
`sit-in-view.sh`, `sit-in-view-fb-refresh.py`,
`de-skia-text/probe-run.py` — now reads `VIRTIO MODE` and falls back to
`VIRTIO SCAN` only if it is absent. `VIRTIO SCAN` was the wrong source:
it is what the device *said*, not what the OS *drove*, and those are
different numbers on purpose.

## 2. Root cause of the 640x480 readback

QEMU does not ignore `xres=`/`yres=`. It seeds `req_state[0]` from
them. Then the UI frontend overwrites `req_state[0]` through
`dpy_set_ui_info` with the size of the console it actually realised,
and `GET_DISPLAY_INFO` answers from `req_state[0]`. So the last writer
wins, and the last writer is the display backend:

| launch | backend | reports |
|---|---|---|
| `de-skia-text/shot-venus.sh` (before this ADR) | `gtk,gl=on` under `xvfb-run` | 640x480 |
| `sit-in-view.sh --venus` (the door) | `sdl,gl=on` sized 1280x720 | 1280x720 |

That is the difference GAP-0328 recorded as "not yet identified" and
listed as its binary next step. It is the display backend, not the
device properties and not a parsing bug: `resp+32`/`resp+36` were
always being read correctly. `gtk,gl=on` with no window manager to
resize it realises a 640x480 placeholder console and reports that;
`sdl,gl=on` tracks the window the door asks for.

**Why the fix is not "always pass `sdl,gl=on`".** That would make the
mode a property of the launcher, so every harness, every backend and
every future headless path would have to re-derive it, and a backend
that reports a postage stamp would still produce one. The hint is
advice from the host window; the scanout is the OS's. `SET_SCANOUT`'s
rect is what resizes the console, so driving it at the size we want is
both the fix and the mode set.

`virtgpuModeFloor` is therefore true in both directions — when the
hint is smaller than we want, and when the hint is a host window this
attach path cannot back — and false when the want itself does not fit,
because then the hint is all there is.

## 3. 1280x720 is the largest mode this attach path can describe

Not a preference. `virtgpuModeFits` checks the two real ceilings:

- backing frames: `1280*720*4` is 3.5 MiB, 900 pages, under
  `virtgpuBackCap` 1024.
- entry frames: 900 entries of 16 bytes is 4 pages, exactly
  `virtgpuEntCap` 4.

The entry cap is the binding one: 1280x720 sits on it with nothing to
spare. 1366x768 needs 5 entry pages and 1920x1080 needs 9, so either
would require growing `virtgpuEntCap` first. The mode was chosen to be
the largest 16:9 mode that needs **no** cap change, so this rung
changes the mode and nothing about the attach path's shape.

## 4. The mode set uncovered a paging refusal, and it was ours

With the floor in, the door booted to chrome and then refused every
spawn with `PROC REFUSED 01` — "the address space was never installed".
`vmMetaReady` was 0 because `vmInit` had returned `vmStatusTooBig`:
`kernel_image_end()` exceeded `vmFineBytes`, so the kernel never
installed its own page tables and stayed on `boot.S`'s bootstrap set.

Measured: `__kernel_end` is `0x10193F0`, **16.10 MiB**, against a
16 MiB (`0x1000000`) fine window. It crossed by about 100 KiB. This is
ADR-0187's growth — the Roboto outline tables and the 3 MiB paint
stack — not the mode, and it was latent before this rung: any boot on
the current tree could raise chrome (the compositor runs in kernel
context) while being unable to start a single process. It is exactly
the failure `plug-the-os` warns about, in that the pixels looked alive
while the OS underneath had silently declined to page itself.

The 4 KiB-page identity window is now 32 MiB, with the six constants
that describe it moved together: `vmFineBytes` 16→32 MiB,
`vmFinePages` 4096→8192, `vmBigFirst` 8→16, `vmFrameCount` 12→20,
`vmIxPdPci` 11→19, `vmStoreBytes` 176→240 (`vmStoreWords` 22→30).
`nm` confirms `vmStore` is `0xf0` = 240 bytes. The scanout backing
lands at `0x103C000`, immediately above the kernel image, so the larger
mode needs the larger window too.

`m8-paging/run.sh` had the 16 MiB limit and the 176-byte `vmStore`
typed in as literals, which is how a window can be grown without the
harness that guards it noticing. It now derives both from `vm.dart`.

## 5. Binary

Live door, `sit-in-view.sh --venus`, current tree:

    VIRTIO SCAN 00000000 00000000 00000500 000002D0 00000001
    VIRTIO MODE 00000500 000002D0 00000000
    WM ON BASE 0103C000 PITCH 00001400 BG 00184060
    WM DE START 04

`0x500`x`0x2D0` is 1280x720. Pitch `0x1400` is 5120 = 1280*4, which is
the independent check: the compositor's stride is derived from the
mode, so a 640-wide scanout could not print it. `src` is 0 because on
`sdl,gl=on` the device already offers 1280x720 and the floor correctly
did not fire — the floor is not doing the work here, it is the
guarantee that a backend which reports a postage stamp cannot impose
one.

`core/build/tigervnc-live-now.png` is a 1280x720 capture of that
framebuffer, read with `pmemsave` at `0x103C000` stride 5120 — the
scanout bytes themselves, not a VNC-side scale.

`de-skia-text/shot-venus.sh` now asserts `VIRTIO MODE 1280x720` and
`WM ON BASE ... PITCH 0x1400`, so the floor is guarded on the
`gtk,gl=on` path where the hint really is 640x480 and the override
really does fire.

## 6. What is NOT claimed

- Not EDID. `VIRTIO_GPU_CMD_GET_EDID` is not issued; there is no mode
  list, no preferred-timing parse and no validation that a chosen mode
  is one the host would enumerate. The floor is a driver policy with a
  fit check, which is a different and smaller thing.
- Not resolution independence. 1280x720 is a constant, not a
  negotiation, and going above it needs `virtgpuEntCap` grown first
  (§3). Nothing here makes the OS handle a mode change after boot.
- Not multi-scanout. `pmodes[1..15]` are still unread and scanout 0 is
  still the only one driven.
- Not a fix for what is painted at that size. GAP-0329 (DESK.ELF's
  strip is hardcoded to an 800x600 bottom and floats mid-desk at any
  other size) becomes *more* visible at 1280x720, not less, and is
  untouched here. GAP-0333 (an idle client's body is erased by the
  cached wallpaper and never re-blitted) was found while capturing the
  live door for this ADR and is likewise untouched — it is size
  independent, and the door's own boot frame and
  `de-chrome-venus.png` both show complete bodies at 1280x720.
- The `vmFineBytes` growth is a window resize, not a memory-map
  redesign. `derive.py`'s `MAP_BYTES` is still 128 MiB against
  `vm.dart`'s 256 MiB — pre-existing drift from ADR-0155, left alone
  because correcting it moves `m8-paging`'s derived golden and is not
  this rung.
