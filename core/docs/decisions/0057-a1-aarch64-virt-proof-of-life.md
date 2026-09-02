# ADR-0057: A1 aarch64 virt proof of life — a parallel boot path, PL011 MMIO, PSCI exit 0

**Status:** VERIFIED — `core/tests/conformance/a1-boot/run.sh` reports an unqualified PASS: real
`dcc build --mode bare --target bare-aarch64` (`kmain_virt.dart`) + real assembly
(`boot-arm/boot.S`) + real `ld.lld -T kernel-arm.ld` + `verify-freestanding.sh` clean on the
linked ELF + a real `qemu-system-aarch64 -M virt-11.0,gic-version=2 -cpu cortex-a72 -m 128M
-kernel` boot whose captured serial matches `OSCORTEX A64 OK\n` byte-for-byte **and whose QEMU
exit status is 0** (PSCI `SYSTEM_OFF`). The `file(1)` of `core/build/kernel-arm.elf` is
`ELF 64-bit LSB executable, ARM aarch64`; the x86 `core/build/kernel.elf` was not overwritten
and remains `ELF 32-bit LSB executable, Intel 80386`.

Numbered **0057** because 0055 and 0056 were already claimed on this branch by parallel
compositor ADRs (`0055-a-click-reaches-the-client.md`,
`0056-chrome-is-compositor-policy.md`, `0059-virtio-gpu-is-recognised.md`).

**Implements** `docs/design/arm64-port.md` A1. **Does not implement** A0 (that exit lives in the
DCDart repo) or A2–A9.

## Decision

- **A parallel boot path, not a rewrite of `boot.S`.** `core/boot-arm/boot.S`,
  `core/arch/aarch64/kmain_virt.dart`, `core/link/kernel-arm.ld`,
  `core/scripts/build-kernel-arm.sh`. The x86 kernel, its harnesses, and `build-kernel.sh` are
  untouched. Output is `build/kernel-arm.elf`, not `build/kernel.elf`.
- **A separate library root.** DCDart has no conditional compilation (`arm64-port.md` STEP 2).
  Sharing `kmain.dart` via two part-lists is the document's option 1 and is still unverified;
  A1 does not take that risk. `kmain_virt.dart` is a tiny `@bare` file that only proves UART
  + halt.
- **`--target bare-aarch64` is real, and it was checked.** The design doc claimed DCDart emits
  aarch64; this build asserts `file` on `kmain_virt.o` says `ARM aarch64` before linking. A
  silent fallback to the default `bare-x86_64` target is a hard fail.
- **Proof of life is the PL011 at `0x09000000`, via `Volatile<u32>`.** No `Port` — aarch64 has
  no I/O port space (DCDart already rejects `Port` on this target). The address is hardcoded;
  A2 is the device-tree walk that makes it derived.
- **PSCI `SYSTEM_OFF` is two instructions in `boot.S`:** `ldr w0, =0x84000008; hvc #0`. DCDart
  cannot emit `hvc` (or `mrs`/`msr`). `kmain` calls `@extern psci_system_off`; `_start` falls
  through to the same label if `kmain` returns. The harness asserts QEMU exit 0, not timeout
  124 — a hang is a failure, which is the property every x86 harness still lacks.
- **`ld.lld` is enough.** No Multiboot header, no `elf32-i386` container, no GNU-ld hunt. Load
  address `0x40080000` (virt RAM starts at `0x40000000`; this is the address the design-doc
  probe already booted).
- **Machine pin:** `-M virt-11.0,gic-version=2 -cpu cortex-a72` under TCG. HVF is refused for
  the golden (`arm64-port.md` STEP 4).

## One real bug found against the real toolchain

PL011 `UARTFR.TXFF` (bit 5) is SET when the transmit FIFO is **full**. The 16550's `LSR.THRE`
is SET when the holding register is **empty**. Copying `uart.dart`'s
`(lsr & 0x20) < 1` wait onto the PL011 spun forever on an empty FIFO: QEMU exit 124, serial
empty, PSCI never reached. Disassembly showed `tbz w9, #5` looping while the bit was clear.
The wait is now `(fr & 0x20) > 0`. Measured both ways; only the second polarity prints and
exits 0.

## What this deliberately is not

No device tree, no GIC, no generic timer, no MMU, no PMM, no EL0, no virtio, no ECAM, no
framebuffer, no sharing of `uart.dart` / `kmain.dart`. Those are A2–A9. A0 — a
`bare-aarch64` conformance target **in DCDart** — is still that repo's to land; this tree
only consumed the enum case and proved it emits.

See `docs/known-gaps.md` GAP-0310.
