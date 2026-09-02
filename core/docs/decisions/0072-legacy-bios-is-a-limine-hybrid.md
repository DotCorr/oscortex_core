# ADR-0072 — Legacy BIOS is the same Limine hybrid ISO, under SeaBIOS

**Status:** accepted, implemented, verified (`tests/conformance/p4-bios/run.sh`)
**Date:** 2026-08-30
**Milestone:** PORT4 (`docs/design/portable-hardware.md` PORT note)
**Files:** `core/scripts/build-uefi-image.sh` (`limine bios-install`,
require `limine-bios.sys`), `core/boot-uefi/limine.conf` (comment),
`core/tests/conformance/p4-bios/run.sh`
**Does not close** GAP-0001 on real hardware. Does not write amdgpu/i915/nouveau.
Does not add USB HID, NVMe, AHCI, or a GOP requirement on BIOS.
**Number:** 0072 — 0068 is USB1 xHCI; 0067 is G2. This file was one of
the 0068s.

---

## 1. The question

PORT1/PORT2 (ADR-0060, ADR-0061) proved OVMF + Limine loads the Multiboot1
kernel without `-kernel`. Old x86 machines do not have UEFI. GAP-0001
still named BIOS MBR as unbuilt. The laptop path stays UEFI; the load
*story* for a non-UEFI box is a second firmware on the same image.

## 2. The decision

1. **One ISO, two firmwares.** `build-uefi-image.sh` already carried
   Limine's El Torito BIOS files (`limine-bios-cd.bin`). It now
   *requires* `limine-bios.sys` and runs `limine bios-install` on the
   finished ISO so SeaBIOS can boot `-cdrom` *or* `-drive` without
   OVMF. p2-gop keeps using this builder; the UEFI half is unchanged.
2. **Same `limine.conf`, same `protocol: multiboot`.** BIOS is not a
   second entry point. `_start` still sees EAX magic and EBX info.
   Switching to the Limine protocol would skip `boot.S`.
3. **GOP is not required on BIOS.** SeaBIOS has no Graphics Output
   Protocol. `fb` may print any ADR-0064 winner: `FB GOP` (Limine
   filled the Multiboot VIDEO tag from VBE — measured on this host as
   1024×768 at `0xFD000000`), `FB BAR`, or `FB NONE`. The criterion
   is that `fb` ran and did not `#PF`, not that GOP won.
4. **No kernel change.** No `.bss`, no help line, no syscall,
   `wmeventStore` stays last. The Multiboot1 header (magic + flags 7)
   is untouched so `-kernel` stays the m0 gold.

## 3. What was measured on this host

BIOS command (no `-kernel`, no `-bios`, no pflash):

```
qemu-system-x86_64 \
  -cdrom hybrid.iso \
  -m 128M -serial file:serial.txt -display none -no-reboot
```

First serial line, byte-exact:

```
OSCORTEX M0 OK
```

Then the ordinary M1 capture through `M1 END`. `fb` printed:

```
FB GOP 0400x0300 00001000 00000000FD000000
```

Limine filled the Multiboot VIDEO tag from VBE (1024×768, the Bochs
BAR). That is allowed; it is not required. `-drive
file=hybrid.iso,media=cdrom,if=ide` printed the same first line.

`-kernel` on the same `kernel.elf`:

```
OSCORTEX M0 OK
…M1 END…
FB BAR FD000000 MODE 0320x0258x20 OK
```

## 4. Binary

`p4-bios/run.sh`:

* refuses to start without `qemu-system-x86_64`, `limine`, and
  `xorriso`, with the brew install line, not a silent skip;
* builds the ordinary `kernel.elf` (elf32-i386, Multiboot1 magic intact);
* packs it with the same `build-uefi-image.sh` p2-gop uses, and requires
  the ISO to contain `limine-bios.sys`, `limine-bios-cd.bin`, and
  `BOOTX64.EFI`;
* launches QEMU with `-cdrom` only — argv must not contain `-kernel`,
  `-bios`, `pflash`, or `OVMF`/`edk2`;
* requires the first serial line to be `OSCORTEX M0 OK\n` (m0-boot's
  contract) and `M1 END` after;
* requires `fb` to print `FB GOP` or `FB BAR` or `FB NONE` (GOP not
  required), and no `FAULT` / `PF CR2`;
* negative: `-kernel` still prints the M0 banner, `M1 END`, and the
  Bochs MODE line.

Anti-vacuity is the recorded argv (a `-kernel` boot cannot satisfy this
by accident) and the first-line byte compare (emptiness or a firmware
splash fails). Negative control is the Multiboot boot.

## 5. What this is not

Not a metal BIOS boot. Not a Ryzen laptop. Not USB HID. Not NVMe.
Not AHCI. Not a GOP requirement. Not a replacement for p2-gop.
QEMU SeaBIOS is the proof; a real MBR stick is still unverified.
