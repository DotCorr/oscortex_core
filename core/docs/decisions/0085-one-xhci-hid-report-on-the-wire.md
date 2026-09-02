# ADR-0085 — One xHCI HID boot report on the wire

**Status:** accepted, implemented, verified (`tests/conformance/u3-xhci/run.sh`)
**Date:** 2026-08-30
**Depends on** USB0/USB1 (ADR-0068), USB2 (ADR-0073), `pciWrite32` (ADR-0065),
and `Volatile<T>` (ADR-0044).
**Implements** `docs/design/usb-hid.md` USB3.
**Number:** 0085 — 0082 is Graphite; 0084 is G5. Do not collide 0074.

---

## 1. The question

USB2 translates a HID boot report into a set-1 scancode on `kbdq`. The
producer was `usb feed` on COM1. USB3 is the missing half: a real xHCI
transfer ring so the eight bytes exist on the wire. Attaching
`-device usb-kbd` on any 8042 harness steals QEMU `send-key`
(`usb-hid.md` §1). The question is how to prove the ring without
rewriting USB0/USB1/USB2 or stealing last `.bss`.

## 2. The decision

1. **New file `core/kernel/usb3.dart`, appended after `wmevent.dart`.**
   USB0/USB1/USB2 stay in `usb.dart` and keep their contracts: no
   `pciWrite32`, no Volatile store, no `SET_PROTOCOL` in that file.
   `usb.dart` is still not last. `usb3.dart` donates no `.bss`.
   Rings, DCBAA, contexts and the report buffer come from
   `allocFrame()`. `wmeventStore` stays last; `kbdqStore` still abuts
   it.
2. **Hidden command `usb hid`, not a rewrite of `usb` or `usb feed`.**
   Bare `usb` is still the USB0/USB1 print. `usb feed` is still the
   labelled USB2 seam. Longest-first dispatch. Not in `help`.
   `usb3Init()` prints nothing.
3. **The path is port reset / Enable Slot / Address Device /
   GET_DESCRIPTOR / SET_CONFIGURATION / SET_PROTOCOL(0) / Configure
   Endpoint / one Normal TRB on the interrupt IN ring.** The doorbell
   is the kick. Completion is a Transfer Event on the event ring,
   polled with `Volatile<u32>` (GAP-0071). The eight bytes call
   `usbHidApply`.
4. **`USB HID WAIT` is the harness sync.** The interrupt TRB is posted
   and the doorbell rung before that line. The harness then QMP
   `input-send-event` `down:a` (HID usage 0x04). QEMU delivers that
   key to `usb-kbd`, not the 8042. The printed dump is
   `USB HID RPT <16 hex>` then `USB HID 001E`.
5. **Injection is COM1 for the command, QMP for the USB key.** This
   harness attaches `qemu-xhci` + `usb-kbd`. u0/u1/u2 and every 8042
   harness do not. No USB syscall. Syscall 11 stays `fdwait`.

## 3. The printed lines

```
USB HID PORT 01 1
USB HID DESC 12 01 0627:0001
USB HID WAIT
USB HID RPT 0000040000000000
USB HID 001E
```

Empty ports: `USB HID NONE`, and no WAIT / RPT / 001E.
No controller: `USB NONE`.

## 4. Binary

`u3-xhci/run.sh` sends `usb hid` on COM1 with `-device qemu-xhci
-device usb-kbd`, waits for WAIT, injects `down:a`. Printed usage
must be `04`. Printed event must be `001E`. The next prompt types
`a` and must not type `3`. Negative: the same kernel on qemu-xhci
with no device prints `USB HID NONE` and does not enqueue. Plain
`-M pc` prints `USB NONE`.

Anti-vacuity is the alphabet plus the empty port: a canned `001E`
fails the empty-port boot; usage-as-scancode fails both the event
and the drain character.

`u0-xhci`, `u1-xhci` and `u2-hid` still pass: those harnesses omit
`usb-kbd`, still type `usb` / `usb feed`, and still see USBCMD
Run/Stop clear on the probe command.

## 5. What this is not

Not a full USB stack, not hubs, not six-key rollover, not MSI, not
a USB mouse, not a help line, not a rewrite of `usb feed`, and not
metal xHCI (a vendor:device that is not `1b36:000d`). Polling a
command for one report is not a resident keyboard.
