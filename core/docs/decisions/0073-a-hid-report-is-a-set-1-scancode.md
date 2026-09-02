# ADR-0073 — A HID boot-protocol report is a set-1 scancode on kbdq

**Status:** accepted, implemented, verified (`tests/conformance/u2-hid/run.sh`)
**Date:** 2026-08-30
**Depends on** USB1 (ADR-0068) and the input queue (ADR-0054).
**Implements** `docs/design/usb-hid.md` USB2.
**Number:** 0073 — 0068 is USB1 xHCI; 0067 is G2. This file was one of
the 0068s. Citation-only remumber; USB2 is already landed.

---

## 1. The question

USB1 reads qemu-xhci capability registers. USB2 is one HID
boot-protocol keyboard report into the existing queue. A full xHCI
transfer ring (port reset, address, SET_CONFIGURATION, SET_PROTOCOL(0),
one interrupt endpoint) does not fit this slice. The question is how
to prove the *upper* half — translate and enqueue — without attaching
`-device usb-kbd`, which steals QEMU `send-key` from the 8042
(`usb-hid.md` §1).

## 2. The decision

1. **HID usage is translated to set-1, then `kbdqPush`.** Usage `0x04`
   is `a`. Set-1 make for `a` is `0x1E`. They are different numbers.
   Enqueueing the usage as a scancode would make the shell type `3`
   (`kbdSet1Ascii[0x04]`) and would give syscall 24 a new encoding
   with no flag. One queue, one encoding (display-protocol.md §4.2
   item 5).
2. **The translator is `usbHidApply`.** Modifier edges come from the
   bitmap delta; the first usage slot is compared to the previous
   report. Make and break are ordinary `kbdq` packed words (ADR-0054).
   A transfer-ring path must call this function. Six-key rollover is
   USB3.
3. **`usb feed <hex>` is a labelled test seam**, same shape as
   `mouse feed`. Packed form is two bytes per report: modifier, then
   usage. `0004` is `a` down; `0000` is all keys up. An 8-byte boot
   report is accepted when the argument is a multiple of eight bytes.
   Previous-report state is locals inside one command. No `@bss`.
4. **Injection is COM1, not `usb-kbd`.** The harness writes the
   command to the serial socket. Serial does not enqueue on `kbdq`
   (GAP-0309). After the command, `kbdqDrainToShell` types the
   translated character — that is the queue proof. `-device usb-kbd`
   is forbidden on this boot and on USB0/USB1.
5. **Still no help line, no syscall, no last `.bss`.** `shellStrHelp`
   stays 2511 bytes. `part 'usb.dart'` stays after `nic.dart` and
   before `wmevent.dart`. D7 still owns last place. Focus is
   untouched (ADR-0062). `kbdq` stays global.

This is not a host-controller bring-up. It is not a metal xHCI
proof. It is the decoder the bring-up must call.

## 3. The printed line

```
USB FEED 001E 011E
```

Make 0x1E, break 0x1E (bit 8). The next prompt then shows `a`,
because the drain indexes `kbdSet1Ascii[0x1E]`.

Bare `usb` is still USB0/USB1. An unknown `usb` argument prints
the usage line. `usb` is not in `help`.

## 4. Binary

`u2-hid/run.sh` sends `usb feed 0004 0000` on COM1 (plain `-M pc`,
no `qemu-xhci`, no `usb-kbd`). Printed events must be `001E` then
`011E`. The next prompt must type `a` and must not type `3`.
Negative control: `usb` alone prints `USB NONE` and no `USB FEED`,
and does not drain an `a`.

Anti-vacuity is the alphabet: `kbdSet1Ascii[0x04]` is `3`. A kernel
that stored the usage as a scancode fails both the printed event
and the drain character.

`u0-xhci` and `u1-xhci` still pass: the device line and the cap/op
lines are unchanged, and those harnesses still omit `usb-kbd`.

## 5. What this is not

Not a transfer ring, not `SET_PROTOCOL`, not `pciWrite32`, not MSI,
not a USB mouse, not a help line, and not a rewrite of focus or of
`wmeventStore`. Metal xHCI (a vendor:device that is not
`1b36:000d`, a real interrupt endpoint, no 8042) is leftover.
