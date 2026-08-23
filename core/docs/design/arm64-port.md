# ARM64 — and the compiler question, which has already been answered

**Status: DESIGN. Nothing here is a decision.** Written by the ARM64 specialist against the tree as of
2026-08-23. This is the fourteenth document in `core/docs/design/`. The index's own "what this corpus
does not cover" line names ARM64 first and defers it: *"the compiler question comes first and belongs
to the DCDart repo."* This document went and asked. The answer is not the one the deferral assumed.

---

## The headline

**DCDart already emits aarch64, and `aarch64-unknown-none-elf` is a registered target named
`bare-aarch64`.** The ARM64 port is therefore **not** gated on a DCDart backend milestone. It is an
oscortex milestone from day one.

That contradicts this repo's own `CLAUDE.md`, rule 4, which states:

> DCDart's backend has only ever verified `x86_64-unknown-none-elf`

**That sentence has been false since DCDart's ADR-0033.** It should be corrected in the same change
that accepts this document, because it is the single belief that has kept ARM64 off every ladder in
the corpus.

The precise, honest version — because the corrected sentence is *also* not "aarch64 is done":

| claim | true? | evidence |
|---|---|---|
| The backend can emit aarch64 machine code | **yes** | `DCTarget.bareAarch64`, `linuxAarch64`, `macosAarch64`, `windowsAarch64` in `core/backend/lib/targets.dart` |
| aarch64 codegen is exercised on every test run | **yes, incidentally** | ~every conformance `run.sh` builds a second time with `--target host`, and **this host is arm64 macOS** — so all 32 conformance targets already compile and *run* their language feature as arm64 code |
| ADR-0033 verified it end to end | **yes** | "17 of the 18 example targets — including the entire ARC suite — ran natively on arm64 with no codegen change whatsoever. Only `m2-port` failed, exactly as predicted." |
| **`bare-aarch64` specifically has a conformance target** | **NO** | `grep -rl aarch64 core/tests/` in DCDart returns **nothing**. Every test names `bare-x86_64` or `host` |

So the gap is narrow and nameable: **`aarch64-unknown-none-elf` is enumerated but never built.**
Everything around it is proven — the same IR, the same ARC, the same traps, on arm64 — but always
against a *hosted* arm64 triple (`arm64-apple-macosx`) with a real linker and libc underneath.
`macos-arm64` differs from `bare-aarch64` in exactly the ways that matter to a kernel: object format
(Mach-O vs ELF), `forbidsRedZone`, and the absence of any entry stub.

DCDart's own registry comment states the rule that closes this: *"adding a third means adding a real
conformance target for it, not just an enum case."* ADR-0033 says the same in its consequences:
*"Adding a ninth target means adding a real conformance target for it."* By DCDart's own standard,
`bare-aarch64` was added as an enum case. **The one DCDart-side item this port owes upstream is a
`bare-aarch64` conformance target** — build an existing `@bare` example for it, link it with an
aarch64 `_start.S`, run it under `qemu-system-aarch64`, assert the exit status. That is a day, it is
DCDart's rule not ours, and it is the *only* DCDart work this port requires.

**Nothing else about the language is x86-shaped, with one exception, and that exception is already
decided.** See below.

---

## STEP 1 — The language, feature by feature

### `Port.inb`/`Port.outb` (ADR-0029, ADR-0045) — x86-only, and *already diagnosed as such*

This was flagged in the brief as "a language-design question, not just a codegen one." It is, and
**DCDart has already answered it**, which is the second surprise in this document.

`TargetArch.supportsPortIo` is a property on the target enum:

```dart
/// `Port.outb`/`Port.inb` (ADR-0029) emit x86 `outb`/`inb` inline asm.
/// They are x86-only AND ring-0-only. On any other arch the correct
/// behaviour is a clear compile-time error naming the instruction, not an
/// unreadable failure from `clang` about an unknown asm mnemonic.
bool get supportsPortIo => this == TargetArch.x86_64;
```

and `checkFeatureSupport(target, usesPortIo:)` rejects the combination *before* `clang` is invoked,
with a message that names the construct, the ADR and the target. Building `examples/m2-port` for
arm64 fails cleanly today.

**The design consequence for oscortex is the important half.** aarch64 has no I/O port space at all —
no separate address space, no `in`/`out` instruction, nothing. Every peripheral is memory-mapped.
There is no aarch64 `Port` to implement and **DCDart must never grow one**; the correct aarch64
primitive is a volatile load/store to a device address, and DCDart *already has that* as ADR-0041
(`volatile pointer access`), which is architecture-neutral and needs no new language surface.

So the port-I/O question resolves to: **not a DCDart gap, a kernel-driver-structure gap.** Six
oscortex files hold 78 `Port.*` call sites:

| file | `Port.*` sites |
|---|---|
| `core/kernel/ata.dart` | 34 |
| `core/kernel/interrupts.dart` | 16 |
| `core/kernel/uart.dart` | 13 |
| `core/kernel/keyboard.dart` | 9 |
| `core/kernel/vga.dart` | 4 |
| `core/kernel/pci.dart` | 2 |

Every one of those 78 is a *device access*, and on `-M virt` every one of those devices is either a
different device or absent. This is the reason the ARM64 port is mostly a **driver** port and only
secondarily a CPU port — a point the milestone ladder below is built around.

### `@bare` prelude — architecture-neutral except for `Port`

`core/runtime/dc-core-bare/prelude.dart` is 688 lines. Grepping it for x86 constructs returns hits in
exactly two places, both of them `Port` and its `u16` port-number type. There is **no** register
naming, no inline asm surface beyond ADR-0029's two fixed shapes, no calling-convention assumption.
ADR-0033 already recorded why: the emitted IR has no `datalayout`, no `dso_local` and no explicit
calling convention (`m0-target.md` §1 chose the plain C ABI deliberately), and the trap machinery
uses `llvm.trap`/`llvm.*.with.overflow.*`, which are recognised-by-name on every LLVM target. **The
plain-C-ABI decision made in M0 for readability is what makes this port cheap three years later.**

### `@bss` (ADR-0051) — architecture-neutral

`@bss final Bss idt = const Bss(bytes: 4096, align: 4096);` declares a zero-initialised symbol of a
given size and alignment. That is an ELF concept, not an x86 one, and `aarch64-unknown-none-elf` is
ELF. Alignment is *declared rather than inferred* — ADR-0051's own reasoning was "a hardware contract:
wrong alignment faults" — which is if anything more valuable on aarch64, where translation-table base
registers have stricter alignment rules than CR3 does. **No change required.** The only caveat is
semantic, not mechanical: the five oscortex `@bss` blocks are named `idt`, page tables, TSS and so on,
and on aarch64 those become a vector table, translation tables and no TSS at all. The *mechanism*
ports; the *contents* are STEP 3 work.

### `forbidsRedZone`

Already handled and already reasoned about for aarch64: `forbidsRedZone => isFreestanding`, applied to
aarch64 freestanding targets too, because "`clang` accepts `-mno-red-zone` there without complaint,
and asserting the property uniformly is safer than encoding an arch-by-arch exception list that a new
arch would silently fall out of." AAPCS64 has no red zone to disable, so this is a no-op that cannot
become a bug.

### The `verify-freestanding.sh` rule

Rule 1 of `CLAUDE.md` is unaffected: a `.bss` global introduces no undefined symbol on either arch,
and the script already normalises Mach-O's leading underscore. An aarch64 ELF object needs no new
normalisation.

**Summary of STEP 1: one DCDart item (a `bare-aarch64` conformance target, ~1 day, DCDart's own rule),
zero DCDart language changes, and an explicit standing decision that `Port` never grows an aarch64
implementation.**

---

## STEP 2 — Classifying `core/kernel/` (22,088 lines, 19 files)

### First, the structural problem that outranks every individual file

**The whole kernel is one DCDart library.** `kmain.dart` is the library root and the other eighteen
files are `part`s of it — forced, not stylistic: `dcc` lowers exactly one library per object file, so a
`@bare` function in an *imported* library is never compiled at all (GAP-0004 item 4). Every kernel
file's header restates this.

**And DCDart has no conditional compilation.** No `#ifdef`, no `-D`, no `bool.fromEnvironment`, no
`dart.library.*` conditional imports — `dcc build` takes a mode, a target and a source file, and that
is all. Grepping `core/dcc/lib/` and `core/backend/lib/` for any define/conditional mechanism returns
nothing but C-header emission and unrelated prose.

Put those two facts together and the consequence is sharp, and it is the single most important
*design* decision this port has to make:

> **There is no way to write `if (arch == arm64)` inside a kernel source file, and no way to include a
> file on one arch and not the other except by changing the `part` list.** Arch selection in oscortex
> can only happen at the granularity of *which files are in `kmain.dart`'s part list*.

`hot-files.md` already names that list as **"append-only and load-bearing"** — its whole point is that
two agents both appending break a third file. A two-architecture port turns that append-only list into
a *variant* list, which is a different and worse hazard.

Three options, and this document does not choose between them:

1. **Two library roots.** `kmain-x86_64.dart` and `kmain-aarch64.dart`, each a `part` list, with the
   portable files parted into both and the arch files into one. Costs: `part of 'kmain.dart'` is
   written literally at the top of all eighteen files and would have to become the variant name, which
   is a hot-file edit in every single file; and DCDart may not accept one file being `part of` two
   libraries in two separate builds (it should — they are separate `dcc` invocations — but **this is
   unverified and is the first thing an A0 milestone must check**).
2. **A generated part list.** `build-kernel.sh` writes `kmain.dart`'s part list from a manifest per
   arch. Removes the hot-file collision entirely (nobody edits the list, they edit a manifest), at the
   cost of a generated source file in a repo that has none.
3. **Ask DCDart for conditional compilation.** Rule 3 of `CLAUDE.md` says scope it to the narrowest
   real need — and this *is* a real need, surfaced by a real kernel. But it is also a language feature
   with a long tail, and options 1 and 2 need no DCDart change at all. **This document's
   recommendation is to exhaust 1 and 2 first**, and only escalate if both fail.

### The table

Classification is by *what has to happen to the file*, not by how much x86 text it contains. The
"x86 markers" column is a mechanical count of `cr0/2/3/4`, `rflags`, `rsp`, `rip`, `msr`, `gdt`, `idt`,
`tss`, `iretq`, `syscall`, `lapic`, `0x3F8`, `multiboot`, `ring3`, `dpl`, `cpuid`, `Port.` — useful as a
signal, misleading on its own (see `file.dart`).

| file | lines | x86 markers | verdict | why |
|---|---|---|---|---|
| `fat.dart` | 2,632 | **0** | **PORTABLE, unchanged** | Zero hits of any marker. FAT16 is a byte format; it does not know what a CPU is. The largest file in the kernel is also the one that needs nothing. |
| `file.dart` | 1,629 | 42 | **PORTABLE, unchanged** | Every one of the 42 is the word `syscall` or `ring 3` as a *concept* — the ABI it serves — not an instruction. It calls `fat*` and returns `fileRet*` codes. Nothing here is arch-shaped. |
| `heap.dart` | 436 | 14 | **PORTABLE, one abstraction** | `brk` over the VM layer. Its only arch contact is the page size baked in as `4096` (3 sites) and two `CR3` mentions in prose. Needs a `PAGE_SIZE` constant, not a rewrite — see the granule paragraph in STEP 3. |
| `pmm.dart` | 1,653 | 8 | **NEEDS AN ABSTRACTION** | A bitmap over 4 KiB frames. The allocator logic is arch-neutral; its *input* is not — 7 of its 8 hits are `Multiboot`, and aarch64 has no Multiboot. Needs a memory-map source behind an interface: Multiboot on x86, **device tree `/memory` node** on aarch64. Body unchanged. |
| `elf.dart` | 1,994 | 26 | **NEEDS AN ABSTRACTION** | ELF64 parsing is arch-neutral (and the container is already ELF on both). But it checks `EM_X86_64` in `e_machine`, and it hands `e_entry`/RSP/RIP/CR3/rflags to the ring-3 entry path. Split: the parser is portable, the "enter this image" tail is arch code. |
| `args.dart` | 645 | 25 | **NEEDS A REVIEW, probably portable** | All 25 markers are `RSP`. It builds the initial user stack (argc/argv/envp). SysV and AAPCS64 both want 16-byte stack alignment, but the *initial process stack contract* differs (aarch64 passes argc/argv in x0/x1 by the Linux convention rather than on the stack). One decision, not a rewrite. |
| `pci.dart` | 500 | 5 | **NEEDS AN ABSTRACTION (and it is the interesting one)** | Only 2 `Port.*` sites — but they are `0xCF8`/`0xCFC`, the legacy config mechanism, which **does not exist on aarch64 at all**. On `-M virt` PCIe config space is ECAM: a memory-mapped window whose base comes from the device tree. The *enumeration walk* above `pciRead32` is entirely reusable; only the 5-line accessor changes. This is the best-shaped file in the kernel for porting. |
| `uart.dart` | 239 | 21 | **MUST BE REWRITTEN (small)** | 239 lines of 16550 at `0x3F8` over 13 `Port.*` sites. `-M virt` has a **PL011 at `0x09000000`**, MMIO, entirely different register map. But the *interface* (`uartPutChar`, `uartPuts`) is three functions wide, so everything above it — including all 20 harnesses' serial assertions — is untouched. Rewrite the driver, keep the API. |
| `keyboard.dart` | 268 | 10 | **MUST BE REWRITTEN or DROPPED** | i8042 PS/2 controller at ports `0x60`/`0x64`. `-M virt` has **no PS/2 controller and no ISA bus**. Input on `virt` is USB HID (`-device usb-kbd` on the XHCI controller) or virtio-input — both far larger than a PS/2 poll. **The honest first move is to drop keyboard input on aarch64 entirely** and drive the shell from serial input, which the UART already carries. |
| `vga.dart` | 442 | 10 | **DROPPED** | VGA text mode at `0xB8000` with CRTC index/data ports. There is no VGA text mode on aarch64 and no `0xB8000`. Not portable, not replaceable, not needed — `OSCORTEX_SPEC.md` §3 already chose serial over VGA. |
| `fb.dart` | 854 | 20 | **MUST BE REWRITTEN** | 45 mentions of `vbe`: the Bochs VBE (dispi) interface, a BIOS-era ISA-port protocol. QEMU's `bochs-display` PCI device *can* be attached to `-M virt` and exposes the same dispi registers through a BAR rather than ports — so this is closer to a rewrite of the *access path* than of the drawing code. But `gpu.md` already argues for VirtIO-GPU, which is the same answer on both arches, so **this file may be overtaken rather than ported**. |
| `ata.dart` | 1,251 | 37 | **MUST BE REWRITTEN or DROPPED** | The heaviest port-I/O user in the kernel: 34 `Port.*` sites on the legacy ATA task-file at `0x1F0`. There is **no IDE controller on `-M virt`**. Storage there is virtio-blk (or AHCI via `-device ahci`). `storage.md` already proposes AHCI for x86; **choosing virtio-blk instead makes one driver serve both arches** and deletes 1,251 lines from the ARM64 tree. This is the single largest lever in the port. |
| `multiboot.dart` | 274 | 12 | **REPLACED WHOLESALE** | Multiboot1 does not exist on aarch64 — see STEP 3. Its replacement is a device-tree reader of comparable size, and its *consumers* (`pmm.dart`, the RAM report) are the reason it must be an abstraction rather than a deletion. |
| `shell.dart` | 1,642 | 32 | **MOSTLY PORTABLE** | A command loop over `file*`/`fat*`/`proc*`. Its 32 markers are the PIC-mask writes the index already flags as a bug (`shell.dart:1085,1090`) plus command names. Once the PIC-mask consolidation the index demands lands, the arch surface here is close to zero. **Fixing that bug first makes this file free.** |
| `kmain.dart` | 294 | 21 | **NEEDS AN ABSTRACTION** | The part list (above) plus the boot-time init order: GDT, IDT, PIC, PIT. Order and names change; shape does not. |
| `interrupts.dart` | 620 | 68 | **MUST BE REWRITTEN** | IDT construction, 8259 PIC remapping, PIT programming, and every handler body. On aarch64: a **vector table (`VBAR_EL1`)**, the **GIC**, the **generic timer**. Every one of the 16 `Port.*` sites is the PIC or the PIT. The handler *bodies* (what to do about a page fault) are partly salvageable; the delivery machinery is not. |
| `vm.dart` | 2,317 | 66 | **MUST BE REWRITTEN** | A 4-level x86-64 page table installed in CR3, with the `[3 GiB, 4 GiB)` PCI-hole identity map the index's ADR-0002 correction relies on. aarch64 uses TTBR0/TTBR1, a different descriptor format, different permission bits and MAIR-indexed memory attributes. The *policy* (which region gets which permissions) ports; not one line of the descriptor code does. |
| `proc.dart` | 2,554 | 85 | **MUST BE REWRITTEN (context switch) / PORTABLE (scheduler)** | The process table, states and scheduling policy are arch-neutral and are most of the file. The saved-register set, the switch, and the syscall return path are not. This is the file that most needs splitting along a seam it does not currently have. |
| `user.dart` | 1,844 | **202** | **MUST BE REWRITTEN** | The densest x86 file in the kernel by a factor of 2.4. Ring 3, CPL, the TSS, `iretq`, the syscall gate — aarch64 has **EL0/EL1**, no TSS, `eret`, and `SVC`. Nothing survives except the *idea*. |
| `core/boot/boot.S` (1,017) | — | — | **MUST BE REWRITTEN, and it gets SHORTER** | See below. |
| `core/boot/isr.S` (1,056) | — | — | **MUST BE REWRITTEN** | 1,056 lines of x86 interrupt stubs. aarch64's vector table is 16 entries of 128 bytes with the exception *cause* in `ESR_EL1` rather than a vector number, which is a genuinely smaller construct. |
| `core/boot/kdata.S` (281) | — | — | **MOSTLY DELETED** | GDT and TSS descriptors. aarch64 has neither. M17 already moved most symbols out of it; the index warns that 41 stale comments still tell readers to edit it. |
| `core/boot/portio.S` (112) | — | — | **DELETED, and the index already wants it gone on x86 too** | `GAP-0066`'s status is stale: word/dword port I/O is on the DCDart pin, so this file is already removable work on x86. On aarch64 it is meaningless. |

### `boot.S` gets shorter, which is the pleasant surprise of STEP 2

`core/boot/boot.S` is 1,017 lines, and a large fraction of it exists to solve problems aarch64 does
not have:

* **No 32-bit→64-bit transition.** QEMU's `-M virt` enters the kernel at **EL1 (or EL2) in AArch64
  already**. There is no protected-mode stanza, no `lgdt`, no far jump, no `long_mode_start`.
* **No GDT.** aarch64 has no segmentation. `gdt_base`, `tss64`, `zero_tss`, `tss_base` — gone.
* **No CPUID feature dance.** `no_sse`, `skip_osfxsr`, `no_nx`, `skip_nxe`, `skip_sse_cr0`,
  `skip_fninit` are six labelled branches guarding SSE and NX detection. On aarch64, NEON is
  architectural (it needs one `CPACR_EL1` store, not a feature test), and NX is `UXN`/`PXN` bits in
  the descriptor, always present.
* **No Multiboot header.** The `.section .multiboot` block goes.

What *replaces* them is real but smaller: set `VBAR_EL1`, drop from EL2 to EL1 if the firmware left us
at EL2 (QEMU `-M virt` starts at EL1 by default without `virtualization=on`, so this may be optional),
configure `MAIR_EL1` and `TCR_EL1`, install `TTBR0_EL1`/`TTBR1_EL1`, enable the MMU via `SCTLR_EL1`.
**A defensible estimate is 400–500 lines against the current 1,017.** The rule-4 argument in
`CLAUDE.md` — that boot assembly stays boot assembly — is unchanged and applies identically.

### The counts

| verdict | files | lines |
|---|---|---|
| portable unchanged | `fat.dart`, `file.dart` | **4,261** |
| portable after a small abstraction | `heap.dart`, `pmm.dart`, `elf.dart`, `args.dart`, `pci.dart`, `shell.dart`, `kmain.dart` | 7,385 |
| rewritten or dropped | `uart`, `keyboard`, `vga`, `fb`, `ata`, `multiboot`, `interrupts`, `vm`, `proc`, `user` | 10,442 |

**Roughly 19% of the kernel is portable as written, 33% needs an abstraction, and 47% is arch code.**
That ratio is worse than a mature kernel's and it is worth saying why plainly: this kernel has never
had a reason to grow an arch seam, so it does not have one. The abstraction work in tier two is
mostly *creating that seam*, and every hour of it is repaid on the third architecture — but there is
no third architecture, so it must be justified by the second alone.

## STEP 3 — The pieces with no x86 counterpart

Everything in this section was **measured on this machine**, not recalled. `qemu-system-aarch64
11.0.0` and `dtc` are both installed; the device tree below came from
`qemu-system-aarch64 -M virt,dumpdtb=virt.dtb -cpu cortex-a72 -m 128M`, and the boot facts came from
actually booting a hand-written aarch64 ELF (STEP 4).

### EL0/EL1 instead of rings — replaces `user.dart`'s CPL, the GDT and the TSS

x86-64 has four privilege rings selected by the low two bits of CS, reached through a descriptor in
the GDT, with a per-CPU TSS holding the ring-0 stack pointer that the CPU loads automatically on a
privilege change. `user.dart` (1,844 lines, 202 x86 markers) is built entirely on that machinery.

aarch64 has **exception levels**: EL0 (user), EL1 (kernel), EL2 (hypervisor), EL3 (firmware). They
are not selected by a segment descriptor because there are no segments — there is no GDT and no TSS.
The kernel stack pointer for EL1 is simply `SP_EL1`, a *separate architectural register* that the
hardware swaps in on exception entry; there is no table for the CPU to look it up in. Going down to
EL0 is `eret` with `SPSR_EL1` set to the target level; coming back up is any exception, including the
deliberate one, `SVC` — which is aarch64's syscall instruction and, unlike x86, is a plain
exception through the same vector table as a page fault rather than a special gate.

**What this deletes:** the GDT, the TSS, `kdata.S`'s descriptor tables, `iretq`, the ring-3 stack
switch, and the whole class of bug where a descriptor's DPL disagrees with a selector's RPL.
**What it costs:** `user.dart` and the syscall half of `proc.dart` are rewritten, not ported.
`file.dart`, which *serves* the syscall ABI, does not change at all — that separation already exists
and is the reason the ARM64 port is survivable.

### The GIC instead of the 8259 pair — replaces `interrupts.dart`'s PIC half

x86 inherits two cascaded 8259 PICs, programmed through four I/O ports, that must be *remapped* out
of the exception range at boot because IBM wired IRQ0 to vector 8 in 1981. `interrupts.dart` spends
16 `Port.*` sites on this, and the index already records that **eight whole-byte PIC-mask writes are
scattered across five files and silently re-mask every IRQ they do not name.**

`-M virt` provides a **GICv2** (`compatible = "arm,cortex-a15-gic"`) at two measured addresses: the
distributor at `0x08000000` (64 KiB) and the CPU interface at `0x08010000` (64 KiB), plus a
`gic-v2m-frame` MSI controller at `0x08020000`. All three are **memory-mapped** — the driver is
volatile loads and stores through `Pointer<u32>` (ADR-0041), with no `Port` anywhere.

Three consequences worth naming:

* **There is no remapping step.** Interrupt IDs are architectural: SPIs start at 32, PPIs at 16,
  SGIs at 0. The 1981 problem does not exist.
* **The mask register is per-interrupt, not a byte.** `GICD_ISENABLER`/`GICD_ICENABLER` are
  set-to-enable / set-to-disable *bit* registers — writing one bit cannot disturb another. **The
  eight-whole-byte-write bug the index lists as fix #1 is structurally impossible on the GIC.** The
  x86 fix is still needed; the ARM64 port simply cannot reintroduce it.
* **MSI comes for free, at the first milestone rather than the eighth.** The v2m frame is present in
  the device tree from boot. `net-e1000.md` polls for seven milestones because x86 MSI needs the
  APIC, which needs ACPI. On aarch64 there is nothing to unlock.

### The generic timer instead of the PIT — replaces `interrupts.dart`'s PIT half

x86 uses an Intel 8253/8254 PIT: a 1.193182 MHz oscillator divided by a 16-bit reload value,
programmed through ports `0x40`–`0x43`. The corpus's Tier-1 item is about this device — mode 3 vs
mode 2, half-period ambiguity, a free-running counter for sub-tick time.

aarch64 has the **ARM generic timer** (`compatible = "arm,armv8-timer"`, and the device tree marks it
`always-on`). It is not a device at all: it is a set of system registers. `CNTFRQ_EL0` reports the
frequency, `CNTPCT_EL0` is a **64-bit free-running physical counter that always runs**, and
`CNTP_CVAL_EL0` / `CNTP_TVAL_EL0` set the next interrupt as an absolute or relative deadline. Its
interrupt is PPI 13/14 (measured in the `timer` node).

**This is the single largest simplification in the port.** The corpus's whole first Tier-1
milestone — "sub-tick time and a free-running PIT, and this is now FIRST, not optional" — exists to
build, on x86, something aarch64 has architecturally: a counter that runs while the machine is idle,
readable at full width, with no divisor arithmetic and no mode-3 ambiguity. `CNTPCT_EL0` *is*
GAP-0058's answer. And because it is a system register rather than MMIO, reading it needs `mrs` —
which DCDart cannot emit today (see the gap at the end of STEP 5).

### TTBR0/TTBR1 and granules instead of CR3 — replaces `vm.dart`

x86-64 has one page-table root register, CR3, holding one 4-level tree covering the whole 48-bit
space. Kernel and user share it; separation is the U/S bit in each entry. `vm.dart` is 2,317 lines of
this, including the `[3 GiB, 4 GiB)` identity map for the PCI hole.

aarch64 has **two** roots. `TTBR0_EL1` translates the low half of the address space and `TTBR1_EL1`
the high half, with the split configured by `TCR_EL1.T0SZ`/`T1SZ`. Kernel mappings live in TTBR1 and
user mappings in TTBR0, so **a context switch writes TTBR0 only and never disturbs the kernel map** —
what x86 achieves by copying kernel PML4 entries into every address space, aarch64 gets from the
hardware. TLB maintenance is explicit (`TLBI` plus `DSB`/`ISB`), where x86 mostly gets it from the
CR3 write itself.

**Granule size is a genuine new axis with no x86 analogue.** x86-64's page size is 4 KiB, full stop.
aarch64 implementations choose among **4 KiB, 16 KiB and 64 KiB** translation granules, and the
choice changes the number of levels, the descriptor field widths, and the address split. The kernel
must pick one and encode it as a constant rather than assuming 4096 — which is exactly why
`heap.dart`'s three bare `4096` literals and `pmm.dart`'s eight are classified as "needs an
abstraction" rather than "portable". **Recommendation: pick 4 KiB and say so in an ADR**, because it
keeps `pmm.dart`'s bitmap arithmetic and all the frame-count goldens numerically identical to x86, and
because 4 KiB is mandatory-to-implement on every aarch64 CPU while 16 and 64 are optional.

Memory *attributes* also move. x86 encodes cacheability in PAT/MTRR — `memory.md` notes the kernel
has never read an MTRR, so the framebuffer's effective type is unknown to it. aarch64 puts an
**index** in each descriptor pointing into `MAIR_EL1`, an eight-entry table the kernel writes once at
boot. That is strictly easier to reason about and it closes GAP-0071 by construction on this arch:
the kernel cannot *not* know the memory type, because it wrote the table.

### Device tree instead of PCI enumeration — replaces `multiboot.dart`, and reshapes `pci.dart`

On x86 the kernel finds devices two ways: it *knows* the legacy addresses (`0x3F8`, `0x1F0`, `0x60`),
or it walks PCI config space through the `0xCF8`/`0xCFC` port pair. `multiboot.dart` separately
supplies the memory map.

On `-M virt` there are **no legacy addresses to know** and **no `0xCF8`**. Instead the firmware places
a **flattened device tree blob in `x0`** at kernel entry, and everything is in it. Measured, from the
real dump:

| node | address | what it replaces |
|---|---|---|
| `memory@40000000` | `0x40000000`, 128 MiB with `-m 128M` | the Multiboot memory map |
| `pl011@9000000` | `0x09000000` | the 16550 at `0x3F8` |
| `intc@8000000` | dist `0x08000000`, cpu `0x08010000` | the 8259 pair |
| `pcie@10000000` | ECAM at **`0x4010000000`**, 256 MiB | `0xCF8`/`0xCFC` |
| `pl031@9010000` | `0x09010000` | the CMOS RTC at `0x70`/`0x71` |
| `virtio_mmio@a000000` | 32 slots at `0x0a000000`, stride `0x200` | — (no x86 equivalent) |
| `psci` | `method = "hvc"` | ACPI shutdown |
| `timer` | system registers, PPI 13/14 | the PIT |

**Two of those rows deserve their own sentence.**

First: **RAM starts at 1 GiB, not 0.** `memory@40000000`. Every x86 assumption that low physical
memory exists is false here — there is 64 MiB of CFI flash at `0x00000000` instead. `pmm.dart`'s
bitmap is written for a map that starts near zero; it must become base-relative. This is the kind of
thing that works on every harness until someone hardcodes a frame number.

Second: **PCI is not gone, it moved.** `pci-host-ecam-generic` means config space is a memory window:
device *(bus, dev, fn, reg)* is simply an offset into it. `pci.dart`'s 500 lines of enumeration walk
are entirely reusable; only `pciRead32`/`pciWrite32` change, from two `Port` calls to one address
computation and a volatile load. **`pciWrite32` is already Tier-1 on the x86 ladder for the NIC and
storage DMA — writing it as an abstraction rather than a port pair serves both arches at once, and
this is the strongest argument in this document for doing the ARM64 abstraction work *early*, while
that function is being written anyway rather than after.**

The device-tree reader itself is new code with no x86 counterpart: an FDT is a big-endian,
null-terminated-string, tag-structured blob. Parsing enough of it to find `/memory`, `/chosen`, the
UART and the GIC is on the order of 300–400 lines — comparable to `multiboot.dart`'s 274, which is
the honest framing: **not new work, replacement work.**

### No BIOS and no Multiboot — and this one turned out better than expected

`core/link/kernel.ld` sets `OUTPUT_FORMAT(elf32-i386)` and `boot.S` carries a `.section .multiboot`
header, both for one reason recorded in the build script: *"QEMU's Multiboot loader rejects a 64-bit
ELF container."* That forces a 32-bit container, a 32-bit entry stub, a protected-mode stanza and a
long-mode transition, and it forces the build to find `x86_64-elf-ld` because **lld refuses
`elf32-i386` outright.**

**None of that applies on aarch64, and I verified it rather than assuming it.** `-M virt` has no BIOS,
no Multiboot, no real mode and no 32-bit mode to leave. `qemu-system-aarch64 -M virt -kernel` accepts
a **plain 64-bit aarch64 ELF** and jumps to its entry point. The alternative on real hardware is UEFI
or a raw `Image`, but for the harness the ELF path is direct.

Measured, on this machine, with a 17-line hand-written `k.S`:

```
$ clang --target=aarch64-unknown-none-elf -mno-red-zone -c k.S -o k.o     # assembles
$ ld.lld -Ttext=0x40080000 -e _start k.o -o k.elf                          # links, plain lld
$ timeout 10 qemu-system-aarch64 -M virt -cpu cortex-a72 -m 128M \
      -kernel k.elf -serial file:serial.txt -display none -no-reboot
QEMU_EXIT=0
$ cat serial.txt
OSCORTEX A64 OK
```

Three separate things fell out of that one run:

1. **No Multiboot header, no elf32 container, no 32→64 transition.** The ELF is entered directly.
2. **`ld.lld` links it.** The x86 build's whole `find_elf_linker` dance — GNU ld required, lld
   explicitly documented as "will not work with the current link script", Homebrew keg-only paths —
   **does not exist on aarch64.** Ordinary lld is sufficient. That removes a real setup barrier.
3. **The kernel shut the machine down itself, and QEMU exited 0.**

That third one is the one to dwell on, because the corpus has a Tier-1 milestone about it.

### PSCI: aarch64 gets for free what the ACPI+APIC milestone is largely for

The index's Tier-1 case for ACPI+APIC says, in the time specialist's sharpened form: *"the real gap is
that the guest never terminates itself and never reports a status, which has been true since M0."*
All 20 harnesses currently boot `qemu-system-x86_64` and treat `timeout`'s exit 124 as the expected
termination path.

`-M virt`'s device tree carries a `psci` node with `method = "hvc"`. **`SYSTEM_OFF` is
`ldr w0, =0x84000008; hvc #0` — two instructions, available at the first milestone, with no tables to
parse.** The run above is the proof: exit **0**, not 124. A second probe confirmed the CPU starts at
**EL1** (`mrs x4, CurrentEL` printed `EL1`) under `-cpu cortex-a72`, so `hvc` reaches the PSCI
implementation without any EL2 setup.

So on ARM64, the guest can terminate itself and report a status **from milestone A1**, and the
harnesses can assert an exit code instead of tolerating a kill. That does not make the x86 ACPI/APIC
milestone unnecessary — it still wants MSI and a microsecond clock — but it removes shutdown from
that milestone's justification on one of the two arches, and it means **the ARM64 harnesses are
strictly better instrumented than the x86 ones from day one.**

## STEP 4 — QEMU `-M virt`, and how a harness verifies an ARM64 boot

### What `-M virt` provides

`-M virt` is a machine that never existed in hardware: QEMU invents a clean aarch64 platform and
describes it entirely in a device tree, precisely so a guest needs no board-specific knowledge. The
full measured inventory, from the dump:

* **CPU** — one `cortex-a72` (or `-cpu max`); entry at **EL1**; SMP via `-smp`, with secondary cores
  started by PSCI `CPU_ON` rather than x86's INIT-SIPI-SIPI dance.
* **RAM** — `memory@40000000`, base **1 GiB**, size from `-m`.
* **Serial** — **PL011 at `0x09000000`**, IRQ SPI 1, `stdout-path` in `/chosen`, aliased `serial0`.
* **Interrupts** — GICv2 dist `0x08000000` / cpu `0x08010000`, MSI v2m frame `0x08020000`.
  (`-M virt,gic-version=3` gives a GICv3 instead, with a redistributor and system-register access;
  **v2 is the simpler target and the default here** — pin it explicitly in the harness so a future
  QEMU default flip cannot move it.)
* **Timer** — ARM generic timer, system registers, `always-on`.
* **PCIe** — `pci-host-ecam-generic`, config `0x4010000000`+256 MiB; 32-bit MMIO window at
  `0x10000000`, 64-bit window at `0x8000000000`.
* **virtio-mmio** — 32 slots at `0x0a000000`, stride `0x200`. **This is the ARM64 shortcut**: a
  virtio-blk or virtio-net device can be driven without any PCI code at all, at a fixed address from
  the device tree.
* **RTC** — PL031 at `0x09010000`. (Cheaper than x86's CMOS: no index/data port pair.)
* **Shutdown** — PSCI `SYSTEM_OFF` over `hvc`. Also a PL061 GPIO at `0x09030000` for gpio-poweroff.
* **fw-cfg** — `0x09020000`, the same channel x86 has.
* **Flash** — 64 MiB CFI at `0x00000000`, where UEFI (`edk2-aarch64-code.fd`) would go if this were a
  firmware boot rather than `-kernel`.

**A note on this host, since it changes the cost of everything above.** This machine is arm64 macOS.
That means the ARM64 harnesses run under **TCG** as things stand, exactly as the x86 ones do — QEMU
is emulating aarch64 on aarch64 because `-cpu cortex-a72` forces TCG. Switching to `-cpu host
-accel hvf` would run the guest **natively**, and would make the ARM64 suite substantially faster than
the x86 suite on this hardware. **That is a tempting optimisation and this document recommends
against taking it in the ladder**: HVF and TCG differ in timer behaviour and in which CPU features are
exposed, and a suite that passes under one and not the other is worse than a slow suite. Pin
`-cpu cortex-a72` + TCG for the goldens; use HVF only for interactive work.

### How a harness verifies an ARM64 boot

`m0-boot/run.sh` is the template and it maps across almost unchanged, because **its assertion is about
bytes on a serial line, and both machines have a serial line.** Its five steps:

| step | x86 today | aarch64 |
|---|---|---|
| 1. build | `build-kernel.sh`: `dcc` + `clang` on `boot.S`/`isr.S`/`kdata.S` + `x86_64-elf-ld -T kernel.ld` | same shape; `--target bare-aarch64`, `--target=aarch64-unknown-none-elf`, and **`ld.lld` suffices** |
| 2. freestanding | `verify-freestanding.sh` on `kernel.elf` | **unchanged** — the allowlist is symbol names, not instructions |
| 3. boot | `timeout 5 qemu-system-x86_64 -kernel ... -serial file:... -display none -no-reboot` | `timeout 10 qemu-system-aarch64 -M virt -cpu cortex-a72 -m 128M -kernel ...`, same three I/O flags |
| 4. terminate | exit 124 from `timeout` is the **expected** path | **exit 0 from PSCI `SYSTEM_OFF`** — assert it |
| 5. assert | `head -c` on the exact expected byte length, `cmp` against `OSCORTEX M0 OK\n` | **byte-identical** |

Step 5 not changing is the important part. The serial *device* is a PL011 instead of a 16550, but
`-serial file:` captures the same bytes either way, so **every existing serial golden is portable
as-is** — the driver under it changes, the assertion does not.

Step 4 is where the ARM64 harness is *better* than its x86 sibling. Today `m0-boot` explains at
length why exit 124 is expected and only exit codes other than 0 and 124 are failures. On aarch64 the
correct assertion is `QEMU_EXIT -eq 0`, and **a hang becomes a detectable failure rather than the
normal case.** The x86 harnesses cannot distinguish "halted correctly" from "hung"; the ARM64 ones
can, from the first milestone.

**Two anti-vacuity traps carry over, and one is worse here.** The index warns that no criterion may
derive an expectation from an `xp` dump of a device BAR, because `xp` reads MMIO in 4-byte units
regardless of the width typed. That is unchanged. But the index's other trap — the e1000 option ROM
sending seven packets before any guest runs — has an ARM64 analogue that is **easier to fall into**:
on `-M virt` there is no option ROM, so a "capture is non-empty" test is safe, *but* `-serial file:`
combined with `stdout-path` in `/chosen` means a guest that does nothing still produces no output,
while **UEFI firmware, if anyone switches from `-kernel` to a flash boot, prints a great deal.** Any
serial criterion must therefore assert a **prefix or an exact byte count**, never non-emptiness — which
`m0-boot` already does correctly with `head -c`, and which the ARM64 copies must not relax.

A third, ARM64-specific trap: **`-M virt` is a versioned machine.** QEMU 11.0.0 is what is installed
here; `-M virt` is an alias that tracks the newest revision and its device tree can change between
QEMU releases. Goldens derived from measured addresses should pin a versioned alias
(`-M virt-11.0`) or re-derive the address from the device tree at runtime rather than hardcoding it.
The addresses in this document are `-M virt` on **QEMU 11.0.0** and are not promised beyond it.

## STEP 5 — The milestone ladder, and an honest count of the harnesses

Binary exit criteria only, per `CLAUDE.md` rule 2. Every criterion below is mechanically checkable and
several are already demonstrated in this document.

### A0 — `bare-aarch64` becomes a verified DCDart target *(DCDart repo, not this one)*

The only upstream item. DCDart's own registry comment and ADR-0033's consequences both state that
adding a target means adding a conformance target for it, and `bare-aarch64` does not have one.

> **Exit:** a new `core/tests/conformance/bare-aarch64/run.sh` in **DCDart** builds an existing `@bare`
> example with `--target bare-aarch64`, links it against a hand-written aarch64 `_start.S` (the same
> shape `ffi-extern/run.sh` step 3 already uses for x86), runs it under `qemu-system-aarch64 -M virt`,
> and asserts the expected output and exit status. Green.

**Blocked today, and not on anything to do with ARM64.** `dcc` does not run on this host at all: the
vendored frontend's `kernel` package declares Dart language version 3.12 and the installed SDK is
3.11.0, so `dart .../dcc.dart build` fails with 49 "language version too high" errors — **identically
for `--target bare-x86_64` and `--target bare-aarch64`.** That is a pre-existing, arch-neutral
toolchain break and it gates A0, the x86 suite, and this document's ability to have proved STEP 1
end to end. **It should be fixed first and it is not ARM64 work.**

### A1 — proof of life

> **Exit:** `core/tests/conformance/a1-boot/run.sh` builds a `@bare` DCDart `kmain` for
> `bare-aarch64`, links with an aarch64 `boot.S`, boots under
> `qemu-system-aarch64 -M virt -cpu cortex-a72 -m 128M -kernel`, captures serial to a file, and asserts
> the first bytes are exactly `OSCORTEX A64 OK\n` **and that QEMU exited 0** (PSCI `SYSTEM_OFF`), and
> `verify-freestanding.sh` reports a clean pass on the linked ELF.

**The assembly half of A1 is already demonstrated above** — 17 lines of `k.S` produced exactly that
output and exit status on this machine. What A1 adds is that the message comes from DCDart rather than
from `.asciz`, which is precisely what A0 unblocks.

### A2 — the device tree

> **Exit:** the kernel reads the FDT pointer from `x0`, walks it, and prints the base and size of
> `/memory` and the `reg` of the `pl011` node. Harness asserts `0x40000000`, the size implied by `-m`,
> and `0x09000000`, byte-exactly — **and re-asserts with `-m 256M`**, so a hardcoded constant fails.

That negative control matters: the index records that ACPI tables move when x86 RAM grows and that
`m7-frames` boots 256 MiB. Same class of bug, caught at A2 instead of at M7.

### A3 — the PL011 driver behind `uart.dart`'s interface

> **Exit:** `uartPutChar`/`uartPuts` are backed by MMIO at the device-tree-derived address; A1's
> golden still passes byte-for-byte with no change to the assertion.

### A4 — the vector table and the GIC

> **Exit:** `VBAR_EL1` installed; a deliberate data abort is caught and reports its `ESR_EL1` class;
> the GIC is initialised and the generic timer's PPI fires. Harness asserts a tick count printed after
> N ticks, plus the fault message — the aarch64 analogue of `m1-interrupts` + `m4-fault`.

### A5 — TTBR1, TTBR0 and a 4 KiB granule

> **Exit:** the kernel builds its own translation tables, enables the MMU via `SCTLR_EL1`, and runs
> from them. Harness asserts a QMP RAM dump of the table root matches host-side derived descriptors —
> the same technique `m8-paging` uses, and legitimate because it dumps **guest RAM, not a BAR**.

### A6 — the frame allocator, base-relative

> **Exit:** `pmm.dart` initialised from the device-tree memory map; free-frame count asserted at
> both `-m 128M` and `-m 256M`. **The count must be derived from base + size, not from a constant.**

### A7 — EL0 and `SVC`

> **Exit:** a payload runs at EL0, makes an `SVC`, and returns. Harness asserts the round trip and
> that an EL0 store to a kernel page faults with the expected `ESR_EL1` — the aarch64 `m9-ring3`.

### A8 — virtio-blk over virtio-mmio, and FAT16 unchanged

> **Exit:** the kernel reads sector 0 from a virtio-mmio block device and `fat.dart` — **unmodified,
> not one line changed** — lists the root directory of the same FAT16 image `m14-fat` uses. Harness
> compares against the same expected listing.

**A8 is the milestone that proves the whole port.** 2,632 lines of the largest file in the kernel
running on a different architecture with zero edits is the binary demonstration that the seam is in
the right place. It is also the milestone that deletes `ata.dart`'s 1,251 lines from the ARM64 tree.

### A9 — ECAM, and `pciRead32`/`pciWrite32` as an abstraction

> **Exit:** `pci.dart`'s enumeration walk, **unmodified**, lists the devices on `pcie@10000000`
> through an ECAM accessor. Same negative control the index demands: `romfile=` where relevant.

### The harness count — the honest answer

**There are exactly 20 harnesses** in `core/tests/conformance/`. Every single one of them:

* invokes `qemu-system-x86_64` (20/20), and
* 18 of 20 additionally shell out to `x86_64-elf-objdump`, `x86_64-elf-ld`, `x86_64-elf-readelf` or
  `x86_64-elf-objcopy` — only `m0-boot` and `mb-info` do not.

Beyond that: **10 carry their own `prog.ld`** for a userland test binary that is linked for x86-64,
and **14 ship Python derive/check scripts** that compute expected values from x86 structures.

So the blunt answer to "how many would need duplicating or parameterising" is **20 of 20** — but that
number is misleading in both directions, and the useful breakdown is:

| group | count | what actually happens |
|---|---|---|
| **Assertion ports directly; only the runner changes** | 6 — `m0-boot`, `mb-info`, `m2-console`, `m3-shell`, `m14-fat`, `m15-fileio` | The expected bytes are serial output from portable code. Parameterise `$QEMU`, `$TARGET`, `$OBJDUMP` and the golden survives. |
| **Concept ports, expectation must be re-derived** | 8 — `m1-interrupts`, `m4-fault`, `m5-pci`, `m7-frames`, `m8-paging`, `m12-heap`, `m16-filewrite`, `m19-argv` | The *question* is the same (does a fault report correctly, is the frame count right) but the answer is an aarch64 number. The Python derive scripts need an arch branch, not a rewrite. |
| **Genuinely new harness required** | 4 — `m6-disk`, `m9-ring3`, `m11-proc`, `m18-preempt` | ATA→virtio, ring 3→EL0, x86 context switch→aarch64. These are A5/A7/A8's harnesses, written fresh. |
| **May not port at all** | 2 — `m10-elf`, `m13-libc` | Both link a userland ELF via `prog.ld` for x86-64 and check `EM_X86_64`. They need an aarch64 test binary and toolchain, which is a second cross-compilation setup. |

**Recommendation: parameterise, do not duplicate.** A shared `core/tests/lib/arch.sh` exporting
`QEMU`, `QEMU_MACHINE_ARGS`, `DCC_TARGET`, `CLANG_TARGET`, `LD`, `OBJDUMP` and `EXPECT_EXIT` would let
the 6 in group one become dual-arch with a one-line edit each, and would give groups two and three a
place to hang arch-specific expectations. Duplicating 20 harnesses creates 20 pairs that drift.

**But that is a hot-file change of the widest possible kind** — it edits all 20 `run.sh` files, and
`hot-files.md` exists because this repo has already been bitten by narrower collisions. **It must land
as one atomic change, before any ARM64 milestone, and while nothing else is in flight.** That
sequencing constraint is more likely to sink this port than any technical item in it.

---

## What this document does not cover, and what it got wrong to begin with

* **It could not run `dcc`.** The central STEP 1 claim — that `--target bare-aarch64` produces a
  working object — is supported by ADR-0033's recorded verification, by the registry, and by the fact
  that `clang --target=aarch64-unknown-none-elf` assembles and `ld.lld` links on this machine, but
  **not by an end-to-end build here**, because `dcc` is broken on this host for both arches. Stated
  plainly rather than glossed.
* **`mrs`/`msr` is a real DCDart gap and this document did not cost it.** aarch64 needs system-register
  access for `VBAR_EL1`, `TTBR0/1_EL1`, `TCR_EL1`, `MAIR_EL1`, `SCTLR_EL1`, `CNTFRQ_EL0`, `CNTPCT_EL0`,
  `ESR_EL1`, `CurrentEL`. Some of it can live in `boot.S` (rule 4 covers the boot-time subset), but
  **`CNTPCT_EL0` must be readable from DCDart at runtime or every clock read is an assembly call.**
  That is the aarch64 counterpart to ADR-0029's port-I/O escalation: narrow, real, and belonging to
  DCDart's repo. It is the second-largest open question in this document after A0.
* **No SMP, no UEFI boot, no real hardware.** `-M virt` only. A Raspberry Pi or an Apple silicon
  machine is a different port again — different UART, different interrupt controller, no device tree
  in the Apple case.
* **`gpu.md`'s conclusion is arch-neutral and this document defers to it.** VirtIO-GPU 2D is the same
  answer on both arches, which is one more argument for virtio over the legacy devices everywhere.
* **Nothing here is implemented.** Two hand-written assembly files that print to a serial port and
  shut a machine down are not an ARM64 port; they are the evidence that the first milestone is
  reachable.
