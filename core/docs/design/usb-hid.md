# USB HID — laptop input over xHCI

**Status: DESIGN. USB0, USB1, USB2 and USB3 are implemented**
(`core/kernel/usb.dart`, `core/kernel/usb3.dart`,
`tests/conformance/u0-xhci/run.sh`, `tests/conformance/u1-xhci/run.sh`,
`tests/conformance/u2-hid/run.sh`, `tests/conformance/u3-xhci/run.sh`,
ADR-0068, ADR-0073, ADR-0085). USB3 is the transfer ring. Do not mark
USB2 as USB3: `usb feed` is still the labelled COM1 seam.
This is not an ADR.

**It cites rather than re-derives.** `peripherals.md` measured QEMU's USB
controllers, ranked UHCI cheapest under `-M pc`, and ranked **xHCI "No — not
for years"** *for sitting at QEMU*. `portable-hardware.md` §6.3 inverted that
ranking for the laptop: a UEFI machine with no legacy 8042 has no PS/2, and
xHCI is the controller the board actually has. GAP-0055 item 5 already named
the missing 8042. `keyboard.dart` / ADR-0005 / ADR-0054 own the PS/2 path and
`kbdq`. This file is the laptop-input ladder that starts at "find xHCI", not
the UHCI stack `peripherals.md` §7.1 specified.

**Prefix `USB`.** Three letters, same as that document's USB1… rungs. Those
rungs were UHCI + enumeration + HID. This ladder **replaces the first rung
and the controller choice** for the laptop path: USB0 is "the kernel found
an xHCI function", not "the kernel read a UHCI I/O BAR". The old USB1–USB7
text stays in `peripherals.md` as the UHCI design; do not implement both
stacks. If a later agent wants UHCI under QEMU, that is a different product
ask than "sit at a Ryzen laptop".

**Not a full USB stack.** No hubs, no bulk, no isochronous, no mass storage,
no device mode. USB2 is one HID boot-protocol keyboard report into the
existing queue. That is the whole of the reach this document claims.

---

## 0. Why xHCI now, and why USB0 is a real exit

`peripherals.md` §0 is still true of the *QEMU default machine*: `-M pc` and
`-M q35` expose **no** class `0x0C03`. USB appears only when the harness
asks. That is the inverse of the e1000 vacuity trap (`net-e1000.md`): a
criterion that needs a USB line fails with no driver, and adding `-device`
without a device-absent control proves nothing.

Two facts have changed since that ranking was written:

1. **The product ask is a laptop.** `portable-hardware.md` §6.3: "On hardware
   that came up through UEFI with no legacy emulation there may be no PS/2
   controller at all; the real input path there is USB HID." Some firmware
   still emulates an 8042. **Do not rely on it.**
2. **Finding a PCI function is already a binary exit.** N0 finds the e1000
   (ADR-0058). G0 finds VirtIO-GPU (ADR-0059). Neither programs the device.
   USB0 is the same shape: walk bus 0 for an xHCI function, print what QEMU
   already knows, or print `USB NONE`. That is a real exit. It is not a
   stack.

**UHCI remains cheaper on `-M pc,usb=on`.** 32 I/O ports, no MMIO, no
64-bit BAR (`peripherals.md` §1.2). It does not exist on a modern laptop
and it does not port to AArch64 without an I/O-window abstraction
(`peripherals.md` §1.3). The laptop path pays xHCI's cost because the
cheap controller is the wrong controller.

**VirtIO-input and serial remain cheaper under QEMU** (`peripherals.md`
§2.6, `arm64-port.md`). Maximum reach is **PS/2 OR USB HID OR serial** —
three producers, one character stream. USB HID is the one that works on
metal without an 8042 and without a VirtIO transport.

---

## 1. How this coexists with PS/2

QEMU's `-M pc` always has an i8042. Adding
`-device qemu-xhci,id=xhci -device usb-kbd` adds a **second** keyboard; it
does not remove the first. A real laptop often has **only** USB.

| machine | PS/2 (8042) | xHCI + HID kbd | serial |
|---|---|---|---|
| QEMU `-M pc` (default) | present (SeaBIOS) | absent unless `-device` | COM1, every harness |
| QEMU `-M pc` + `qemu-xhci` + `usb-kbd` | still present | present | COM1 |
| QEMU `-M virt` | **none** (measured, `peripherals.md` A8) | only if `-device qemu-xhci` | PL011 |
| UEFI laptop, no legacy CSM | often **none** (GAP-0055 item 5) | the board's xHCI | if a UART exists |

**Fallback.** If the walk finds no xHCI function, print `USB NONE` and
leave the 8042 alone. `kbdInit` / `kbdHandle` / `kbdq` do not change.
USB0's init is a no-op that prints nothing — the same silence N0 and G0
owe `m1-interrupts`' 544-byte golden.

**Neither path disables the other.** USB2 enqueues into the **same**
`kbdq` IRQ1 already produces (ADR-0054). Two producers, one ring, one
consumer (`kbdqDrainToShell` / syscall 24). A boot that has both can
type from either. A boot that has only PS/2 is today's machine. A boot
that has only USB (metal, or `-M virt`) is why this ladder exists.

**Maximum reach = PS/2 OR USB HID OR serial.** Serial already reaches the
shell (B1, IRQ4). USB does not replace it. A GOP laptop with no HID and
no 8042 is still a picture plus COM1 (`portable-hardware.md` §6.3).

**QEMU `send-key` is not a USB proof, and with `usb-kbd` it is not a
PS/2 proof either.** Measured on QEMU 11.0.0: with only `qemu-xhci`
attached, QMP `send-key` / `input-send-event` reach the 8042 and the
shell types. Add `-device usb-kbd` and **both** injections go to the
USB HID device; the 8042 sees nothing and the serial capture stays at
`M1 END`. USB0's typing boot therefore attaches the controller only.
USB2 must inject a USB report (or compile the 8042 out) — `send-key`
will not prove the new path while both keyboards exist.

---

## 2. The queue encoding — scancode, not HID usage

`kbdq` stores a packed word (ADR-0054): make-scancode in bits 0–7, break
in bit 8, `0xE0`-extended in bit 9. The shell consumer indexes
`kbdSet1Ascii`. Syscall 24 returns that word. `d2-input` asserts the
set-1 sequence.

A HID boot-protocol keyboard report is eight bytes **[spec]**:

```
  [0]  modifier bitmap (LCtrl, LShift, LAlt, LGUI, RCtrl, …)
  [1]  reserved
  [2..7]  up to six simultaneous HID usage IDs (Keyboard/Keypad page)
```

HID usage `0x04` is `a`. Set-1 make for `a` is `0x1E`. They are different
numbers. Enqueueing the usage as if it were a scancode would make the
shell type the wrong character, and a ring-3 program that already speaks
syscall 24 would see a new encoding with no flag.

**USB2 translates HID usage → set-1 scancode, then `kbdqPush`.** Why:

1. **One queue, one encoding.** `display-protocol.md` §4.2 item 5 forbids
   two input paths that disagree. The USB producer must speak the language
   the PS/2 producer already speaks.
2. **The consumer is already written.** Translation, break-skip, and the
   "command is running" guard live in `kbdqDrainToShell`. A second table
   at every consumer is the worse seam.
3. **HID usage is the *wire* format.** Keeping it would be honest about
   the device and dishonest about every existing reader of the ring.

Modifiers: HID puts them in byte 0; set-1 has dedicated make/break codes
(`0x2A` left shift, …). USB2 synthesises those edges from the modifier
bitmap delta. That is USB2, not USB0.

---

## 3. The ladder

Each rung has a binary exit and a negative control. No `xp` of a device
BAR (`README.md`'s trap; `peripherals.md` §7). BAR *addresses* may come
from QMP `query-pci` / monitor `info pci`.

**Poll-only through USB2.** xHCI MSI/IRQ is a later rung. The PIC-mask
history is ADR-0042; this ladder does not unmask a new line.

**No last `.bss`.** USB0 donates nothing. USB1 may print from locals.
USB2 keeps previous-report state in `usbFeed` locals. A `@bss` between
`kbdq` and `wmevent` would break d2-input's abutment. D7 owns last
place (ADR-0033 §6.4). Stealing that slot is a fail. USB3's live
shadow, if it needs one, sits **before** `kbdq.dart`.

**`usb` is not in `help`.** `shellStrHelp` is 2511 bytes and lives in
byte-exact goldens (GAP-0105, GAP-0115). Same rule as `nic`, `virtgpu`,
`mouse`.

**Do not change `pci.dart`'s class-name table.** It already maps `0C/03`
→ `"usb"`. The table is 20 × 16 = 320 bytes; `m5-pci` asserts that
product. USB0 walks with `pciRead32` and does not add a record.

---

### USB0 — find xHCI on PCI

**Implemented.** `core/kernel/usb.dart`.

Walk bus 0, function 0 of each slot (the same walk `pciFindByClass` and
N0 use). Match class `0x0C` / subclass `0x03` / **prog-IF `0x30`**
(xHCI **[spec]**). UHCI is `00`, OHCI `10`, EHCI `20` — a match on class
alone would claim a PIIX3 UHCI (`-M pc,usb=on`) as xHCI. Print:

```
USB XHCI <bus>:<dev>.<fn> <vend>:<dev> 0C/03/30
```

or `USB NONE` if nothing answered. No BAR read, no MMIO, no config write,
no `@bss`. `usbInit` is a no-op that prints nothing.

*Binary:* harness boots
`qemu-system-x86_64 -kernel … -device qemu-xhci,id=xhci`,
types `usb` on the **PS/2** keyboard, captures monitor `info pci`. The
printed BDF and `vend:dev` must equal QEMU's `1b36:000d` function. The
prog-IF must be `30`. `-device usb-kbd` is omitted on this boot: QEMU
then delivers every QMP key to the USB HID device and the 8042 is
silent (§1).
*Anti-vacuity:* QEMU's own `info pci` on that boot must contain
`1b36:000d`. A kernel that printed a canned line against a machine with
no controller would otherwise pass.
*Negative control:* the same kernel on plain `-M pc` (no `-device`)
prints `USB NONE` and no `USB XHCI` line. QEMU's `info pci` on that boot
must lack `1b36:000d`.
*Coexistence:* the command was typed on PS/2 while xHCI was present.
`pci` is not re-run here; USB0 does not change `pci.dart` or
`shellStrHelp`, so `m5-pci`'s six-function listing on the default
machine is unchanged.
*Structural:* `usb.dart` has no `@bss`, is not last in the `part` list,
does not call `pciWrite32` / `port_outl` to `0xCFC`, and is not named
in `help`.

---

### USB1 — capability and operational registers

**Implemented.** `core/kernel/usb.dart`, ADR-0068,
`tests/conformance/u1-xhci/run.sh`.

Read BAR0 as a 64-bit pair (qemu-xhci is a 64-bit MMIO BAR, 16 KiB —
`peripherals.md` A4). Refuse a non-zero upper dword (identity map stops
at 4 GiB; same refusal as G0). Capability registers sit at BAR0+0
**[spec]**:

| offset | field | what USB1 prints |
|---|---|---|
| `0x00` | `CAPLENGTH` (byte) | the operational-register offset |
| `0x02` | `HCIVERSION` | BCD |
| `0x04` | `HCSPARAMS1` | max slots, max interrupters, **max ports** |
| `0x14` | `DBOFF` | doorbell offset |
| `0x18` | `RTSOFF` | runtime-register offset |

Operational registers sit at `BAR0 + CAPLENGTH`. Print `USBCMD` and
`USBSTS` as found. **Do not set Run/Stop. Do not reset.** A boot-time
xHCI reset with a live `usb-kbd` is a later rung and would be a
coexistence bug if it wedged the controller.

Print, after the USB0 device line:

```
USB BAR <addr> CAPLENGTH <off> HCIVERSION <bcd> SLOTS <n> INTRS <n> PORTS <n>
USB DBOFF <off> RTSOFF <off> USBCMD <word> USBSTS <word>
```

*Binary:* printed `CAPLENGTH`, `HCIVERSION`, max ports, `DBOFF`,
`RTSOFF` are consistent with each other (operational base = BAR +
`CAPLENGTH`; doorbell and runtime offsets land inside the 16 KiB BAR
QEMU reported). Printed BAR equals QEMU `info pci` BAR0.
`HCIVERSION` is a documented xHCI BCD (`0100` / `0110` / `0120`), not
`0xFFFF`. `USBCMD` Run/Stop is still clear.
*Anti-vacuity:* `CAPLENGTH` of 0 or a doorbell offset of 0 is a fail.
Printed `PORTS` must equal the harness `p2+p3` on a non-default
attach (`p2=2,p3=3`). A canned default `08` fails.
*Negative control:* no xHCI → `USB NONE`, and no capability line.
*Structural:* still no `pciWrite32`. Still poll-only. Still no last
`.bss`. `u0-xhci` still passes: the device line is unchanged.

---

### USB2 — one HID boot-protocol report into `kbdq`

**Implemented.** `core/kernel/usb.dart`, ADR-0073,
`tests/conformance/u2-hid/run.sh`. The transfer-ring bring-up this
document does **not** pretend is small — port reset, address device,
one control transfer (`GET_DESCRIPTOR` / `SET_ADDRESS` /
`SET_CONFIGURATION` / `SET_PROTOCOL(0)`), one interrupt endpoint,
one 8-byte report on the wire — is **USB3**. USB2 is the *upper*
half: translate and enqueue.

The **test seam** is `usb feed <hex>`, same shape as `mouse feed`,
labelled as one. Packed form is two bytes per report (modifier +
first usage). An 8-byte boot report is accepted when the argument is
a multiple of eight bytes. Previous-report state is locals inside
one command: no `@bss`, so `kbdqStore` still abuts `wmeventStore`.
`usbHidApply` is the function the transfer path must call.

Injection is **COM1, not `-device usb-kbd`.** Attaching `usb-kbd`
steals QEMU `send-key` from the 8042 (§1). u2-hid writes the command
to the serial socket. Serial does not enqueue on `kbdq` (GAP-0309);
the drain after the command types the translated character.

*Binary:* packed `0004` (usage `0x04` = `a`) produces a `kbdq` event
whose low 8 bits are set-1 `0x1E`. A second packed `0000` produces
the matching break bit. The printed dump is `USB FEED 001E 011E`.
The next prompt types `a`.
*Anti-vacuity:* a host model that treats the usage as a scancode
(`0x04` → character from `kbdSet1Ascii[0x04]`, which is `3`) must
fail both the printed event and the drain character.
*Negative control:* no `usb feed` → the ring is still only PS/2. A
boot that types bare `usb` prints `USB NONE` and does not enqueue a
synthetic key.
*Coexistence:* PS/2 IRQ1 still enqueues. USB2 does not mask IRQ1 and
does not drain the 8042. Focus is untouched (ADR-0062).

**Do not implement a full USB stack to close USB2.** The translator +
seam landed; the TRB ring is USB3. Honesty about that split is
better than a half-built host controller that prints a canned `a`.

---

## 4. What this is not

| | why it is not here |
|---|---|
| UHCI / OHCI / EHCI | `peripherals.md` §1. Wrong controller for metal |
| Hubs, bulk, isochronous, BOT/SCSI | no consumer; disk is ATA (`storage.md`) |
| USB mouse / tablet | USB2 is keyboard. Absolute pointer is VirtIO-tablet or a later HID rung |
| IRQ / MSI | poll through USB2; PIC history is ADR-0042 |
| `pciWrite32` / BME | USB0/USB1 do not DMA. USB1 is a `Volatile` load. USB2's seam does not DMA. USB3's bring-up will need the write |
| A help line | goldens |
| GOP, e1000 packets, compositor focus | other agents; this file does not touch them |
| AArch64 xHCI | A1 is proof of life (`arm64-port.md`). Same MMIO, different map. Named successor |

---

## 5. USB0, USB1, USB2 and USB3 — what landed

* `core/kernel/usb.dart` — walk, 64-bit BAR0, cap/op MMIO print,
  HID→set-1 table, modifier edges, `kbdqPush`, `usb feed`. No `@bss`.
* `core/kernel/usb3.dart` — BME, HCRST, DCBAA, command / event /
  transfer rings, port reset, Address Device, GET_DESCRIPTOR,
  SET_CONFIGURATION, SET_PROTOCOL(0), one interrupt IN, `usbHidApply`.
  No `@bss`; frames from `allocFrame()`.
* `part 'usb.dart'` after `nic.dart`, before `wmevent.dart`.
  `part 'usb3.dart'` appended after `wmevent.dart`.
* Hidden `usb` / `usb feed` / `usb hid`. `usbInit()` / `usb3Init()` silent.
* `tests/conformance/u0-xhci/run.sh`, `u1-xhci/run.sh`, `u2-hid/run.sh`,
  `u3-xhci/run.sh`.
* ADR-0068, ADR-0073, ADR-0085.

**Injection method (USB2):** COM1 `usb feed 0004 0000`. Not
`-device usb-kbd`. Not QMP `send-key` of `a`.

**Injection method (USB3):** COM1 `usb hid`, then QMP `down:a` after
`USB HID WAIT`. This harness attaches `qemu-xhci` + `usb-kbd`. Do
not copy that device line onto an 8042 harness.

---

## 6. Leftover after USB3 — metal and a resident keyboard

* Distinguishing QEMU `send-key` (8042) from a USB report when both
  keyboards exist. Measured: attaching `usb-kbd` makes `send-key` and
  `input-send-event` miss the 8042 entirely. USB2 therefore injects
  through COM1. USB3's own harness may attach `usb-kbd`; no 8042
  harness may.
* Metal: a real xHCI is not `1b36:000d`. USB0 matches **prog-IF 0x30**,
  so a laptop Intel/AMD controller should print `USB XHCI` with a
  different vendor:device. That is unverified.
* `-M virt` / AArch64: no 8042; USB0's walk is PCI and would work if
  the A64 kernel had `pciRead32`. It does not yet. The translator
  itself is architecture-free.
* Six-key rollover, HID mouse/tablet, xHCI MSI/IRQ. A usable USB
  keyboard at the idle prompt needs a resident poll or an IRQ
  (`display-protocol.md` §4.4). USB3 is one command, one report.
  **ADR-0138 (`hid-sess/`) closed the session door:** focused
  `kbdevent` sees COM1 `usb feed`, and `usb mfeed` moves the
  pointer through `usbHidMouseApply`. Resident poll is still open.
* Live previous-report state across commands, if a later rung polls
  from `procTick`, still needs a small `@bss` that does not sit
  between `kbdqStore` and `wmeventStore`. USB3 used locals.
