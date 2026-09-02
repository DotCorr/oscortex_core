# ADR-0060 — UEFI OVMF + Limine loads the Multiboot1 kernel; GOP is a tag, not Bochs

**Status:** accepted, implemented, verified (`tests/conformance/p2-gop/run.sh`)
**Date:** 2026-08-30
**Milestone:** PORT1 + PORT2 (`docs/design/portable-hardware.md` §7)
**Files:** `core/boot/boot.S` (Multiboot1 VIDEO flag + video fields),
`core/kernel/gop.dart` (new, no `@bss`), `core/kernel/fb.dart` (`shellFb`
tries GOP first), `core/kernel/kmain.dart` (`part 'gop.dart'`),
`core/boot-uefi/limine.conf`, `core/scripts/build-uefi-image.sh`,
`core/tests/conformance/p2-gop/run.sh`
**Does not close** GAP-0001 on real hardware. Does not write amdgpu/i915/nouveau.
**Superseded for paint:** ADR-0061 maps the GOP aperture and proves a pixel.
**Number:** 0060 — 0059 is G0 virtio-gpu.

---

## 1. The question

The owner has a Ryzen / Windows laptop. QEMU's built-in Multiboot
`-kernel` loader is the only tested boot path (GAP-0001) and will not
boot that machine. The honest first step is not `amdgpu`. It is UEFI
firmware + a bootloader + (for a pixel) the GOP framebuffer Linux calls
efifb. Prove it in QEMU with OVMF first.

## 2. The decision

1. **Limine 12, Multiboot1, not the Limine protocol.** Limine is on this
   Mac (`brew install limine`, 12.2.0). `protocol: multiboot` hands the
   existing `_start` a 32-bit Multiboot1 machine: EAX magic, EBX info,
   paging off. The Limine protocol would enter at 64-bit and skip
   `boot.S`. That is a second entry point, not this ADR.
2. **OVMF is Homebrew's `edk2-x86_64-code.fd`, used as pflash.**
   `qemu-system-x86_64 -bios` on that file fails:
   `"could not load PC BIOS"`. Measured. The working command is two
   `-drive if=pflash` lines (CODE readonly + a writable copy of
   `edk2-i386-vars.fd`). There is no `OVMF.fd` on this machine.
3. **The Multiboot1 header gains flags bit 2 (VIDEO) and the 32-byte
   video trailer (mode_type 0, width/height 0, depth 32).** Limine on
   UEFI panics without it: `"multiboot1: Cannot use text mode with UEFI"`.
   QEMU's `-kernel` loader ignores the request. The first-line M0 banner
   and the 544-byte M1 capture are unchanged — measured, not assumed.
4. **`gop.dart` parses the Multiboot1 framebuffer tag (info flags bit
   12) from the pointer `shellInit` already stashed.** Zero `@bss`. Not
   last (D7 owns `wmeventStore`). No help line. No syscall. No write to
   `0x1CE`/`0x1CF`.
5. **`fb` is the printer.** If the tag is present and names a nonzero
   RGB aperture, `shellFb` prints `FB GOP <w>x<h> <pitch> <addr>` and
   returns. Otherwise the existing Bochs path runs. That is the
   negative control: `-kernel` does not set bit 12, so sit-in and
   m5-pci keep `FB BAR FD000000 MODE 0320x0258x20 OK`.

## 3. What was measured on this host

UEFI command (no `-kernel`):

```
qemu-system-x86_64 \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -cdrom uefi.iso \
  -m 256M -serial file:serial.txt -display none -no-reboot
```

Limine `resolution: 1024x768x32`. After `M1 END` the `fb` command printed:

```
FB GOP 0400x0300 00001000 0000000080000000
```

1024×768, pitch 4096, physical address `0x80000000`. That address is
**not** in `boot.S`'s 0–128 MiB map and **not** in the 3–4 GiB PCI hole.
A store there was a page fault. ADR-0060 printed the four numbers and
did not paint. ADR-0061 maps that range and proves a pixel.

`-kernel` on the same `kernel.elf`:

```
OSCORTEX M0 OK
…544-byte M1 capture unchanged…
FB BAR FD000000 MODE 0320x0258x20 OK
```

No `FB GOP` line.

## 4. Binary

`p2-gop/run.sh`:

* refuses to start without `qemu-system-x86_64`, OVMF CODE+VARS, `limine`,
  and `xorriso`, with the brew install line, not a silent skip;
* builds the ordinary `kernel.elf` (elf32-i386, Multiboot1 magic intact);
* packs it into an ISO with Limine `BOOTX64.EFI` (no `-kernel` on that
  QEMU line);
* requires `OSCORTEX M0 OK` and `FB GOP` whose width×height×pitch equal
  the resolution the harness itself wrote into `limine.conf`;
* requires the GOP address nonzero and not the Bochs BAR `0xFD000000`;
* negative: `-kernel` still prints the Bochs MODE line and no GOP.

Anti-vacuity is the 1024×768 choice (not 800×600). The negative control
is the Multiboot boot.

## 5. What this is not

Not a laptop boot. Not USB HID. Not NVMe. Not AHCI. Not amdgpu. Not a
mapped GOP aperture. Not PORT3 as a separate harness — PORT3's invariant
(the same image still works with `-kernel`) is the negative control
above, and `m0-boot` / `m1-interrupts` still run unchanged against that
image.
