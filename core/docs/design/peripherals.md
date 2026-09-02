# Peripherals — USB and audio

**Status: PROPOSAL. Nothing here is built, and most of it should not be built for a long time.**
`README.md`'s closing paragraph lists what the corpus does not cover; **USB** and **audio** are two of
those names. This document covers both, to a brief that says *ranking honestly matters more than
completeness*. So the ranking is §0, before any design.

**Everything below labelled "measured" was measured on this host**, `qemu-system-x86_64` /
`qemu-system-aarch64` **11.0.0** — the same QEMU the harnesses run and the same one
`time-and-power.md` measured against. Facts taken from a specification rather than from a run are
labelled **[spec]**, for the reason that document gives: this repo has been wrong about hardware
before, and it was always the unmeasured half. Appendix A reproduces every measurement.

**Milestone prefixes are `USB1..` and `AUD1..`, deliberately long.** `README.md` records that
`namespace.md`, `net-e1000.md` and `net-stack.md` all used `N`, so "N1" names three milestones. Every
one- and two-letter prefix in the corpus is already taken (`B D G L N P S T X`, measured). Three
letters costs nothing and cannot collide.

---

## 0. The ranking, first

*("lines of code" means non-comment, non-blank lines; this repo writes roughly 2.2–3.7 total lines per code line — §0.3.)*

| rank | item | cost | build it? |
|---|---|---|---|
| 1 | **AC97 output** (`-device AC97`) | ~300–400 lines of code, **pure port I/O, no MMIO, no BAR mapping**, one DMA descriptor list in one `allocFrame` page | **Yes — it is the cheapest real device left in the machine**, and its exit criterion is a byte count on a file the host writes |
| 2 | **UHCI + control transfers + enumeration** (`-M pc,usb=on`) | ~600–900 lines of code (~1200+ with HID), **pure port I/O on x86**, one 4 KiB frame list | **Yes, eventually** — but only after the PIC-mask fix, and only if input on ARM64 is not solved more cheaply |
| 3 | **USB HID boot-protocol keyboard** | +~200 lines of code on top of USB5 | **Only when there is a reason** — the PS/2 keyboard works and `-M virt` has a cheaper answer (§2.6) |
| 4 | **Intel HDA** | ~1200–2000 lines of code, MMIO BARs, CORB/RIRB, codec-graph walk | **No.** It buys nothing AC97 does not, at 4× the size |
| 5 | **USB mass storage (BOT/SCSI)** | +~800 lines of code on top of a working bulk-transfer stack | **No.** `storage.md` already owns the disk, over ATA and then AHCI |
| 6 | **xHCI** | ~2500–4000 lines of code, five DMA structure types, 64-byte contexts, scratchpad buffers | **No — not for years.** §1.2 |
| 7 | **EHCI, OHCI, USB hubs, isochronous transfers, USB audio, virtio-sound** | each ≥ the item above it | **No.** §8 lists each with a reason |

**The one-sentence version: build AC97, do not build USB yet, and never build HDA or xHCI on the
strength of an argument that starts "modern hardware has".** This machine is QEMU. What QEMU
presents, measured, is §0.1.

**And the finding that reframes both subsystems:**

> **QEMU's default x86 machines present no USB controller and no audio device at all.** Measured:
> `-M pc` and `-M q35` each expose exactly six PCI functions, and **not one of them is class `0x0C03`
> or class `0x04xx`**. USB appears only with `-M pc,usb=on` (or an explicit `-device`); audio appears
> only with an explicit `-device` **and** an `-audiodev`.

That is the opposite of the situation `net-e1000.md` found, and it is worth stating in exactly those
terms. **The NIC's trap was that the device does something before the guest runs, so a naive
"non-empty capture" criterion passes with no driver.** USB and audio have the *inverse* property:
**the device is not there at all unless the harness asks for it, so a naive criterion fails with no
driver — and a harness author who "fixes" that by adding the device without checking has learned
nothing.** Both are vacuity traps; they just point in opposite directions.

---

## 0.1 What QEMU actually presents — measured

`query-pci` over QMP, machine `pc` (the harnesses' machine), 128 MiB, no extra devices:

```
00:00.0 8086:1237 class=0x0600 Host bridge
00:01.0 8086:7000 class=0x0601 ISA bridge
00:01.1 8086:7010 class=0x0101 IDE controller       BAR4 io 16
00:01.3 8086:7113 class=0x0680 Bridge
00:02.0 1234:1111 class=0x0300 VGA controller
00:03.0 8086:100e class=0x0200 Ethernet controller
```

**Six functions, no `00:01.2`.** On a real PIIX3, `00:01.2` is the UHCI controller; QEMU only
instantiates it when the machine property `usb=on` is set.

`-M q35` is the same story with different numbers: host bridge, VGA, e1000e, ISA bridge, AHCI, SMBus
— **no USB, no audio**.

**`-usb` as a bare option is gone in QEMU 11.0.0.** Measured: `-M pc -usb` fails with
`invalid option`. The spelling that works is **`-M pc,usb=on`**. A harness copied from an older wiki
page will not start at all, which is at least a loud failure.

### What each controller costs to *ask for*, and what it then looks like

Measured with QMP `query-pci`, so the class codes and BAR shapes are the device's own, not a wiki's:

| `-device` | id | class | BAR0/4 | note |
|---|---|---|---|---|
| `-M pc,usb=on` → PIIX3 UHCI at `00:01.2` | `8086:7020` | `0x0C03` | **BAR4: I/O, 32 bytes** | **the whole register file is 32 I/O ports** |
| `pci-ohci` | `106b:003f` | `0x0C03` | MMIO, 256 B | |
| `usb-ehci` | `8086:24cd` | `0x0C03` | MMIO, 4096 B | exactly one page |
| `qemu-xhci` | `1b36:000d` | `0x0C03` | MMIO, 16384 B | 64-bit BAR |
| `AC97` | `8086:2415` | `0x0401` | **BAR0: I/O 1024 B, BAR1: I/O 256 B** | **no MMIO at all** |
| `intel-hda` | `8086:2668` | `0x0403` | MMIO, 16384 B | needs a codec device too |

**`-M q35,usb=on` gives four controllers, not one** (measured): three ICH9 UHCI companions
(`8086:2934/2935/2936`) and one EHCI (`8086:293a`). A driver that assumes "the USB controller" would
find several and have to choose. `-M pc,usb=on` gives exactly one. That alone is a reason for any
first USB harness to use `pc`, which is also the machine the other twenty harnesses use.

### The kernel already prints "usb" and does not print "audio"

`pci.dart`'s `pciClassNames` table has an entry for class `0x0C` subclass `0x03` — the three bytes
`u8(0x75), u8(0x73), u8(0x62)`, `"usb"`. It has **no** entry for `0x04/0x01` or `0x04/0x03`; the only
class-4 entry is the wildcard `04/FF` `"multimedia"`.

So, today, with no new code: `-M pc,usb=on` makes `pci` print a line ending `0C/03/00 H00 usb`, and
`-device AC97` makes it print `04/01/00 H00 multimedia`. **That is a free first milestone for both
subsystems and it is the correct first milestone**, because it is the one that proves the harness
actually instantiated the device before any driver exists to blame.

---

## 0.2 What this kernel has today toward either — measured, by absence

Grepped across `core/kernel/` and `core/boot/`:

* **No BAR is ever read.** `pci.dart` reads registers `0x00`, `0x08`, `0x0C` and `0x18` and nothing
  else. `pciRegBar0` does not exist as a constant, and no code reads offset `0x10`. **Every device
  this kernel has ever driven was at a compiled-in address** — that is `pci.dart`'s own opening
  paragraph, and it is still true after M19.
* **No `pciWrite32`.** Configuration space is read-only. `README.md` lists this in Tier 1 as "smallest
  item with the widest unblock"; USB and audio are two more things behind it.
* **No bus-master enable, anywhere.** Per `README.md`'s resolution of the three-way BME disagreement:
  **BME is set only where an option ROM ran.** Nothing drives a UHCI or an AC97 during POST, so both
  arrive with `PCI_COMMAND` bit 2 **clear**, exactly like the VirtIO devices the GPU specialist
  measured at `cmd=0x0103`. **Both drivers must set it themselves, and cannot until `pciWrite32`
  exists.**
* **No MMIO device access of any kind** except the framebuffer.
* **Driver state is cheap now, and this corrects a belief several older headers still state.**
  `pci.dart` and `ata.dart` both say the kernel has nowhere to keep anything (GAP-0053), and
  `ata.dart`'s header explains at length why it hexdumps each word instead of buffering a sector.
  **That expired at M17.** ADR-0021 closed GAP-0053, moved **13952 of 14048 bytes** out of
  `core/boot/kdata.S`, and gave the language `@bss` mutable statics — `args.dart:312`, `elf.dart:846`,
  `fb.dart:251`, `fat.dart` all declare them today. **So a USB or audio driver may declare its own
  state block directly, with no donated `.bss`, no `@extern` accessor and no storage seam.** This is
  the same correction `README.md` makes about the allocator ("it expired at M7"), one milestone
  later and for a different constraint. **`stale-comments.md` §D already catalogues every header that
  still says otherwise** — including `pci.dart:53-60` and `ata.dart:36-42` — so this is a citation,
  not a rediscovery.
* **Nothing blocks** (`blocking-and-threads.md`, GAP-0141). Every wait in this kernel is an
  iteration-counted spin, and `ata.dart`'s header explains why every one of them is bounded.
* **The PIC mask is written as eight whole bytes** at `keyboard.dart:173,190`, `kmain.dart:272`,
  `shell.dart:1085,1090`, `proc.dart:2006,2434`, `vga.dart:426`. `README.md` fix #1. **Any interrupt
  a USB or audio driver unmasks works until the next shell command and then stops, silently.**
* **No `int` handler arm exists for anything but IRQ0, IRQ1 and the exception vectors.**
  `hot-files.md` §3 measures `isrDispatch` as *not* hot — two subsystems in nineteen milestones — and
  concludes "leave it". A USB IRQ and an audio IRQ would be the third and fourth. That is still not
  hot; the recommendation stands.

## 0.3 The unit these estimates are in

Every line count below is given twice, because this repo's files are mostly prose. Measured:

| file | total lines | non-comment, non-blank | ratio |
|---|---|---|---|
| `ata.dart` — PIO identify + read + write + hexdump + 3 shell commands | 1251 | 554 | 2.26× |
| `pci.dart` — full bus walk with bridge recursion | 500 | 203 | 2.46× |
| `fb.dart` | 854 | 381 | 2.24× |
| `keyboard.dart` | 268 | 72 | 3.72× |

**So "400 lines of code" means "roughly 900–1000 lines of file, written the way this repo writes
files."** Estimates below give the code figure and say so. They are **estimates**, not measurements,
and they are the least reliable numbers in this document.

The other yardstick, from `gpu.md` by way of `README.md`: **this kernel is 22,088 lines.**

---

## 1. USB — honest sizing

### 1.1 There are four host-controller interfaces and they are not a progression

They are four different hardware designs that happen to drive the same wire protocol.

| | UHCI | OHCI | EHCI | xHCI |
|---|---|---|---|---|
| speeds | low (1.5 Mb/s), full (12) | low, full | **high only** (480) | low, full, high, super |
| register access | **32 I/O ports** | 256 B MMIO | 4 KiB MMIO | 16 KiB MMIO, 64-bit BAR |
| schedule shape | 1024-entry frame list of QH/TD chains, walked by hardware every 1 ms | HCCA + ED/TD lists | periodic frame list + async QH ring | **command ring + event ring + per-endpoint transfer rings, all TRB-based** |
| DMA structures a driver must build | frame list, QH, TD | HCCA, ED, TD | frame list, QH, qTD | DCBAA, device context, input context, command ring, event ring, ERST, transfer rings, scratchpad array |
| distinct structure types | **3** | 3 | 3 | **7+** |
| device addressing | driver assigns addresses, driver owns everything | same | same | **controller owns addressing**; driver issues `Enable Slot` / `Address Device` commands and waits for completion events |
| register-width need on x86 | `inw`/`outw`/`inl`/`outl` — **`port_inw`/`port_outw`/`port_inl`/`port_outl` all already exist in `core/boot/portio.S`** (measured: four `.global`s) | MMIO | MMIO | MMIO, and some registers are 64-bit |

**xHCI is not "UHCI but newer".** It replaces the driver-drives-the-schedule model with a
command/event/completion model. Two of the three hardest things in it — the event ring with its
segment table, and the two-stage `Address Device` handshake — have no counterpart in UHCI at all.
**`gpu.md` reached a structurally identical conclusion about modesetting drivers and stated it as a
size ratio; the same ratio here is roughly 4–6×, and it is the wrong 4–6× to spend first.**

### 1.2 The realistic first target is UHCI, and the reason is not "it is old"

It is that **UHCI is the only host controller in the machine that needs nothing this kernel does not
have.**

Measured: `-M pc,usb=on` puts a PIIX3 UHCI at `00:01.2`, `8086:7020`, class `0x0C03`, **BAR4 an I/O
region of 32 bytes**. Every one of its registers is reached with `Port.inb`/`Port.outb` and the
`port_inw`/`port_outw`/`port_inl`/`port_outl` helpers `ata.dart` and `pci.dart` already use. **Zero
MMIO. Zero new BAR-mapping code. Zero new assembly. Zero new page-table work.**

Concretely, the register file **[spec]**:

```
  +0x00  USBCMD     word    run/stop, host-controller reset, global reset
  +0x02  USBSTS     word    interrupt, error interrupt, halted
  +0x04  USBINTR    word    interrupt enables      <- leave at 0 and POLL
  +0x06  FRNUM      word    current frame index, 0..1023
  +0x08  FLBASEADD  dword   frame-list base, 4 KiB aligned
  +0x0C  SOFMOD     byte
  +0x10  PORTSC1    word    connect, enable, reset, low-speed
  +0x12  PORTSC2    word
```

That is eight registers. `ata.dart` drives nine.

**And the schedule is a data structure, not a protocol.** The controller reads
`FLBASEADD[FRNUM]` once per millisecond and follows whatever chain it finds. A driver that wants a
single control transfer builds one queue head and three transfer descriptors, points **one** frame-list
entry at it, and polls the last descriptor's status word until the active bit clears. **Everything
else in the 1024-entry list can be the terminate bit.** This is the same shape of deal `ata.dart`
took and described in its header — the minimum honest thing, with the cost stated.

**The counter-argument, and it is real: UHCI cannot see a USB 2.0 high-speed device.** Full speed is
12 Mb/s. QEMU's `usb-kbd`, `usb-mouse`, `usb-tablet` and `usb-storage` all operate at full speed, so
nothing this project wants is out of reach — but a USB 3 flash drive on real hardware is, and so is
any throughput argument. **If USB is ever wanted for bandwidth rather than for input, UHCI is the
wrong controller and the work does not transfer.** Say that now rather than discover it at
milestone 6.

### 1.3 The trap inside UHCI's simplicity, and it is the ARM64 trap

**UHCI's cheapness is entirely an x86 cheapness.**

`in` and `out` are x86 instructions. AArch64 has no I/O address space at all; on `-M virt`, PCI I/O
space is a *memory window* the GPEX host bridge decodes (`virt`'s device tree places it low in the
PCI aperture), and an "I/O BAR" access is an ordinary `ldrh`/`strh` to that window plus the BAR's
offset.

So a UHCI driver written against `port_inw(base + 0x02)` **does not port to ARM64 by recompiling.**
It ports by first inventing an abstraction this kernel does not have — "read a 16-bit device register
at BAR-relative offset N" — with two implementations. That abstraction is small, it is the right
thing, and it should be built **in the first USB milestone rather than retrofitted**, because
retrofitting it means touching every register access in the file.

**The same trap applies to AC97**, whose registers are also I/O BARs (measured: BAR0 I/O 1024 B,
BAR1 I/O 256 B). It does **not** apply to EHCI, xHCI or Intel HDA, which are MMIO everywhere.

**This is the honest shape of the "USB unblocks ARM64" claim**, and it is narrower than it sounds:
the *controller* choices that are cheap on x86 are the ones whose register access does not port, and
the ones whose register access does port are the expensive controllers. Measured, all five
controllers **do** instantiate on `-M virt` (`qemu-xhci`, `nec-usb-xhci`, `usb-ehci`,
`piix3-usb-uhci`, `pci-ohci` — every one accepted), so this is not a device-availability problem. It
is an access-width problem, and it costs one abstraction.

---

## 2. What a USB stack actually needs

Six layers. Each one is useless without the one below it, which is why **a USB stack has no
half-built state that does anything** — and that is the single most important scheduling fact about
it. `ata.dart` could print a sector before there was anywhere to put one. A USB stack cannot print a
keystroke before control transfers, enumeration, descriptor parsing, endpoint setup and interrupt
transfers all work.

### 2.1 The controller

Reset it, allocate and zero the frame list, point `FLBASEADD` at it, set run. Detect port connect via
`PORTSC`, drive the port reset sequence, read the low-speed bit. **Bounded polls everywhere**, per
`ata.dart`'s rule: an unbounded wait on a device register is a silent hang with no diagnostic, and
this kernel has already decided against those.

### 2.2 Enumeration

The fixed dance **[spec]**, in order:

1. port reset; the device answers on **address 0**;
2. `GET_DESCRIPTOR(DEVICE, 8 bytes)` — the first eight bytes are all that is needed, because byte 7
   is `bMaxPacketSize0` and until you know it you cannot legally issue a longer control transfer;
3. `SET_ADDRESS(n)`; the device must be given ≥ 2 ms to take the new address;
4. `GET_DESCRIPTOR(DEVICE, 18 bytes)` at the new address;
5. `GET_DESCRIPTOR(CONFIGURATION, 9)`, read `wTotalLength`, then `GET_DESCRIPTOR(CONFIGURATION,
   wTotalLength)` — the second read is the one that returns the interface and endpoint descriptors;
6. `SET_CONFIGURATION(1)`.

**Step 5's two-read pattern is the one that bites.** The total length is not knowable in advance, and
a driver that assumes a size gets a short transfer on some devices and a babble error on others.

**A 2 ms delay is required and this kernel cannot express one.** There is no sleep, no monotonic
clock exposed to a driver, and the PIT is *masked at rest* — `time-and-power.md` §0.2 measures
`picUnmaskKeyboardOnly` leaving mask `0xFD`, timer off, as the shell's steady state. So today the
only available delay is a spin of counted iterations, whose duration is a property of the host, not
of the guest. **`time-and-power.md` §2.4's sub-tick PIT latch is the correct fix and it is already
Tier 1 in `README.md`'s queue.** Do not build a USB stack that calibrates its own delay loop.

### 2.3 Descriptors

Device, configuration, interface, endpoint, string, and the class-specific ones (HID report
descriptor, and for mass storage none). All are byte-packed little-endian structures reachable with
`Pointer<u8>` arithmetic — **no new language capability, and no struct type needed**, which is exactly
how `fat.dart` already reads directory entries.

The genuinely awkward one is the **HID report descriptor**: a nested, item-encoded bytecode that in
the general case requires a parser. **The boot protocol exists precisely to avoid it** — see §2.6.

### 2.4 Endpoints and the four transfer types

| type | used by | UHCI cost | needed for the goal? |
|---|---|---|---|
| **control** | every device, every enumeration | one QH, three TDs (setup / data / status) | **yes, first** |
| **interrupt** | HID keyboard and mouse | one QH placed in every *n*-th frame-list entry | **yes** |
| **bulk** | mass storage, usb-serial, usb-net | one QH on the async chain | only for storage |
| **isochronous** | USB audio, webcams | TDs placed directly in frame-list entries, no retry, no error recovery, **hard real-time** | **no — §8** |

**Interrupt transfers are not interrupts.** The controller polls the device every *n* frames and
writes the result into a TD; whether the *driver* learns about it via an IRQ or by re-reading the TD's
status word is a separate decision. **Poll first.** `net-e1000.md` reaches the same conclusion for the
same reason and polls for seven of its milestones — and `README.md` explains why: without MSI, every
driver after ATA is stuck polling, and the PIC-mask bug means an unmasked line dies at the next shell
command anyway.

### 2.5 Class drivers

* **HID boot protocol** — `SET_PROTOCOL(0)` puts a keyboard into a **fixed 8-byte report**: modifier
  byte, reserved byte, six keycode bytes. A mouse boot report is 3–4 bytes: buttons, dx, dy, wheel.
  **Neither requires parsing the report descriptor**, which is the whole point of the boot protocol
  and the reason it exists in the spec. This is a few hundred lines, not a few thousand.
* **Mass storage (BOT)** — Bulk-Only Transport wraps SCSI: a 31-byte CBW out, data in or out, a
  13-byte CSW in. Then a SCSI command set: `INQUIRY`, `READ CAPACITY(10)`, `READ(10)`, `WRITE(10)`,
  `TEST UNIT READY`, and `REQUEST SENSE` for every failure. **That is a second storage stack**, and
  `storage.md` already owns storage with a shorter path (AHCI). §8.

### 2.6 HID would eventually replace PS/2 — and on ARM64 there is no PS/2 to replace

**Stated plainly, because the brief asks for it plainly.**

`keyboard.dart` drives an 8042 at ports `0x60`/`0x64`. **Measured: QEMU's `-M virt` machine contains
no i8042 at all.** `info qtree` on `-M virt` lists `pl011`, `pl031`, `pl061`, `arm_gic`,
`arm-gicv2m`, `gpex-pcihost`, `virtio-mmio`, `cfi.pflash01`, `fw_cfg_mem`, `gpio-key`,
`virtio-net-pci` — and **zero** matches for `i8042`. The same grep against `-M pc` returns two.

So: **on ARM64 `-M virt`, `keyboard.dart` drives nothing, and this kernel has no way to receive a
keystroke.** That is a real, measured, hard dependency for the owner's ARM64 goal, and it is not
something a compiler port fixes.

**But USB is not the only answer to it, and pretending otherwise would be dishonest.** Measured,
`-M virt` accepts `-device virtio-keyboard-pci`, `-device virtio-mouse-pci` and
`-device virtio-tablet-pci`. VirtIO-input is:

* **one virtqueue, receive-only**, delivering fixed 8-byte `virtio_input_event` structures
  (`type`, `code`, `value` — the Linux evdev encoding) **[spec]**;
* built on the **same VirtIO transport `gpu.md` already specifies** for VirtIO-GPU — so if the display
  path lands, the queue code, the descriptor ring and the notification path are **already written**;
* an estimated **150–250 lines of code** on top of that transport, versus **~1200+ code lines** for
  UHCI-plus-enumeration-plus-HID.

**Therefore, USB is not the cheapest answer, and it is not even the second cheapest.**

**And `arm64-port.md` names a third option that is cheaper than both, and it is right.** That
document's file-by-file table marks `keyboard.dart` **"MUST BE REWRITTEN or DROPPED"** and concludes:
*"The honest first move is to drop keyboard input on aarch64 entirely and drive the shell from serial
input, which the UART already carries."* Measured, `-M virt`'s default device list includes `pl011`,
so the UART is there with no `-device` at all. **That is the correct first answer and this document
endorses it** — with one operational note the two documents together need: **the existing harnesses
use `-serial file:<capture>`, which is output-only.** Driving the shell from serial input needs a
chardev that carries both directions (`-serial stdio`, a pty, or a socket), which is a harness change,
not a kernel change.

So the full ranking of "how does ARM64 get a keystroke" is four deep, not three:

| option | cost | note |
|---|---|---|
| **serial input over PL011** | **~zero new device code** | `arm64-port.md`'s recommendation; needs a bidirectional chardev in the harness |
| **VirtIO-input** | low | reuses `gpu.md`'s transport; absolute coordinates; works on `-M pc` too |
| **USB HID over UHCI** | ~5–8× VirtIO-input | §1.3's register abstraction first |
| **USB HID over xHCI** | ~15× | the only option on a physical board |

**So the accurate sentence is not "USB is on the critical path for ARM64". It is: *input* is on the
critical path for ARM64, USB is the most expensive of three ways to supply it under QEMU, and the
only way on metal.** If the ARM64 goal is "boot `-M virt` and type at the shell", **build serial
input, then VirtIO-input if a pointer is wanted — not USB.** If the ARM64 goal is a physical board,
USB HID over xHCI is unavoidable and it is a multi-month item that should be scheduled as one.

**One thing USB gives that VirtIO-input does not**, and it is worth naming: on `-M pc`, a `usb-kbd`
plus `usb-tablet` gives **absolute pointer coordinates**, which `display-protocol.md`'s input routing
wants and which a PS/2 mouse's relative deltas do not provide. That is a genuine argument for USB —
but `virtio-tablet-pci` supplies absolute coordinates too, on both machines, for a fraction of the
cost.

**A note for the display specialist, not a contradiction of them.** `display-protocol.md` D1 is "a
mouse exists" and specifies a **PS/2** mouse — IRQ12, the 8042's `0xA8`/`0xD4` commands, a three-byte
packet with a resync rule. That is the right first mouse **on x86**, and its §4.4 already names the
PIC-mask bug as the thing that breaks it. What this document adds is only that **D1 produces nothing
on `-M virt`**, and that a `virtio-mouse-pci` / `virtio-tablet-pci` variant of D1 would run on both
machines, deliver absolute coordinates D1 §4.3 wants, and reuse `gpu.md`'s transport. Whether that is
worth doing instead of, or after, D1 is a coordinator's call and not mine.

---

## 3. DMA, against what `pmm.dart` actually provides

### 3.1 What the allocator gives, measured

* **`allocFrame()` returns one 4096-byte physical frame**, frame-aligned by construction
  (`f << pmmFrameShift`), or `0` when exhausted. There is no multi-frame, no contiguous-run and no
  aligned-to-more-than-4-KiB request. `README.md` states this as a constraint and it is exact.
* **`pmmMaxFrames = 32768`**, a 128 MiB bound chosen to match `boot.S`'s identity map. **So every
  physical address this allocator can ever return is below `0x08000000`** — comfortably inside 32
  bits, which matters because UHCI's frame list, UHCI's TD link pointers and AC97's buffer-descriptor
  list are **all 32-bit physical addresses [spec]** and none of them can be handed an address this
  allocator is capable of producing that would not fit.
* **`allocFrame` does not zero the frame.** Read the function: it sets a bitmap bit, decrements a
  counter, and returns. **A frame list of uninitialised memory is a list of plausible TD pointers**,
  and a UHCI controller will follow them one millisecond after `run` is set. **Every DMA structure
  must be explicitly zeroed by its driver**, and the first milestone that forgets is the one that
  corrupts memory at 1000 Hz with no diagnostic.
* **The identity map means physical == virtual for kernel accesses below 128 MiB**, so no
  `virt_to_phys` is needed and none exists. That is a convenience the drivers below assume and should
  say they assume.

### 3.2 What each candidate device needs, against that

| structure | size | alignment **[spec]** | fits `allocFrame`? |
|---|---|---|---|
| **UHCI frame list** | 1024 × 4 B = **4096 B** | **4096 B** | **exactly one frame, perfectly** |
| UHCI transfer descriptor | 32 B (16 B hardware + 16 B software) | 16 B | many per frame |
| UHCI queue head | 8 B | 16 B | many per frame |
| **AC97 buffer-descriptor list** | 32 × 8 B = **256 B** | 8 B | trivially |
| AC97 sample buffer | driver's choice, ≤ 0xFFFE samples per entry | 2 B | one frame = 1024 stereo 16-bit frames = **~23 ms at 44.1 kHz** |
| EHCI periodic frame list | 4096 B | 4096 B | one frame |
| Intel HDA CORB / RIRB | 1024 B / 2048 B | 128 B | one frame holds both |
| Intel HDA BDL | 256 entries × 16 B = 4096 B | 128 B | one frame |
| **xHCI DCBAA** | (max slots + 1) × 8 B | **64 B, must not cross a 2048 B boundary** | one frame |
| **xHCI command / event / transfer ring** | 16 B per TRB; a 256-TRB ring is **4096 B** | 64 B, **and a ring segment may not cross a 64 KiB boundary** | one frame **only if the ring is capped at 256 TRBs** |
| xHCI device + input contexts | 32 or 64 B per context × 33 | 64 B | one frame per device |
| xHCI scratchpad buffers | `HCSPARAMS2`-many pages | 4096 B | one frame each |

**The headline is a good one and it is worth being surprised by: the single-4-KiB-frame allocator is
not the obstacle anyone would expect it to be.** UHCI's frame list is *exactly* one page with exactly
the right alignment. AC97's descriptor list is 256 bytes. Even xHCI's structures fit, one per frame,
**provided every ring is capped at 256 TRBs** — a constraint a driver would want anyway.

**What does not fit is a large audio buffer.** One frame is ~23 ms of CD-quality stereo. A playback
path wanting a 250 ms buffer needs eleven frames, and `allocFrame` cannot return eleven *contiguous*
frames. **But it does not have to** — that is what a buffer-descriptor list *is*: AC97's BDL and
HDA's BDL both take up to 32 / 256 independent physical addresses, so **a scatter-gather list of
individually-allocated frames is the natural and correct shape.** The allocator's limitation and the
hardware's design happen to agree.

### 3.3 The three cross-cutting blockers every device on this page inherits

Cited, not re-derived, per the brief:

1. **`pciWrite32` does not exist** (`README.md`, Tier 1). Configuration space is read-only, so
   **no driver on this page can enable bus mastering**, and every one of them needs it. `README.md`
   also settles the argument about whether it is already set: **BME is set only where an option ROM
   ran**, and no option ROM drives a UHCI or an AC97. Both arrive with the bit clear.
2. **The PIC mask is eight whole-byte writes** (`README.md` fix #1, eight named sites). **Any IRQ a
   USB or audio driver unmasks works until the next shell command and then stops, silently.** Both
   ladders below are therefore **poll-only until that fix lands**, and both say so in their exit
   criteria rather than in a comment.
3. **Nothing on this machine can block** (`blocking-and-threads.md`; GAP-0141). There is no `sleep`,
   no wait queue, and the PIT is masked at rest. Every wait is a counted spin whose duration is a
   property of the host. **This is survivable for USB enumeration** (the delays are short and a
   generous spin is merely wasteful) and it is **fatal for audio**, and §5.1 is the accounting.

---

## 4. Audio — AC97 versus Intel HDA

### 4.1 QEMU emulates both, and neither by default

Measured: `qemu-system-x86_64 -device help` lists `AC97` (`Intel 82801AA AC97 Audio`),
`intel-hda` (ich6), `ich9-intel-hda`, `ES1370`, `sb16`, `adlib`, `gus`, `cs4231a`, `virtio-sound-pci`,
and the USB device `usb-audio`. **None is present on `-M pc` or `-M q35` by default** (§0.1).

Two QEMU plumbing facts that will otherwise cost an afternoon, both measured:

* **`intel-hda` has no `audiodev` property.** `-device intel-hda,audiodev=s` fails with
  `Property 'intel-hda.audiodev' not found`. The `audiodev` goes on the **codec**:
  `-device intel-hda -device hda-output,audiodev=s`. `AC97` takes it directly.
* **`intel-hda` with no codec child instantiates fine and has nothing behind it.** A driver would
  enumerate zero codecs and correctly conclude there is no audio. `info qtree` shows the codec as a
  child device (`dev: intel-hda` → `dev: hda-output`), so **a harness that forgets the codec line gets
  a controller that resets, responds, and never makes a sound** — the single most likely wasted day in
  this whole document.

### 4.2 The comparison

| | **AC97** | **Intel HDA** |
|---|---|---|
| QEMU device | `AC97` (`8086:2415`, class `0x0401`) | `intel-hda` (`8086:2668`, class `0x0403`) + a codec |
| register access | **BAR0 I/O 1024 B (mixer), BAR1 I/O 256 B (bus master)** — measured | **BAR0 MMIO 16 KiB** — measured |
| needs BAR mapping code | **no** — I/O ports, on x86 | **yes**, plus the volatile-load discipline `time-and-power.md` §3.1 and DCDart GAP-0006 describe |
| how you talk to the codec | **write a 16-bit mixer register.** That is it | **build a CORB command ring and a RIRB response ring**, submit verbs, poll the response write pointer |
| how you find the output | you do not — PCM Out is at a fixed offset | **walk the codec's widget graph**: node counts, function group type, widget capabilities, connection lists, pin capabilities — then find a path from an Audio Output converter to an output-capable Pin, and configure amplifiers and pin control along it |
| DMA descriptor list | 32 entries × 8 B, one dword address + a sample count | 256 entries × 16 B, plus an optional DMA position buffer |
| streams | one PCM Out box, fixed | up to 30 stream descriptors, index negotiated |
| interrupts | one status word | `INTCTL`/`INTSTS` with per-stream bits |
| **estimated code** | **~300–400 lines of code (~700–900 lines of file in this repo's style)** | **~1200–2000 lines of code (~2700–4500 lines of file)** |
| what it buys over the other | — | multichannel, >48 kHz, input, hot-plug jack detection, modern hardware |

**AC97 is the answer and it is not close.** The brief's framing is right: AC97 is a few hundred lines,
HDA is much more. Concretely, an AC97 playback path is:

1. `pciWrite32` the command register to set **bus master** (bit 2) and **I/O space** (bit 0);
2. read BAR0 and BAR1, mask off the low bits, keep the two I/O bases;
3. NAM: write `0x0000` (reset), then unmute master volume (`0x02`) and PCM Out volume (`0x18`);
4. NABM: cold-reset via global control (`0x2C`), reset the PCM Out box (`CR` bit 1);
5. `allocFrame` a page, zero it, fill in a buffer-descriptor list — each entry a 32-bit physical
   address plus a 16-bit **sample** count (samples, not bytes — the classic off-by-two);
6. write the BDL's physical address to `BDBAR`, set `LVI` to the last valid index;
7. set `CR` bit 0 (run);
8. poll `CIV`/`PICB` to know where the hardware is, and refill behind it.

Eight steps, no graph, no rings, no MMIO. **Compare `ata.dart`, which is 554 code lines for a
single-sector PIO read and write.** AC97 is in that class of work. HDA is in `fat.dart`'s class.

**The one honest argument for HDA**, recorded so nobody has to rediscover it: **AC97 is not present on
any machine made after roughly 2008**, and `ich9-intel-hda` is what a real x86 laptop has. If this OS
is ever expected to make a sound on physical hardware, AC97 is dead weight. **That is the same trade
`gpu.md` made and refused**: reachable-under-QEMU now, versus real-hardware-someday. This document
makes the same call for the same reason — **and adds that the AC97 driver's *upper* half (the mixer
abstraction, the BDL refill loop, the sample-format conversion) is exactly the half that transfers to
HDA.** Only the bottom ~120 lines are wasted.

---

## 5. What audio needs that does not exist

Three things, in increasing order of how much they hurt.

### 5.0 A DMA ring buffer, and the discipline around it

**Nothing in this kernel is a ring buffer.** Not the UART, not the keyboard (which echoes in the
handler), not the disk. Audio is the first subsystem where the hardware and the software both hold a
pointer into the same memory and neither may pass the other.

The shape, for AC97:

* a **buffer-descriptor list** of up to 32 entries, each a physical address and a sample count;
* the controller advances `CIV` (current index) through it and **wraps at `LVI`** (last valid index);
* `PICB` counts samples remaining in the current buffer, so `(CIV, PICB)` is the play position;
* the driver must write new audio **behind** `CIV` and move `LVI` forward, and must never let `CIV`
  reach `LVI` or the stream halts (`DCH` in the status word) and the speaker clicks.

**Two failure modes with no diagnostic**, both worth pre-empting:

* **Underrun** — the driver did not refill in time. On AC97 this sets `CELV` and plays the last
  buffer again. It sounds like a stutter and reads like nothing.
* **Writing ahead of `CIV`** — the driver overwrites a buffer the hardware is currently reading. This
  cannot be detected after the fact at all.

Both are *timing* failures, which is §5.1.

**The good news, and it is the thing that makes AUD1 buildable at all: a fixed, finite, fire-and-forget
playback needs none of this.** Fill up to 32 buffers, set `LVI` to the last one, hit run, and poll
until `DCH` sets. The hardware plays it and stops. **Ring-buffer discipline is only needed for
*streaming*, which is a strictly later milestone and should be one.**

### 5.1 A clock good enough for sample-accurate playback — and the honest version of that requirement

**Do not re-derive the timer design; `time-and-power.md` owns it.** The relevant results from that
document, cited:

* The only clock is PIT channel 0 at **99.9985 Hz** (§0.1 there) — a **10 ms** tick.
* **The timer is masked at rest** (§0.2 there): `picUnmaskKeyboardOnly` leaves master mask `0xFD`,
  and that is the shell's steady state. Two sites unmask IRQ0 temporarily; a plain shell command
  never does.
* **A free-running timer costs one mask byte and two golden lines** (§0's decision 3 and §2.3 there), and
  `README.md` has already promoted it to **Tier 1, first**, because `blocking-and-threads.md` B1
  depends on it.
* **Sub-tick resolution is available for free**: latching PIT channel 0 gives **838 ns** (§2.4 there),
  *after* channel 0 moves from mode 3 to mode 2 — a one-nibble change that moves no golden.
* **The ACPI PM timer** at `PM_TMR_BLK = 0x608`, 3.579545 MHz, 24-bit, is readable with the
  `port_inl` that already exists (§3.2 there).
* **Reprogramming the PIT to 1000 Hz moves no golden** (§4.3 there), because `M1 TICKS
  0000000000000064` prints a *count*, not a duration.

**Now the part this document has to add, because it is the part that decides whether audio is
buildable: the phrase "sample-accurate playback" is doing too much work, and the requirement is
softer than it sounds.**

**The DAC has its own clock.** Once the BDL is running, the AC97 controller pulls samples at 48 kHz
(or 44.1 kHz with VRA) **regardless of what the CPU is doing**. The kernel does not clock the audio;
it only has to *stay ahead* of a DMA engine. So the real requirement is a **deadline**, not a
sampling rate:

| buffer size | 16-bit stereo @ 44.1 kHz | ticks of slack at 100 Hz | at 1000 Hz |
|---|---|---|---|
| one `allocFrame` page, 4096 B | **23.2 ms** | 2.3 | 23 |
| four pages, 16 KiB | 92.9 ms | 9.3 | 93 |
| sixteen pages, 64 KiB | 371.5 ms | 37 | 371 |

**So the timer requirement for a first audio milestone is: none at all**, because AUD1 is
fire-and-forget and polls. **For streaming it is: a free-running timer, which is already Tier 1 and is
being built anyway for reasons that have nothing to do with audio.** 838 ns sub-tick resolution is
not needed and 1000 Hz is not needed — a 64 KiB ring at 100 Hz has 37 ticks of slack.

**The thing that actually blocks streaming audio is not the clock. It is that nothing can run while
something else is happening.** With no blocking (`blocking-and-threads.md`, GAP-0141) and no resident
process (`display-protocol.md` D3), a shell command that plays five seconds of audio **busy-spins for
five seconds** and the machine does nothing else — no keystrokes processed, no other command, nothing.
That is acceptable for a demo and is not a sound system. **Streaming audio is therefore gated on B1 /
D3, the same milestone `README.md` says to "build once".** Put it after them or do not put it anywhere.

### 5.2 A mixer — and the word means two different things

**The hardware mixer** is trivial: on AC97 it is a handful of 16-bit writes to the NAM I/O region —
master volume at `0x02`, PCM Out volume at `0x18`, mute is bit 15. **Three lines. Build it in AUD1**,
because a driver that cannot unmute produces a correct, silent, byte-identical-to-the-negative-control
WAV file and looks exactly like a driver that does not work.

**The software mixer** — two programs making sound at once — is a different animal, and this kernel is
missing every prerequisite:

| a software mixer needs | this kernel has | gap |
|---|---|---|
| more than one thing running at a time | four process slots, alive only while a shell command runs (`README.md`, `smp.md`) | **there is no second audio client to mix** |
| a per-client buffer the kernel owns | `@bss` statics and 4 KiB frames | fine |
| saturating integer addition of two streams | integer ops only | fine — clamp to ±32767 by hand |
| **sample-rate conversion** | **no floating point in kernel code at all** (grepped: no `f32`, no `f64` anywhere under `core/kernel/`) | needs fixed-point resampling, written by hand |
| a device-node to open (`audio:` or similar) | `namespace.md` specifies the sigil and the `fileSysOpen` branch | **the design exists; nothing is built** |
| a way to not block the writer | nothing blocks | **`fdwait` (`blocking-and-threads.md` B1)** |

**Verdict: do not build a software mixer.** One stream, one client, exclusive access, refuse the
second opener. `smp.md` reaches the identical conclusion about a second CPU by the identical argument
— there is no workload for it — and that argument is just as true here.

**Note the floating-point result, because it reaches further than audio.** Kernel code uses no
floating point today. `boot.S` *does* set CR4.OSFXSR and OSXMMEXCPT when CPUID says SSE exists
(M11 / ADR-0015), and processes get an FPU save area — **so the machine is capable and the kernel
simply does not use it.** Any resampling or format conversion the kernel does must be fixed-point, and
that is a choice worth keeping, not a limitation worth removing.

---

## 6. What ffmpeg would need to actually PLAY something

`exec-format.md` §4 and `libc-roadmap.md` §2.4 already size the ffmpeg problem and this section does
not repeat their work. **Their conclusions, cited:**

* **ffmpeg is gated on size, not on linking.** `elfImageMax` is **65,536 bytes** and `libavutil.__text`
  **alone** is **355,944 bytes** — **5.4×**. `fatChainMax` is **262,144 bytes** against an estimated
  1.5–3 MB static build. The user address window is **2,097,152 bytes total**. The stack is **4096
  bytes, one page**, and `exec-format.md` calls it the most likely silent failure on the list.
* **The libc gap is ~220–260 symbols against 41 existing**, of which only nine are C89
  (`libc-roadmap.md`; `README.md`'s one-line summary).
* **Three syscalls are genuinely missing and genuinely required**: a file-size/`fstat` equivalent,
  write-at-offset, and a clock (`exec-format.md` §4.3).
* **`exec-format.md` §4.5 argues ffmpeg should not be the forcing function**, and recommends a
  smaller target that gets there faster. **This document agrees and §6.3 names the smaller target.**

### 6.1 What playing adds on top of all that

Everything above is about ffmpeg *running*. Playing needs an output path, and that is five more
things, none of which the two sizing documents cover because neither owns a sound card:

| # | needed | status | owner |
|---|---|---|---|
| 1 | **an audio device driver** | nothing | this document, AUD1–AUD3 |
| 2 | **a name to open it by** — `audio:` or similar | designed, not built. The sigil is `:`, and the branch goes in `fileSysOpen`, **never** `fatLookup` | `namespace.md` (`README.md` records both decisions) |
| 3 | **write bandwidth** | `fdwrite` is capped at **512 bytes** per call. 16-bit stereo at 44.1 kHz is 176,400 B/s, so **345 syscalls per second, forever, just to keep the DAC fed.** Syscall 1 is worse and unusable: it caps at 128 bytes, prints `USER WRITE ` first and appends its own newline (`exec-format.md` §4.3) | `display-protocol.md` hits the identical cap from the other side — 512 bytes is 128 pixels — so **raising the `fdwrite` cap is a shared unblock for two subsystems**, which is an argument neither document could make alone |
| 4 | **back-pressure** — a write that waits when the ring is full instead of dropping or spinning | nothing blocks | `blocking-and-threads.md` B1 / `fdwait` |
| 5 | **a clock exposed to ring 3** | missing; `av_gettime()` needs it | `exec-format.md` §4.3 item 3, `time-and-power.md` |

**Item 3 is the one worth staring at.** 345 syscalls per second is not obviously fatal — this kernel's
syscall path is a `syscall`/`sysret` pair, not a fault — but it is 345 opportunities per second for
the caller to be late, on a system where being late by 23 ms is an audible click and where **nothing
can block, so "wait until there is room" is a spin that starves everything else**.

### 6.2 One genuinely good piece of news

**ffmpeg's raw PCM muxer never seeks.** `-f s16le` writes a headerless byte stream: no header to
patch, no index to rewrite, no `SEEK_END`. So the single ugliest hole in the file layer for ffmpeg —
**append-only writes with no write-at-offset (GAP-0127, `exec-format.md` §4.3 item 2)** — **does not
bite the audio output path at all.** `ffmpeg -i in.mp3 -f s16le -ar 44100 -ac 2 audio:` is expressible
with the file layer this kernel already has, plus `namespace.md`'s device branch.

That is worth recording because it is unusual: for **playback**, ffmpeg needs *fewer* file-layer
features than for transcoding. The blockers that remain are size, libc, bandwidth and back-pressure —
not seeking.

### 6.3 The honest ordering, and the smaller forcing function

**Audio-only is dramatically cheaper than video, and the numbers say so.** `exec-format.md` measures
that a single 1080p YUV420 frame is **3,110,400 bytes** and the entire user address space is
**2,097,152** — *the address space cannot hold one uncompressed video frame*. **A decoded second of
CD-quality audio is 176,400 bytes**, and a decoder's working set is tens of kilobytes. **Video is
architecturally out of reach today; audio is only quantitatively out of reach.**

So the ladder to "this OS plays a sound file", cheapest first:

| step | what it is | why it is the right size |
|---|---|---|
| **1** | **a `play` shell command that reads a WAV file off FAT16 and pushes it at AC97** | **~80 lines on top of AUD2.** No ELF, no libc, no ffmpeg. It proves driver + filesystem + BDL end to end and produces a checkable WAV out the other side |
| **2** | **the same thing as a ring-3 program** over `open`/`read`/`write` to `audio:` | forces items 2, 3 and 4 of §6.1 to be real, and produces the device-node and bandwidth work as a milestone with an exit criterion |
| **3** | **a single-file MP3 or Vorbis decoder** (the minimp3-class ones are ~1500 lines, header-only, needing little more than `memcpy` and `malloc`) | fits `elfImageMax` after it is raised once, needs a small fraction of libc tier D, and is the first thing that decodes rather than replays |
| **4** | **ffmpeg** | everything above, plus `exec-format.md` §4.2's four caps, plus `libc-roadmap.md` tier D |

**Step 4 is not a milestone. It is a consequence of eight to twelve other milestones**, which is the
same shape of conclusion `exec-format.md` §4.5 reached, arrived at from the output side instead of the
input side. Step 3 is the honest target for "this OS plays music".

---

## 7. The ladders

Twelve rungs across two ladders. **Each rung has a binary exit criterion and a negative control**, per
CLAUDE.md rule 2. Where a criterion says *derived*, the harness computes the expectation from the
machine (QMP `query-pci`) rather than having it typed — the discipline `m7-frames` and `m18-preempt`
already follow, and `time-and-power.md` §7 restates.

**`README.md`'s `xp` trap is respected throughout.** No criterion below reads a device BAR with `xp`.
The BAR *addresses* come from QMP `query-pci`, which reports the host's own bookkeeping and is not an
MMIO access at all — measured, after SeaBIOS assigns them: **UHCI BAR4 = `0x0000C540`, size 32;
AC97 BAR0 = `0x0000C000`, size 1024; BAR1 = `0x0000C400`, size 256; both devices on IRQ 11.**

### 7.0 The one measured fact that shapes both ladders

**Both devices land on IRQ 11, which is on the SLAVE PIC.** SeaBIOS's PIIX3 PIRQ routing put them
there; the interrupt line is readable from configuration space offset `0x3C`, which `pci.dart` does
not currently read.

`time-and-power.md` §4.5 already rejected RTC periodic interrupts partly for this reason, and the
objection transfers verbatim: **using IRQ 11 means unmasking a line on the slave PIC *and* IRQ 2 (the
cascade) on the master, and issuing EOI to *both* PICs** — a second interrupt path with a second
correctness rule. Combined with `README.md` fix #1 (the eight whole-byte mask writes, which would
silently re-mask it at the next shell command), the conclusion is not close:

> **Every rung below is poll-only. Neither ladder unmasks an interrupt. `USBINTR` stays 0 and the
> AC97 interrupt-enable bits stay clear**, and each rung's structural check asserts it.

This is the same call `net-e1000.md` makes — polling for seven milestones, interrupts at the eighth —
and for the same two reasons.

---

## 7.1 The USB ladder

### USB1 — the kernel reads a BAR, for the first time ever

*The smallest possible step, and it is genuinely a first: no code in this kernel has ever read PCI
configuration offset `0x10`.*

1. `pci.dart` gains `pciReadBar(bus, dev, fn, n)` and `pciReadIrqLine(...)` (offset `0x3C`). Neither
   writes anything; `pciWrite32` is still absent at this rung.
2. A new `usb` shell command finds the first class-`0x0C03` function, prints its BDF, its BAR4 I/O
   base with the low two bits masked off, its BAR4 size (probed read-only is impossible without a
   write — **so the size is NOT probed and NOT printed**; see the negative control), and its IRQ line.
3. **Criterion, derived:** run with `-M pc,usb=on -qmp ...`; the harness reads `query-pci`, finds the
   class-`0x0C03` function, and requires the guest's printed base to equal `regions[bar==4].address`
   and the printed IRQ to equal `irq`. Nothing is typed into the harness.
4. **Negative control 1:** the same kernel on plain `-M pc` must print `USB NONE` and must not print a
   base. This is the control that catches the whole class of "the device was never there" vacuity,
   and it is the inverse of `net-e1000.md`'s trap.
5. **Negative control 2 (the one that matters):** a mutant that prints BAR4 *unmasked* (low bits
   intact) must fail the derived comparison. The low bit of an I/O BAR is 1, so an unmasked base is
   off by one and every subsequent port access is to the wrong register.
6. **Structural check:** the linked kernel contains no `port_outl` to `0xCFC` — i.e. this rung really
   is read-only.

### USB2 — the controller runs, and the frame counter proves it

*The first rung that needs `pciWrite32` (`README.md` Tier 1) and the first that uses `allocFrame` for
DMA.*

1. Set `PCI_COMMAND` bits 0 (I/O space) and 2 (bus master) via `pciWrite32`. **Read it back and print
   it**; `README.md`'s BME resolution says the bit arrives clear here, so the before/after pair is
   itself the evidence.
2. `allocFrame` one page for the frame list, **explicitly zero all 4096 bytes**, then write the
   terminate bit (`0x00000001`) into all 1024 entries. Write the page's physical address to
   `FLBASEADD`, `0` to `FRNUM`, `0` to `USBINTR`, then set the run bit in `USBCMD`.
3. **Criterion:** the guest prints `FRNUM` twice with a bounded spin between, and the two values
   **differ**. Printed as `USB FRNUM <a> <b>`.
4. **Negative control:** a second boot of the *same kernel* with a `usb norun` argument that skips the
   run bit must print two **equal** values. This is what distinguishes "the controller is running"
   from "two reads of an unimplemented register returned different garbage".
5. **Structural check:** the zeroing loop exists and covers 4096 bytes, and `USBINTR` is written with
   `0` on every path. A frame list of uninitialised memory is a list of plausible TD pointers and the
   controller will follow them (§3.1).
6. `pmm`'s free-frame count after the command is exactly one less than before, printed and compared —
   this reuses `m7-frames`'s existing ledger discipline.

### USB3 — a port sees a device, and an empty port sees nothing

1. Read `PORTSC1`/`PORTSC2`; print connect-status, connect-status-change, enable and the low-speed
   bit for both. Drive the reset sequence (set reset, bounded delay, clear reset, set enable, bounded
   delay) and print `PORTSC` again.
2. **Criterion:** with `-device usb-kbd`, exactly one port reports connected, and after the reset
   sequence that port reports **enabled** with the low-speed bit **clear** — measured, `usb-kbd`
   attaches at **port 1 at 12 Mb/s**, so full speed is the correct expectation and a driver that
   reports low speed is wrong.
3. **Negative control:** the same kernel with no `-device usb-kbd` reports **zero** ports connected
   and performs no reset.
4. **The delay is the hazard.** Both waits are counted spins whose duration is a host property
   (§2.2). The rung's structural check asserts every spin is bounded and that exhaustion prints a
   diagnostic naming the register — `ata.dart`'s rule, applied.

### USB4 — one control transfer, and the device says who it is

*The rung where a USB stack stops being register poking.*

1. Build one queue head and three transfer descriptors (SETUP / IN / OUT-status) in a second
   `allocFrame` page, zeroed. Point frame-list entry 0 at the queue head. Issue
   `GET_DESCRIPTOR(DEVICE, 8)`, then `GET_DESCRIPTOR(DEVICE, 18)` using the `bMaxPacketSize0` the
   first read returned.
2. **Criterion:** the guest prints the 18-byte device descriptor as hex. The harness requires
   `bLength == 0x12`, `bDescriptorType == 0x01`, and `bcdUSB`, `idVendor` and `idProduct` **equal to
   what QEMU reports for the attached device** — derived from the monitor, not typed.
3. **Criterion 2, and this is the one that proves the transfer really happened:** the guest also reads
   the **product string descriptor** and prints it as ASCII. It must be exactly
   `QEMU USB Keyboard` — measured, that is what `info usb` reports for `-device usb-kbd`. A string
   that arrived over three chained descriptor reads cannot be a coincidence of garbage.
4. **Negative control:** with `-device usb-mouse` instead, the string must be different and the
   harness must reject the keyboard string. Two devices, one kernel, different output.
5. **Structural check:** exactly one frame-list entry is non-terminate.

### USB5 — enumeration: a device gets an address and a configuration

1. `SET_ADDRESS(1)`, ≥2 ms settle, re-read the device descriptor **at address 1**, then
   `GET_DESCRIPTOR(CONFIGURATION, 9)`, read `wTotalLength`, re-read the full configuration, then
   `SET_CONFIGURATION(1)`.
2. **Criterion:** the guest prints the interface descriptor's `bInterfaceClass`, `bInterfaceSubClass`
   and `bInterfaceProtocol`. For `usb-kbd` these must be `03 / 01 / 01` (HID / boot / keyboard) and
   for `usb-mouse` `03 / 01 / 02`. **Two devices, one kernel, two different derived expectations** —
   the same two-boot shape `time-and-power.md` T3 uses for the RTC century.
3. **Criterion 2:** the second device-descriptor read is issued to **address 1**, proven by a mutant:
   a kernel that keeps talking to address 0 after `SET_ADDRESS` must fail. (It will: the device stops
   answering there.)
4. **Negative control:** `wTotalLength` is *read from the device*, not assumed. A mutant that
   hardcodes a plausible configuration length must fail on one of the two devices.

### USB6 — a USB keystroke reaches the shell

*The first rung that produces user-visible behaviour, and the first that could replace PS/2.*

1. `SET_PROTOCOL(0)` (boot protocol). One interrupt queue head placed in every 8th frame-list entry,
   with an 8-byte data TD. Poll the TD's status word.
2. Decode the 8-byte boot report — modifier byte, reserved, six keycodes — into the same character
   stream `keyboard.dart` feeds the shell, **through a shared function rather than a duplicated
   table**, so there is exactly one HID/scancode-to-ASCII decision in the kernel.
3. **Criterion:** the harness sends keystrokes with QMP `send-key` and the resulting **serial capture
   is byte-identical to `m3-shell`'s existing golden** for the same input. The strongest available
   criterion: the new input path must be indistinguishable from the old one.
4. **Negative control:** a boot with `-device usb-kbd` but with the PS/2 path compiled out and the USB
   poll disabled must produce a capture with **no echoed characters at all** — proving the golden in
   (3) came from USB and not from the 8042 still sitting there.
5. **The known limitation, stated in the rung rather than discovered later:** polling from a shell
   command means keystrokes are only collected while a command runs. **A usable USB keyboard needs
   either the IRQ (blocked on `README.md` fix #1) or a resident process (`blocking-and-threads.md`
   B1 / `display-protocol.md` D3).** `display-protocol.md` §4.4 makes this identical point about the
   PS/2 mouse — "polling a PS/2 port from a shell loop is not a design anyone chose".

### USB7 — the same kernel enumerates on ARM64 `-M virt`

*Do not build this until the DCDart AArch64 backend exists. It is listed so the shape is on record.*

1. §1.3's register-access abstraction has two implementations: `in`/`out` on x86, and a load/store to
   the GPEX I/O window on AArch64.
2. **Criterion:** on `qemu-system-aarch64 -M virt -device qemu-xhci -device usb-kbd`, the guest
   prints the same `QEMU USB Keyboard` string USB4 asserts on x86. **Note this requires an xHCI
   driver, not the UHCI one** — §1.2. On `-M virt -device piix3-usb-uhci -device usb-kbd` the UHCI
   driver should also work, and if it does, that is a strictly cheaper route worth measuring first.
3. **Negative control:** `-M virt` with no USB device must print `USB NONE`, and the **PS/2 path must
   report absent** rather than silently reading `0xFF` from a port that does not exist — measured,
   `-M virt` contains **zero** `i8042` devices.

---

## 7.2 The audio ladder

### AUD1 — the mixer answers

*Cheapest rung in this document. No DMA, no buffers, no timing.*

1. Find class `0x0401`, read BAR0 and BAR1, mask the low two bits, print both. Set `PCI_COMMAND` bits
   0 and 2 with `pciWrite32` and print the before/after values.
2. Write `0x0000` to NAM `0x00` (reset). Write `0x0000` (0 dB, unmuted) to NAM `0x02` (master) and NAM
   `0x18` (PCM Out).
3. **Criterion, derived:** the printed I/O bases equal `query-pci`'s `regions[0].address` and
   `regions[1].address` for the class-`0x0401` function — measured `0x0000C000` and `0x0000C400`.
4. **Criterion 2:** the guest prints a **read-back** of NAM `0x02` after writing it. A mixer register
   that reads back what was written proves the I/O base is right; a wrong base reads `0xFFFF`. Print
   both a write of `0x0000` and a write of `0x8000` (mute) and require the two read-backs to differ.
5. **Negative control:** the same kernel with no `-device AC97` must print `AUDIO NONE`.
6. **Structural check:** no MMIO access and no `allocFrame` call in `ac97.dart` at this rung.

### AUD2 — the machine makes a sound, and the host has the file to prove it

*The rung this ladder exists for, and its exit criterion is unusually strong.*

1. `allocFrame` a page for the buffer-descriptor list (zeroed), `allocFrame` N pages for PCM. Generate
   a **square wave of a known frequency and known amplitude** into them — computed with integer
   arithmetic, no floating point (§5.2).
2. Fill the BDL: physical address + **sample count, in samples not bytes**. Set `BDBAR`, set `LVI`,
   set `CR` run. Poll `CIV`/`PICB`/`SR` until `DCH`. Stop, print the final `CIV` and `SR`.
3. **Criterion, and this is the good one:** the harness runs with
   `-audiodev wav,id=s,path=out.wav -device AC97,audiodev=s`. Measured: **with no driver, `out.wav` is
   exactly 44 bytes** — the canonical PCM header, `0x0001` format, 2 channels, `44100`, 16-bit,
   `data` length `0`. So:
   * `stat out.wav` must report **more than 44 bytes**;
   * the header's `data` chunk length must be **non-zero**;
   * and — the real check — **the exact byte sequence of the generated square wave must appear as a
     contiguous substring of the file's PCM payload.** The guest computed those samples; finding them
     verbatim in a file the host wrote is not something a broken driver produces. Substring rather
     than equality, deliberately, so that leading or trailing silence from stream start/stop does not
     make the criterion flaky.
4. **Negative control:** the same kernel with the run bit never set must produce **exactly 44 bytes**.
   This is the audio analogue of `net-e1000.md`'s `romfile=` control, and unlike the NIC's case it is
   already true today — measured on an unmodified QEMU, twice, for both `AC97` and
   `intel-hda`+`hda-output`.
5. **Second negative control, and it is the one that catches the likeliest bug:** a mutant that
   leaves the mixer **muted** (skip AUD1's step 2) must fail. A muted driver produces a *large* file
   full of zeros — it passes a naive "more than 44 bytes" check and fails the substring check. This is
   why criterion 3 has three parts.
6. **The harness must pass `-audiodev`.** Measured: with no audio backend at all, `-device AC97`
   prints `Can not open 'ac97.pi'` warnings (those are the *capture* streams; the `wav` backend is
   output-only and they are harmless), and with no `audiodev=` at all on AArch64 the device refuses to
   instantiate. Both are loud failures, which is the good kind.

### AUD3 — a file on the disk plays

1. A `play <NAME.WAV>` shell command: open through the FAT16 path, parse the RIFF header, refuse
   anything that is not 16-bit stereo PCM **with a printed reason**, and stream the payload into the
   BDL a page at a time, refilling behind `CIV`.
2. **Criterion:** the PCM payload of the input `.WAV` on the disk image and the PCM payload of
   `out.wav` are **bit-identical over the overlapping region** — the harness extracts both with a
   dozen lines of Python and compares. A resampling bug, an endianness bug, a channel-swap bug and an
   off-by-one in the sample-count field all fail this.
3. **Negative control 1:** a `.WAV` with a mono or 8-bit header must be refused **by name**, and
   `out.wav` must be exactly 44 bytes.
4. **Negative control 2:** the input file's samples must not appear in `out.wav` when the run bit is
   skipped.
5. **Criterion 3 (`m14-fat`'s discipline):** the boot issues **no disk write**. `m14-fat` and
   `m15-fileio` already assert this about their own boots and this rung inherits the assertion.
6. **Known limitation to state in the rung:** this command busy-polls for the duration of the file
   (§5.1). A ten-second WAV is a ten-second unresponsive machine. That is acceptable *here* and is
   exactly what AUD4 fixes.

### AUD4 — streaming, and the machine stays responsive

**Blocked on `blocking-and-threads.md` B1 + `display-protocol.md` D3 (one milestone, per
`README.md`), and on the free-running timer (`time-and-power.md` §2.3, Tier 1).** Do not attempt
before both.

1. A cyclic BDL with `LVI` chasing `CIV`, refilled from `procTick` rather than from a spin —
   `time-and-power.md` §4.3's "fixed sequence of named calls in `procTick`", not a callback registry
   (DCDart has no function pointers, GAP-0002).
2. **Criterion:** a boot plays a 10-second WAV **and** echoes keystrokes sent by QMP `send-key`
   during playback, with both the audio comparison of AUD3 and the echo comparison of `m3-shell`
   passing in the same capture.
3. **Criterion 2 — the underrun counter:** the driver counts `CELV`/`DCH` events and prints the
   total. It must be **zero**. This is the number that makes "it sounded fine" into a measurement, and
   it is the one this ladder would otherwise have no way to check.
4. **Negative control:** a deliberately under-sized ring (one page, 23 ms — §5.1's table) must produce
   a **non-zero** underrun count, proving the counter can move.

### AUD5 — ring 3 can open `audio:` and write to it

**Blocked on `namespace.md` (the device branch in `fileSysOpen`, sigil `:`) and on the `fdwrite`
512-byte cap (§6.1 item 3).**

1. `open("audio:")` returns a descriptor; `fdwrite` appends PCM to the ring; the write refuses (or
   waits, once `fdwait` exists) when the ring is full.
2. **Criterion:** a ring-3 program produces the same bit-identical `out.wav` payload AUD3's kernel
   command produces, from the same input file.
3. **Criterion 2:** the syscall count for one second of 44.1 kHz stereo is printed and equals
   **345** (176,400 / 512, rounded up) at the current cap. **That number is the argument for raising
   the cap**, and printing it turns an assertion into a measurement.
4. **Negative control:** a second `open("audio:")` while the first is open must be refused with a
   named error (§5.2 — one client, exclusive).

---

## 8. What should simply not be built, and for how long

**This is the most useful section in the document.** Each row says what would have to change for the
answer to become "yes", so the refusal is revisable rather than permanent.

| do not build | why not | what would change the answer |
|---|---|---|
| **xHCI** | 7+ DMA structure types against UHCI's 3; a command/event/completion model with no counterpart in UHCI; an estimated **4–6×** the code. **And on QEMU there is nothing it can reach that UHCI cannot** — `usb-kbd`, `usb-mouse`, `usb-tablet` and `usb-storage` are all full speed (measured: 12 Mb/s) | **Physical ARM64 hardware.** A real board has xHCI and nothing else, and then this is unavoidable and should be scheduled as a multi-month item, not a milestone |
| **EHCI** | High speed **only** [spec]; full/low-speed devices need a companion controller or a hub doing split transactions — which is why `-M q35,usb=on` gives **three UHCI companions plus one EHCI** (measured). So EHCI is not a simpler xHCI, it is UHCI plus a routing problem | Wanting >12 Mb/s over USB, which nothing here does |
| **OHCI** | A third schedule format (HCCA + ED/TD) that reaches exactly what UHCI reaches | Nothing under QEMU. Real non-Intel hardware |
| **USB hubs** | Enumeration behind a hub means port status/change bitmaps, hub descriptors, and per-port power. QEMU attaches devices directly to the root ports | Wanting more than the root ports supply |
| **Isochronous transfers** | No retry, no error recovery, hard real-time TD placement in the frame list, and **`blocking-and-threads.md` says nothing on this machine can block** | Nothing. This is the last USB feature to build, not an early one |
| **`usb-audio`** | A USB sound card is isochronous audio *plus* the whole USB stack, to reach what one AC97 driver reaches over I/O ports (§4.2) | Nothing, ever, under QEMU |
| **USB mass storage (BOT/SCSI)** | A second storage stack — CBW/CSW framing plus `INQUIRY`, `READ CAPACITY(10)`, `READ(10)`, `WRITE(10)`, `REQUEST SENSE`. `storage.md` already owns storage and gets there over AHCI for far less | A USB stick being the *only* medium, which QEMU never forces |
| **`usb-net`, `usb-serial`, `usb-ccid`, `usb-mtp`** | `net-e1000.md` owns networking over a NIC that is present by default; the UART already exists | Nothing |
| **Intel HDA** | ~4× AC97's size for capabilities nothing here uses. The CORB/RIRB rings and the codec widget-graph walk are the entire difference and they are all cost (§4.2) | Physical hardware, where AC97 does not exist. The AC97 driver's upper half transfers |
| **`virtio-sound`** | A third audio device to reach what AC97 reaches. Would only make sense if the VirtIO transport were already built for `gpu.md` **and** AC97 were not | If `gpu.md`'s transport lands *and* audio has not been started yet, re-evaluate — this is the one refusal on this list that could flip |
| **`sb16`, `ES1370`, `adlib`, `gus`, `cs4231a`** | Legacy ISA devices, no better than AC97 and mostly worse. `adlib` is FM synthesis, not PCM at all | Nothing |
| **Audio capture / microphone** | There is no consumer. `hda-duplex`'s capture streams are why `-device AC97` prints `Can not open 'ac97.pi'` under a `wav` backend — the input direction is not even connected in the harness | A recording application, which does not exist |
| **A software mixer / multiple concurrent streams** | **There is no second audio client.** Processes exist only while a shell command runs, four slots, nothing blocks (§5.2). `smp.md` refuses a second CPU by the identical argument | A resident process (`display-protocol.md` D3) *and* a second audio-producing program |
| **Sample-rate conversion** | No floating point in kernel code (grepped: no `f32`/`f64` under `core/kernel/`), and AC97's VRA lets the *hardware* change rate instead | A file whose rate the hardware refuses. Then it is fixed-point, by hand |
| **MIDI, 3D/positional audio, DSP effects** | No consumer, no application, no plan | Nothing on any current roadmap |
| **USB device mode / OTG** | This machine is a host | Nothing |
| **Interrupt-driven anything on this page** | Both devices land on **IRQ 11**, on the **slave** PIC (measured) — two PICs to EOI, a cascade line to unmask, and `README.md` fix #1 means it dies at the next shell command anyway (§7.0) | `README.md` fix #1 (consolidate the eight mask writes), and preferably the APIC + MSI work `README.md` promotes to Tier 1 |

### 8.1 And the ranking restated as a schedule

| when | build |
|---|---|
| **After `pciWrite32` lands (Tier 1), any time** | **AUD1, AUD2, AUD3.** Three rungs, no dependencies beyond `pciWrite32`, and AUD2's exit criterion is a file the host writes. This is the cheapest real capability left in the machine |
| **After B1/D3 and the free-running timer** | **AUD4**, then **AUD5** if a ring-3 audio program is wanted |
| **Only if input on `-M virt` is not solved by serial input (`arm64-port.md`) or VirtIO-input** | **USB1–USB6** |
| **Only when there is physical ARM64 hardware** | **USB7**, and only then, xHCI |
| **Never, on current facts** | everything in §8's table |

---

## 9. What I did not decide, and would rather be told

1. **Is the ARM64 goal QEMU `-M virt` or a physical board?** §2.6's whole ranking turns on it. If it
   is `-M virt`, **`arm64-port.md`'s serial-input answer is cheaper still and VirtIO-input is 5–8×
   cheaper than USB while reusing `gpu.md`'s transport**, and USB should be deferred outright. If it is a board, xHCI is unavoidable and is a multi-month item that
   should be on the roadmap as one. **This is the single highest-value answer anyone could give this
   document.**
2. **Is "audio" a goal at all, or only a consequence of the ffmpeg goal?** If it is only ffmpeg, §6.3
   says the ordering is WAV player → ring-3 WAV player → single-file decoder → ffmpeg, and AUD1–AUD3
   are on that path either way. If audio is wanted for its own sake, AUD1–AUD3 are worth doing now
   regardless of ffmpeg.
3. **Should `display-protocol.md` D1 (a PS/2 mouse) become a VirtIO-input milestone instead?**
   §2.6 argues it would run on both machines and deliver the absolute coordinates D1 §4.3 wants. That
   is the display specialist's call, not mine — I only supply the measurement that `-M virt` has no
   8042.
4. **Who owns raising the `fdwrite` 512-byte cap?** Two subsystems need it for the same reason —
   `display-protocol.md` calls it "128 pixels", this document calls it "345 syscalls per second"
   (§6.1). It should be one change with one owner, not two.
5. **Is a `--play`-style demo wanted for `demo-harness.md`?** AUD2's WAV artifact is the most
   demonstrable thing in this document and I did not look at whether that harness wants it.

---

## 10. Corrections and additions this document makes

* **`pci.dart`'s class-name table already knows about USB and does not know about audio.** It has
  `0C/03` → `"usb"` and a wildcard `04/FF` → `"multimedia"`, with **no** `04/01` or `04/03` entry. So
  `-device AC97` prints `04/01/00 H00 multimedia` today. Adding two 16-byte records is a
  one-line-per-record change to a table whose total size the `m5-pci` harness asserts
  (`pciNameCount * pciNameStride` = 20 × 16 = 320) — **so it moves that assertion**, which is exactly
  the kind of coupling `hot-files.md` exists to warn about.
* **`pci.dart` never reads a BAR.** Its register constants are `0x00`, `0x08`, `0x0C`, `0x18` only.
  Offsets `0x10` (BAR0) and `0x3C` (interrupt line) have no constant and no reader. USB1 and AUD1
  both need them; whoever builds the first one should add them for both.
* **QEMU 11.0.0 has removed the bare `-usb` option.** Measured: `-M pc -usb` fails with
  `invalid option`. The spelling is `-M pc,usb=on`.
* **`-M q35,usb=on` instantiates four USB controllers** (three ICH9 UHCI companions plus one EHCI),
  `-M pc,usb=on` exactly one. Any USB harness should use `pc`, which is also the machine every
  existing harness uses.
* **`intel-hda` takes no `audiodev`; its codec does.** Measured: `Property 'intel-hda.audiodev' not
  found`. And `-device intel-hda` with no codec child instantiates a controller with nothing behind
  it.
* **Both new devices land on IRQ 11 — the slave PIC.** `time-and-power.md` §4.5's objection to RTC
  IRQ8 (two PICs to EOI, a cascade to unmask) applies verbatim, and neither document could have
  noticed that overlap alone.
* **`allocFrame` does not zero the frame.** Nothing in the corpus says so, and for a DMA structure it
  is the difference between a driver and a memory corrupter running at 1000 Hz.
* **An addition to `arm64-port.md`, not a disagreement with it.** Its recommendation to drive the
  aarch64 shell from serial input is right and this document endorses it (§2.6). The operational
  detail neither document had alone: **every existing harness uses `-serial file:<capture>`, which is
  output-only.** Serial *input* needs a bidirectional chardev — a harness change, not a kernel change.
* **A third harness trap, alongside `README.md`'s two.** The NIC's trap is that a device *acts before
  the guest runs*, so a "capture is non-empty" criterion passes with no driver. USB and audio have the
  **inverse** trap: **the device is absent unless the command line asks for it**, so a criterion fails
  with no driver and the tempting fix — add `-device` and move on — proves nothing. **Both rungs above
  therefore carry a device-absent negative control as well as a driver-disabled one.**

---

## Appendix A — every measurement, and how to reproduce it

Host: `qemu-system-x86_64` / `qemu-system-aarch64` **11.0.0**, macOS arm64, 2026-08-23. Same QEMU as
`time-and-power.md`'s Appendix A.

**A1 — no USB and no audio on the default machines.**
```sh
printf 'info pci\nquit\n' | qemu-system-x86_64 -M pc  -display none -monitor stdio -m 128M
printf 'info pci\nquit\n' | qemu-system-x86_64 -M q35 -display none -monitor stdio -m 128M
```
→ neither listing contains a `USB controller` or an `Audio controller`. `-M pc` has no `00:01.2`.

**A2 — `-usb` is gone; `usb=on` is the spelling.**
```sh
qemu-system-x86_64 -M pc -usb -display none      # -> "invalid option"
qemu-system-x86_64 -M pc,usb=on -display none    # -> USB controller 8086:7020 at 00:01.2
```

**A3 — `-M q35,usb=on` gives four controllers.** `8086:2934`, `8086:2935`, `8086:2936` (UHCI
companions) and `8086:293a` (EHCI).

**A4 — class codes and BAR shapes, via QMP rather than `xp`.**
```sh
printf '{"execute":"qmp_capabilities"}\n{"execute":"query-pci"}\n{"execute":"quit"}\n' \
| qemu-system-x86_64 -M pc,usb=on -display none -qmp stdio -m 128M \
    -audiodev wav,id=s,path=/tmp/x.wav \
    -device AC97,audiodev=s -device intel-hda -device hda-output,audiodev=s \
    -device qemu-xhci -device usb-ehci -device pci-ohci
```
→ `8086:7020` class `0x0c03` BAR4 io 32 · `8086:2415` class `0x0401` BAR0 io 1024, BAR1 io 256 ·
`8086:2668` class `0x0403` BAR0 mem 16384 · `1b36:000d` class `0x0c03` BAR0 mem 16384 ·
`8086:24cd` class `0x0c03` BAR0 mem 4096 · `106b:003f` class `0x0c03` BAR0 mem 256.

**A5 — BAR addresses and IRQ, after SeaBIOS assigns them.** Same command as A4, but issue
`query-pci` **~4 s after** `qmp_capabilities` instead of immediately (a bare `query-pci` at startup
reports every BAR as *not mapped*, which is a trap of its own):
→ UHCI BAR4 `0x0000C540`, AC97 BAR0 `0x0000C000` / BAR1 `0x0000C400`, **both devices `irq: 11`**.

**A6 — the audio negative control is 44 bytes, twice.**
```sh
qemu-system-x86_64 -M pc -display none -m 128M -monitor stdio \
  -audiodev wav,id=s,path=/tmp/a1.wav -device AC97,audiodev=s            <<< quit
qemu-system-x86_64 -M pc -display none -m 128M -monitor stdio \
  -audiodev wav,id=s,path=/tmp/a2.wav -device intel-hda -device hda-output,audiodev=s <<< quit
```
→ both files are **exactly 44 bytes**, and the header decodes as PCM (`0x0001`), 2 channels,
`44100` Hz, byte rate `176400`, block align 4, 16 bits, `data` length **0**.

**A7 — `intel-hda` has no `audiodev` property.**
`-device intel-hda,audiodev=s` → `Property 'intel-hda.audiodev' not found`.

**A8 — ARM64 `-M virt` has no PS/2, no USB, no audio, no VGA.**
```sh
printf 'info qtree\nquit\n' | qemu-system-aarch64 -M virt -cpu cortex-a57 -display none \
  -monitor stdio -m 128M | grep -c i8042        # -> 0   (the same grep on -M pc -> 2)
printf 'info pci\nquit\n'  | qemu-system-aarch64 -M virt -cpu cortex-a57 -display none \
  -monitor stdio -m 128M                        # -> host bridge + virtio-net-pci, nothing else
```
Default `-M virt` devices: `pl011`, `pl031`, `pl061`, `arm_gic`, `arm-gicv2m`, `gpex-pcihost`,
`gpex-root`, `virtio-mmio`, `cfi.pflash01`, `fw_cfg_mem`, `gpio-key`, `virtio-net-pci`.

**A9 — every USB controller instantiates on `-M virt`.** `qemu-xhci`, `nec-usb-xhci`, `usb-ehci`,
`piix3-usb-uhci`, `pci-ohci` — all accepted. `virtio-keyboard-pci`, `virtio-mouse-pci` and
`virtio-tablet-pci` are accepted on **both** `-M virt` and `-M pc`. `AC97` and `virtio-sound-pci`
refuse without an explicit `audiodev=`.

**A10 — `usb-kbd` is a full-speed device on port 1.**
```sh
printf 'info usb\nquit\n' | qemu-system-x86_64 -M pc,usb=on -display none -monitor stdio \
  -m 128M -device usb-kbd
```
→ `Device 0.0, Port 1, Speed 12 Mb/s, Product QEMU USB Keyboard`.

**A11 — MMCONFIG is not a shortcut.** `xp /1wx 0xB00_2_0008` on `-M q35` reports
`Cannot access memory` at startup. The 0xCF8/0xCFC mechanism `pci.dart` already uses is the only path
that needs no firmware cooperation, on either machine.

**A12 — repo figures.** `wc -l` and a comment-stripping grep over `core/kernel/`:
`ata.dart` 1251/554, `pci.dart` 500/203, `fb.dart` 854/381, `keyboard.dart` 268/72.
`pmmMaxFrames` = 32768 (`pmm.dart:611`). `port_inl`, `port_outl`, `port_inw`, `port_outw` are the four
`.global`s in `core/boot/portio.S`. No `f32`/`f64` anywhere under `core/kernel/`.

---

## Appendix B — repo facts this design depends on

| fact | where | why it matters here |
|---|---|---|
| `pciWrite32` does not exist; configuration space is read-only | `README.md` Tier 1; `pci.dart` has only `pciRead32` | **blocks every rung past USB1 and AUD1** |
| BME is set only where an option ROM ran | `README.md`, the three-way disagreement | UHCI and AC97 both arrive with bus mastering **off** |
| the PIC mask is eight whole-byte writes | `README.md` fix #1, eight named sites | both ladders are poll-only until it is fixed |
| nothing blocks | `blocking-and-threads.md`; GAP-0141 | survivable for USB, fatal for streaming audio (§5.1) |
| `allocFrame` returns single 4 KiB frames, does not zero them, bounded to 128 MiB | `pmm.dart:1090`, `pmm.dart:611` | UHCI's frame list fits **exactly**; every DMA structure must be zeroed by hand |
| `@bss` mutable statics exist since M17 | ADR-0021; `stale-comments.md` §D | driver state costs nothing; several headers still say otherwise |
| the timer is masked at rest; free-running is Tier 1 | `time-and-power.md` §0.2, §2.3 | AUD1–AUD3 need no timer; AUD4 needs the Tier 1 work |
| `fdwrite` caps at 512 bytes | `display-protocol.md` / `README.md` | 345 syscalls/second for CD-quality audio (§6.1) |
| the device-name sigil is `:`, and the branch goes in `fileSysOpen` | `namespace.md`; `README.md` | `audio:` is how ring 3 reaches AUD5 |
| ffmpeg is gated on size: 65,536 / 262,144 / 2,097,152 / 4096 | `exec-format.md` §4.2 | §6 builds on this rather than re-measuring |
| ffmpeg's libc gap is ~220–260 symbols against 41 | `libc-roadmap.md` §2.4 | ditto |
| `isrDispatch` is measured as *not* a hot file | `hot-files.md` §3 | a USB arm and an audio arm are fine to add |
| `-M virt` has no PS/2; serial input is the cheapest aarch64 answer | `arm64-port.md` (its `keyboard.dart` row) | §2.6 endorses it and adds the `-serial file:` note |
| `kmain.dart`'s `part` list is append-only and load-bearing | `hot-files.md` §1 | `usb.dart` and `ac97.dart` each append one line, and two agents appending last collide silently |
