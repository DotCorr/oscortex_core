# ADR-0193 — Absolute pointer is a tablet, and the door is a QEMU window

**Status:** accepted, implemented (`core/kernel/virtab.dart`,
`mouseAbsPlace` in `mouse.dart`, `scripts/sit-in-view.sh --abs`,
`tests/conformance/view-door/`)
**Date:** 2026-08-31
**Milestone:** the pointer the owner moves is the pointer the OS hits
**Files:** `core/kernel/virtab.dart`, `core/kernel/mouse.dart`
(`mouseAbsPlace`), `core/kernel/usb.dart` (`usbHidTabletApply`),
`core/kernel/keyboard.dart` (IRQ0 stays up while the tablet is armed),
`core/scripts/sit-in-view.sh` (`--abs`, `virtio-tablet-pci`,
`prove_abs_input`), `core/scripts/sit-in-view-input-bridge.py`
(QMP abs, not rel), known-gaps GAP-0324
**Depends on** ADR-0042 (PS/2 mouse stays), ADR-0138 (HID mouse was
relative), ADR-0175 (look door). Does not replace QEMU.
**Number:** 0193 — 0192 is the desk taskbar. Do not reuse.
Syscall 11 stays `fdwait`. No new syscall.

---

## 1. The question

Tiger + x11vnc `-rawfb` + QMP `input-send-event` **rel** cannot track
the Mac cursor. Relative PS/2, Y-invert, and a scaled VNC desktop
disagree. The owner asked to use QEMU (or another emulator) because
that door was a headache. Absolute HID was the leftover on
GAP-0324 / ADR-0175.

## 2. The measurement

* QEMU cocoa (or QEMU's own `-vnc`) plus `virtio-tablet-pci` sends
  `EV_ABS` / `ABS_X` / `ABS_Y` in 0..32767. The host cursor is the
  window pointer; there is no relative warp dance.
* QEMU `-vnc` cannot share a GL context (ADR-0175). Venus Graphite
  therefore cannot be the clickable window on this Mac. The clickable
  door is cocoa / QEMU VNC even when scanout is stdvga or GOP.
* `usb-tablet` on xHCI would also be absolute, but USB3 is still a
  one-shot `usb hid` command. VirtIO-input is one virtqueue on the
  transport `virtgpu.dart` already speaks (`peripherals.md` §2.6).
* IRQ0 is masked at rest unless `wm pace` is on. A tablet that only
  polls from the PIT would freeze after `picUnmaskKeyboardOnly`.
  The tablet bit keeps IRQ0 unmasked.

## 3. The decision

1. **`mouseAbsPlace` SETs `mouseWordX/Y`.** A tablet event is a
   screen coordinate. It is not added to the last PS/2 packet.
   `wmPointerTick` is unchanged (ADR-0190 kick gate / ADR-0191 chrome
   cache stay).
2. **`virtio-tablet-pci` is the live device.** `virtab.dart` finds
   `1AF4:1052`, negotiates VERSION_1, posts one eventq, scales
   ABS_X/ABS_Y onto `fbGeomWidth` × `fbGeomHeight`, and commits on
   `SYN_REPORT`. The queue holds 64 events (rather than five complete
   reports in 16 events); one PIT poll coalesces bare motion to its final
   absolute position but commits every button edge with the axes from that
   same report. Once this device is armed, decoded PS/2 packets are drained
   for framing but cannot overwrite its axes or buttons. Silent arm from
   `mouseEnable`; `vtab` prints
   `VTAB OK`. `vtab feed` is the COM1 SET seam. Keyboard stays 8042.
3. **The owner door is `sit-in-view.sh --abs`.** QEMU cocoa window
   titled `oscortex-abs-pointer`, one cursor, click inside the
   window. If cocoa cannot open, QEMU `-vnc 127.0.0.1:5900` with the
   same tablet — Tiger may attach as a viewer only. No x11vnc-rawfb
   pointer path. No closed-loop relative warp.
4. **Venus look may still exist.** It now attaches the same tablet.
   INPUT prove is QMP abs → `MOUSE ABS` → Start → `WM DE START`.
   The pipeinput bridge emits abs, not rel.

## 4. Binary exit

`sit-in-view.sh --abs` leaves a live QEMU window (or QEMU VNC).
Serial shows `VTAB OK` and `MOUSE ABS X … Y …` at the injected Start
center (within 2 px). A click there prints `WM DE START`. PNG at
`core/build/tigervnc-live-now.png`. Syscall 11 unchanged.

## 5. Leftover

Homebrew cocoa still cannot arm Venus (no gl device). A live xHCI
interrupt poll for `usb-tablet` is not this door — `usbHidTabletApply`
exists so the HID report has a SET path when USB3 grows a resident
poll. Cursor-erase trails are a sibling (ADR-0190 session-debt);
this ADR does not change `wmPointerTick`'s kick rule.
