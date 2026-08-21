# ADR-0008 — PCI enumeration: finding hardware instead of knowing where it is

**Status:** accepted, implemented, verified (`tests/conformance/m5-pci/run.sh`)
**Date:** 2026-08-21
**Milestone:** M5 (`ROADMAP.md`)
**Files:** `core/kernel/pci.dart`, `core/boot/portio.S`, `core/scripts/build-kernel.sh`,
`core/kernel/shell.dart` (the `pci` command and the `help` line), `core/kernel/kmain.dart` (one
`part` directive), `core/tests/conformance/m2-console/qmp-drive.py` (two optional flags),
`core/tests/conformance/m5-pci/`

---

## 0. The problem this milestone actually solves

Every device this kernel drove through M4 was found by **knowing where it is**:

| device | address | why the kernel knows |
|---|---|---|
| 16550 UART | `0x3F8` | COM1 has been there since 1981 |
| 8259 PICs | `0x20`, `0xA0` | IBM PC/AT |
| 8253/8254 PIT | `0x40`–`0x43` | IBM PC |
| 8042 keyboard controller | `0x60`, `0x64` | IBM PC/AT |
| VGA text buffer | `0xB8000` | IBM VGA |
| VGA CRTC | `0x3D4`/`0x3D5` | IBM VGA |

Not one of those addresses was discovered. Every one is a constant compiled into the kernel, and
every one is a bet that the machine is shaped like a 1990 PC. The kernel has never asked a machine
what is present on it.

That is the ceiling this milestone lifts. **A PCI device is the first thing this kernel can find
without having been told**, and it is the shape every real driver begins with: a disk controller, a
NIC and a framebuffer are each located by enumerating a bus, reading a class code, and reading a base
address register.

## 1. Decision

Implement **PCI configuration mechanism #1** — the legacy `0xCF8` (address) / `0xCFC` (data) port
pair — in DCDart (`core/kernel/pci.dart`), and add a `pci` shell command that walks bus 0, follows
PCI-to-PCI bridges to the buses behind them, and prints one line per function that answers:

```
PCI 00:01.1 8086:7010 01/01/80 H00 ide storage
```

bus:device.function, vendor:device, class/subclass/prog-IF, the raw header-type byte, and a short
decoded class name from a `@rodata` table — **or no name at all** when the class is not in the table.

## 2. What is in assembly, and why that is not rule 3 being bent

`Port.outb`/`Port.inb` (DCDart ADR-0029) are the only port primitives DCDart has, and they are **byte
wide**. PCI configuration mechanism #1 is defined in terms of **doubleword** accesses: the PCI Local
Bus Specification decodes CONFIG_ADDRESS only for a full 32-bit access, so four byte writes to
`0xCF8..0xCFB` are not a legal substitute for one `outl`.

So `core/boot/portio.S` contains two functions and nothing else:

```
uint64_t port_inl(uint64_t port);
void     port_outl(uint64_t port, uint64_t value);
```

**This is the same category as `cpuid`, `lidt`, `int3` and `div`** — an instruction with no DCDart
primitive, reached over the plain C ABI, which is exactly what `OSCORTEX_SPEC.md` §5's table already
lists five of. It is *not* a workaround built here for a language gap that should have been closed
upstream (CLAUDE.md rule 3): the language gap is **filed as `docs/known-gaps.md` GAP-0066**, the ask
is narrow and named (`Port.outl`/`Port.inl`, precisely ADR-0029 one width wider), and this repo is
explicitly not the place to build it. When it lands, `portio.S` is deleted and two `@extern`
declarations become two `Port` calls.

The division is deliberate and is the one rule 3 asks for: **assembly provides the instruction, and
nothing else.** The selector layout, the enable bit, the register offsets, the presence test, the
multi-function decision and the bus recursion are all DCDart, in one readable file.

## 3. Decisions inside the walk

**3a. The multi-function bit is honoured, not ignored.** Functions 1..7 are probed only when function
0's header-type byte has bit 7 set. Scanning all eight unconditionally also "works" on QEMU and is
wrong: a single-function device may alias its function-0 registers across every function number, so a
blind scan reports one device eight times. Under QEMU's i440FX exactly one slot (00:01, the PIIX3)
sets the bit, and it is exactly the slot with extra functions — `m5-pci/run.sh` asserts both halves of
that, and asserts that no non-zero function appears on any other slot.

**3b. The raw header-type byte is printed.** `H80` versus `H00` is what makes 3a checkable from a
capture rather than a claim in a comment.

**3c. Bridges are followed, with two independent guards.** A type-1 header names the bus on its far
side; the scan recurses into it. `bus < secondary` is what makes the recursion terminate at all —
bus numbers strictly increase away from the host bridge, so a device claiming a secondary bus at or
below its own would otherwise be an infinite loop driven by a register value. A depth cap of 4 bounds
the 16KiB boot stack (there is no guard page — GAP-0007) even when the numbers are legal.

**3d. Unknown class codes get no name.** There is no "unknown device" string and no default entry: a
class the table does not list prints its raw `class/subclass/prog-IF` triple and stops. The raw
number is always exactly true; a guess would not be. `00:01.3` (the PIIX4 ACPI function, class
`06/80`) exercises this in the golden — it falls back to the class wildcard `bridge`, and no attempt
is made to name subclass `0x80`.

**3e. The class-name table carries its own lengths.** `pciClassNames` is 20 fixed 16-byte records:
class, subclass (or `0xFF` for "any"), name length, then 13 NUL-padded name bytes. The obvious
encoding — one `@rodata` table per name — would have added **twenty** more hand-maintained byte counts
to the forty-nine this kernel already carries (GAP-0060, which bit at M4). Putting the length inside
the record leaves exactly **one** hand-maintained number for the whole table, and `m5-pci/run.sh`
reads the table's bytes back out of the object file and checks every record's self-declared length
against its own name and padding. This does not close GAP-0060 — it collapses twenty instances into
one and then checks that one mechanically.

**3f. Nothing is retained.** The scan prints as it walks, exactly as `mbReport` does with the memory
map. **This subsystem costs zero donated `.bss`** — the first since M1 that does not grow
`core/boot/kdata.S` (GAP-0053), and `m5-pci/run.sh` asserts the total is *still* 392. That is not
virtue: it is the same limitation wearing a different hat, and the cost is that a later driver cannot
ask "which device did you find?" without walking the bus again (GAP-0067).

**3g. Configuration space is read-only here.** No writes, no BAR sizing, no capability list, no bus
mastering, no MSI. Rule 3's discipline applied to this repo's own scope: the milestone is *finding*
devices, and a write path with nothing to write would be untested code wearing a feature's name.

## 4. What the DCDart compiler forced

`dcc` rejects **nested `while` loops** ("nested while-loops are not supported yet"), hit here for the
first time in this project. The natural shape — a function loop inside the device loop inside
`pciScanBus` — is not expressible, so the inner loop became `pciScanFunctions1To7`, its own function.
The result is arguably clearer, which is exactly why it is worth recording: nothing in the source says
that a compiler limitation chose the decomposition. `docs/known-gaps.md` GAP-0068.

## 5. Verification (`tests/conformance/m5-pci/run.sh`)

Three real QEMU boots and eleven assertions. Two of them are the ones worth naming here.

**The kernel is checked against QEMU, not only against itself.** `qmp-drive.py` gained two optional
flags (`--monitor-command`, `--monitor-capture`) so the harness can capture QEMU's own `info pci`
from the *same boot*. The set of `bus:device.function` and `vendor:device` pairs the kernel found by
writing `0xCF8` must equal the set QEMU's device model reports. Two different programs describing the
same bus from different sources — a golden the kernel wrote and then agreed with proves much less.

**The bridge recursion is executed, not merely compiled.** QEMU's default i440FX has no PCI-to-PCI
bridge at all, so on the session boot the recursion is never entered once: it would pass every other
check here while being completely untested. A third boot adds `-device pci-bridge` with an e1000
behind it, and the kernel has to produce a `>BUS 01` suffix and find a device whose bus number is
`01` — output that cannot appear in any other boot, on a machine the other two boots do not have.

Also asserted: `port_inl`/`port_outl` encode as exactly `ed`/`ef` (a byte access would be `ec`/`ee`
and a 16-bit one would carry a `66` prefix — QEMU would silently widen a narrow access and hardware
would not, so this is the check that keeps the driver honest about a machine it has never run on);
the serial capture byte-for-byte with M1's 544-byte golden intact as a prefix; three `pci` blocks that
must be byte-identical, one of them run **after a deliberate `crash ud`**, so M4's recovery is
re-proved with a new subsystem on top; the 80x25 framebuffer read from guest physical memory; a PNG;
and a negative control.

## 6. Rejected alternatives

**Byte-wise writes to `0xCF8..0xCFB` using the `Port.outb` that already exists.** It would probably
have worked under QEMU — its memory core widens undersized accesses to a register whose
implementation declares a 4-byte minimum — and it is not what the bus specification says. It would
have been a driver that works on the emulator and fails on the hardware, with nothing in the source
admitting it. Rejected outright; this is the class of shortcut `OSCORTEX_SPEC.md` §3 already warns
about for `0xB8000`.

**Memory-mapped configuration space (ECAM / MMCONFIG).** The right long-term mechanism — it reaches
the extended 4KiB configuration space and needs no port I/O at all — but its base address comes from
the ACPI `MCFG` table, and this kernel has no ACPI parser, no RSDP scan, and (until the framebuffer
work) no mapping above 16MiB. Mechanism #1 is universally available on x86 and needs none of that.
GAP-0067.

**Scanning buses 0..255 exhaustively instead of following bridges.** It removes the recursion and the
stack question, and it is what a lot of small kernels do. Rejected because it reports devices behind
bridges that the *host* cannot actually reach in the general case, and because 8192 configuration
reads to avoid 30 lines is a trade in the wrong direction. The recursion is bounded and is tested.

**A device list in donated `.bss`.** Would let a later driver ask "where is the NIC?" without a
re-walk. Rejected for this milestone precisely because it is the GAP-0053 pattern again, and because
the physical memory manager (M6) is blocked on the *same* upstream decision — adding a second
subsystem that depends on assembly-donated storage before that decision is made would prejudge it in
the same wrong direction ADR-0006 §0 and `ROADMAP.md` already argue against. Recorded as GAP-0067
rather than built.
