# ADR-0042 — The PS/2 mouse, IRQ12, and the PIC mask that had to be fixed first

**Status:** accepted
**Milestone:** D1 (`docs/design/display-protocol.md` §6, "A mouse exists")
**Supersedes:** nothing. **Depends on:** ADR-0002 (the IDT), ADR-0009 (the framebuffer's PCI hole
map), ADR-0021 (`@bss` mutable statics), ADR-0031 §4.3 rule 5 (the ioctl bounce buffer stays last in
`.bss`).

---

## 1. What this decides

This kernel now has a pointing device. `core/kernel/mouse.dart` drives a PS/2 mouse on the 8042's
**auxiliary** port: it enables the port, modifies exactly two bits of the controller's configuration
byte, resets the device, performs the IntelliMouse knock and **asks the device what it is**, enables
reporting, and unmasks IRQ12 — which is the first line this kernel has ever taken from the slave
8259. A packet state machine decodes three- or four-byte packets with 9-bit signed deltas, an
explicit resynchronisation rule and an overflow discard; the accumulated position, buttons and wheel
are readable from ring 3 through syscall 20; and an arrow can be drawn on the 800×600 framebuffer by
the `mouse` command.

Six decisions inside that are not obvious, and one of them is a change to a file the mouse does not
own.

---

## 2. The scroll wheel is DETECTED. It is not assumed, and the report says so.

The IntelliMouse extension is entered by a "magic knock" — set sample rate 200, then 100, then 80 —
after which a device that has a wheel sends **four**-byte packets and one that does not still sends
three. **The knock itself tells you nothing**: a plain PS/2 mouse accepts all three sample rates and
stays a plain PS/2 mouse. The only way to know is to send 0xF2 afterwards and read the identity byte
back.

So `mouseKnockForWheel()` knocks and then asks, `mouseEnable()` sets the packet size to 4 **if and
only if** the answer is 0x03, and `mouseWordId` keeps whatever the answer actually was. The `mouse`
command prints `SIZE 4 ID 003` — the conclusion and the evidence for it, side by side — because a
report that printed only the conclusion would be indistinguishable from one that had assumed it.

**The identity is printed in THREE hex digits and the third one is load-bearing.** `mouseRead`
answers `0x100` when the controller did not reply at all, and that is what is stored when the device
never said what it was. In two digits that comes out `00` — indistinguishable from a plain PS/2 mouse
that answered `0x00` — so a machine with no mouse would have reported `SIZE 3 ID 00`, which is a
claim about a device rather than an admission that none answered. `ID 100` says the second thing.

`d1-mouse`'s harness makes that structural as well as behavioural: the four-byte size is written at
**exactly one site** in the whole file, and that site is inside the `id == mouseIdWheel` arm.

**Observed, on QEMU 11.0.0's emulated device: the knock succeeded and the device answered 0x03.** The
harness asserts four-byte packets *because the transcript says the device claimed them*, and on a
device that answered anything else the derived packet lines would be three bytes wide and the harness
would fail rather than quietly assert the wrong shape.

---

## 3. The PIC mask stops being a whole byte, and this was a prerequisite rather than a tidy-up

`docs/design/display-protocol.md` §4.4 found, while costing this milestone, that **every PIC mask
write in this kernel was a literal whole byte**. `picUnmaskKeyboardOnly` wrote `0xFD` to the master
and `0xFF` to the slave; `picUnmaskTimerAndKeyboard` wrote `0xFC` and `0xFF`. Each of them therefore
**re-masked every line it did not name**, including the whole slave PIC.

The consequence for a mouse is exact and silent: unmask IRQ12 at boot, and it works until the next
`ticks` command — which calls `picUnmaskTimerAndKeyboard` and then `picUnmaskKeyboardOnly` — after
which the mouse is dead for the rest of the boot with no diagnostic anywhere. The same is true of a
NIC, a disk interrupt, and every future interrupt-driven device. That document calls it a
cross-cutting blocker and it is right.

**The fix is not a shadow copy in `.bss`.** The 8259's mask register is *readable*: an `in` from the
data port returns the current OCW1. So `picUnmaskLine`/`picMaskLine` read the chip, change one bit,
and write it back. Nothing to keep in sync, no ordering hazard with `.bss` not being zeroed, and no
way for a shadow to drift from the hardware. Two whole-byte writes remain and both are legitimate:
`picRemap`, which has just re-initialised both chips and is stating a whole mask, and `picMaskAll`,
whose entire meaning is "everything". The harness asserts that those two are the only ones left.

**Nothing observable changed for anything that existed before.** With no mouse present,
`picUnmaskKeyboardOnly` still takes the master from 0xFE to 0xFD and `picUnmaskTimerAndKeyboard`
still takes it to 0xFC. Twenty-four harnesses' goldens are untouched.

`m18-preempt`'s assertions were **not** moved: they count call sites of
`picUnmaskTimerAndKeyboard()` and `procSessionTimerOff()` in `proc.dart`, and both functions still
exist with the same names and the same number of callers. §4.4 predicted "one moved assertion in
`m18-preempt`"; that turned out not to be necessary, because the consolidation happened *inside* the
two functions rather than by replacing them.

**And it is asserted from outside the kernel.** `d1-mouse` runs `ticks` **before** every pointer
event, so all twelve packets arrive after it, and then reads QEMU's own `info pic` at the end of the
boot and requires the master's bits 1 and 2 and the slave's bit 4 to be clear. That is the emulator's
device model answering, not the kernel's own report — the same independence `m5-pci` gets from
`info pci`.

---

## 4. The framing rule, and what resynchronisation can honestly claim

A PS/2 packet has no length, no terminator and no checksum. The only structure on the wire is that
**bit 3 of byte 0 is always one**. So when the decoder is expecting a first byte and receives one
without it, that byte cannot be a first byte, the stream is offset, and the only safe move is to
**discard the byte and stay where it is** — consuming it as a first byte would keep the offset
forever.

What this buys, stated as the weaker claim it is: discarding one byte at a time realigns a stream
offset by one within one packet and by two within two, which is every offset a three- or four-byte
packet can have. **It is not infallible and this driver does not pretend it is.** A byte 1 or byte 2
whose value happens to have bit 3 set is accepted as a first byte and produces **one wrong report**
before the next misaligned byte fails the test. There is no more information on the wire to use.

`d1-mouse` asserts exactly that sequence, and it does it with the **real device**, not a simulation
of one: it feeds a single byte through `mouse feed`, which leaves the state machine expecting byte 1,
and then injects a genuine QMP pointer motion. The transcript then contains, in order, one packet
assembled out of the wrong bytes, one `MOUSE SYNC 00` discarding the real packet's Z byte, and then a
correct packet from the next motion — all of it derived on the host beforehand by a model of the byte
stream, not read off a previous run.

Every discard is counted and printed, so a stream that is quietly resynchronising forty times a
second is visible rather than merely producing a pointer that stutters.

---

## 5. `mouse feed` is a test seam and it is labelled as one

There is no way to ask a PS/2 mouse to misalign its own stream, to overflow its own delta on demand,
or to send a positive 9-bit delta larger than 127 — QEMU clamps each axis to ±127 per packet and
sends more packets until the motion drains. Those are exactly the inputs that distinguish a correct
decoder from a plausible one:

* a byte that cannot be a first byte (the framing rule);
* a packet with an overflow flag set (which must be **discarded**, not clamped: the byte that arrived
  is the low eight bits of something larger and there is no way to recover what);
* **`08 C8 C8 00`** — a *positive* 200 whose byte 1 has its own high bit set. A driver that
  sign-extended from byte 1 rather than from byte 0's ninth bit reads that as −56 and moves the
  pointer left. This is the single easiest thing to get wrong in the protocol and the only input that
  tells the two decoders apart.

So `shellMouseFeed` pushes bytes straight into `mouseByte` — **the same function IRQ12 calls, with
the same state**. It bypasses nothing: a decoder that only worked when fed by hand would still be the
decoder the interrupt uses. The harness asserts the correct final position is present **and** that
the position a byte-1 sign extension would produce is absent, and it checks before it asserts the
absence that the two are different numbers.

---

## 6. The cursor is drawn by a command, not by the interrupt handler

Blitting a cursor that *tracks* needs the pixels under the previous position saved and restored.
There is **no allocation in an interrupt handler** — the compiler forbids it and this file does not
work around it — and a fixed save buffer would be 192 more words of `.bss` for a feature no
compositor will want, because a compositor composites rather than blitting a cursor over a console.

So the handler updates **numbers** and the `mouse` command draws **pixels**. GAP-0251 records the
cost: the pointer does not track live, and each `mouse` leaves an arrow behind at the last position.

The arrow is two `@rodata` bitmaps — a black outline and a white interior — because an arrow with no
outline is invisible over light content and a solid black one is invisible over dark content; with
both, exactly one of the two colours always contrasts.

**`MOUSE DRAW` prints the address of row 8 of the arrow it just drew**, and that is there for the
harness. `m5-pci` established the rule that pixels this kernel draws are asserted by reading them
back out of guest physical memory at an address the *kernel* reported, never one the harness assumed,
because the framebuffer's base is a fact about SeaBIOS's BAR allocator. D1 has one more variable —
*where the cursor is* is the thing under test — so the kernel names the address and the harness
independently derives the same address from the base the kernel reported plus the offset the injected
deltas imply, and requires the two to be equal before dumping twelve pixels there. Row 8 is
`edge, seven fill, edge` followed by three untouched pixels: three distinct colours in one read.

---

## 7. Syscall 20 returns one packed register, and what that costs

`mouse` returns `x | y<<16 | buttons<<32 | packets<<40`.

**One register rather than a pointer to a struct**, deliberately: a struct means validating a ring-3
address, and `chan.dart`'s fourteen refusal codes are the evidence for how much work that honestly
is. Sixteen bits is enough for a coordinate on a screen this kernel can actually set (800×600).

**The packet counter is in there so that "nothing has moved" and "the mouse is not working" are
different values to a ring-3 program.** A position of (0, 0) with no buttons is a legitimate state
and is also exactly what a caller would see from a kernel that had never decoded a packet at all.

**It requires no process slot and refuses nobody**, which puts it with `who` rather than with `yield`
and `sbrk`. That is not laziness: it reads global device state and writes nothing, so there is no
per-caller resource to look up and no owner to invent. Every other syscall that refuses a caller does
so because it would otherwise have to invent a heap, a descriptor table or an endpoint.

What that costs is stated rather than hidden: **every ring-3 program can see the pointer**, including
one that should not. There is no notion of input focus in this kernel and this syscall is not the
place to invent one — `docs/design/display-protocol.md` §4.3 is, and it says the routing decision
belongs to a compositor. GAP-0253.

When the pointer gets a real ring-3 interface it will be an `ioctl` on a device node or a `read` of
an event queue (that document's D2), not a wider version of this. GAP-0252.

---

## 8. What was rejected

**A shadow PIC mask in `.bss`.** Rejected in favour of reading the chip (§3). A shadow is a second
copy of a fact the hardware already holds, it has to be initialised before anything reads it in a
kernel that does not zero `.bss`, and it can drift.

**Enabling the mouse from a shell command instead of at boot.** It would have kept the blast radius
to one harness. Rejected: a mouse is a boot device, and putting the initialisation in `m2Enter()`
beside `kbdInit()` makes **all twenty-five harnesses** the regression test for "the mouse did not
break the keyboard" — which is the failure this milestone was most likely to cause and the one
hardest to notice from a single test.

**Drawing the cursor from IRQ12.** §6.

**A help-text line for the `mouse` command.** `shellStrHelp` is 2224 bytes and five byte-exact serial
goldens plus `m3-shell`'s screen golden contain it verbatim (GAP-0105, GAP-0115). M18 added three
commands with no help line and M20 added none at all, for this reason.

**And there is a second reason that only applies right now, which is worth recording because it is
about sequencing rather than about cost.** A concurrent branch is settling GAP-0142 and takes
`shellStrHelp` to 2511 bytes, regenerating exactly those six goldens. Adding two lines here would
have collided with that work in six goldens and one pinned constant, and the merge would have had to
choose between two regenerations of the same files. GAP-0254 records what the absence costs — the
command is undiscoverable from the shell itself — and says plainly that closing it is a two-line
change to sequence AFTER that branch lands, not beside it.

`d1-mouse` therefore pins the byte count AND, separately, asserts the kernel's `.rodata` carries no
help-shaped `  mouse ` line. The first is a pin that moves at the merge; the second is the claim D1
is actually making and it does not move.

**A `SYS_MOUSE` in `oslibc.h`.** Rejected for the reason §7 gives — a public libc binding to a packed
`u64` whose coordinate fields stop being wide enough at the first mode above 800×600 is an interface
this project would have to keep. `d1-mouse`'s program declares the number itself, exactly as
`m20-ipc`'s declares its three, and `docs/syscall-registry.md` lists both places.

**Making `mouseHandle` hand a non-auxiliary byte to `kbdHandle`.** A byte waiting on IRQ12 without
the 8042's AUX status bit set is a keyboard byte on the wrong line. It is read anyway — leaving it
would stop the controller raising *any* further interrupt, keyboard included — and then **counted as
a stray and dropped**, because feeding a scancode to the packet state machine is how a keystroke
becomes pointer motion. The count is reported by `mouse`, and the harness asserts it is zero.

---

## 9. What adding a kernel file costs, measured

`mouse.dart` made the kernel image **three 4KiB pages** bigger. Nothing about the mouse appears in
any earlier milestone's transcript, but **23 goldens across 12 harnesses moved anyway** — 376 lines —
because those transcripts print absolute addresses: section boundaries, kernel object addresses, the
frame-bitmap base, and every physical frame the allocator hands out after the image. `PMM FREE`
dropped by exactly three and `PMM USED` rose by exactly three, which is exactly the three pages.

**The regeneration was gated rather than trusted.** Regenerating a golden from a wrong kernel
enshrines the wrong output; `m11-proc`'s own comment says so. So every removed/added line pair had
every run of two or more hex digits masked and was required to be **identical afterwards**. All 376
lines passed, so every change is an address or a count and none is a change of meaning. Anything that
failed that gate would have been read by a human before being accepted.

Two harnesses needed more than `--regen`. `m19-argv` carries a `.bss` grand-total assertion whose
shape no other harness shares, and D1's first pass missed it — found by the regeneration failing, not
by inspection. `m7-frames` fails on a stale DCDart pin that predates this branch (GAP-0256) four
seconds in, before its own boot, so its goldens were regenerated through a temporary copy with only
that one assertion removed; with the pin bypassed it passes in full, which is independent evidence
that the pin is the only thing wrong with it.

GAP-0257 records the whole cost and what would close it — printing addresses relative to a base the
same transcript reports, which is what `d1-mouse` already does for the cursor and why its own golden
does not move when the image does.

---

## 10. What this milestone does not do

* **No focus, no event queue, no enter/leave.** `display-protocol.md` D2 is the milestone that adds a
  queue and it is explicitly sequenced after `argv`. GAP-0253.
* **No absolute coordinates.** A PS/2 mouse reports relative motion. `docs/design/peripherals.md`
  §2.6 is right that a `virtio-tablet-pci` would give absolute coordinates on both x86 and `-M virt`;
  it is also right that D1 is the correct first mouse *on x86*, and that D1 produces nothing at all
  on `-M virt`, where there is no i8042.
* **No acceleration, no scaling, no sample-rate policy.** The device is set to its own defaults
  (`0xF6`) so that two machines report the same thing.
* **The cursor does not track.** §6, GAP-0251.
* **No real hardware.** QEMU's 8042 and QEMU's IMPS/2 mouse. GAP-0055 already records that this
  kernel assumes an 8042 exists at all; on a UEFI machine with no legacy emulation, `mouseEnable`
  runs out its bounded waits, records what it managed in `INIT`, and the machine carries on with no
  pointer — which is strictly better than the keyboard's behaviour in the same situation, not equal
  to it.
