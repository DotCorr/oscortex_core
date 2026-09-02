# ADR-0138 — xHCI HID reaches kbdevent and mouse

**Status:** Accepted
**Date:** 2026-08-30
**Number:** 0138. Syscall 11 stays `fdwait`.

---

## 1. Context

USB0–USB3 landed (ADR-0068/0073/0085): class probe, MMIO, HID→set-1
translator, one wire report into `kbdq`. Shell drain was the only
consumer. A focused ring-3 client and a HID mouse report were still
open. Attaching `usb-kbd` on 8042 harnesses steals QEMU `send-key`.

## 2. Decision

1. **`usbHidApply` → `kbdq` → syscall 24.** With `proc spawn` the
   prompt returns while the client holds. Focus via PS/2 click.
   COM1 `usb feed 0004 0000` (no `usb-kbd`) plants usage `0x04`; the
   focused client prints `HID SESS SEQ N 02 01E 11E`.
2. **`usbHidMouseApply` + `usb mfeed`.** HID boot-mouse bytes
   (buttons, dx, dy) update the pointer. HID Y positive is down the
   framebuffer (not PS/2 inverted). Announce `USB MOUSE`.
3. **Harness `hid-sess/`.** Structural: this harness and
   `m0`/`m1`/`d1`/`d2`/`u0`/`u1`/`u2` omit `usb-kbd`. `qemu-xhci`
   may sit as the class stand-in. No help line. No new syscall.

## 3. Consequences

* `tests/conformance/hid-sess/run.sh` is the binary exit.
* u3 may still attach `usb-kbd` for the wire path; 8042 goldens must
  not copy that device line.
* Resident xHCI IRQ poll at the idle prompt remains a leftover
  (`usb-hid.md` §6).
