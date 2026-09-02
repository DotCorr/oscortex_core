# oscortex storage — getting off PIO, and what a filesystem here is actually for

**Status: DESIGN.** When a piece of this is built it gets its own numbered ADR; this file is the
thing those ADRs will point back at, the same way `display-protocol.md` is for the window system and
`exec-format.md` is for the loader.

**A0 (ADR-0069) landed.** The kernel finds class `01/06/01` / QEMU `8086:2922`,
prints ABAR and CAP (`core/kernel/ahci.dart`, `tests/conformance/a0-ahci`).

**A1 (ADR-0077) landed.** One `READ DMA EXT` of LBA 7 (`ahci read`). Command
list + FIS + table + sector in one `allocFrame`. `PxCI` poll watches
`PxIS.TFES` through `Volatile`. IDE PIO is unchanged — `m6-disk` is still
the PIO proof.

**NVM0 (ADR-0071), NVM1 (ADR-0074), NVM2 (ADR-0087), NVM3 (ADR-0088), NVM4 (ADR-0089), NVM5 (ADR-0090) and NVM6 (ADR-0092) landed.** The kernel finds class
`01/08/02`, prints BDF + BAR0 (`tests/conformance/nvm0`), loads CAP at BAR0+0 and VS at
BAR0+8 (`tests/conformance/nvm1`), issues one Identify Controller (admin opcode 06h,
CNS=1) whose SN/VID/NN come from the controller (`tests/conformance/nvm2`),
creates an I/O queue pair then reads one planted sector at LBA 7 (`core/kernel/nvme.dart`,
`tests/conformance/nvm3`), writes that plant to LBA 11 so the host image
can read it back (`tests/conformance/nvm4`), serves FAT through that I/O
pair when an NVMe controller is present (`tests/conformance/nvm5`), and
`run` / `spawn` of a named ELF reads image sectors through the same
pick (`elfDiskRead` → `fatDiskRead` → `nvmeIoRead`,
`tests/conformance/nvm6`). **A2 (ADR-0137)** made AHCI an equal
`fatDiskRead` root: class `01/06/01` → `ahciIoRead` when NVMe is
absent (`tests/conformance/nvm-root`). Machines with neither still
use ATA PIO.

**Provenance.** The brief for this document named the subject — PIO's cost, AHCI/SATA, life beyond
FAT16, a block layer, a milestone ladder — and asserted one quantity about the write path that turns
out to be low by a factor of two and a half. That correction is §1.2 and it is reported rather than
absorbed, because the number is the argument. Everything else here is measured out of the tree at the
commit this was written against, or is an **estimate** that says so and gives its method.

### The six things this document concludes, for a reader in a hurry

| | conclusion | where |
|---|---|---|
| **PIO's real cost** | **The byte-shuffling is the small half.** A 512-byte file costs **five sector writes and five `FLUSH CACHE` commands**, not two and two — and on real hardware the five flushes cost 20–500× what the 1280 `outw` instructions do. **DMA does not fix the flushes.** | §1 |
| **What PIO actually breaks** | **`IF` is clear for the whole of every syscall** (every gate in this IDT is an interrupt gate). So a `fdwrite` is a hole in M18's preemption guarantee whose width is the disk's latency. That is the argument for DMA, and it is a *scheduling* argument, not a throughput one. | §1.4 |
| **The intermediate step is real and nearly free** | **Bus-master IDE DMA on the PIIX3 that is already there.** Three I/O registers, one PRDT, **zero change to any harness's QEMU command line**. AHCI needs `-device ich9-ahci` in twelve harnesses. | §2.1 |
| **DMA memory is NOT the problem people expect** | A PRDT *is* a scatter-gather list. `allocFrame`'s one-4KiB-frame-at-a-time is **exactly the right granularity** — one PRD per frame — and the identity map makes physical address = virtual address for free. The real blockers are **no `pciWrite32`** (bus-master enable is a config write) and **cacheable MMIO** (GAP-0071). | §2.3, §2.5 |
| **Filesystem** | **Extend the FAT driver. Do not port ext2. Do not write a native filesystem — yet.** FAT's decisive property is not its format, it is that `fsck_msdos` and macOS's `msdos` driver are an **independent judge**, and that judge is the only reason M16's write path is known to be real rather than self-consistent. §3.4 says exactly what would have to be built to replace it, and what it costs. | §3 |
| **Block layer** | **Worth it, and cheapest to take now, at four call sites.** But the version worth building is not `bread`/`bwrite` — it is the **request** shape (`n` sectors, a completion, an error), because that is the only shape DMA can be slid under later without touching FAT again. | §4 |

**And the finding that surprised me most:** the flush discipline, not PIO, is what makes writing slow
here — and it is the one part of the stack that is **verified structurally and only structurally**
(ADR-0020 §2, GAP-0129: QEMU persists a write whether or not the drive's cache is flushed, so no test
this harness can run distinguishes a driver that flushes from one that does not). The single largest
performance win available is to flush **once per `close`** instead of once per sector — and taking it
would delete the only property of the write path that no test can currently see. §1.5.

---

## 0. What this has to be true of

Every row is read out of the tree and cited, so the next agent can check whether it still holds.

| # | fact | where |
|---|---|---|
| 1 | `ataReadInto` and `ataWriteFrom` each move **exactly one 512-byte sector per command**, 256 `u16` at a time through port 0x1F0 | `ata.dart:900`, `ata.dart:1041`, `ata.dart:245` |
| 2 | `ataWriteFrom`'s last statement is `return ataFlushCache();` — **one `FLUSH CACHE` (0xE7) per sector**, and the harness reads the function body to require it | `ata.dart:1097`, `ata.dart:1015`, ADR-0020 §2 |
| 3 | `ataSelect` writes **nIEN before the device select**, so the drive's IRQ line is masked and polling is the only completion signal there is | `ata.dart:582`, `ata.dart:186` |
| 4 | `ataWait` is the only polling loop, bounded at **2²¹ iterations** — an iteration count, not a duration (GAP-0073) | `ata.dart:468`, `ata.dart:206` |
| 5 | **Every gate in this IDT is an interrupt gate**, so `IF` is clear for the whole of every kernel entry from ring 3; a syscall cannot be preempted and a tick inside one is *not delivered* | ADR-0022 §1, ROADMAP M18, GAP-0138 |
| 6 | `ataWriteFrom` has **exactly one caller**, `fatWriteSector`, and the harness requires it | `fat.dart:1736–1737`, ADR-0020 §8 |
| 7 | `ataReadInto` has **one filesystem/loader call site**: `fatDiskRead` in `fat.dart`. `elfDiskRead` calls `fatDiskRead`. The PIO fallback is that one `if`. | grep |
| 8 | `fatSetEntry` writes the patched FAT sector to **every copy of the FAT** — `BPB_NumFATs` is 2, so **one FAT entry change is two sector writes** | `fat.dart:1763–1781`, ADR-0020 §3 rule 1 |
| 9 | `allocFrame` hands out **one 4096-byte frame at a time**; there is no contiguous multi-frame request, and pmm.dart's own header names a DMA buffer as the thing that would want one | `pmm.dart:1090`, `pmm.dart:127`, `pmm.dart:587` |
| 10 | The first **128 MiB is identity-mapped** with 2 MiB pages, and QEMU is started with `-m 128M`, so for every frame `allocFrame` returns, **physical address == virtual address** | `boot.S:59,96`, `m16-filewrite/run.sh:790` |
| 11 | **3–4 GiB is identity-mapped**, present + writable + PS, **cacheable, no PAT, no MTRR** — the PCI hole is reachable and is mapped wrong for MMIO on purpose | `boot.S:106–128,382–400`, GAP-0071 |
| 12 | `pciRead32` exists. **There is no `pciWrite32` anywhere in this kernel.** `port_outl` is declared and is used only to write the CONFIG_ADDRESS register | `pci.dart:266`, `pci.dart:82` |
| 13 | Reading a BAR is already done once, for the framebuffer: `pciRegBar0 = 0x10`, `bar & 0xFFFFFFF0`, and bit 0 distinguishes memory from I/O space | `fb.dart:295,330` |
| 14 | The MMIO primitive is `Pointer<u32>.fromAddress(addr).value = v` — **stores only. No load through a `Pointer` has ever been in a poll loop in this kernel** | `fb.dart:415`, `fb.dart:263` |
| 15 | Every harness with a disk starts QEMU with `-drive file=…,if=ide,index=0` — the PIIX3 IDE controller `8086:7010` that `pci` reports at `00:01.1` | `m16-filewrite/run.sh:796`, ADR-0010 §1 |
| 16 | The FAT volume has **1024-byte clusters** (2 sectors), a 512-entry root directory, two FATs | `m16-filewrite/make-image.py:88,101` |
| 17 | The largest file the driver will hand back is **256 clusters** (`fatChainMax`); the largest image the loader will read is **65536 bytes** | `fat.dart:202`, `elf.dart:767` |
| 18 | A write descriptor is **append-only and starts empty**; there is no write at an offset, no `unlink`, no `mkdir`, no subdirectory write, no timestamp | ADR-0020 §0, §10; GAP-0127 |

And two facts about the *language*, which shape §2 and §4:

19. **`@bare` DCDart has no function pointers and no dynamic dispatch** — `isrDispatch` is a branch
    chain and the shell's command table is an `if` chain. **A block layer cannot be a vtable of
    device drivers.** It can only be an `if` on a device number. (`exec-format.md` §0 item 10.)
20. **DCDart has no mutable statics** (GAP-0053). Every byte of a command list, a PRDT or a request
    queue is either assembly-donated `.bss` behind a seam accessor, or a frame from `allocFrame`.
    ADR-0021 changed *how* that is spelled; it did not change that it is true.

---

## 1. WHY PIO IS NOW THE BOTTLENECK

### 1.1 It was not a bottleneck, and the reason it was not is worth keeping

ADR-0010 §3 chose PIO because PIO **needs no memory manager**: no bus-master enable, no
physically-contiguous landing buffer, no PRDT, nowhere to put either. M7 was blocked; M6 was
buildable. That argument was correct and it has now **expired**, in the precise sense that every one
of its three premises is false today:

| ADR-0010 §3 said DMA needs… | today |
|---|---|
| a physically contiguous landing buffer | `allocFrame` returns 4 KiB frames; **a PRDT does not need contiguity** (§2.3) |
| a PRDT | one frame, or 64 bytes of donated `.bss` |
| somewhere to put both, which is a page allocator | M7 shipped. `pmm.dart` is 1653 lines |

ADR-0010 said so itself: *"A DMA driver is strictly better and is a post-allocator milestone."* We are
nine milestones past the allocator.

### 1.2 The cost of one 512-byte file, counted rather than assumed

The brief for this document said a 512-byte file write costs *"two sector writes plus two FLUSH CACHE
commands"*. **It costs five of each.** Here is the trace, for `open(name, O_WRITE)` on a name that is
not on the volume, one `fdwrite` of 512 bytes, and `close` — the smallest complete file this OS can
produce:

| step | code | sector writes | why |
|---|---|---|---|
| `open` → `fatDirCreate` | `fat.dart:2163` | **1** | the new directory entry's sector |
| `open` → `fatDirTerminate` | `fat.dart:2026` | 0 | the next entry is already 0x00 on a formatted volume (ADR-0020 §3) |
| `fdwrite` → `fatAlloc(0)` → `fatSetEntry(c, 0xFFFF)` | `fat.dart:1775` | **2** | one FAT sector, written to **both copies of the FAT** |
| `fdwrite` → `fatAlloc`'s link write | `fat.dart:1869` | 0 | `last` is 0 for the first cluster, so there is nothing to link |
| `fdwrite` → data sector | `file.dart:1160` | **1** | the 512 bytes themselves |
| `close` → `fatDirWrite` | `fat.dart:1975` | **1** | size and first cluster, written last (rule 3) |
| | **total** | **5** | |

**Five `WRITE SECTORS`, and therefore five `FLUSH CACHE`**, because `ataWriteFrom` ends with one
(fact 2). **Ten ATA commands and 2560 bytes moved through the CPU, to put 512 bytes of payload on a
disk.** The amplification is 5× in sectors and 10× in commands.

It gets worse in the ordinary case rather than better. Every subsequent cluster boundary — every
1024 bytes on this volume (fact 16) — costs a `fatAlloc` where `last` is a real cluster, so
`fatSetEntry` runs **twice**: end-of-chain on the new cluster, then the link on the old one. That is
**four** FAT sector writes per cluster, plus two data sectors. Steady-state, appending to a file on
this volume:

```
per 1024 bytes of payload:  4 FAT sector writes + 2 data sector writes = 6 writes, 6 flushes
                            → 3072 bytes moved by the CPU, 12 ATA commands
```

**A three-times write amplification in bytes and a six-times amplification in commands, in the steady
state, forever.** Note where it comes from: two of the four FAT writes are the *second copy of the
FAT*, which is not optional (ADR-0020 §3 rule 1 — a volume whose FATs differ is a volume `fsck_msdos`
rejects and macOS may read either half of). And the two FAT writes per cluster land in **the same FAT
sector** almost always — 256 entries per sector, and `fatFindFree` returns the next free cluster — so
they are two writes of the same 512 bytes to the same LBA, back to back, each with its own flush.
That is the single most obviously removable cost in the stack, and §4 is where it becomes removable.

### 1.3 What the CPU actually spends, with the method stated

Two costs, and they are not the same size.

**(a) The data transfer.** 256 iterations of a `while` loop, each doing one `in`/`out` on port 0x1F0
plus loop arithmetic. This is **not** `rep insw`; the pinned toolchain has no such intrinsic and the
loop is spelled a word at a time (`ata.dart:900`, `ata.dart:1041`).

*Estimate, method stated:* a legacy I/O-port access on a modern chipset is dominated by the LPC/PCI
round trip, not the instruction. Published measurements for `in`/`out` to a legacy ISA-range port
cluster around **0.5–1 µs** on real hardware; PIO mode 4's *specified* peak is 16.7 MB/s, which is
**30 µs** for a sector and implies ~120 ns per word, so the drive's own interface is faster than a
naive port access on a modern host bridge and the true figure sits between them. Take **30–130 µs per
sector transferred** as the band. Under QEMU it is a VM exit per `in`/`out` — roughly **1–2 µs each**
in a KVM-less TCG-or-hvf setup — so **256–512 µs per sector**, which is *worse* than real hardware and
is why the emulator is not a guide here.

**(b) The flush.** `FLUSH CACHE` is defined to not complete until the drive's volatile write cache is
on the medium. On a 7200 RPM disk with a dirty cache that is bounded below by seek + rotational
latency: **4–15 ms**. On a SATA SSD it is a controller-internal barrier: **0.1–1 ms** is the usual
band, and the tail is much longer. Under QEMU against a raw file it is approximately free, which is
GAP-0129's whole point.

**So on real hardware, per sector written: ~0.05 ms of PIO and 0.1–15 ms of flush.** The flush is
between **2× and 300× the transfer**. Put the two together with §1.2's count:

| | 512-byte file, real SSD (est.) | 512-byte file, real 7200 RPM disk (est.) |
|---|---|---|
| 5 × PIO transfer | 0.25 ms | 0.25 ms |
| 5 × `FLUSH CACHE` | 1–5 ms | 20–75 ms |
| **total** | **~1.3–5.3 ms** | **~20–75 ms** |
| **effective throughput** | ~100–400 KB/s | ~7–25 KB/s |

**A DMA engine changes the first row and not the second.** Replacing PIO with UDMA/133 (133 MB/s) or
AHCI (600 MB/s) takes the transfer from 0.25 ms to under 0.02 ms and leaves 1–75 ms of flush exactly
where it was. **Anyone who says "PIO is the bottleneck, so build DMA" has the diagnosis right and the
prescription wrong for this specific workload.** DMA is worth building — §1.4 says why — but the win
on a small-file write is a rounding error until the flush discipline changes too.

Where DMA *does* win outright is the read path, which has no flushes at all: `elfReadSectors`
(`elf.dart:1172`) reads a program one sector per command, and a 65536-byte image is **128 commands**
and 128 poll-spins. That is where the multi-sector, multi-PRD transfer pays immediately.

### 1.4 The real cost is not throughput. It is that `IF` is clear the whole time

This is the argument that actually forces the issue, and it is a scheduling argument.

Fact 5: **every gate in this IDT is an interrupt gate**, so the CPU clears `IF` on entry and it stays
clear for the entire kernel-side duration of a syscall. ADR-0022 leans on this deliberately — it is
what makes "only ring 3 is preempted" more than a shortcut, because a tick that arrives at CPL 0 is
*not delivered* rather than merely declined. `procHeadKernTicks` counts the ones that do arrive and
**reads 1**, the single tick that can land in `enter_user`'s three-instruction window before its
`cli`, and ROADMAP M18 says out loud: *"if it is ever large, the argument is wrong rather than the
machine."*

`fdwrite` is a syscall. So is `read`, and so is `open`. Therefore:

> **For the whole of a file write — five ATA commands, five poll-spins and five cache flushes — this
> machine takes no timer interrupts, runs no scheduler, preempts nobody, and drops every keystroke.**

On QEMU that window is microseconds and nothing notices. On real hardware, by §1.3, it is **1–75 ms
for a 512-byte file**. A 64 KiB file on this volume is 64 clusters: **128 data sector writes plus 254
FAT sector writes — 382 writes and 382 flushes** — which by §1.3's bands is **0.06–0.4 s on an SSD
and 1.5–6 s on a 7200 RPM disk**, with `IF` clear throughout. M18's guarantee ("a program that never yields
cannot hang the machine") survives that in the letter and not in the spirit: the runaway program is
stopped, and any program that writes a file stops the machine for the duration anyway. And `ticks`
does not merely pause — the PIT keeps firing into a masked `IF` and repeated ticks **coalesce**, so
the tick counter silently under-counts by however long the disk took. That is the same class of
problem as GAP-0073's "an iteration count, not a duration", one layer up.

**This is what DMA buys, and it is worth stating in the shape it is actually bought in:** an interrupt
-driven DMA transfer lets the kernel *stop being in the syscall*. The transfer is started, the process
is marked blocked, `IF` goes back on, and the completion interrupt makes the process runnable. That
requires three things this kernel does not have — a blocked process state, a way to return from a
syscall without a result, and a device IRQ handler — and **not one of them is a DMA engine**. §5's
ladder puts them in the order that makes each one testable alone.

### 1.5 The flush is the biggest available win, and taking it costs the only thing no test can see

The obvious optimisation is: flush once per `close`, not once per sector. It removes four of five
flushes on a 512-byte file and five of six per cluster in the steady state — call it **60–80% of the
real-hardware write cost**, for a change of about ten lines.

**Do not take it casually, and here is exactly why.** ADR-0020 §2 established, by running the
experiment rather than assuming it, that **removing the flush entirely passes all seven of M16's
boots**. QEMU persists a write to a raw image whether or not the drive's cache was flushed. The flush
is verified *structurally* — the harness reads `ataWriteFrom`'s last statement — and by nothing else.
So any change to the flush discipline is a change to a property this test suite **cannot observe**,
and the only thing standing between the current code and a silent regression is a grep.

If the discipline moves, the grep has to move with it and become sharper, not looser:

* a flush per sector is checkable by "the last statement of `ataWriteFrom` is `ataFlushCache()`";
* a flush per `close` is checkable only by "every path that ends a write descriptor calls
  `ataFlushCache` after the last `fatWriteSector` and before returning", which is a **reachability**
  claim over `file.dart` rather than a statement-position claim over one function. That is a real
  harness engineering job, not a grep.

And the ordering rules do not survive the move unexamined. ADR-0020 §3's rules 2 and 3 are about
*order on the medium*, and with a write-back cache and no flushes between the steps, the drive is
free to commit them in any order it likes. Rule 2 (mark end-of-chain before linking) becomes
meaningless without a barrier between the two writes. **The honest version of "one flush per close" is
"one flush per close, plus one barrier between the FAT write and the directory write" — two flushes,
not one** — and that is still a 3–5× win and it keeps the crash story ADR-0020 §3 actually argues
for. Anything cheaper than that is a different crash story and needs to say so.

---

## 2. GETTING OFF PIO

Two targets, and the smaller one is genuinely worth taking first.

### 2.1 Bus-master IDE DMA: the intermediate step, and why it is nearly free here

The controller `pci` already reports at `00:01.1` — Intel `8086:7010`, class `01/01` (ADR-0010 §1) —
is a PIIX3 IDE, and **it is a bus master**. Every harness starts QEMU with `-drive …,if=ide` (fact
15), and QEMU's PIIX3 model implements bus-master DMA fully. **So this path requires no change to any
harness's QEMU invocation, no new device, and no re-plumbing of twenty test images.** That is the
whole argument for doing it first, and it is a large one in a repo where "the image grew and seven
goldens moved" is a recurring cost (GAP-0078).

**The register set is three registers per channel.** Bus Master IDE lives in an **I/O** BAR — BAR4,
config offset 0x20 — of the IDE function:

| offset | name | width | what |
|---|---|---|---|
| BAR4 + 0x00 | `BMICP` — command | 8 | bit 0 = Start/Stop, bit 3 = direction (1 = write to memory, i.e. a disk *read*) |
| BAR4 + 0x02 | `BMISP` — status | 8 | bit 0 = active, bit 1 = error, bit 2 = interrupt, bits 5/6 = drive-is-DMA-capable |
| BAR4 + 0x04 | `BMIDTPP` — PRDT pointer | 32 | **physical** address of the PRDT, 4-byte aligned |

Secondary channel is the same three at +0x08. That is it. There is no command list, no FIS, no port
structure. Compare §2.2.

**A PRD is eight bytes:**

```
  0..3   physical base address of a region      (32-bit; must not cross a 64 KiB boundary)
  4..5   byte count                             (0 means 65536; must be even)
  6..7   flags                                  (bit 15 = EOT, end of table)
```

**The sequence, in full:**

1. Build the PRDT in memory. Set EOT on the last entry.
2. Write its physical address to `BMIDTPP`.
3. Clear the error and interrupt bits in `BMISP` (write 1 to clear — this is the register everyone
   gets wrong).
4. Set the direction bit in `BMICP`, Start still clear.
5. Issue `READ DMA` (0xC8) / `WRITE DMA` (0xCA) to the ATA registers — **the same 0x1F0–0x1F7 the
   current driver already drives**, with the same LBA28 packing `ataSelect` already does.
6. Set the Start bit in `BMICP`.
7. Wait for completion — the drive's IRQ14, or a poll of `BMISP` bit 2 / the ATA status.
8. Clear Start. Read `BMISP`: bit 1 set is a failed transfer, and bit 0 still set with bit 2 clear
   means the PRDT ran out before the drive did.

**What this reuses, unchanged:** `ataSelect` and its nIEN discipline, `ataWait`, the LBA28 packing,
the timeout with a phase digit, `ataFailed`, and every diagnostic. `ataWriteFrom`'s callers do not
change at all. **What it adds:** ~120 lines, one BAR read, one PRDT, and one config-space *write*.

**Two things stand in the way and neither is DMA.** They are §2.5 (`pciWrite32` does not exist) and,
for the interrupt-driven version only, §2.6 (there is no device IRQ handler and no blocked process).
A **polled** bus-master DMA path — start the transfer, spin on `BMISP` — needs only §2.5, and buys
§1.3(a) but not §1.4. It is a legitimate first rung precisely because it is small enough that its
harness can be about DMA rather than about scheduling.

**And it retains the flushes**, exactly as today: `WRITE DMA` reports completion into the same
volatile cache `WRITE SECTORS` does. §1.5 is orthogonal to all of this.

### 2.2 AHCI/SATA: the structures, and only the registers actually needed

AHCI is bigger, and the honest framing is that most of its size is **capability this OS cannot use
yet** — 32 command slots and native command queuing are for a device with concurrent requests, and
this kernel has one caller and no concurrency (GAP-0090 item 9). The parts that are unavoidable:

**Three memory structures, all host-built, all read by the HBA over DMA.**

**(a) The Command List.** 32 entries × 32 bytes = **1024 bytes, 1024-byte aligned.** Each entry is a
*Command Header*:

```
  DW0   bits 4:0   CFL   command FIS length in DWORDs (5 for a Register H2D FIS)
        bit 6      W     1 = write (host to device)
        bit 5      A     ATAPI
        bits 31:16 PRDTL number of PRD entries in this command's table
  DW1   PRDBC      bytes actually transferred — written BY the HBA, and the thing you check
  DW2   CTBA       physical address of this command's Command Table (128-byte aligned)
  DW3   CTBAU      upper 32 bits, or 0
  DW4..7           reserved
```

**(b) The Command Table**, one per in-flight command, 128-byte aligned:

```
  0x00..0x3F   CFIS    the command FIS itself (up to 64 bytes)
  0x40..0x4F   ACMD    ATAPI command (unused here)
  0x50..0x7F   reserved
  0x80..       PRDT    16 bytes per entry
```

and a PRD entry is:

```
  DW0   DBA    physical base, 2-byte aligned (bit 0 must be 0)
  DW1   DBAU   upper 32 bits
  DW2          reserved
  DW3   bit 31       I    interrupt on completion
        bits 21:0    DBC  byte count MINUS ONE; must be odd (i.e. an even byte count)
```

**(c) The Received FIS structure**, 256 bytes, **256-byte aligned**, written by the HBA. In practice
one field matters: the D2H Register FIS at offset 0x40, whose status and error bytes are the ATA
status and error you would have read from 0x1F7/0x1F1.

**The command FIS.** A *Register Host-to-Device* FIS is 20 bytes and is where LBA48 comes from for
free:

```
  0   0x27               FIS type: Register H2D
  1   0x80               bit 7 = "this is a command", low bits = port multiplier port
  2   command            0x25 READ DMA EXT / 0x35 WRITE DMA EXT / 0xEC IDENTIFY / 0xEA FLUSH CACHE EXT
  3   featurel
  4-6 lba0,lba1,lba2     LBA 7:0, 15:8, 23:16
  7   device             0x40 — LBA mode. NOT the 0xE0|bits27:24 that ata.dart:582 packs
  8-10 lba3,lba4,lba5    LBA 31:24, 39:32, 47:40
  11  featureh
  12-13 countl, counth   sector count, 16-bit
  15  control
```

Note row 7 against fact 3: **AHCI's device byte carries no LBA bits at all.** LBA28's habit of
smuggling bits 27:24 into the drive-select register (`ata.dart:582`) is a PATA artifact, and the
**128 GiB** ceiling `ataLba28Max` imposes (`ata.dart:220` — 2²⁸ sectors × 512 bytes) simply
evaporates. Not a limit that binds today, and one that binds absolutely the first time a real disk is
attached.

**The registers actually needed, and no more.** ABAR is **BAR5** (config offset 0x24), a memory BAR,
read the same way `fbFindVgaBar` reads BAR0 (fact 13).

Global, at ABAR + offset:

| off | name | needed for |
|---|---|---|
| 0x00 | `CAP` | bit 31 `S64A` (64-bit addressing), bits 12:8 `NCS` (slots−1). Read once; if `S64A` is 0 every structure must be below 4 GiB, which the identity map guarantees anyway |
| 0x04 | `GHC` | bit 0 `HR` (HBA reset), bit 31 `AE` (AHCI enable), bit 1 `IE` (global interrupt enable) |
| 0x08 | `IS` | which ports have a pending interrupt. Write 1 to clear |
| 0x0C | `PI` | **ports implemented** — the bitmap that says which of the 32 port register sets exist |
| 0x10 | `VS` | version. Useful in a diagnostic, not in a decision |

Per port, at ABAR + 0x100 + port×0x80:

| off | name | needed for |
|---|---|---|
| 0x00 | `PxCLB` / 0x04 `PxCLBU` | physical address of this port's Command List |
| 0x08 | `PxFB` / 0x0C `PxFBU` | physical address of this port's Received FIS structure |
| 0x10 | `PxIS` | port interrupt status. **Write 1 to clear.** Bit 30 `TFES` is the task-file error you must check |
| 0x14 | `PxIE` | port interrupt enable |
| 0x18 | `PxCMD` | bit 0 `ST` (start), bit 4 `FRE` (FIS receive enable), bit 14 `FR`, bit 15 `CR` — the two "is it actually running" bits you must spin on when stopping |
| 0x20 | `PxTFD` | the task file: byte 0 is **the same ATA status byte** `ataWait` polls, byte 1 the error. BSY is bit 7, DRQ bit 3 |
| 0x24 | `PxSIG` | device signature — 0x00000101 is SATA disk, 0xEB140101 ATAPI. The direct analogue of `ata.dart`'s LBA-mid/high signature check (ADR-0010 §4.3) |
| 0x28 | `PxSSTS` | SATA status. Low nibble `DET` == 3 and bits 11:8 `IPM` == 1 is "device present and communicating" — the presence test |
| 0x34 | `PxSACT` | NCQ only. Not needed |
| 0x38 | `PxCI` | **commands issued.** Set bit *n* to launch slot *n*; the HBA clears it on completion. **This is the whole of "did it finish"** |

**Fifteen registers.** That is the honest size of AHCI for one non-queued command at a time — larger
than bus-master IDE's three, far smaller than its reputation.

**The sequence for one command:**

1. Port must be idle: clear `PxCMD.ST`, spin until `PxCMD.CR` clears; clear `PxCMD.FRE`, spin until
   `PxCMD.FR` clears.
2. Point `PxCLB`/`PxFB` at the structures. Set `PxCMD.FRE`, then `PxCMD.ST`.
3. Build the command header in slot 0 and the command table it points at.
4. Clear `PxIS` (write 1s), spin until `PxTFD` has BSY and DRQ clear.
5. `PxCI |= 1`.
6. Wait until `PxCI & 1` is 0 — **and check `PxIS.TFES` on every iteration**, because a task-file
   error leaves `PxCI` set and a loop that only watches `PxCI` hangs on every failed command.
7. On error: read `PxTFD`'s status and error bytes, and restart the port (step 1 and 2 again) — a
   task-file error stops the port and it does not restart itself.

**Step 6 is the AHCI equivalent of `ata.dart:468`'s "BSY before DRQ"** — the one ordering rule that
separates a driver that works from a driver that works under an emulator. It deserves the same
treatment `ataWait` got: its own function, its own bound, its own phase digit.

### 2.3 Where physically-contiguous DMA memory comes from — and why the question is smaller than it looks

The brief asks this as the hard problem, given `allocFrame` hands out single 4 KiB frames (fact 9),
and pmm.dart's own header names *"no contiguous multi-frame request, which is what a DMA buffer would
need"* (`pmm.dart:127`). **That header is describing a data buffer, and for both DMA paths here it is
wrong about the requirement.**

**A PRDT *is* a scatter-gather list. That is its entire purpose.** The whole point of a PRD table is
that a transfer's data need not be contiguous — the controller walks the table and consumes each
region in turn. So:

* **Bus-master IDE:** each PRD region must not cross a **64 KiB boundary**. A frame from `allocFrame`
  is 4096 bytes and 4096-aligned, and a 4 KiB-aligned 4 KiB region can never straddle a 64 KiB
  boundary. **Every frame this allocator produces is a legal PRD region by construction.** The PRDT
  itself must be 4-byte aligned and must not cross a 64 KiB boundary — one frame, or 64 bytes of
  donated `.bss`, satisfies both.
* **AHCI:** each PRD's base must be 2-byte aligned and its byte count even, both trivially satisfied
  by a frame. Up to 65535 PRDs per command. **A 64 KiB program image is 16 PRDs pointing at 16
  unrelated frames**, and the loader already allocates its image frame by frame.

**So the answer to "where does contiguous DMA memory come from" is: it mostly does not have to.** What
*is* genuinely required to be contiguous is small and fixed:

| structure | size | alignment | fits in |
|---|---|---|---|
| BM-IDE PRDT (8 entries) | 64 B | 4 B, no 64 KiB straddle | donated `.bss`, or offset 0 of a frame |
| AHCI Command List | 1024 B | **1024 B** | offset 0 of one frame |
| AHCI Received FIS | 256 B | **256 B** | offset 1024 of the same frame |
| AHCI Command Table + 8 PRDs | 256 B | **128 B** | offset 2048 of the same frame |
| | **1536 B used of 4096** | | **ONE frame holds all three** |

**One `allocFrame` call satisfies every alignment AHCI requires**, because a 4096-aligned base makes
offset 0 1024-aligned, offset 1024 256-aligned, and offset 2048 128-aligned. There is no allocator
work to do at all.

**And the identity map does the rest.** Fact 10: the first 128 MiB is identity-mapped and QEMU is run
with `-m 128M`, so **the physical address a PRD needs is the same number the virtual pointer already
is**. `allocFrame` returns a physical address (`pmm.dart:1090`) which is also a valid kernel virtual
address. There is no `virt_to_phys`, and there does not need to be one — **but that is a property of
the boot-time map, not a law**, and the day anything maps a frame somewhere other than its identity
address, every PRD in the kernel becomes wrong silently. That should be written down at the PRD
construction site as a comment and asserted by the harness as a source-level check ("the value written
into a PRD came from `allocFrame` or from `Bss.addressOf`, and from nowhere else"), for the same
reason ADR-0018 §2 refuses to read `BS_FilSysType`: the failure mode is a plausible wrong answer, not
an error.

**The one place contiguity is genuinely wanted** is a multi-sector transfer into `fat_store`'s
512-byte sector buffer or `file_store`'s — and those are single sectors inside donated `.bss`, so
they are contiguous already. If a future read-ahead wants 32 KiB in one command, the choice is eight
frames and eight PRDs (free) or a contiguous 32 KiB region (a new allocator). **Take the eight PRDs.**

### 2.4 Which to build, and the harness cost that decides it

| | bus-master IDE | AHCI |
|---|---|---|
| registers | **3** | 15 |
| memory structures | 1 (PRDT) | 3 (CL, FIS, CT+PRDT) |
| address width | 32-bit PRD, LBA28 (**128 GiB** via `ataLba28Max`) | 64-bit PRD, **LBA48** |
| max transfer per command | 64 KiB per PRD, 8 KiB PRDT | 4 MiB per PRD, 65535 PRDs |
| reuses `ataSelect`/`ataWait`/LBA packing | **yes, all of it** | no — FIS replaces the register file |
| QEMU command line | **unchanged** (`if=ide`) | `-device ich9-ahci` + `if=none` + `-device ide-hd,bus=ahci.0` |
| harnesses whose invocation changes | **0** | ~12 (every one with a disk) |
| new externs / assembly | 0 | 0 |
| estimated new lines | ~120 | ~400 |

**Build bus-master IDE first**, and build it *polled*. The reason is not that AHCI is hard; it is that
AHCI's change to twelve QEMU command lines puts "did the DMA work?" and "did the image plumbing
survive?" inside one commit, and this repo's own rule (ADR-0010 §6) is that two changes wearing one
commit make a regression hard to attribute.

**How either one is proved to be DMA rather than PIO**, since "it read the right bytes" is exactly
what a working PIO driver also does:

* **Structural, and the strongest of the three:** the DMA read path contains **no access to port
  0x1F0 at all**. `ataReadInto`'s data loop is the only thing in the kernel that touches it (ADR-0020
  §8 already relies on this shape), so "the DMA path does not read the data port" is a grep that a
  PIO fallback cannot satisfy.
* **Negative control, and the one that makes it evidence:** boot with the Bus Master Enable bit
  **left clear** in the PCI command register. The transfer must fail with a named diagnostic and no
  data must appear — the direct analogue of ADR-0010 §8's "negative control B: no drive", which is
  what makes every other assertion in that harness mean something.
* **Observable:** `PRDBC` (AHCI) or the byte count the drive consumed (BM-IDE) is a number **the
  controller wrote into host memory**, not one the kernel computed. Print it and require it to equal
  the transfer size. A PIO path cannot produce it.

### 2.5 The two things actually blocking both paths, neither of which is DMA

**(a) There is no `pciWrite32`.** Fact 12: `pci.dart` has `pciRead32` and nothing that writes
configuration space. **Both DMA paths need one**, because bus-mastering is off at reset and is enabled
by setting **bit 2 of the PCI command register at config offset 0x04**. Without it the controller will
not issue a memory cycle and the transfer completes zero bytes — silently, which is the worst
available failure.

This is ~10 lines (`port_outl` to CONFIG_ADDRESS, `port_outl` to CONFIG_DATA — and `port_outl` is
already declared at `pci.dart:82`). It is small and it is **the first write into configuration space
this kernel has ever done**, which makes it worth its own careful note: a read-modify-write of the
command register must preserve the other bits (memory-space enable, I/O-space enable), because
clearing memory-space enable on the *display* controller by accident is a black screen and clearing it
on the IDE controller is a dead disk.

**(b) MMIO is mapped cacheable, and AHCI is the first consumer for which that is a bug.** Fact 11 and
GAP-0071: `boot.S` identity-maps 3–4 GiB as present + writable + PS with **no PCD, no PWT, no PAT and
no MTRR setup**, and `boot.S:126` says so explicitly — *"Cacheable is wrong in principle for MMIO and
right in practice for a linear framebuffer."*

**A framebuffer tolerates it because nothing ever reads it back.** AHCI does not: step 6 of §2.2 is a
loop that re-reads `PxCI` and `PxIS` until the HBA changes them, and **a cached mapping is entitled to
serve every one of those reads out of the line fetched the first time.** Under QEMU it happens to
work (there is no real cache between the guest and the device model). On hardware it is an infinite
loop that `ataWait`'s successor would report as a timeout on a transfer that actually completed.

Three ways out, and they are not equal:

1. **Set PCD+PWT on the 3–4 GiB PD entries** — one constant in `boot.S:392`, `0xC0000083` becomes
   `0xC000009B`. Cost: **the framebuffer becomes uncached too**, and an uncached linear framebuffer is
   catastrophic for `fb.dart` (every pixel store becomes a bus transaction; a full-screen clear goes
   from a burst to ~500,000 individual writes).
2. **Split the directory** — leave the 2 MiB pages covering the framebuffer's BAR cacheable and mark
   the rest uncached. This needs to know where the BARs are *before* the page tables are built, which
   inverts the boot order (`fbFindVgaBar` runs from DCDart, long after `boot.S`).
3. **Write page-table entries at runtime**, which `boot.S:117` explicitly declined as *"a second,
   much larger capability"* — a walker, TLB invalidation, and a decision about where new tables come
   from. That decision is now answerable (`allocFrame` exists), and `vm.dart` shipped at M8, so this
   is no longer the wall it was at M5.

**Option 3 is the right answer and it is a milestone of its own**, not a line in a disk driver.
Option 1 is a legitimate temporary measure **only** if `fb.dart` is not on the critical path of
whatever is being measured, and it should be marked as such loudly if taken. This is the single
biggest hidden cost in the AHCI plan, and it is not in anybody's estimate of "how hard is AHCI".

**One more, smaller:** fact 14 — the MMIO primitive is `Pointer<u32>.fromAddress(a).value`, and **no
load through a `Pointer` has ever appeared inside a poll loop in this kernel.** Every existing use is
a store to the framebuffer or to a `.bss` seam. Whether the pinned `dcc` treats such a load as
volatile — i.e. whether it may hoist it out of a `while` — is **unknown and must be established by
disassembly before any AHCI polling loop is trusted**. `ataWait` is safe from this because
`Port.inb` is an `in` instruction the compiler cannot elide; `PxCI` is a memory load and it can. The
check belongs in the harness as a disassembly assertion the same way `m6-disk` asserts `ataWait`'s
bound survives into the instruction stream (ADR-0010 §4.2), and if the answer is "it hoists", the
mitigation is an `@extern` assembly `mmio_read32` and the extern count goes from 44 to 45.

### 2.6 What interrupt-driven DMA needs that DMA does not

§1.4 said the win is letting the kernel leave the syscall. That needs, in order:

1. **A device IRQ handler.** `isrDispatch` is a branch chain with three interesting vectors
   (`interrupts.dart:477`). IRQ14 (vector 0x2E) for BM-IDE, or the PCI interrupt line for AHCI — which
   is *shared*, so the handler must read `IS`/`PxIS` and decline politely if it was not this device.
2. **A blocked process state.** `proc.dart` has running and not-running; there is no "waiting on
   something" and nothing that could make a process runnable again from an interrupt handler.
3. **A way to return from a syscall without a result** — i.e. to suspend a kernel-side operation
   mid-flight and resume it. ADR-0022 §1 established that the 22-word interrupt frame *is* a suspended
   thread, but only for frames taken at CPL 3. **A kernel-side continuation is a different and larger
   thing**, and the cheap version is to make the syscall re-entrant: return "would block", have the
   scheduler re-dispatch it. That has its own name in the literature and its own problems, and it
   should be picked deliberately rather than arrived at.

**Item 2 and item 3 are process work, not storage work.** That is why §5's ladder puts polled DMA
first, and interrupt-driven DMA behind a rung that is honestly labelled as scheduler work.

---

## 3. FILESYSTEM BEYOND FAT16

### 3.1 The real limits, stated as what they cost rather than what they are

| limit | mechanism | what it actually costs |
|---|---|---|
| **8.3 names only** | ADR-0018 §5. LFN entries (attr 0x0F) are skipped; a name that is too long, has two dots or an empty stem is `fatErrBadName` rather than a truncation | No `main.c`+`main.o`+`main.out` in one directory without collisions. No package-style names. **And note the asymmetry M16 introduced deliberately** (ADR-0020 §5): the read path accepts any printable byte, the write path enforces the fifteen forbidden characters. That asymmetry is correct and must be preserved by anything built on top |
| **No subdirectory writes** | GAP-0127; ADR-0018 §9. `SUB` is on the volume with real `.`/`..` and is **refused by name** | Everything lives in one 512-entry root. A build tree, a `/tmp`, a per-program working directory: none expressible. This is the limit that bites first for real software |
| **No permissions** | GAP-0090 item 5. One attribute byte, used only to refuse a subdirectory | No `x` bit — `run` will load anything and the ELF checks are the only gate (ADR-0018 §9). No ownership. Which is *consistent* today: there is no user, and processes are slots in a fixed table |
| **No timestamps** | GAP-0127 item 4. `DIR_CrtTime`/`DIR_WrtTime`/`DIR_LstAccDate` written as zero, left alone on truncate | No `make`. No incremental anything. No "which of these is newer". **And the cause is not FAT** — it is that this machine has no wall clock at all (GAP-0058: the PIT is masked at rest so `ticks` stays reproducible, and there is no RTC driver) |
| **Append-only writes** | ADR-0020 §0; GAP-0127 item 1 | No editing a file in place, no `O_APPEND` that keeps content, no read-write descriptor |
| **No `unlink`/`rename`** | GAP-0127 item 3 | No atomic replace, therefore no safe update of anything |
| **256-cluster ceiling** | `fat.dart:202` — 256 KiB on this volume, and **never tested above 9632 bytes** (ADR-0018 §9) | |

**Two of these are not FAT's fault and will follow you to any filesystem you choose.** Timestamps
need an RTC driver (~60 lines against the CMOS ports, or ACPI, or the HPET) — that is a *kernel*
milestone, and it is a prerequisite for the metadata, not a consequence of the format. Permissions
need a user model. **Choosing ext2 or writing a native filesystem gives you a place to *put* a
timestamp and does not give you a clock to read.** Any plan that lists "timestamps" as a benefit of
changing filesystem is mis-attributing the work.

### 3.2 THE PROPERTY THAT DECIDES THIS, AND IT IS NOT A FORMAT PROPERTY

Read ADR-0018 §1 and ADR-0020 §0 together and the actual reason FAT16 is here comes out:

> *"It is checkable by tools that have never heard of this repo… A volume only this kernel can read is
> not evidence about this kernel."* — ADR-0018 §1
>
> *"the volume the guest writes is accepted by `fsck_msdos` and mounted and read back byte-for-byte by
> macOS's own `msdos` driver, on a volume whose free space is fragmented so that a contiguous writer
> destroys a file that is already there — and the bytes are still there after the machine has been
> switched off and on."* — ADR-0020 §0

**This is not a convenience. It is the epistemology of the entire storage stack.** M16's harness does
not check the write path by reading it back with the same driver that wrote it — that would prove only
self-consistency, which is precisely what a driver with a systematically wrong idea of the format
also has. It checks it with **two independent implementations written by people who have never seen
this code**: Apple's `fsck_msdos` (from FreeBSD) and the `msdos` kext.

**And it has already caught something no internal test could have.** ADR-0020 §5: the first version of
M16's test program asked for `BAD*NAME.X` expecting a refusal, **got a descriptor**, and put an
illegal short name on the volume. `fsck_msdos` accepted it — the host tools do not validate name
characters — but the episode is exactly the shape of what the external judge is for: the driver's own
idea of correct was wrong, and the only reason anyone found out is that the volume was being examined
by something that did not share the driver's assumptions. (`fatNameLegal` exists because of it.)

**Quantify what would be lost.** M16's harness currently derives:

* that `fsck_msdos` exits 0 on the written volume — which checks FAT/directory consistency, chain
  integrity, cross-linked files, lost chains, and **that both copies of the FAT agree** (the failure
  ADR-0020 §3 rule 1 exists to prevent, and one this kernel cannot detect in itself because it wrote
  both copies from the same buffer);
* that macOS's `msdos` driver **mounts** it — a stricter test than `fsck`, because a mount runs a
  different code path with different tolerances;
* that a 307200-byte file planted by the host reads back byte-for-byte **after** the guest wrote
  around it on a deliberately fragmented volume;
* that a 64-byte file the guest wrote reads back through the host driver equal to bytes derived from
  `prog.elf` on the host.

Every one of those is a claim about **this kernel** established by **something that is not this
kernel**. That is the property. It is worth more than any format feature on the table.

### 3.3 The three paths, evaluated

#### Path A — Extend the FAT driver

**VFAT (long filenames), FAT32, and subdirectory writes.** Three separable pieces, and they are not
the same size.

* **Subdirectory writes** are the smallest and the most valuable. The mechanism already exists: a
  subdirectory *is* a cluster chain whose contents are directory entries. `fatDirCreate`,
  `fatDirWrite` and `fatDirTerminate` operate on the root directory's fixed sector range
  (`fat.dart:1964`, `:2013`, `:2142`); making them operate on a chain instead is replacing a sector
  range with `fatClusterSector`, which already exists. Then `mkdir` is: allocate a cluster, zero it,
  write `.` and `..`, create the entry in the parent. **Estimate: ~200 lines**, plus a path parser
  (which does not exist — there is no tokenizer, GAP-0057 item 3) and one hard case: the root
  directory is fixed-size and cannot grow, subdirectories can, and `fatDirCreate` must learn to
  allocate a cluster when it runs out of entries.
* **FAT32** is mostly *deletions of refusals*. ADR-0018 §2 refuses it by name from a computed cluster
  count. What it costs: 32-bit FAT entries (`fatPut16` becomes `fatPut32` on that path), `BPB_FATSz32`,
  a root directory that is a chain rooted at `BPB_RootClus` rather than a fixed range — **which is the
  same change subdirectory writes need**, so the two share their hardest piece — and the FSInfo sector
  (optional; a driver may ignore it, and should, because a stale FSInfo is a classic corruption).
  Buys: volumes above 2 GiB, and more than 512 root entries. **Estimate: ~300 lines** on top of the
  subdirectory work. Note that this *widens* the external-judge property rather than narrowing it:
  `fsck_msdos` handles FAT32.
* **VFAT/LFN** is the one to think hardest about, and the reason is **patents-are-expired but
  correctness-is-not**. Writing LFN entries means: generate a unique 8.3 alias (the `~1`, `~2`
  numbering, with a checksum tie-break), compute the one-byte checksum of that alias, split the UTF-16
  name into 13-character chunks, write them in **reverse order** immediately before the short entry,
  each carrying the sequence number and that checksum. Get the checksum wrong and every other
  implementation ignores the long name silently — **which reads as "it works" from inside this kernel
  and is caught only by the external judge**, and is therefore an argument *for* doing it in FAT
  rather than against. **Estimate: ~350 lines** and the highest bug density of anything in this
  section. Buys: real filenames. ADR-0018 §5 already puts three real LFN entries on the test volume
  and requires macOS to resolve `program-b-with-a-long-name.elf` from them, so **the test fixture for
  reading them already exists.**

**What Path A keeps:** every line of the external-judge property, unchanged and strengthened.
**What Path A does not fix:** timestamps (no clock), permissions (no user model), atomic replace,
crash consistency, files above 4 GiB, fragmentation.

#### Path B — Port ext2

**Recommend against, and the reason is not difficulty.** ext2 is a well-documented, well-specified
format and a read-only ext2 driver is genuinely comparable in size to the FAT one. The problems are
elsewhere:

1. **The external judge gets much weaker on macOS.** `fsck_msdos` and the `msdos` kext are in the base
   system; the harness runs `hdiutil` and `fsck_msdos` with no dependency the next machine might not
   have (ADR-0018 §1 makes "no `newfs_msdos`, no mtools" an explicit requirement). **macOS has no ext2
   driver and no `fsck.ext2`.** Replacing them means `e2fsprogs` from Homebrew (a dependency, and one
   whose absence turns a hard failure into a setup error) plus **`fuse-ext2` or a Linux VM to mount**
   — and macOS FUSE requires a kernel extension the user must approve. The judge survives in reduced
   form (`e2fsck`, `debugfs dump`) and the *mount* half — the stricter half — realistically does not.
2. **Nothing about ext2 is small once you write.** Block groups, a block bitmap and an inode bitmap
   per group, indirect/double-indirect/triple-indirect block pointers, the superblock backup copies,
   and directory entries that are variable-length records which must be **split and merged in place**
   on create and delete. Compare FAT's write path: one 16-bit entry per cluster, both copies, one
   directory entry. **Estimate for read-only ext2: ~700 lines. For a write path with correct bitmap
   and inode accounting: ~1500 more, and that is the number that should stop this.**
3. **It buys the metadata this OS cannot use.** Permissions with no user model, timestamps with no
   clock, hard links with no `unlink`, symlinks with no path resolution.
4. **The one thing it genuinely buys — indirect blocks — is worth having and is not worth this.**
   FAT's chain walk is O(clusters) and materialises into a 256-entry array (`fat.dart:202`). ext2's
   indirect blocks are O(1) random access. That matters for `seek` on a large file. It does not matter
   for a kernel whose largest tested file is 9632 bytes and whose loader caps at 65536.

**Where Path B would become right:** if the host judge moved from macOS to Linux (where `e2fsck`,
`debugfs` and a real mount are all in the base system), points 1 and its knock-ons evaporate and this
becomes a genuine contest. That is a fact about the *development host*, not about the OS, and it is
worth writing down because it means the correct answer here could change without a single line of
kernel code changing.

#### Path C — A native filesystem

**Recommend against for now, and §3.4 is the condition under which that flips.**

The case *for* is real and should not be strawmanned. A filesystem designed for this machine could:

* have exactly the metadata this OS has a source for and no fields it must write as zero;
* be **crash-consistent by construction** — a log-structured or copy-on-write design makes ADR-0020
  §3's five hand-maintained ordering rules into a property of the format instead of a discipline in
  the code, which is a categorical improvement over "we got the order right and here are five
  paragraphs explaining why";
* have a **checksum per block**, which would turn silent corruption into a named refusal — this
  kernel has 28 refusal codes on the mount path (ADR-0018 §2) and none of them can detect a sector
  that came back wrong;
* be designed around 512-byte sectors and one open file, rather than around 1980s floppy geometry;
* and match the project's own stated direction — `exec-format.md` records the owner wanting a native
  `.osx`, and `display-protocol.md` records a native display protocol chosen over Wayland
  compatibility.

**The case against is one sentence: it deletes the external judge, and the external judge is the only
reason anyone knows the write path works.**

Look at what M16 would have been without it. The harness would boot the kernel, write a file, read it
back with the same driver, and pass. **A driver that had the cluster arithmetic systematically wrong
would pass that test.** A driver that updated one copy of the FAT would pass it (nothing in this
kernel reads the second copy). A driver that wrote a name FAT forbids would pass it — and did, until
`fsck_msdos` was pointed at it. ADR-0018 §1 says the thing directly: *"A volume only this kernel can
read is not evidence about this kernel."*

### 3.4 What would have to replace the external judge — costed

This is the part of the question that decides it, so here it is in full rather than as a gesture.
**If a native filesystem is built, these five must exist before it is trusted, and they must be
written by someone reasoning from the on-disk specification rather than from the driver.**

**(1) An independent host implementation of the format.** A Python reader in `core/tests/` that walks
the on-disk structures from the *specification document* and reports what it finds, with **no shared
code with the kernel and no constants copied from it**. This is exactly what `make-image.py` already
is for FAT on the *write* side — ADR-0018 §1 counts "the harness can build one in plain Python" as one
of the three reasons FAT was chosen — so half of this pattern is already in the repo and proven.
**Estimate: 400–600 lines of Python.** The discipline that makes it worth anything: it must be written
from the spec, and where it and the kernel disagree, **the spec wins and both are examined.** A host
tool derived from the kernel is the same self-consistency trap in a different language.

**(2) A fsck.** Not a reader — a *checker*. Free-space accounting reconciles with what is allocated;
no block belongs to two files; every directory entry points at a live inode; every live inode is
reachable; every checksum verifies. This is the piece that catches the cross-linked-file class, which
ADR-0020 §3 rule 2 names as *"the corruption a read test cannot see"*. **Estimate: 300–500 lines**,
and it must be **shown to fire**: fed deliberately broken images, each of its assertions must reject
one — the same discipline `check-stack.py` was held to at M19 (nine assertions, nine demonstrated).

**(3) A mount.** This is the one that cannot be replaced cheaply and it must be said plainly. The
macOS `msdos` kext is a **stricter and differently-motivated** reader than `fsck_msdos`, and M16 runs
both because they check different things. A native format has no third-party mount, and the honest
substitutes are:
   * a FUSE driver (macOS FUSE needs a user-approved kernel extension — a real friction cost in CI);
   * **a second, independent in-repo implementation** written by a different agent from the spec, with
     a rule that neither may read the other's source. This is the cheapest genuine substitute and it
     is not cheap; it is the whole driver again. **Estimate: as large as the driver.**
   * Accept the loss and say so in the ADR. **This is a legitimate choice if it is made out loud.**

**(4) A fuzzer over the mount path.** FAT gets this for free in a weak sense — `fsck_msdos` and the
kext have been fed malformed volumes by the world for thirty years, so a driver that survives them has
survived something. A native format has no such history. Feeding randomly-corrupted images to
`fsMount` and requiring **a named refusal rather than a hang, a fault, or a wrong answer** is the
substitute. The refusal vocabulary to hold it to already exists as a model: 28 refusal codes, each
with its own sentence, every one required to be reachable (ADR-0018 §2). **Estimate: 150 lines plus
CI time.**

**(5) A written statement of what is no longer known.** GAP-shaped, in `known-gaps.md`, in the same
register as GAP-0129's *"the flush is verified structurally and only structurally"*. The sentence is:
**"no implementation outside this repository has ever read a volume this kernel wrote."** It should be
in the ADR's first section, not its ninth.

**Total: 850–1250 lines of host tooling, plus either a FUSE driver or a second independent
implementation, before the first byte of the filesystem itself is trusted.** That is the price of
Path C, and it is not the price of Path C's *code* — it is the price of Path C's *evidence*.

### 3.5 Recommendation

**Path A, in this order: subdirectory writes → FAT32 → VFAT.** And do it because of what it does to the
evidence, not what it does to the features:

* **Subdirectory writes** are the limit that actually blocks real software (a build tree, a `/tmp`),
  they reuse machinery that exists, and `fsck_msdos` checks subdirectory structure — so the external
  judge gets *more* to check, not less.
* **FAT32** shares its hardest piece (a root directory that is a chain) with subdirectory writes, is
  mostly the deletion of a refusal, and keeps the judge.
* **VFAT** is the highest bug density on the list and is therefore exactly the thing that most wants
  an independent checker — which it has.

**Revisit Path C when, and only when, one of these becomes true:** (a) the development host moves to
Linux, which makes Path B genuinely competitive and reframes the whole comparison; (b) a real
requirement appears — crash consistency after power loss, or per-block checksums — that FAT
structurally cannot meet and that matters more than the judge; or (c) the tooling in §3.4 is built
*first*, for its own sake, at which point Path C's evidence cost has already been paid and the
decision is a normal engineering one.

**And regardless of path: build the RTC driver.** It is small, it is independent of every question
here, and it is the actual blocker on timestamps — which currently read as a filesystem limitation and
are not one.

---

## 4. A BLOCK LAYER

### 4.1 What exists

`fatDiskRead` is the one read door: NVMe via `nvmeIoRead`, AHCI via
`ahciIoRead`, or ATA via `ataReadInto`. `fatWriteSector` is the one write
door (`ataWriteFrom`, `nvmeIoWrite`, or `ahciIoWrite`). `elfDiskRead`
calls `fatDiskRead`. ADR-0020 §8's "`ataWriteFrom` is defined once and called from
exactly one place" still holds for the PIO write — that place is still `fatWriteSector`.

So the write side is *already* behind a seam, and the seam is `fatWriteSector` — which is not a block
layer, it is a FAT-layer function that happens to be the choke point. The read side has no seam at all.

### 4.2 What an abstraction costs

**In lines: very little.** Four functions and a device number.

**In this repo's actual currencies, which are not lines:**

| currency | cost |
|---|---|
| **Indirection with no dispatch** | Fact 19: `@bare` DCDart has no function pointers. A block layer is an `if` chain on a device number, not a vtable. With one device that `if` has one arm, and it is honest to say so |
| **Donated `.bss`** | Zero, if it stays stateless. A request queue or a buffer cache is real storage behind a seam accessor, with the alignment arithmetic `m14-fat` and `m16-filewrite` both assert (`fat_store` at 1824, `file_store` at 14048) |
| **Harness churn** | Every structural check that names `ataReadInto`/`ataWriteFrom` call sites moves. That is `m14-fat` and `m16-filewrite` at minimum, and ADR-0020 §8's "defined once, called once" claim has to be restated one layer up |
| **A layer that can lie** | A block layer with a cache is a layer that can return bytes the drive does not have. ADR-0020 §3 rule 5 is *already* about exactly this hazard for `fat_store`'s one-sector buffer, and it is the rule most likely to be got wrong at a larger scale |
| **Goldens** | Only if it prints. It should not print; the ATA layer's diagnostics are the ones with values read out of hardware, and adding a second diagnostic vocabulary in front of them would dilute what ADR-0010 §4.3 established |

### 4.3 What it buys — and the version worth building is not the obvious one

**The obvious block layer is `blkRead(lba, dst)` / `blkWrite(lba, src)`, and it buys almost nothing.**
It is a rename. It does not let DMA in, because the shape is still one sector per call and DMA's entire
value is *n* sectors per command.

**The version worth building is the request shape:**

```
blkRequest(dev, lba, count, buffer, direction) -> status
```

Four things follow from `count` being a parameter, and none of them follow from the rename:

1. **DMA slides underneath without touching `fat.dart` at all.** A PIO implementation loops
   `ataReadInto` `count` times; a DMA implementation builds `count`-worth of PRDs and issues one
   command. The caller does not change. **This is the only reason to build a block layer now rather
   than later**, and it is decisive: the alternative is editing `fat.dart` and `elf.dart` again when
   DMA lands, and `fat.dart` is 2632 lines of carefully-argued ordering rules that nobody should be
   editing for a reason that is not about FAT.
2. **`elfReadSectors` collapses.** `elf.dart:1172` is a loop of one-sector reads into consecutive
   addresses (`buf + (i << elfSectorShift)`) — **it is literally a multi-sector request written out
   by hand.** One call replaces it. On DMA that is 128 commands becoming 1 for a 64 KiB image.
3. **The double FAT write becomes visible as the redundancy it is.** §1.2: `fatSetEntry` writes the
   same 512 bytes to two LBAs, back to back, each with its own flush. A request layer is where "these
   two writes are the same buffer" can be noticed and where a single flush can cover both — without
   `fatSetEntry` having to know anything about caches.
4. **A second device becomes expressible.** GAP-0090 item 7 is `UNCHANGED` — primary master only. A
   `dev` parameter does not implement a second device; it makes the day one arrives a change in one
   file. With fact 19 in mind, it is an `if` on a small integer and that is fine.

**And one thing it buys that is not about DMA:** a place to put the retry policy. ADR-0020 §2 says
**"No retries"**, with a good reason — *"a driver that retried would turn one bad sector into several
attempts at it and would still not know whether the first attempt landed."* That reasoning is about
the *device*, and it is right at the device layer. Whether the *filesystem* should retry is a
different question with a different answer, and today there is no layer at which it can be asked.

### 4.4 What it should NOT buy yet

**Not a buffer cache.** `fat_store`'s one-sector, one-LBA cache (ADR-0018 §7, ADR-0020 §3 rule 5) is
the right size for a kernel with one caller, and its correctness argument fits in a paragraph. A
general cache needs eviction, write-back or write-through, and a dirty-sector story that interacts
with the flush discipline of §1.5. **Two hard problems, and coupling them is how both get got wrong.**

**Not asynchrony.** A completion callback is a function pointer (fact 19: not expressible) and a
blocked process is §2.6's work. The request function stays synchronous and returns a status, exactly
as `ataReadInto` does.

**Not a partition layer.** GAP-0090 item 6 — the MBR is still unread and the volume is the whole disk.
Partitions are an LBA offset per device and belong in the block layer when they arrive, but they are
not what is blocking anything today.

### 4.5 Verdict

**Build it, and build it before DMA, and build it as a request rather than a sector.** The cost is
lowest it will ever be — four read call sites and one write call site — and the specific thing it buys
is that §2's work does not require reopening `fat.dart`. The structural checks ADR-0020 §8 relies on
survive the move, restated one layer up: *`ataReadInto` and `ataWriteFrom` are called from exactly one
file, `blk.dart`, and from nowhere else in `core/kernel/`* is a **stronger** grep than the four the
harnesses run today.

---

## 5. THE MILESTONE LADDER

Binary exit criteria, in this repo's style. Each rung is a milestone whose harness can fail for one
reason. Nothing here is scheduled — this project adds a milestone only when the previous one is
actually done (`ROADMAP.md` preamble) — so these are numbered S1…S7 and become M-numbers when taken.

---

### S1 — The disk is behind one door

**Goal.** `fat.dart` and `elf.dart` stop knowing what an ATA command is. One file owns the device, and
its interface is a *request* — a device, an LBA, a **count**, a buffer, a direction — so that a
multi-sector transfer is expressible before anything can perform one.

**Exit.** `core/tests/conformance/sN-block/run.sh` exits 0, having asserted:

* `ataReadInto` and `ataWriteFrom` are referenced in **exactly one file** in `core/kernel/`, and that
  file is `blk.dart`; **zero** references in `fat.dart`, `elf.dart` or anywhere else.
* `blkRequest` takes a sector count and `elfReadSectors` calls it **once** for a whole image — the
  disassembly shows no loop of single-sector reads remaining in `elf.dart`.
* A `run PROGA.ELF` boot produces a serial capture **byte-for-byte identical** to m14-fat's, and
  `m14-fat`, `m15-fileio` and `m16-filewrite` all exit 0 unchanged.
* **The image is byte-for-byte identical (SHA-256) after every read-only boot**, exactly as m14-fat
  asserts today.
* Donated `.bss` is **unchanged** — S1 is stateless and adds no storage.
* Declared externs **unchanged** at 44 — S1 adds no assembly.
* All existing harnesses exit 0, and `m1-interrupts/expected.txt` is byte-for-byte its 544 bytes.

**Explicitly out of scope:** any cache beyond `fat_store`'s existing one, any second device, any
partition parsing, any asynchrony, any change to the flush discipline.

---

### S2 — This kernel can write to configuration space

**Goal.** `pciWrite32`, and the bus-master enable bit. Small, and it is on the critical path of both
DMA paths (§2.5a). Separated because "the first configuration-space write this kernel has ever done"
should not be inside a commit whose subject is DMA.

**Exit.**

* `pci bm on` / `pci bm off` at the shell set and clear **bit 2 only** of the command register at
  `00:01.1`, and `pci` reports the register's value read back from the device. The captured value
  differs between the two boots **at exactly that bit** — every other bit identical, which is the
  assertion that catches a read-modify-write done as a plain write.
* A negative control: the same command aimed at a device function that does not exist returns
  0xFFFFFFFF and is refused **by name**, not written to.
* `m5-pci`'s golden is regenerated by mechanical insertion (the ADR-0018 §8 discipline: insert the
  new lines, require the kernel to reproduce the whole file byte-for-byte), not by fresh capture.
* All harnesses exit 0.

**Out of scope:** BAR sizing (writing all-ones to a BAR and reading back the mask), MSI, any
configuration write to any device other than the IDE controller.

---

### S3 — A sector arrives without the CPU carrying it

**Goal.** Bus-master IDE DMA on the PIIX3 that is already there (§2.1), **polled**. No QEMU
command-line change anywhere. `READ DMA` (0xC8) only — reads first, because the read path has no
flushes and therefore no interaction with §1.5.

**Exit.**

* `blkRequest` on device 0 with direction=read uses the DMA path, and **`core/kernel/` contains no
  read of port 0x1F0 on any path `blkRequest` can reach for a read** — asserted by disassembly, not
  by grep alone. (`ataReadInto` may still exist for `disk read`; the check is about reachability from
  the request path.)
* `run PROGA.ELF` and `cat HELLO.TXT` produce serial captures **byte-for-byte identical to m14-fat's**
  — the same fragmented, interleaved volume ADR-0018 §4 built specifically to punish a driver that
  ignores the chain, now read by a different transport.
* **A 64 KiB image is read in `ceil(65536/N)` commands and not 128**, where `N` is the per-command
  sector count, printed as a counter and derived by the harness from the image size.
* **THE NEGATIVE CONTROL, and it is what makes the rest evidence:** a boot with bus-master enable
  **left clear**. The transfer must fail with a named diagnostic, the counter of bytes the controller
  reported must be **0**, and the harness greps the whole capture for hexdump-shaped lines and for any
  successful read line and requires that **neither appears anywhere** — ADR-0010 §8's "negative
  control B" discipline applied to the transport instead of the device.
* **A second negative control:** a PRDT whose byte count is one sector short of the request. The
  driver must detect the short transfer from the controller's own byte count and refuse, rather than
  returning a buffer that is partly stale.
* The `ataWait`-equivalent bound on the DMA completion poll **survives into the compiled code**,
  asserted by disassembly (ADR-0010 §4.2's check, for the new loop).
* All harnesses exit 0; `m1-interrupts` byte-for-byte.

**Out of scope:** DMA writes, interrupts, AHCI, LBA48, any second channel or device.

---

### S4 — And it leaves the same way

**Goal.** `WRITE DMA` (0xCA) on the same path. The flush discipline is **unchanged** — one
`FLUSH CACHE` per command, exactly as ADR-0020 §2 requires — so that this milestone is about the
transport and nothing else.

**Exit.**

* `m16-filewrite`'s **entire** assertion set passes unchanged: `fsck_msdos` exits 0, macOS's `msdos`
  driver mounts the volume, `KEEP.BIN`'s 307200 bytes read back byte-for-byte, the guest-written file
  matches host-derived bytes, and the derived total sector count is met.
* **The written volume is byte-for-byte (SHA-256) identical to the volume the PIO write path
  produces**, from the same keystrokes on the same starting image. This is the strongest available
  statement that the transport changed and nothing else did.
* `core/kernel/` contains no write to port 0x1F0 on any path `blkRequest` can reach for a write.
* The flush is still structurally verified: **the last thing every write request does before returning
  success is issue `FLUSH CACHE`**, asserted by reading the function body (ADR-0020 §2's check,
  relocated). GAP-0129 is restated for the new path — this remains verified structurally and only
  structurally.
* All harnesses exit 0.

**Out of scope:** batching flushes (that is S6), interrupts, AHCI.

---

### S5 — MMIO is mapped the way MMIO has to be mapped

**Goal.** Close GAP-0071 for real: runtime page-table entries with cache attributes, so a device's
registers can be mapped uncached while the framebuffer stays cacheable (§2.5b). **This is not a
storage milestone** and it is on the ladder because AHCI is blocked behind it and nobody's AHCI
estimate includes it.

**Exit.**

* `vm.dart` can map a physical range at 4 KiB granularity with PCD+PWT set, taking its page tables
  from `allocFrame`, and invalidates the TLB for every page it changes.
* `vm map` at the shell reports the **actual PTE** read back out of the live tables for a named
  address — not the value the kernel intended to write.
* The AHCI ABAR region (or, before AHCI exists, any 4 KiB range in the PCI hole) reads back with
  PCD set, and the framebuffer's pages read back with it **clear**, in the same boot and the same
  capture.
* `m5-pci`'s framebuffer drawing and its screenshot golden are **unchanged** — the proof that the
  cacheable mapping the framebuffer needs survived.
* **A load through `Pointer<u32>.fromAddress` inside a `while` loop is disassembled and shown to
  issue a load on every iteration** (§2.5, last paragraph). If it does not, this milestone also adds
  `mmio_read32` as an `@extern` and the extern count goes 44 → 45, and the ADR says why.
* All harnesses exit 0.

**Out of scope:** MTRRs, the full PAT, write-combining for the framebuffer (a separate and real win,
and a separate milestone).

---

### S6 — The disk stops holding the machine still

**Goal.** The scheduling fix (§1.4, §2.6), which is the thing DMA was actually for. A device interrupt,
a blocked process state, and a syscall that can be suspended. **This is process work wearing a storage
hat and the ADR should say so.**

**Exit.**

* `isrDispatch` gains an IRQ14 (or PCI interrupt line) arm which **reads the controller's status,
  declines if the interrupt was not its device, and acknowledges correctly** — asserted by a boot in
  which a spurious interrupt on a shared line is delivered and the handler declines it.
* A process blocked on a disk request is in a **named state**, `proc sched` prints the count, and
  the harness requires it to be non-zero in a boot where a program writes a file.
* **`procHeadKernTicks` — which reads 1 today (ROADMAP M18, GAP-0138) — still reads 1** after a boot
  in which a program writes a 64 KiB file. That is the whole milestone in one number: it says the
  write no longer swallows timer ticks.
* **Two programs, one writing a file and one spinning, are interleaved**: `PROC PREEMPTS` is non-zero
  *during* the write, which the harness establishes by ordering in the capture rather than by a total.
* `m18-preempt` exits 0 unchanged.
* All harnesses exit 0; `m1-interrupts` byte-for-byte.

**Out of scope:** AHCI, NCQ, more than one in-flight request, an I/O scheduler.

---

### S7 — The FAT driver grows a directory tree

**Goal.** §3.5's first step: subdirectory **writes**, and therefore a path. The FAT driver stops being
a root-directory driver.

**Exit.**

* `mkdir` and a path-taking `open` exist; a program creates `/SUB/DEEP/FILE.TXT` from ring 3, two
  levels below the root, and writes to it.
* **`fsck_msdos` exits 0 on the resulting volume and macOS's `msdos` driver mounts it and reads
  `/SUB/DEEP/FILE.TXT` back byte-for-byte** against host-derived bytes. The external judge is the
  criterion, exactly as at M16.
* `.` and `..` in every created directory are correct, and are checked **by the host tools' willingness
  to traverse them**, not by this kernel reading them back.
* A subdirectory that has filled its last cluster **grows by one** and the volume still passes both
  host tools — the case that distinguishes a chain-walking directory writer from one that assumed a
  fixed range.
* Path refusals are named and distinct: a component that is not 8.3, a path too deep, a component that
  is a file where a directory was expected, a path escaping the root. Every one reachable, in the
  ADR-0018 §2 discipline.
* **The volume `make-image.py` builds is byte-for-byte unchanged after every read-only boot**, and
  `m14-fat`, `m15-fileio`, `m16-filewrite` all exit 0.
* All harnesses exit 0.

**Out of scope:** FAT32, LFN, `unlink`, `rmdir`, `rename`, timestamps.

---

### What is deliberately NOT on this ladder, and why

| | why not |
|---|---|
| **AHCI** | Blocked behind S5, and until S6 exists it buys throughput this OS cannot spend. It belongs after S6, and its own milestone should be honest that **twelve harness QEMU invocations change** and that that is most of the risk |
| **Batching the flush** (§1.5) | The largest single performance win available, and it modifies the one property no test in this repo can observe (GAP-0129). It should be its own milestone whose *first* deliverable is the sharper structural check, and whose ADR states plainly that the harness is the entire guarantee |
| **A buffer cache** | §4.4. Wants the flush discipline settled first |
| **ext2** | §3.3 Path B. The answer changes if the development host changes; the answer does not change because of anything in the kernel |
| **A native filesystem** | §3.4. Its evidence costs 850–1250 lines of host tooling plus a second independent implementation, and none of that is paid |
| **An RTC driver** | **Should be built, and it is not storage.** It is the actual blocker on timestamps, it is ~60 lines against the CMOS ports, and it is independent of every question in this document. It is listed here so it is not mistaken for something a filesystem change would deliver |
| **Partitions / MBR** (GAP-0090 item 6) | Belongs in `blk.dart` when it arrives; blocking nothing today |
| **A second device** (GAP-0090 item 7) | S1's `dev` parameter makes it a one-file change later. Building it now would be a parameter with no second value |
