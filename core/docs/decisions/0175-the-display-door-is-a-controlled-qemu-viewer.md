# ADR-0175 — The display door is a controlled QEMU viewer, not a second hypervisor

**Status:** accepted, implemented (`scripts/sit-in-view.sh`,
`tests/conformance/view-door/`)
**Date:** 2026-08-31
**Milestone:** make sit-in / Venus lookable at a sane size on a Mac
**Files:** `core/scripts/sit-in-view.sh`, `core/scripts/sit-in.sh`
(cocoa `zoom-to-fit`), `core/scripts/sit-in-view-fb-refresh.py`,
`core/scripts/sit-in-view-input-bridge.py` (`-pipeinput` → QMP),
`core/scripts/build-qemu-gl.sh` (`x11vnc`),
`tests/conformance/view-door/`, known-gaps GAP-0324
**Depends on** ADR-0107 (osgfx→virtio-gl scanout), ADR-0134 (Venus),
ADR-0060/0061 (GOP). Does not replace QEMU for Graphite.
**Number:** 0175 — 0174 is real-named `libdl.so.2`. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall.

---

## 1. The question

QEMU boots oscortex looking tiny (~640×480 Venus under gtk+Xvfb, or
800×600 Bochs cocoa at 1:1 on Retina). The owner wants an official
alternative with better display control. Is the answer a second
hypervisor (VirtualBox / UTM-without-gl / Bochs-as-product)?

## 2. The measurement

* Homebrew QEMU has cocoa (and `zoom-to-fit`) but **no**
  `virtio-gpu-gl-pci`. Graphite / Venus needs Docker
  `oscortex-qemu-gl` (ADR-0134).
* Venus sit-in under `xvfb-run` + `-display gtk,gl=on` reported
  `VIRTIO SCAN … 00000280 000001E0` (**640×480**) even when
  `xres=1200,yres=720` was on the device. The PNG dump was a
  postage stamp; there was no Mac window (headless Xvfb).
* The same device with **`-display sdl,gl=on`** on an explicit
  `Xvfb :99 -screen 0 1280x720x24` reported
  `VIRTIO SCAN … 00000500 000002D0` (**1280×720**). Graphite paint
  is unchanged (same `venus=on` device). SDL still paints that scanout
  in a ~640×480 cell on the Xvfb (window chrome may report 1280×720
  with black letterbox). QEMU **`-full-screen`** mode-switches to
  640×480 and collapses SCAN — do not use it. **`xdotool windowsize`**
  blanks the GL paint — do not use it for the look path.
* **Wrong look fix (reverted):** `x11vnc -clip 640x480+0+0 -scale …`
  upsizes the painted cell and **crops** the 1280×720 desk (owner:
  "fullscreen but still cropped"). Stretching VNC to Mac logical
  points with a non-16:9 aspect also crops.
* **Correct look fix:** `x11vnc -rawfb map:/work/view-fb.bin@1280x720x32`
  of the guest SCAN buffer (pmemsave / `sit-in-view-fb-refresh.py`).
  Same composition as `sit-in-view-venus.png`. No 640 clip. Darwin
  Mac fill uses **integer** scale only (1× / 2× …) so thin chrome is
  not stair-stepped by a fractional 1280→~1800 stretch; Mac
  **letterboxes** the leftover (letterbox OK; crop not OK). x11vnc
  keeps default blending (bilinear) — never `:nb`. Tiger
  `-FullScreen=1` with `-PreferredEncoding=Raw -NoJPEG=1` so Tight
  JPEG does not soften edges on the wire.
* QEMU `-vnc` with a GL context fails:
  `Display vnc is incompatible with the GL context`. The host
  viewer for Venus is **x11vnc of the guest FB**, not QEMU VNC.
* UTM is still QEMU. VirtualBox / Bochs do not offer Venus.

## 3. The decision

1. **QEMU remains the Graphite emulator.** The "alt" is a
   controlled viewer / scale path (`sit-in-view.sh`), not a second
   hypervisor.
2. **Local (non-Venus):** `-display cocoa,zoom-to-fit=on` so the
   Mac window scales the guest FB. Optional `--uefi-hd` hands GOP
   **1280×720** via a view-only Limine conf (does not change
   `boot-uefi/limine.conf`'s 1024×768 p2-gop golden).
3. **Venus:** Docker `virtio-gpu-gl-pci,venus=on` at
   `xres=1280,yres=720`, **`-display sdl,gl=on`** (not gtk) for the
   Venus GL context, Xvfb exactly 1280×720, xdotool **windowmove
   +0+0** only, then **x11vnc `-rawfb` of guest SCAN** at
   **1280×720** (no `-clip 640x480`) **with `-pipeinput` → QMP
   input bridge** so the Mac Tiger session is live, not a picture.
   Darwin door size is an
   **integer** multiple of that SCAN (letterbox on the Mac). Serial
   stamps `VIEW MODE 1280x720`. Guest FB PNG is native sharpness;
   VNC desktop matches the integer door. Do not claim Skia from an
   upscaled mush look.
4. Bochs `fb.dart` 800×600 stays the Multiboot conformance mode.
   Do not raise it to chase Retina; zoom is the host half of the
   door.

## 4. Binary exit

`view-door/run.sh` PASSes: structural (script + zoom + rawfb +
`-pipeinput` + input bridge + ADR), Venus boot shows `VIRTIO VENUS OK`,
`VIRTIO SCAN` width≥1280 height≥720, `VIEW MODE`, PNG at that size,
VNC desktop 1280×720, `input.ok` (MOUSE PKT + Start click →
`WM DE START`), designed chrome colours (pearl title, terracotta Start —
not gold `0xD8B060` paper stamp). Syscall 11 unchanged.

## 5. Leftover

Live cocoa cannot show Venus Graphite on Homebrew (no gl device).
x11vnc `-rawfb` is the Mac look path for Venus; `-pipeinput` →
`sit-in-view-input-bridge.py` → QMP `input-send-event` is the input path
(PS/2 relative; QEMU `-vnc` still cannot share the GL context). SDL's
on-Xvfb paint cell may remain ~640×480; do not treat it as Tiger look
proof. Fullscreen gtk on a real DRM node is unproven here. Do not claim
VirtualBox runs Graphite. Absolute tablet / USB HID pointer is not on
this door — kernel mouse is still 8042.
