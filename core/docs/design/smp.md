# The oscortex multiprocessor design — the APIC, a second CPU, and the locking this kernel has never had. A design, not yet a decision.

**Status: DESIGN. Not an ADR, not numbered, nothing implemented, and no file outside this one was
touched to produce it.** When a piece of this is built it gets its own numbered ADR; this file is the
thing those ADRs will point back at, the same way `display-protocol.md` and `exec-format.md` are for
the window system and the executable format. Next free numbers at the time of writing: **ADR-0024**,
**GAP-0152**.

**Provenance.** Nobody asked for SMP. `docs/known-gaps.md` GAP-0141 lists it last in the scheduler's
successor list, GAP-0136 says the honest close might be *"a stated single-core invariant in
`OSCORTEX_SPEC.md` that this kernel is entitled to rely on"*, and ADR-0022 §13 ends with the rule
**"anything a second CPU would need a lock for, this kernel gets away with because there is exactly
one instruction stream and interrupt gates clear IF."** This document is written as the counter-brief
to that: what it would actually take, what it would actually cost, and — §4 — whether it is worth
doing at all. **§4 argues against.** The rest of the document exists so that the argument is made
against a real plan rather than against a vague one.

**Everything here is a proposal.** Where I measured something I give the command; where I am unsure I
say so and give the options rather than picking silently.

### The six things this document concludes, for a reader in a hurry

| | conclusion | where |
|---|---|---|
| **Two of the three stated APIC blockers are already false** | ADR-0002 rejected the APIC for MMIO at `0xFEE00000`, MSR access, and ACPI parsing. **The MMIO has been mapped since M5.** **xAPIC needs no MSR at all** — the enable bit is in a memory-mapped register, and the base address comes out of the MADT. Only ACPI is real. | §1.1 |
| **APIC-first can move zero goldens** | Bring the APIC up *after* `M1 END`, behind a command, and the 544-byte golden that seventeen harnesses assert as a prefix does not move. Replace the 8259 *at boot* and it moves in all seventeen. | §1.4 |
| **Per-CPU state needs nothing new from DCDart** | One `@bss` block of `nCpu × stride`, a `@packed extends Struct` for the field offsets, and "which CPU am I" as **two volatile loads** — the LAPIC ID register and a 256-byte translation table. No arrays needed, no thread-locals needed, no assembly needed. `%gs`/`swapgs` is an *optimisation*, and it is the part that is 100% inexpressible. | §2.4 |
| **You cannot write a lock in DCDart today. Not a good one, not a bad one, not a wrong-but-usually-fine one.** | No atomics, no fences (DCDart GAP-0033, GAP-0039). And software-only mutual exclusion does not rescue you: Peterson's and Dekker's algorithms both need store→load ordering, which x86-TSO does not give and DCDart cannot ask for. **This is a DCDart milestone before it is an oscortex one.** | §3.1, §3.2 |
| **Some cross-CPU code *is* expressible today, and it is exactly the AP handshake** | On x86-TSO a plain aligned store is a release and a plain aligned load is an acquire. Every `Pointer<T>` access in DCDart is already `volatile` (ADR-0041). So single-writer publish/observe works today; anything read-modify-write, or anything needing store→load ordering, does not. | §3.2 |
| **Build the APIC and ACPI on ONE core, and treat SMP as a separate, later, optional decision** | ACPI buys shutdown (every harness still ends by `timeout`-killing QEMU), reboot, a microsecond timer, and the MCFG table. The APIC alone buys MSI/MSI-X, >15 IRQ lines, and a per-CPU timer that does not destroy time the way the 8259 does. All of that lands on one core and pays for itself. **SMP is the only part with no user-visible payoff on this machine.** | §4 |

**And the finding that surprised me most**, which is not about SMP at all:

> **The local APIC and the I/O APIC are already mapped, and have been since M5.** `vm.dart:596`
> identity-maps `[3 GiB, 4 GiB)` as 512 2 MiB pages for the PCI hole. `0xFEE00000` (LAPIC) and
> `0xFEC00000` (I/O APIC) are both inside it. There is nothing to map. What there *is*, is that
> those pages are mapped **cacheable** — `pw | vmHuge | nx`, no `PCD`, no `PWT` — which
> `docs/known-gaps.md` GAP-0071 already records as *"wrong in principle for MMIO and right in
> practice for a linear framebuffer."* It stops being right in practice the moment the thing behind
> the mapping is an EOI register. That is a one-branch change in one function and it moves one
> harness assertion. §1.2.

---

## 0. What this has to be true of

Fourteen facts about this machine. Each is read out of the tree or measured on this host at the
commit this was written against, and each is cited so the next agent can check whether it still
holds.

| # | fact | where |
|---|---|---|
| 1 | Interrupts are the **8259 pair**, remapped to `0x20`–`0x2F`, with only IRQ0 and IRQ1 ever unmasked | `interrupts.dart:256` (`picRemap`), `keyboard.dart:189` |
| 2 | The clock is the **8253/8254 PIT at 100 Hz**, divisor `0x2E9C`, mode 3 | `interrupts.dart:310` (`pitInit`) |
| 3 | Every gate in the IDT is an **interrupt gate** (`0x8E`), so **IF is clear for the whole of every handler** | `interrupts.dart:206` (`idtSetGate`) |
| 4 | Dispatch is an **`if`-chain on the vector**, because DCDart has no function pointers | `interrupts.dart:477` (`isrDispatch`) |
| 5 | `[3 GiB, 4 GiB)` is identity-mapped, **512 huge pages, RW + NX, cacheable, no PCD/PWT** | `vm.dart:596` (`vmPciBase`), the PCI-hole loop |
| 6 | `[0, 1 MiB)` is mapped **RW + NX** with 4 KiB pages, and every frame below 1 MiB is **permanently reserved by the allocator** | `vm.dart:910` (`vmPageFlags`), `pmm.dart:634` (`pmmLowReserved = 256`) |
| 7 | Only **type-1** Multiboot regions are freed, so ACPI-reclaim memory is never handed out | `pmm.dart:829`, `pmm.dart:982` |
| 8 | There is **one GDT**, in `.rodata`, and it is **read-only from the CR3 switch onwards**. `ltr` writes the busy bit, so `ltr` runs in `boot.S` before that switch | `boot.S:676–712` |
| 9 | There is **one TSS** (104 bytes) and **one ring-0 stack** (16 KiB), and one is enough only because *"only one process is ever inside the kernel at a time"* | `boot.S:272`, `boot.S:278`, `proc.dart:51–54` |
| 10 | Kernel mutable state is **17 DCDart `@bss` blocks totalling 14272 bytes** plus **96 bytes of assembly-owned `.bss`**; the sum, **14368**, is asserted by `m19-argv/run.sh:164` | measured: `readelf -sW core/build/kmain.o`, `core/build/kdata.o` |
| 11 | **44 `@extern external` declarations**, asserted by count and by name | `core/build/kmain.o.externs`; `m11-proc/run.sh:649` |
| 12 | **20 conformance harnesses.** `m1-interrupts`' **544-byte golden** is asserted byte-for-byte, and as a mechanical prefix by **seventeen** of the others | `ROADMAP.md` M19 |
| 13 | **`-cpu qemu64` is pinned by 23 harness invocations.** Measured on it: `"apic": true`, **`"x2apic": false`** | measured: `query-cpu-model-expansion` on `qemu64`, QEMU 11.0.0 |
| 14 | **No harness passes `-smp` at all**, so every boot in this suite runs on exactly one vCPU | measured: `grep -o '\-smp [0-9]*' core/tests/conformance/*/run.sh` → no hits |

And four facts about the language, from a survey of the DCDart tree at `DCDART_PIN.txt`'s
`8713298 (2026-08-23)`:

| # | fact | where |
|---|---|---|
| 15 | **There are zero atomic operations and zero memory barriers in DCDart.** No `Atomic`, no CAS, no fetch-add, no `fence`. Every occurrence of the words in DCDart's tree is prose describing the absence | DCDart GAP-0033, GAP-0039; `dc-ir/lib/instructions.dart:408` lists `Atomic<u32>` under *"NOT here yet, on purpose"* |
| 16 | **Every `Pointer<T>` load and store is LLVM-`volatile`, unconditionally.** That is ordering against the compiler and nothing else | DCDart ADR-0041, GAP-0034 |
| 17 | **No MSR access, no `%gs`/`%fs`, no `swapgs`, no thread-locals, no TLS model.** A grep for any of them over all of DCDart returns nothing at all | DCDart GAP-0019 |
| 18 | **`@bss` symbols have LOCAL binding**, so assembly in another object file cannot name one | DCDart ADR-0051; oscortex GAP-0134 |

---

## 1. APIC FIRST — the 8259 pair has to go before any of this is possible

An 8259 has no concept of a destination processor. It has one INTR line, wired to one CPU. On an SMP
machine the APs' local APICs are the only thing that can be sent an interrupt at all, and the only
thing that can send one. So this section is not "a better interrupt controller"; it is the
prerequisite, and it is also — see §4 — the only part of this document I would actually build.

### 1.1 Three stated blockers. Two of them are no longer true.

ADR-0002 and `docs/known-gaps.md` GAP-0007 both reject the APIC in the same three words. Taken one at
a time, at today's tree:

**"MMIO at `0xFEE00000`."** *Already done, and by accident.* M5 (ADR-0009) identity-mapped
`[3 GiB, 4 GiB)` as 512 2 MiB pages so a PCI BAR would be reachable at all. `0xFEE00000` is
4,276,092,928; `0xFEC00000` is 4,273,995,776; the window is `[3221225472, 4294967296)`. Both the
local APIC and the I/O APIC are inside it. **There is no mapping work.** There is a *cacheability*
problem, which is §1.2.

**"MSR access (`IA32_APIC_BASE`)."** *Not needed for xAPIC.* The three things you would reach for
that MSR to do are:

* *find the APIC.* The MADT's fixed header carries a 32-bit **Local Interrupt Controller Address**
  field, and a type-5 entry overrides it if the firmware relocated it. So the address comes out of a
  table, not out of a register.
* *enable the APIC.* Bit 11 of `IA32_APIC_BASE` is the *hardware* enable, and its reset value is 1
  on every CPU that has an APIC. The bit the kernel actually has to set is the **software** enable,
  bit 8 of the Spurious Interrupt Vector Register at MMIO offset `0xF0` — an ordinary 32-bit store
  through a `Pointer<u32>`.
* *ask whether this is the BSP.* Bit 8 of the same MSR. But the MADT lists the processors, and the
  BSP is by construction the one already running `kmain`, so nothing needs to ask.

**So the whole of xAPIC — LAPIC ID, EOI, SVR, the LVT, the ICR that sends INIT and SIPI — is
32-bit MMIO, and 32-bit MMIO is `Pointer<u32>` in ordinary `@bare` DCDart.** This kernel already
does exactly that shape of thing to the framebuffer.

What *does* need MSRs is **x2APIC** (register access moves to MSRs `0x800`–`0x83F`) and **`%gs`-based
per-CPU data** (`IA32_GS_BASE`/`IA32_KERNEL_GS_BASE`). Neither is required, and x2APIC is not even
available: measured on this host, `-cpu qemu64` reports `"x2apic": false`, and that CPU model is
pinned by 23 harness invocations. **Any design that assumes x2APIC also changes a pinned CPU model in
23 places.** Use xAPIC.

**"ACPI/MP-table parsing to locate the I/O APIC."** *Real, and it is the whole cost.* §1.3.

That is the correction: **the APIC's stated blockers were three, and are one.** ADR-0002 was written
at M1, before M5 mapped the PCI hole and before `Pointer<u32>` MMIO had been exercised on a real
device. It was right when it was written. It should be updated rather than repeated.

### 1.2 The one real mapping problem: those pages are cacheable

`vm.dart`'s PCI-hole loop writes `pw | vmHuge | nx` — present, writable, huge, no-execute. **No
`PCD` (bit 4), no `PWT` (bit 3).** So the effective PAT type for `0xFEE00000` is write-back.

For a linear framebuffer that is wrong in principle and right in practice, which is exactly what
GAP-0071 says. For an APIC it is neither: the EOI register at `+0xB0` is a **write with a side
effect and no data**, and the ICR at `+0x300` is a **write that starts an interprocessor
transaction**. A cached or write-combined store to either is not a slow EOI, it is an EOI that has
not happened. On QEMU it will very likely work anyway; on real hardware the MTRRs usually force UC
over the APIC range regardless of what the page tables say, so it will *also* very likely work.
Neither of those is a reason to write it wrong.

**The fix is one branch.** The PCI-hole loop already writes one PDE per 2 MiB, as
`(base + (i << vmBigShift)) | pw | vmHuge | nx`. The 2 MiB page containing `0xFEE00000` and the one
containing `0xFEC00000` additionally get `PCD` (bit 4) and `PWT` (bit 3), and the rest do not. That is
**two new `const int`s next to `vmPresent`/`vmWritable`/`vmHuge` (`vm.dart:616–618`) — neither exists
today — and two `if`s in a loop that already exists.**

**What it costs somebody else: nothing, and that is itself the finding.** I expected this to move
`m8-paging`, and it does not. `m8-paging/derive.py:190`'s `check_region` folds exactly four things
per page — present, identity, `W`, `NX` — and `run.sh:810` applies it to the PCI hole with
`want_w=True, want_x=False`. **`PCD` is bit 4 and nothing in this project looks at it.** So the
change is free *and* invisible, which means the harness would today pass a kernel that got
cacheability wrong on an APIC register. **That is an argument for adding the assertion, not for
relaxing one:** P2's exit criterion below reads the two PDEs back out of guest memory and requires
`PCD` set on exactly those two and clear on the other 510 — a strictly stronger claim than the
region fold makes, in a dimension it does not currently have.

**Alternative considered and rejected:** map the APICs with 4 KiB pages so the UC region is exactly
the two 4 KiB apertures. It is more correct and it costs two more page-table frames, a split of one
PDE into a PT at each of two addresses, and a second shape in `vmScan`'s report. The 2 MiB
granularity wastes nothing real — the rest of each of those two 2 MiB windows is unoccupied
motherboard address space — so the finer version buys precision nobody can observe.

### 1.3 ACPI: RSDP → RSDT/XSDT → MADT, and every byte of it is already mapped

This is the actual new subsystem, and it is small.

**Step 1 — find the RSDP.** A 16-byte-aligned signature `"RSD PTR "` in either (a) the first KiB of
the EBDA, whose segment is at physical `0x40E`, or (b) `[0xE0000, 0x100000)`. **Both are below 1 MiB,
which `vm.dart:910` maps RW + NX** — readable. Checksum: the first 20 bytes sum to zero mod 256; for
revision ≥ 2, all `Length` bytes sum to zero as well.

**Step 2 — walk the RSDT (32-bit pointers) or XSDT (64-bit).** These live in ACPI-reclaim memory,
which on a `-m 128M` QEMU guest sits just under the top of low RAM — inside `[4 MiB, 128 MiB)`, which
is mapped RW + NX as 2 MiB pages. **Also readable, also already mapped.** And because `pmm.dart` only
frees Multiboot type-1 regions (`pmm.dart:829`, `:982`), the allocator will never hand out a frame
holding an ACPI table. That property is already true and already tested; it just has not been
depended on before.

**Step 3 — find `"APIC"`, the MADT.** Its fixed header is the 36-byte common SDT header plus a
32-bit Local Interrupt Controller Address and a 32-bit Flags word (bit 0 = `PCAT_COMPAT`, "there are
8259s here to mask"). After that is a variable-length list of type/length-prefixed entries. Four
matter:

| type | entry | what the kernel takes from it |
|---|---|---|
| 0 | Processor Local APIC | ACPI processor UID, **APIC ID**, flags (bit 0 = enabled, bit 1 = online-capable). **This is the CPU list.** |
| 1 | I/O APIC | I/O APIC ID, 32-bit MMIO address, **Global System Interrupt base** |
| 2 | Interrupt Source Override | *"ISA IRQ n is really GSI m, with this polarity and trigger mode."* **On essentially every PC, ISA IRQ 0 is overridden to GSI 2.** Ignoring type 2 is the classic way to build an I/O APIC that delivers no timer interrupts at all. |
| 4 | Local APIC NMI | which LINT pin is the NMI on each CPU |

**What this costs in this kernel's own currency.** A table walk with no allocation and no retained
structure would be `pci.dart`'s shape — print as you go, keep nothing (GAP-0067). That is the wrong
shape here, because the CPU list and the I/O APIC address have to *outlive* the walk. So it is a
`@bss` block: call it `acpiStore`, with a metadata region (RSDP revision, XSDT/RSDT address, MADT
address, LAPIC base, flags, counts, a status word) and a small fixed-capacity CPU table (APIC ID +
flags per CPU) and a fixed-capacity override table (say 16 entries). **Estimate: 512 bytes**, one
storage seam with three call sites, the same shape `procStore` and `fatStore` already have.

**Estimate: three or four new `@rodata` refusal sentences** — no RSDP, bad RSDP checksum, no MADT,
bad MADT checksum — each with its own name, per the discipline every other subsystem here follows.

**Zero new `@extern` declarations.** Every read is a `Pointer<u8>`/`Pointer<u32>`/`Pointer<u64>` load
from an already-mapped physical address. **Zero new assembly.**

**And one thing this buys immediately that has nothing to do with interrupts:** the FADT (`"FACP"`)
carries `PM_TMR_BLK`, the ACPI power-management timer — a 24-bit counter at exactly 3.579545 MHz,
read with a 32-bit `in` from an I/O port. **`port_inl` already exists** (`portio.S`). That is a
microsecond-resolution reference clock, on a kernel whose only clock today has 10 ms granularity, for
the price of one more table lookup. §2.1 needs it; so does calibrating the LAPIC timer; so does any
future `nanosleep`.

### 1.4 What it does to every existing IRQ path

There are exactly three places the 8259 is touched, and one place a vector is asserted.

**`picRemap()` → `apicInit()` + `ioapicRoute()`.** The 8259 does not go away; it gets **fully
masked** (`0xFF` to both data ports, which `picMaskAll()` already does) and, if the MADT's
`PCAT_COMPAT` bit is set, that is all that is needed on any machine QEMU emulates. On genuine
MP-era hardware there is also the IMCR (`out 0x22, 0x70; out 0x23, 0x01`) to switch the interrupt
lines away from the PIC; it is two `outb`s and it is harmless where the IMCR does not exist.

**`picEoiMaster()` → `apicEoi()`.** From `Port.outb(0x20, 0x20)` to a 32-bit store of zero at
`lapic + 0xB0`. Same two call sites in `isrDispatch` (`interrupts.dart:477`), in the same order —
and the *order* matters exactly as much as it does today. The timer arm acknowledges **before**
`procTick`, because `procTick` has a path that abandons the interrupt frame and never returns
(ADR-0022 §8). That reasoning survives verbatim; only the instruction changes.

**One genuinely new dispatch arm: the spurious vector.** A local APIC delivers vector `0xFF` (the SVR
value) when an interrupt is withdrawn between assertion and delivery. **It must NOT be EOI'd.** That
is a new `if` in `isrDispatch` that returns immediately, and it is the one arm in that function whose
absence would be a slow, intermittent, extremely confusing bug — the in-service register would stay
set and interrupts would stop, minutes later, for no visible reason. It should have a counter, for
the same reason `procHeadKernTicks` has one: a number that is supposed to be near zero is only
evidence if somebody can read it.

**`picUnmaskKeyboardOnly()` / `picUnmaskTimerAndKeyboard()` (`keyboard.dart:172`, `:189`) → I/O APIC
redirection entries.** Each I/O APIC input is a 64-bit redirection entry, written as two 32-bit
registers through the index/data pair at `+0x00`/`+0x10`. Unmasking becomes "write the entry with
bit 16 clear"; masking becomes "set bit 16". Same call sites, same session-scoped policy.

**And this is where the ISO entries stop being trivia.** The PIT is ISA IRQ 0. On a PC with an I/O
APIC it is almost always overridden to **GSI 2**. A kernel that routes GSI 0 and waits for a tick
waits forever — and `kmain`'s `while (ticks < 100)` loop is exactly that wait, so the failure mode is
a hang at boot with no diagnostic. **Any harness for this must therefore assert the override was
found and honoured, not merely that a tick arrived.**

**The keyboard's edge/level and polarity.** ISA interrupts are edge-triggered, active high; PCI
interrupts are level-triggered, active low. The MADT's type-2 entries carry the flags. Getting these
backwards produces a keyboard that works for exactly one keystroke and then stops.

### 1.5 What it does to the harnesses — and the sequencing that keeps all of them green

Here is the whole problem in one line of output:

```
M1 PIC 20
```

`m1ReportPic` (`interrupts.dart:351`) is printed by the **first timer interrupt**, and it prints
**the vector the interrupt was actually delivered on**. ADR-0002 is explicit that this is the point:
*"an 8259 cannot be asked what vector base it was programmed with — ICW2 is write-only — so printing
back the constant this kernel sent would prove nothing about the hardware. What CAN be observed is
where the interrupt lands."* It is evidence, deliberately, and that is exactly why it is brittle
here: **the vector changes when the controller changes.**

That two-hex-digit field lives inside the 544-byte golden that `m1-interrupts/run.sh` asserts
byte-for-byte and that **seventeen other harnesses assert as a mechanical prefix**.

So there are two sequencings, and they have wildly different costs:

**(A) Replace the 8259 at boot.** `M1 PIC 20` becomes `M1 PIC 30` (or whatever vector the I/O APIC
entry names). The 544-byte golden moves. Every one of the seventeen prefix assertions moves with it.
Every harness that measures serial byte counts moves. **This is a whole-suite change for a milestone
whose subject is an interrupt controller**, and it destroys the property that M1's golden has not
moved since `2bd7cce`.

**(B) Bring the APIC up *after* `M1 END`, behind a command.** `kmain` runs unchanged: IDT, `int3`,
`picRemap`, `pitInit`, `sti`, 100 ticks, the deliberate `#UD`, `M1 END`, `m2Enter()`. The shell comes
up on the 8259 exactly as it does today. Then an `apic` command — sibling of `pci`, `fb`, `vm`,
`frames` — parses ACPI, reports what it found, masks the 8259s, programs the I/O APIC, and reports
the vector the *next* tick arrives on, in the same evidential style `M1 PIC` established.

**Recommendation: (B), and it is not close.** It is the same argument M5 made for the framebuffer
getting its own boot, and M14 made for mounting from a command rather than at boot: **a subsystem
that can fail belongs behind a prompt, not in the boot path that seventeen goldens depend on.** It
also means the interesting negative control is free — a boot that does not type `apic` must produce
byte-identical output to today, which is a stronger regression check than any new assertion.

The day the APIC becomes the *only* controller is a later, separate decision, and by then it can be
made with a working APIC to compare against.

**One golden that moves under either sequencing, eventually.** `m3-shell` asserts a byte-exact
`ticks` value. If the LAPIC timer ever replaces the PIT as the tick source, that number changes.
GAP-0058 already records this as fragile. It is worth knowing that the LAPIC timer does not have to
replace the PIT to be useful — a per-CPU timer on an AP and a global PIT on the BSP can coexist, and
on this kernel that is probably the right first shape anyway.

**And a calibration note.** The LAPIC timer counts at the bus/core crystal frequency, which is not
architecturally discoverable on `-cpu qemu64` (CPUID leaf `0x15` is not populated). So it has to be
**calibrated against something**: the PIT, or the ACPI PM timer from §1.3. The PIT therefore does not
leave the machine even when it stops being the clock — it becomes the reference the clock is measured
with.

---

## 2. Bringing up a second CPU

### 2.1 INIT–SIPI–SIPI, and where the delays come from

For each APIC ID in the MADT that is not the BSP's, and whose flags say enabled:

1. Write the AP's APIC ID into **ICR high** (`lapic + 0x310`, bits 31:24). *High first, always* — the
   write to ICR low is what launches the transaction.
2. Write **ICR low** (`lapic + 0x300`) = `0x00004500`: delivery mode INIT, level assert, edge
   trigger, destination shorthand none.
3. Poll ICR low bit 12 (Delivery Status) until clear, then **wait 10 ms**.
4. Write ICR low = `0x00004600 | (trampoline_page >> 12)`: delivery mode Startup. The low 8 bits are
   the **page number**, so the trampoline must be page-aligned and below 1 MiB.
5. Poll delivery status, **wait 200 µs**, send the same SIPI again.
6. Wait for the AP to publish its "I am up" word, with a timeout.

**The delays are the interesting part on this kernel, because it has no clock finer than 10 ms.**
The PIT is 100 Hz. Step 3's 10 ms is exactly one tick and can be done by spinning on `tick_count()`
— which is already the one read in this kernel that is guaranteed not to be hoisted, because it is an
opaque `@extern` call (`isr.S:307–324`). Step 5's **200 µs is below the PIT's resolution entirely**.
Options:

* **The ACPI PM timer.** 3.579545 MHz, one 32-bit `port_inl` from the FADT's `PM_TMR_BLK`. 200 µs is
  716 ticks. This is the honest answer and §1.3 already pays for it.
* **A calibrated busy loop.** Count iterations of a `Pointer` load between two PIT ticks, divide.
  Works, is fragile across hosts, and is exactly the kind of number that is right on the machine it
  was measured on.
* **Skip it.** The second SIPI exists because some old CPUs miss the first, and on QEMU one is
  enough. It would work here and it would be wrong to build on.

**Recommendation: the PM timer.** It is one port read, the instruction already exists, and the same
counter is the thing that will eventually make `nanosleep` and LAPIC-timer calibration possible.

### 2.2 The AP trampoline: where it lives, and the trap that kills the first attempt

An AP starts in **real mode** at `CS = vector << 8`, `IP = 0`, with no paging, no GDT, no long mode.
It has to be walked all the way back up: real mode → protected mode → PAE → long mode → the kernel's
address space. That is `boot.S`'s `_start`, done a second time, in a page that has to be below 1 MiB.

**Where it goes.** A fixed page below 1 MiB — `0x8000` is conventional and avoids the IVT/BDA at
`[0, 0x500)`, the EBDA near `0x9FC00`, and the VGA aperture at `0xB8000`. **The allocator will never
hand out that frame:** `pmm.dart:634` reserves all 256 frames below 1 MiB unconditionally. And it is
**writable**: `vm.dart:910` maps `[0, 1 MiB)` RW + NX. So the BSP can copy the trampoline there at
runtime with an ordinary loop of `Pointer<u8>` stores, and the harness for M8's page permissions does
not move at all.

**The trap, stated before somebody finds it the hard way.** `[0, 1 MiB)` is mapped **NX**. So the
sequence inside the trampoline is load-bearing:

> The trampoline must enable paging with **`boot.S`'s bootstrap `p4_table`** — which maps
> `[0, 128 MiB)` as 2 MiB pages with **no NX and no per-section permissions** — and then far-jump to
> a 64-bit entry point in `.text` **above 1 MiB**, and only *then* install the kernel's real PML4.
> An AP that installs the kernel PML4 while its RIP is still below 1 MiB dies on its very next
> instruction fetch, with no output, on a machine where everything else works.

That the bootstrap tables are still there is not luck — `boot.S:78` says they are *"DELIBERATELY LEFT
INTACT AFTER THE SWITCH"* so that `vm.dart` could decline to switch and leave a running kernel. That
decision, made at M8 for a completely different reason, is what makes AP bring-up cheap.

**How much of it is new assembly.** The trampoline is ~120 lines of 16-bit and 32-bit assembly that
is largely a transcription of `boot.S:_start`, plus a GDT with a 16-bit-addressable descriptor for
the first far jump. It cannot be DCDart and nobody should try: CLAUDE.md rule 4 covers exactly this
("the 32-bit→long-mode transition ... lives in `core/boot/boot.S`, hand-written"). It should be its
own object — `core/boot/ap.S` — for `portio.S`'s reason: it is one identifiable thing, it should be
countable, and it should be deletable as a unit.

It also has to be **position-independent**, because it is assembled at a link address in the kernel
image and executed at `0x8000`. Two ways: assemble it `.code16` with all references relative to a
known base and fix up the far-jump target at copy time, or link it at `0x8000` in its own output
section and copy it verbatim. **The second is simpler and it is what the linker script is for.**

### 2.3 GDT, IDT, TSS — what has to be per-CPU, and what emphatically does not

| structure | per-CPU? | why |
|---|---|---|
| **IDT** | **No.** One IDT, every CPU `lidt`s the same base. | The vector→handler mapping is a property of the kernel, not of a CPU. Every CPU that takes vector `0x20` should run the same code. There is no reason to duplicate 4 KiB. |
| **GDT** | **Preferably no** — one GDT with N TSS descriptors. | The code and data descriptors are identical for every CPU. Only the TSS descriptor differs, and a TSS descriptor is 16 bytes; N of them appended to the existing GDT is smaller and simpler than N GDTs. Each CPU then `ltr`s selector `0x28 + 16i`. |
| **TSS** | **Yes, mandatory.** | The TSS holds RSP0. The CPU reloads RSP0 from *its own* TR on every ring-3→ring-0 entry. Two CPUs sharing a TSS means two CPUs entering the kernel on the same stack. |
| **Ring-0 stack** | **Yes, mandatory.** | Same reason, one level down. 16 KiB each. |
| **`current process`** | **Yes.** `procHeadCurrent` is one global word today, and §3 says so. | |

**The `ltr` problem, which is real and has bitten this kernel once already.** `boot.S:676–712`
records it: **`ltr` sets the busy bit in the TSS descriptor, which is a store into the GDT, and this
kernel's GDT is in `.rodata` and read-only from the CR3 switch onwards.** M9's first attempt called
`ltr` from DCDart after the switch and took a #GP. The fix was to move `ltr` into `boot.S`, before
the switch.

**That fix generalises to the APs, and it constrains the bring-up order.** Each AP must `ltr` its own
TSS descriptor **while it is still on the bootstrap page tables**, where `.rodata`'s physical pages
are writable, and *then* install the kernel PML4. Combined with §2.2's NX trap, the AP's 64-bit entry
does exactly this, in this order:

```
  (still on p4_table, RIP above 1MiB)
  lgdt   the shared GDT
  ltr    $(0x28 + 16*i)          <- writes the busy bit; .rodata must still be writable
  lidt   the shared IDT
  mov    kernel_pml4, %cr3       <- from here on .rodata is read-only
  call   apEntry(cpuIndex)       <- a named DCDart symbol; there are no function pointers
```

**Two things this makes visible.** First, the TSS *descriptors* have to be built before any AP runs,
and building them is a store into `.rodata` — so it happens either in `boot.S` (where the existing
one is built, `boot.S:453–469`) or in DCDart before `vmInit()`. Both are boot-path changes in the
one file CLAUDE.md rule 4 is most protective of. Second, the GDT limit changes, which `gdt_base()`
and `user.dart`'s TSS report both observe, and `m9-ring3` asserts.

**The alternative worth naming:** move the GDT out of `.rodata` into its own writable, NX page. It
makes AP bring-up order-free and it costs the M8 property that *"the GDT is immutable from the CR3
switch onwards"* — a hardening that was deliberately paid for. `boot.S:695` already records that the
same choice was considered and rejected once. **I would not reopen it for SMP**; the ordering
constraint above is three instructions in a file that is already assembly.

### 2.4 Per-CPU state in a language with no arrays and no thread-locals

This is the part the brief calls the hard one. **It is not, and the reason is worth being precise
about: this kernel has never had an array and has 17 `@bss` blocks anyway.** Every one of them is
raw bytes reached by hand-computed offsets. A per-CPU array is the eighteenth, and it is structurally
identical to `procStore` — which is already a table of four 512-byte slots indexed by a shift.

**The storage.** One block, `nCpu × stride`, with the seam shape `procStore` established:

```dart
/// Four CPUs, and it is a capacity rather than a design limit: a fifth entry in
/// the MADT is refused by name and says so.
const int cpuMax = 4;

/// One control block: 256 bytes, 32 u64 words. 256 rather than 128 so that two
/// CPUs' blocks can never share a 64-byte cache line even if a field is added.
const int cpuBlockBytes = 256;
const int cpuBlockShift = 8;
const int cpuStoreBytes = 1024;   // cpuMax * cpuBlockBytes, as a literal (GAP-0077)

/// `align: 64` IS A CORRECTNESS-ADJACENT REQUIREMENT, NOT HYGIENE. A per-CPU
/// counter that shares a cache line with another CPU's is not wrong, it is
/// slow -- and it is slow in a way that only shows up as a number nobody
/// expected. DCDart REJECTS a non-power-of-two alignment at compile time
/// (its ADR-0051), which `.align 63` in an assembly file would not have.
@bss
final Bss cpuStore = const Bss(bytes: cpuStoreBytes, align: 64);

@bare u64 cpuBlockBase(u64 c) {
  return Bss.addressOf(cpuStore) + (c << u64(cpuBlockShift));
}
@bare u64 cpuGet(u64 c, u64 w) {
  return Pointer<u64>.fromAddress(cpuBlockBase(c) + (w << u64(3))).value;
}
@bare void cpuSet(u64 c, u64 w, u64 v) {
  Pointer<u64>.fromAddress(cpuBlockBase(c) + (w << u64(3))).value = v;
}
```

**And there is a better option for the field offsets than named `const int` word indices.** DCDart
has `@packed class ... extends Struct` with compiler-computed field offsets (DCDart ADR-0011), and a
struct instance *is* its base address — `Struct.fromAddress(cpuBlockBase(c))` costs nothing. Every
other subsystem in this kernel hand-numbers its words (`procSlotState = 0`, `procSlotId = 1`, …), and
`docs/known-gaps.md` GAP-0143 §1 records what that costs: **M18's first version put the scheduler's
preempt counter in slot word 16, which was already M12's heap base, and it booted, preempted, and
printed a heap break as a scheduler statistic. Nothing crashed.** A per-CPU block is a new structure
with no legacy numbering; it is the natural place to use the feature that makes that class of bug
impossible. It is also the one part of the SMP data model that is in *good* shape today.

**"Which CPU am I?" — and this is the actual question.** The block above needs an index, and the
index cannot be a parameter: a per-CPU current-process pointer is read from `procLive()`, which is
read on every fault and every syscall, from the bottom of a call chain. DCDart has no default
arguments, so threading a `cpu` parameter through is viral — it would touch every function in
`proc.dart`, `user.dart`, `elf.dart`, `heap.dart`, and every one of their callers.

Three ways, and the first one is available today:

**(i) Read the local APIC ID. Two volatile loads. No assembly, no MSR, no language change.**

```dart
/// Which CPU this is, as a dense index in [0, cpuMax).
///
/// The LAPIC ID register is memory-mapped at `lapic + 0x20`, ID in bits 31:24.
/// It is not a dense index -- APIC IDs are assigned by firmware and need not be
/// contiguous -- so it is translated through a 256-byte table the BSP builds
/// from the MADT. Two loads, both through `Pointer<T>`, both therefore volatile
/// (DCDart ADR-0041), so neither can be hoisted out of a loop.
@bare
u64 cpuIndex() {
  final u64 apicId =
      Pointer<u32>.fromAddress(apicBase() + u64(0x20)).value.toU64() >> u64(24);
  return Pointer<u8>.fromAddress(cpuIdMapBase() + apicId).value.toU64();
}
```

The cost is honest: the LAPIC aperture is (or should be, §1.2) uncacheable, so that first load is a
real bus transaction — tens to low hundreds of cycles on real hardware. On a function called from
every syscall entry, that is not free.

**(ii) `%gs`.** `wrmsr` `IA32_KERNEL_GS_BASE` to each CPU's block address, `swapgs` on every ring
transition, and `mov %gs:0, %rax` is one instruction. **This is the standard idiom and it is 100%
inexpressible in DCDart** — no MSR access, no segment access, no `swapgs`, and a survey of the entire
DCDart tree for any of those words returns nothing at all. It would be an `@extern` function
returning a `u64`, which the compiler treats as an opaque call it cannot inline or reason about. So
the fast idiom becomes a non-inlinable call, and the gap between (i) and (ii) narrows to *one
uncached load versus one call*. **It is an optimisation, not an enabler, and it should be measured
before it is built.**

**(iii) Pass it down from `isr_common`.** The interrupt path already passes `frame` — the address of
the saved register block — into `isrDispatch`. `isr_common` could equally push the CPU index and pass
it as a fifth argument. That covers everything reached *from an interrupt*, which on this kernel is
every syscall and every fault. It does not cover the shell loop, which is not in interrupt context.
**Worth knowing, not sufficient on its own.**

**Recommendation: (i), and write down that (ii) exists.** It needs nothing from DCDart, it is four
lines, and it can be replaced later without any call site changing.

**What actually goes in the block.** The migration is a *split* of `procStore`'s header, not a new
parallel structure — the same discipline ADR-0022 §4 applied when M18 grew the header rather than
adding a second `@bss` block:

| word | field | moves from |
|---|---|---|
| 0 | `cpuApicId` | new |
| 1 | `cpuState` (offline / starting / online) | new |
| 2 | `cpuCurrent` — running slot + 1, 0 for none | **`procHeadCurrent`** |
| 3 | `cpuSlice` — ticks in the current quantum | **`procHeadSlice`** |
| 4 | `cpuTssBase` | new |
| 5 | `cpuStackTop` | new |
| 6 | `cpuTicks` — this CPU's own timer count | **`tick_counter`**, partly |
| 7 | `cpuPreempts`, 8 `cpuQuanta`, 9 `cpuKernTicks` | **`procHead*`** |

**And the cost of that split, stated rather than discovered.** `m11-proc/run.sh` counts the storage
seam's call sites and requires exactly three (`procHeadBase`, `procTableBase`, `procFxBase`). Adding
`cpuBlockBase` makes it four, in a second file, over a different block. That check exists precisely
to make this kind of change loud. It should be *updated*, not weakened, and the updated form is
stronger: *the process table has three seam functions and the per-CPU table has one, and no other
function in this kernel names either block.*

---

## 3. Locking — the kernel has none, assumes none, and cannot currently be given any

### 3.1 DCDart has no atomics. It also has no barriers, and that is worse.

Measured against `DCDART_PIN.txt`'s `8713298`: **there is no `Atomic` type, no compare-exchange, no
fetch-add, no `fence`, no ordering enum, and no `atomicrmw`/`cmpxchg`/`fence` emission anywhere in
the LLVM backend.** Every hit for those words in DCDart's tree is prose describing the absence.
`dc-ir/lib/instructions.dart:408` lists `Atomic<u32>` under a comment reading **"NOT here yet, on
purpose"**. Two DCDart gaps say it directly:

* **GAP-0033** — *"`volatile` is not atomic, not a fence, and says nothing about multi-core
  visibility ... `DCDART_SPEC.md` §6 asks for 'explicit ordering', which means real barriers ...
  **None exist.**"* The entry names *"the first SMP bring-up"* as when it becomes real.
* **GAP-0039** — *"A `@bss` counter incremented from an interrupt handler and read from ordinary code
  is a read-modify-write with no atomicity ... Barriers are about ORDERING; this is about ATOMICITY
  of a single one. **A kernel needs both, and DCDart currently offers neither.**"*

What DCDart *does* have is **unconditional volatility**: ADR-0041 makes every `Pointer<T>` load and
store LLVM-`volatile`. That is ordering against the *compiler*. It says nothing about the CPU and
nothing about another CPU's view.

There is one more thing that belongs in this section and is not filed as a gap in either repo:
**DCDart's ARC is non-atomic.** `dc_retain`/`dc_release` are plain increments. No kernel object today
is ARC-managed — `@bare` code allocates nothing — but the moment any shared structure becomes a
`HeapObject`, its refcount is corruptible by a second CPU with nothing in the language noticing.

### 3.2 You cannot write a lock. And the software-only algorithms do not rescue you.

The obvious response to "no CAS" is "use Peterson's algorithm" or "use Lamport's bakery" — mutual
exclusion built from plain loads and stores, which is all DCDart has.

**They do not work on x86, and they do not work here.** Every one of them depends on a store to one
location becoming visible before a load of another location is performed. x86-TSO permits a store to
be buffered past a subsequent load to a *different* address — that is the one reordering x86 allows —
so Peterson's `flag[me] = 1; if (flag[other] == 0)` can have both CPUs read a stale zero and both
enter. The fix is a **store-load fence** (`mfence`, or any `lock`-prefixed instruction). DCDart has
neither. So:

> **There is no lock expressible in `@bare` DCDart today. Not a spinlock, not a ticket lock, not a
> deliberately-slow-but-correct one. This is not a difficulty; it is an absence.**

**But this is the interesting half, and it is genuinely good news.** x86-TSO *does* give, for free, on
plain aligned accesses:

* a plain aligned load is an **acquire load** (loads are not reordered with later loads or stores);
* a plain aligned store is a **release store** (stores are not reordered with earlier stores or
  loads);
* aligned 64-bit accesses are **not torn**.

Combined with DCDart's every-access-is-volatile, that means **single-writer publish/observe works
today, with no language change at all**:

| pattern | expressible today? |
|---|---|
| AP writes its APIC ID and status, then sets a "ready" word; BSP polls the ready word and then reads the payload | **Yes.** Store-store ordering is free on x86; the volatile qualifier stops the compiler sinking the payload stores past the flag. |
| Each CPU increments **its own** per-CPU counter; any CPU reads any counter | **Yes.** Single writer per word, aligned, untorn. |
| A CPU reads a word another CPU wrote once at boot (the LAPIC base, the CPU table) | **Yes.** |
| Two CPUs increment the **same** counter | **No.** Lost updates, silently. |
| Two CPUs contend for a resource | **No.** No RMW, no store-load fence. |
| A CPU changes a page mapping another CPU has cached in its TLB | **No** — and this one is not even about atomics. `vm.dart:121` records *"No `invlpg` and no TLB shootdown — nothing ever CHANGES a mapping after the one switch, and there is one CPU."* A shootdown needs an IPI and an acknowledgement handshake, which needs §3.5. |

So the AP bring-up handshake — the single most cross-CPU thing in §2 — **is buildable now**. The
locking is not. That is a clean seam, and it is what makes the milestone ladder in §5 orderable.

**The residual risk in that claim, stated rather than hidden.** The argument above rests on x86-TSO
plus "every `Pointer<T>` access is volatile." **Neither is written down as a property this kernel
relies on, and nothing checks either.** If DCDart ever adds non-volatile pointer access (GAP-0034
proposes exactly that, as a device-vs-ordinary-memory distinction), the handshake silently loses its
compiler barrier. That is worth a GAP entry whether or not any of this is built.

### 3.3 The inventory: every piece of global mutable state, and what each needs

**17 DCDart `@bss` blocks (14272 bytes) and 5 assembly-owned symbols (96 bytes).** Measured with
`readelf -sW core/build/kmain.o` and `core/build/kdata.o`; offsets are exact.

| off | block | bytes | owner | who touches it today | what it needs on two CPUs |
|---|---|---|---|---|---|
| 0 | `vgaCursorWord` | 8 | vga | **IRQ + task.** `conPutc` from `kbdHandle`'s echo *and* from every command | **Console lock.** Two CPUs printing interleave at the character, not the line |
| 8 | `m2PhaseWord` | 8 | vga | written once, read on **every fault** | Write-once. Safe by publish/observe (§3.2) |
| 16 | `shellLineBuf` | 256 | shell | **IRQ + task.** Appended by `shellKey` in IRQ context; walked by `shellExecute` | **Owned by one CPU.** The shell is a single thread of control and should stay pinned |
| 272 | `shellLenWord` | 8 | shell | same | same |
| 280 | `shellStateWord` | 8 | shell | **This is the kernel's only synchronisation primitive today.** `shell.dart:1619`: *"written only with interrupts disabled on this side, and only from the IRQ1 handler on the other, so the two never interleave"* | **`cli` does not exclude another CPU.** This sentence becomes false the day an AP exists, and it is load-bearing: `shell.dart:46` says the race it prevents is *"real, not theoretical"* |
| 288 | `shellMbinfoWord` | 8 | shell | write-once at boot | safe |
| 296 | `kbdPrefixWord` | 8 | keyboard | **IRQ only** — the `0xE0` state machine, read and written only inside `kbdHandle` | Safe **iff IRQ1 is routed to exactly one CPU.** An I/O APIC can round-robin by default; it must not here |
| 304 | `faultCountWord` | 8 | shell | **RMW in IRQ context** (`faultCountBump`) | **Atomic increment**, or per-CPU + summed |
| 312 | `fbStateBlock` | 32 | fb | words 0–1 write-once; **words 2–3 (cursor) are IRQ + task** | Same as `vgaCursorWord`: console lock |
| 344 | `pmmStore` | 4672 | pmm | bitmap + 8 metadata words + a 512-byte ledger. Task context mostly, **but `freeFrame` is reachable from IRQ context** via `userOnFault`→`procSpaceFree` and from `procBudgetEnd` | **A lock.** `allocFrame` is find-first-zero-then-set: a textbook RMW race that hands the same frame to two CPUs. `pmmMetaFree`/`Allocs` are RMW counters |
| 5016 | `vmStore` | 128 | vm | 16 words. Boot-time, **except `Faults`/`Cr2`/`Err`, written from the page-fault handler** | Per-CPU fault reporting, or a lock. And: **CR2 is per-CPU hardware.** One global `vmMetaCr2` is meaningless with two faulting CPUs |
| 5144 | `userStore` | 128 | user | `Live` read on **every fault**; `Syscalls`/`Refusals`/`Written` RMW'd inside `userSyscall` (IRQ context) | **RMW counters need atomics.** `Live` becomes per-CPU |
| 5272 | `elfStore` | 128 | elf | built in task context; `elfLive()` read on every fault; `elfTeardown` runs from the fault handler | **One loader at a time** — a lock, or an ownership rule |
| 5408 | `procStore` | 4224 | proc | **the most interrupt-exposed block in the kernel.** 16 header words, 4×512-byte slots, 4×512-byte FXSAVE areas | **§3.4.** This is where the real work is |
| 9632 | `fatStore` | 1824 | fat | metadata + 256-entry chain + **one shared 512-byte sector buffer** + an 8.3 name. Reached from task context (`ls`, `cat`, `run`) *and* IRQ context (syscalls 5–8) | **A filesystem lock.** The single sector buffer is shared mutable state by construction; `fat.dart:1855` already notes two writes that *"are not atomic and cannot be made so on this hardware"* |
| 11456 | `fileStore` | 2560 | file | metadata + 5×4 descriptors + a bounce buffer + an RMW sector buffer. Almost entirely IRQ context | **A lock**, or per-CPU buffers. Two CPUs in `fdwrite` share one 512-byte read-modify-write sector |
| 14016 | `argsStore` | 256 | args | **task context only**, before `enter_user` | Safe if the shell is pinned |

Plus the assembly-owned residue (`kdata.S`), which cannot become `@bss` because DCDart emits `@bss`
symbols with **local** binding and assembly cannot name a local symbol in another object (GAP-0134):

| symbol | bytes | what it is | on two CPUs |
|---|---|---|---|
| `cpu_info` | 64 | CPUID vendor + brand strings | **Per-CPU**, or accept that it describes whichever CPU ran `cpu` |
| `shell_resume_rsp` / `_ok` | 16 | the RSP `fault_resume` restores | **Per-CPU, mandatory.** It is a stack pointer |
| `user_resume_rsp` / `_ok` | 16 | the RSP `user_return` restores | **Per-CPU, mandatory.** Same |

And in `isr.o` / `boot.o`:

| symbol | bytes | on two CPUs |
|---|---|---|
| `tick_counter` | 8 | **The canonical GAP-0136 case.** RMW from the timer handler. Per-CPU, summed on read |
| `idt` (4096), `idtr` (10), `isr_stub_table` (2048) | — | **Shared, correctly.** Written once at boot, read-only after `lidt` |
| `p4/p3/p2/p2_pci_table` (16 KiB) | — | **Shared, correctly** — and load-bearing for §2.2 |
| `nx_flag`, `sse_flag`, `multiboot_info_ptr` | 20 | Boot facts. Shared, safe. In principle per-CPU on an asymmetric machine; not on any machine this will run on |
| `tss64` (104), `kstack0` (16 KiB) | — | **Per-CPU, mandatory.** §2.3 |

**Reading down that column, the summary is:** three blocks are already fine (write-once), three are
fine if ownership is pinned to one CPU, **six need a lock**, **five need atomic increments**, and
four things in assembly need to be per-CPU or the machine does not boot.

### 3.4 The three places that are already wrong by inspection

ADR-0022 §13 named these and they are worth restating with what each would actually take.

**1. `procSwitchTo` (`proc.dart:1486`) is not a critical section and has a window with a name.**
Between `procSetHead(procHeadCurrent, next + 1)` and the last word of `procLoadFrame`, the table
describes neither the outgoing nor the incoming process consistently. On one core nothing can observe
it because IF is clear. On two, **a second CPU running the same `procPickNext` can select the same
READY slot and run the same process on both CPUs, in two different address spaces, with one saved
register frame.** The fix is not a lock around `procSwitchTo` — it is a lock around
`procPickNext`+state-transition, so that "select a READY slot and mark it RUNNING" is one indivisible
step. That is CAS-shaped: `if (slot.state == READY) slot.state = RUNNING`, atomically.

**2. `procHeadPolicy` / `procHeadBudget` are written from shell context with IF set,** and are safe
today for **two** independent reasons that ADR-0022 §13 warns are both load-bearing: (a) the stores
happen before `picUnmaskTimerAndKeyboard()`, so no tick can be delivered between them; (b)
`procLive()` is 0, so `procTick` returns at its first line. **Reason (a) is worth nothing against a
second CPU** — masking IRQ0 on *this* CPU says nothing about an AP. Reason (b) survives. So the
safety margin halves, silently, on the day an AP boots.

**3. `procSessionReset` writes the whole header and every slot with IF set,** safe only for reason
(b). Same halving.

**And one more that is not in ADR-0022 and should be.** `procPreemptLine` (`proc.dart:1655`) prints
from inside the timer interrupt, and its own comment says *"It would stop being safe the day a second
CPU existed."* It is right, and the reason generalises: **`uartPutc` polls LSR bit 5 and then
stores to the transmit register.** That is a poll-then-act sequence on a shared device. Two CPUs both
see THRE set, both store, one byte is lost. **The console is a shared device and needs a lock before
anything else does**, because it is the only way either CPU reports anything.

### 3.5 What to ask DCDart for — and how narrow the ask can be

CLAUDE.md rule 3: *"scope it as narrowly as the actual need (see DCDart's ADR-0029: one port-I/O
primitive, not general inline asm)."* The narrowest thing that unblocks all of §3.3 is **three
operations and one fence**:

```dart
/// Returns the value that was there.
u64 Atomic.exchange(u64 addr, u64 v);
/// Returns the value that was there; the swap happened iff it equals `expected`.
u64 Atomic.compareExchange(u64 addr, u64 expected, u64 desired);
/// Returns the value that was there.
u64 Atomic.fetchAdd(u64 addr, u64 delta);
/// A full barrier. `mfence` on x86-64.
void Atomic.fence();
```

That is one DC-IR instruction family, one LLVM `atomicrmw`/`cmpxchg`/`fence` emission each, and
sequential consistency for all of them — **no ordering parameter**, because an ordering parameter is
a memory-model question and DCDart's memory model is frozen until M3 (DCDart CLAUDE.md rule 4).

**And that framing is the whole reason this can be a small ADR rather than an escalation.** DCDart's
ADR-0051 got mutable statics through the same freeze by restricting them to **raw bytes**, so no
ownership question arose. Atomics over `u64` at a raw address, with no ARC interaction and no
ordering choice, is the identical argument: *it operates on bytes, so §3's frozen questions do not
apply.* If instead the ask is `Atomic<T>` as a *type*, with acquire/release, it touches ownership,
and DCDart's `docs/escalations/` (next free: 0007) is where that belongs — alongside the existing
`0002-allocator-threading.md` and `DCDART_SPEC.md` §12's explicitly-undecided **"Thread model."**

**The interim, and why it is legitimate.** `lock cmpxchg`, `lock xadd`, `xchg`, `mfence` and `pause`
are exactly the same *kind* of thing as `outl`, `cpuid`, `lidt` and `fxsave`: a single instruction
with no DCDart primitive, reachable across the plain C ABI. `portio.S` is the precedent — a file that
exists to stand in for a language gap, is deliberately two instructions wide so that its deletion is
mechanical, and files the real ask as GAP-0066. **A `core/boot/atomic.S` of five functions, with a
GAP entry naming the DCDart ask, is the same pattern and should be argued for on the same terms.**

**But this document should not pretend that is equivalent.** An `@extern` call is opaque to the
compiler, so every lock acquire is a non-inlinable call — and on an uncontended lock that call is
several times the cost of the `lock cmpxchg` inside it. `portio.S`'s workaround costs a call on a
path that already costs a bus transaction; a lock's does not.

---

## 4. Is SMP worth it for this OS, and when?

**No. Not now, and the honest answer is probably not for several milestones after "now" stops being
now.** Here is the argument against, made as strongly as I can make it, followed by the part that
survives it.

### 4.1 There is no workload on this machine that a second CPU could run

* **Nothing blocks.** GAP-0141: four process states, no fifth. *"Nothing ever waits."* No sleep, no
  wakeup, no blocked state. A second CPU's classic first win is overlapping I/O with computation, and
  **this kernel cannot overlap anything**, on one core or four — a `read()` spins the whole machine
  through a PIO transfer with IF clear.
* **There are four process slots and no way for a program to create a process.** GAP-0141 again: no
  `fork`, no `exec`, no `spawn`. Processes come from `proc run <lbaA> <lbaB>` typed at a shell, which
  creates exactly two, refuses to start while anything is live, and does not return until the whole
  session tears down. `display-protocol.md` §6's D3 is the milestone that would change that, and it
  is not built.
* **So the only two-CPU workload constructible today is: type `proc run A B`, and have A on one CPU
  and B on the other.** That is a real demo. It is not a reason.
* **Latency is bounded by the longest syscall, not by the quantum** (GAP-0138), and a second CPU does
  not change that for the process holding the CPU.

### 4.2 And the cost is spread across everything

Counting from §3.3: six blocks want a lock, five want atomic RMW, four assembly objects must become
per-CPU, one `.rodata` immutability property is in tension with `ltr`, one storage-seam call-site
count moves, `.bss` grows by **48 KiB of ring-0 stacks and 312 bytes of TSSs** for three more CPUs,
and **the sentence "one caller, no locking" — which appears throughout this kernel as a load-bearing
justification, not as a note — becomes false in every place it appears.**

**And that `.bss` growth lands in an awkward place, because of GAP-0134.** The AP needs a stack
*before* it can call anything, so its stack address has to be reachable from `ap.S` — and **a DCDart
`@bss` symbol has local binding, which assembly in another object cannot name.** So per-CPU ring-0
stacks and TSSs go where the existing ones already are: `boot.S`'s `.bss`, alongside `kstack0` and
`tss64`, growing `boot.o` from 49296 bytes rather than growing the 14368-byte DCDart total that four
harnesses assert. That is *convenient* — the asserted number does not move — and it is convenient for
a bad reason: it is ADR-0021's whole thesis running backwards, and it is the first storage since M17
that would be donated by assembly because the language cannot export a symbol.

And the verification story is the weakest part. §5 measures it: **on this development host, `-smp N`
is round-robin on one host thread.** A missing lock will essentially never reproduce. So the suite
would be asserting that SMP *works*, and would have almost no power to assert that it is *race-free*
— which is the only interesting property.

### 4.3 What I would spend the effort on instead

Every one of these is smaller, has a user-visible result, and is a prerequisite for something:

1. **A shutdown path.** `known-gaps.md:43` still says *"there is no `timeout`-free shutdown path.
   `isa-debug-exit` or ACPI shutdown remains unbuilt, so every harness still ends by letting
   `timeout` kill QEMU."* **Twenty harnesses.** ACPI gives this.
2. **D3 — a process that outlives the command that started it.** `display-protocol.md` calls it *"the
   structural blocker nobody has costed"* and *"the milestone that should be built first of all of
   these."* It is also the thing that would create a workload SMP could use.
3. **A blocked process state.** The single largest thing the scheduler is missing.
4. **X1/X3 — a program bigger than 64 KiB and a stack bigger than one page.** `exec-format.md` §4:
   `libavutil`'s `__text` alone is 355,944 bytes, 5.4× the loader's cap.
5. **Growing the 2 MiB ring-3 window**, which `display-protocol.md` §1.2 calls the binding constraint
   on a window system, and which is *62 page-directory entries that already exist*.

### 4.4 The part that survives — and it is most of the work

**ACPI and the APIC are worth building on one core, for their own reasons, and they happen to be the
entire prerequisite for SMP.** That is the recommendation.

**ACPI, on one core, buys:**

* **Shutdown and reboot.** The FADT's `PM1a_CNT_BLK` + `SLP_TYPa` from the `\_S5` object is a
  `port_outw` away — the instruction exists. Twenty harnesses stop ending with `timeout`.
* **A microsecond clock.** `PM_TMR_BLK`, 3.579545 MHz, one `port_inl`. The finest clock this kernel
  has today is 10 ms.
* **The MCFG table**, which is the memory-mapped PCIe configuration base. `known-gaps.md:1510`:
  *"extended 4 KiB space needs the memory-mapped window whose base comes from the ACPI `MCFG` table,
  and this kernel has no ACPI parser at all. On a machine with no legacy mechanism #1 — increasingly
  common —"* the PCI enumeration this kernel already has stops working entirely.
* **The HPET table**, if a better timer is ever wanted.

**The APIC, on one core, buys:**

* **MSI and MSI-X.** A modern PCIe device — NVMe, virtio, a real NIC — delivers interrupts by
  *writing to the local APIC's address*. There is no INTx line to route. **Without a local APIC,
  every driver after the ATA one is limited to polling.** This is, to me, the strongest single
  argument in this document for building the APIC, and it has nothing to do with SMP.
* **More than 15 interrupt lines**, and per-vector masking rather than a byte mask per PIC.
* **A per-CPU timer that does not lose time.** GAP-0138 item 3: *"The PIC cannot queue more than one
  IRQ0, so a long syscall does not defer time — it destroys it. Nothing in this kernel notices, and
  `tick_count` is therefore a lower bound on elapsed time rather than a measure of it."* A LAPIC
  timer in TSC-deadline or one-shot mode fixes that.

**So the sequencing recommendation is:**

> **Build P1–P4 of §5 (ACPI, LAPIC, I/O APIC, shutdown). Stop. Re-ask the question.**
> Everything from P5 onwards is SMP proper and should be gated on a workload existing — realistically,
> on D3 and on a blocked state. If that day comes, P1–P4 will already be done and the remaining work
> is a trampoline and a locking story. If it does not come, P1–P4 were worth building anyway, which
> is the definition of a prerequisite that pays for itself.

---

## 5. The milestone ladder

### 5.0 How any of this gets verified, and the limit that has to be stated first

**The tooling almost already exists.** `m2-console/qmp-drive.py` is shared by seventeen harnesses and
takes repeatable `--monitor-command` arguments, which it forwards as `human-monitor-command`. So
**`info cpus` and `info registers -a` work through it with no change to that file at all**.
`query-cpus-fast` is a plain QMP command rather than a monitor one, and the driver's CLI exposes no
way to send one — that is a small **purely additive** flag (`--qmp-command`/`--qmp-capture`, the same
shape `--monitor-command`/`--monitor-capture` already has), and it must be additive because seventeen
harnesses share the file. Measured on this host (QEMU 11.0.0):

```
$ ... -smp 4 ... , then human-monitor-command "info cpus"
* CPU #0: thread_id=55638 model=qemu64
  CPU #1: thread_id=55638 model=qemu64
  CPU #2: thread_id=55638 model=qemu64
  CPU #3: thread_id=55638 model=qemu64
```

**`info cpus` gives the count and nothing else** in QEMU 11 — the `pc=` field older versions printed
is gone. The real evidence tool is **`info registers -a`**, which prints a `CPU#N` block per vCPU
carrying `CPL=`, `EIP=`/`RIP=`, `CR3=`, `EFER=` and `HLT=`. Before bring-up an AP reads
`EIP=0000fff0 CS=f000 ... HLT=1` — real mode, halted. That makes an unfakeable pair of assertions
possible: **before, N−1 CPUs are in 16-bit real mode and halted; after, they are in long mode with a
kernel `CR3` and a kernel `RIP`.**

**And now the limit, which is the most important sentence in this section.** Measured on this host —
`uname -m` is `arm64`, and `qemu-system-x86_64 -accel help` lists **`tcg` only**:

```
$ ... -smp 2 -accel tcg,thread=multi ... "info cpus"
thread_id=56925
thread_id=56925          <- identical: one host thread, round-robin
$ ... -smp 2 -accel tcg,thread=single ... "info cpus"
thread_id=56953
thread_id=56953          <- identical, as expected
```

**MTTCG is not active for an x86 guest on this host.** Both vCPUs run on one host thread, interleaved
at translation-block boundaries. Consequences, stated plainly:

* **Bring-up, per-CPU state, and interrupt routing are fully verifiable here.** They are structural.
* **Race-freedom is essentially not verifiable here.** A missing lock will almost never manifest,
  because two CPUs are never actually simultaneous. A green suite would mean very little about the
  locking.
* Any harness that claims to exercise locking must pin `-accel tcg,thread=multi` **and** say in its
  own header that on a single-threaded-TCG host it is testing nothing, so that a future reader does
  not mistake it for evidence. On an x86-64 host with KVM or MTTCG it becomes real.
* `-cpu qemu64` is pinned by 23 harnesses and has `x2apic: false`. **Nothing below may depend on
  x2APIC.**

Every milestone below states a **binary exit criterion** and a **negative control**, because a
control that must fail is the only thing that proves the assertion is sensitive to the property and
not to the boot happening at all.

---

### P1 — The kernel can read its own firmware tables

**Blocked on: nothing.** No new assembly, no new externs, no DCDart change, no new mapping.

RSDP scan (EBDA + `[0xE0000, 0x100000)`), checksum, RSDT/XSDT walk, MADT parse into a `@bss` block:
CPU list, I/O APIC list, interrupt source overrides. An `acpi` command reports them. The 8259 and the
PIT are untouched.

*Binary:* `acpi` prints the RSDP revision, the OEM ID, the MADT's Local Interrupt Controller Address,
the I/O APIC's address and GSI base, the number of enabled processors, and every interrupt source
override. **The processor count is compared against QEMU's own `query-cpus-fast` from the same boot**
— two independent programs counting the same CPUs, `m5-pci`'s `info pci` mechanism exactly. The
harness boots with **`-smp 1`, `-smp 2` and `-smp 4`** and requires the kernel's count to equal
QEMU's in all three. The I/O APIC address is required to be **inside the mapped PCI hole**, derived
from `vm.dart`'s own constants rather than typed. *Negative control:* a boot where the harness has
**corrupted one byte of the RSDP checksum in guest memory** must produce the named refusal and a live
shell — and a second control with no ACPI at all (`-machine ...,acpi=off`) must refuse by a different
name. **Anti-vacuity:** the harness fails if the override list is empty, because a PC without an ISA
IRQ 0 → GSI 2 override is a PC this design has not seen.

---

### P2 — The local APIC is on, and the machine can turn itself off

**Blocked on: P1.**

Two things, deliberately together, because the second is what makes the first worth shipping. Map the
two APIC 2 MiB pages **uncacheable** (§1.2). Set the SVR software-enable and spurious vector `0xFF`,
mask every unused LVT entry, read back the LAPIC ID and version. Parse the FADT and implement
`shutdown` via `PM1a_CNT` + `\_S5`.

*Binary:* `apic` prints the LAPIC ID and version, and the ID **equals the one the MADT listed for the
BSP**. The harness reads the live page tables out of guest physical memory (the `m8-paging`
mechanism) and requires the two PDEs covering `0xFEC00000` and `0xFEE00000` to have `PCD` set and
**the other 510 in the PCI hole not to**. `shutdown` causes QEMU to emit a **`SHUTDOWN` QMP event
with `"guest": true`**, and the harness's `timeout` **does not fire** — the first boot in this
project's history to end because the kernel said so. *Negative control:* a boot that does not type
`shutdown` must still end by `timeout`, and must produce serial output byte-identical to today's,
including the 544-byte M1 prefix. **The 544-byte golden does not move in this milestone and the
harness asserts that it did not.**

---

### P3 — Interrupts arrive through the I/O APIC, and the 8259s are dead

**Blocked on: P2.**

`ioapic` masks both 8259s, programs redirection entries for the PIT and the keyboard at chosen
vectors, honouring the source overrides and the polarity/trigger flags from P1, and switches the EOI
path to the LAPIC. The spurious-vector arm is added to `isrDispatch` with its own counter.

*Binary:* after `ioapic`, the kernel prints **the vector the next timer interrupt was actually
delivered on** — `M1 PIC`'s evidential form, one milestone later — and it is the new vector, not
`0x20`. `ticks` then advances, which proves the EOI path (exactly the argument `M1 TICKS 0064` makes
for the 8259). Keystrokes injected over QMP are echoed, which proves the keyboard's redirection entry
and its edge/polarity. The harness reads the I/O APIC's redirection entries **back out of guest
physical memory** and compares them against what the kernel said it wrote. *Negative control:* a
build that ignores the interrupt source override must **hang** waiting for a tick — the harness
requires that mutant to fail, so the override is proven load-bearing rather than merely parsed.
**Second negative control:** a boot that does not type `ioapic` is byte-identical to today.

---

### P4 — A DCDart atomics milestone *(a different repo's milestone, listed here because everything after it waits)*

**Blocked on: DCDart.** §3.5 is the ask: `exchange`, `compareExchange`, `fetchAdd`, `fence`, over
`u64` at a raw address, sequentially consistent, no ordering parameter, no ARC interaction — argued
through DCDart's memory-model freeze on ADR-0051's "raw bytes, so §3's questions do not arise"
precedent.

*Binary:* DCDart's own conformance suite, in DCDart's repo, per CLAUDE.md rule 3. **Not this
project's milestone and not this project's exit criterion.** What oscortex owes is the GAP entry that
files the need with the concrete call sites from §3.3.

*If it is refused or deferred:* `core/boot/atomic.S`, five functions, `portio.S`'s pattern, with a GAP
entry naming the real ask and stating the cost (§3.5's last paragraph). That is a legitimate interim
and it should be argued for explicitly rather than slid in.

---

### P5 — One lock exists, and it is exercised before there is anything to contend with it

**Blocked on: P4.**

A ticket lock (fair, and its holder/next counters are directly reportable) around the console and the
frame allocator, plus per-CPU counters. **Built and exercised on one CPU**, where every acquire is
uncontended.

*Binary:* `locks` reports acquire counts and a contention count per lock. After a session that runs
two processes to completion, the console lock's acquire count equals a number **derived from the
lines printed**, and the contention count is **exactly zero** — because there is one CPU. The frame
allocator's free count is identical before and after, to the frame. *Negative control:* a build with
the lock's release removed must **hang on the second acquire**, and the harness requires it to. That
is what proves the lock is in the path rather than decorative.

---

### P6 — A second CPU exists and is in long mode

**Blocked on: P3.** *(Not on P4 — §3.2: the bring-up handshake is single-writer publish/observe and
needs no atomics.)*

The trampoline (`core/boot/ap.S`), the copy to `0x8000`, INIT–SIPI–SIPI with PM-timer delays, the AP's
64-bit entry doing `lgdt`/`ltr`/`lidt`/`CR3` **in that order** (§2.3), and an AP that publishes its
APIC ID and a ready word and then sits in `hlt` with IF clear.

*Binary:* with **`-smp 2`**, the kernel prints `CPU 01 UP APIC 01` — and the APIC ID it prints is
**read by the AP from its own LAPIC ID register**, not the one the BSP sent the SIPI to. QEMU's
`info registers -a` from the same boot shows **CPU#1 with `CR3` equal to the kernel's PML4** (the
value the kernel printed at `vm`), **`EFER.LMA` set**, and a `RIP` inside the kernel's `.text`
range as read from `kernel.map`. *Negative control 1:* the same kernel with **`-smp 1`** must print
**no** `CPU` line at all and produce a byte-identical capture to P3's. *Negative control 2:* an
`info registers -a` taken **before** the bring-up command must show CPU#1 at `EIP=0000fff0`,
`CS=f000`, `HLT=1` — real mode, halted — so that the "after" state is a change and not a
description of the default. *Anti-vacuity:* the harness fails if fewer CPUs came up than the MADT
listed as enabled.

**And the mutation that must be shown to fail:** an AP that installs the kernel PML4 *before* jumping
above 1 MiB (§2.2) must not come up. If that mutant passes, the NX mapping is not what the harness
thinks it is.

---

### P7 — Each CPU has its own state, and both of them can prove it

**Blocked on: P6.**

The per-CPU block of §2.4: `cpuIndex()` via the LAPIC ID and the translation table, per-CPU TSS and
ring-0 stack, `procHeadCurrent`/`procHeadSlice` migrated out of the process-table header. Each CPU's
LAPIC timer is armed and increments its **own** tick counter.

*Binary:* with `-smp 4`, `cpus` prints one line per CPU: index, APIC ID, TSS base, ring-0 stack top,
and tick count. **All four tick counts advance**, and the harness requires each to be non-zero and
the four to differ (identical counts would mean one counter behind four names). The four `cpuStore`
blocks are read out of the linked image and required to be **64-byte aligned and non-overlapping**,
and the four `TR` values from `info registers -a` are required to be **four distinct selectors**.
*Negative control:* a build where `cpuIndex()` returns a constant 0 must produce four identical tick
counts and one `TR`, and the harness must fail it. *Second negative control:* a build with
`cpuStore`'s alignment reduced to 8 must fail the alignment check out of the linked image, **before
any boot** — the same "check it without booting" discipline `m11-proc` applies to `procStore`'s
16-byte `fxsave` alignment.

---

### P8 — Two CPUs run two ring-3 processes at the same time

**Blocked on: P5, P7.**

One big kernel lock, taken at every kernel entry and released at every exit, plus the pinning rules of
§3.3 (the shell is one CPU's; IRQ1 goes to one CPU). `procPickNext` + the state transition become one
atomic step (§3.4). This is the smallest thing that is honestly SMP.

*Binary:* `-smp 2`, `proc run A B`, both programs run to completion and print their derived exit
statuses. The unfakeable part: **at a sampled instant during the session, `info registers -a` shows
two vCPUs with `CPL=3`, with `CR3` values equal to the two processes' distinct PML4 frames** (which
`m11-proc` already reads out of guest memory), **and two different `RIP`s**. That is one QMP command
and it cannot be produced by a kernel that is running one process. The frame allocator's free count
is identical before and after, to the frame. *Negative control:* the same session with `-smp 1` must
run both programs correctly (so the kernel is not SMP-only) and must **never** show two vCPUs at
CPL 3. *Second negative control:* the same session with the big lock removed must be run under
`-accel tcg,thread=multi` — and **the harness header must state that on a single-threaded-TCG host
this control proves nothing**, which on the development host measured in §5.0 it does not.

---

### P9 — The lock is broken up, and each split is justified by a number

**Blocked on: P8, and on a workload that makes the number non-zero.**

Per-subsystem locks, in the order the contention counters from P5 say. Not before.

*Binary:* for each lock split out, the **contention count on the big lock falls** by a measured amount
and the total work done is unchanged. *Negative control:* a split that does not reduce contention is
reverted, and the harness records the number that said so. **This milestone should not be started
until P5's contention counters are non-zero on a real workload**, because a lock split made without
one is a guess with a maintenance cost.

---

## 6. What I did not decide, and would rather be told

**Q0 — Is the recommendation in §4.4 accepted: build P1–P4, stop, re-ask?**
This is the only question that changes what gets built. Everything in §5 after P4 is conditional on
the answer.

**Q1 — Does the APIC go behind a command (§1.5 option B) or into the boot path (option A)?**
B keeps twenty harnesses green and the 544-byte golden frozen. A is what a finished OS looks like.
**I recommend B and would want A named as its own later milestone with its own ADR**, so that the
golden's move is a decision somebody made rather than a side effect of an interrupt-controller
change.

**Q2 — Atomics: a DCDart ADR, or an `atomic.S` in this repo?**
§3.5 argues the DCDart ask can be as narrow as ADR-0051's was, and CLAUDE.md rule 3 is unambiguous
that language gaps get built there. But `portio.S` is a live counter-precedent that has been in this
tree since M5. **This is a rule-3 judgement call and it is explicitly one of the things CLAUDE.md
says to escalate**, so I have not made it.

**Q3 — Is the GDT allowed to become writable?**
§2.3 says no and gives a three-instruction ordering constraint instead. If a future milestone wants
CPUs to be hot-added, or wants per-CPU GDTs for any other reason, the answer changes. `boot.S:695`
already records this being decided once, in the other direction, for M9.

**Q4 — Should `tick_count` become a sum of per-CPU counters, or should the BSP keep the global
clock?**
The second is simpler and keeps `ticks`' meaning and `m3-shell`'s golden intact. The first is what a
per-CPU timer naturally produces. **I lean to the second and would not fight for it.**

**Q5 — How many CPUs is `cpuMax`?**
Four, matching `procMax`, is the tidy answer and is a capacity rather than a limit — a fifth MADT
entry is refused by name, exactly as a fifth `procCreate` is. But the two numbers have nothing to do
with each other, and making them equal by default is the kind of coincidence that reads as a
relationship later.

---

## 7. Notes for the coordinator to fold in elsewhere

**I have not touched `known-gaps.md`, `ROADMAP.md`, `OSCORTEX_SPEC.md` or any ADR.** These are the
entries that belong in them, with my reasoning, for whoever folds them in.

**A correction that should be made whether or not any of this is built.** ADR-0002's *"Rejected: the
APIC"* section and `known-gaps.md` GAP-0007's first bullet both give three reasons, and **two of them
have been false since M5**: the MMIO is mapped (`vm.dart:596`'s PCI hole covers `0xFEE00000` and
`0xFEC00000`), and xAPIC needs no MSR at all (§1.1). They were true when written. Repeating them is
now misleading about how much work the APIC is, and the honest remaining sentence is *"ACPI parsing
is a milestone of its own"* — which is still true, and which §1.3 sizes at roughly 512 bytes of
`@bss`, one storage seam, zero new externs and zero new assembly.

**A latent correctness issue that deserves a GAP entry independently of SMP.** GAP-0071 records that
the PCI hole is mapped cacheable and calls it *"wrong in principle for MMIO and right in practice for
a linear framebuffer."* That entry should name the local APIC and the I/O APIC as the two addresses
inside that window for which it is **not** right in practice, because an EOI is a store with a side
effect. One branch in the PCI-hole loop; one harness assertion moves and becomes stronger.

**GAP-0136's proposed cheap close should be reconsidered in one specific way.** It offers *"a stated
single-core invariant in `OSCORTEX_SPEC.md` that this kernel is entitled to rely on"* as the honest
alternative to atomics, and §4 agrees with the spirit. But the invariant as stated would be
**invisible at the places that depend on it**. There are at least a dozen comments in this kernel of
the form *"safe because there is one caller"* / *"only safe because there is one core"*, and
`shell.dart:1619`'s *"written only with interrupts disabled on this side ... so the two never
interleave"* does not even mention cores. **If the invariant is adopted, the useful form is a named
one** — one sentence in the spec, and every site that relies on it citing the name — so that the day
somebody proposes an AP, a grep finds all of them. That is a documentation change with no code, and
it is worth more than an atomics ADR nobody uses.

**Three gaps are upstream of this whole document and read as scheduler limitations rather than as the
SMP blockers they are:**
* **GAP-0141 — nothing blocks.** No fifth process state. This is why §4.1 says there is no workload,
  and it is a bigger blocker on SMP than the locking is.
* **GAP-0138 item 3 — the PIC destroys time.** *"a long syscall does not defer time — it destroys
  it."* This is an argument **for** the LAPIC timer that is currently filed as a scheduler cost.
* **`display-protocol.md` §6 D3 — a resident process.** Until it exists, `proc run A B` is the only
  multi-process workload that can be constructed, on one core or on four.

**A DCDart-side observation that is not filed in either repo.** DCDart's ARC is non-atomic —
`dc_retain`/`dc_release` are plain increments. No `@bare` kernel object is ARC-managed today so
nothing is wrong now, but it means **the first shared `HeapObject` on a multi-core machine corrupts
its own refcount**, and nothing in the language would notice. It falls out of DCDart GAP-0039 plus the
frozen §3 memory model rather than being its own entry, which is probably why it is not one.

**A residual risk in §3.2's own good news.** The claim *"single-writer publish/observe works today"*
rests on x86-TSO plus DCDart ADR-0041's every-`Pointer<T>`-access-is-volatile. **Neither is written
down anywhere as a property this kernel relies on, and nothing checks either.** DCDart GAP-0034
explicitly proposes making volatility a *type* distinction rather than universal — which would be a
performance win everywhere and would silently remove the compiler barrier the AP handshake depends
on. Worth a GAP entry now, cheaply, rather than a bisect later.

**A tooling note with a known shape.** `info cpus` and `info registers -a` reach
`m2-console/qmp-drive.py` unchanged, because both are `human-monitor-command`. **`query-cpus-fast` is
plain QMP and the driver has no way to send one** — P1 wants it, because comparing the kernel's CPU
count against QEMU's own is the `m5-pci` `info pci` move and it is what makes the count evidence
rather than an echo. That needs a `--qmp-command`/`--qmp-capture` sibling to the two monitor flags,
and it **must be purely additive**: seventeen harnesses share that file. This is the same shape as the
`--pointer` gap `display-protocol.md` §8 records for `input-send-event`, and the two could reasonably
be done together by whoever touches the driver next.

**And a harness fact worth stating separately:** **no harness passes `-smp` at all today** (measured:
`grep -o '\-smp [0-9]*' core/tests/conformance/*/run.sh` finds nothing), so every boot in this suite
has run on exactly one vCPU for nineteen milestones. Adding `-smp` to a harness is therefore a change
in the machine every earlier golden was produced on, and P1's three-way `-smp 1 / 2 / 4` boot should
be a **new** harness rather than a flag added to an existing one.

**And one thing worth stealing from this document even if SMP is never built.** §3.3's table — every
`@bss` block, its measured offset and size, who touches it, and from which context — did not exist
anywhere and took a full sweep of the tree to produce. It is useful for re-entrancy, for the
preempt-ring-0 question (GAP-0138), and for the D3 resident-process work, none of which is SMP. It
belongs somewhere findable regardless of what happens to the rest of this file.
