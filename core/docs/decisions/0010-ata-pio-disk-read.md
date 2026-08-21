# ADR-0010 — ATA PIO: reading a real disk without a memory manager

**Status:** accepted, implemented, verified by `core/tests/conformance/m6-disk/run.sh`
**Milestone:** M6
**Supersedes:** nothing. **Depends on:** ADR-0008 (PCI enumeration found the controller),
ADR-0006 (the shell that runs the command), ADR-0007 (the fault recovery the command is re-proved
under).

---

## 1. Context

M5 taught this kernel to find hardware nobody told it about. `pci` walks configuration space and
reports, among six devices, an IDE controller at `00:01.1` — `8086:7010`, class `01/01`,
`ide storage`. It could **see** storage and could not read a byte of it.

That is a bigger gap than it sounds. Everything this kernel has ever printed came from one of three
places: a register it was compiled to know the address of, a constant in its own image, or the
Multiboot structure the loader handed it. Nothing has ever been read from a device that **stores**
data — which means nothing has ever come from outside the running machine at all.

The obvious next milestone was the physical memory manager, and it is still blocked on a DCDart
decision that is not this repo's to make (GAP-0053: no mutable statics, so a page bitmap has nowhere
to live). §7 argues why a disk driver was built instead and what that does and does not buy.

---

## 2. Decision

**ATA PIO on the primary channel, LBA28, one sector at a time, printed as it arrives.**

- Registers `0x1F0`–`0x1F7` and the device-control/alternate-status register at `0x3F6`. Primary
  master only.
- `IDENTIFY DEVICE` (`0xEC`) for presence, model and capacity; `READ SECTORS` (`0x20`) for data.
- Two shell commands: `disk id`, and `disk read <lba>` with the LBA in hex.
- **No buffer.** Both commands consume the 256-word data block *as it arrives*, printing what they
  care about and forgetting the rest.

New file `core/kernel/ata.dart` (a `part of 'kmain.dart'`, forced — GAP-0004 item 4). No new
assembly, no new externs, and no new donated `.bss`.

---

## 3. Why PIO, and why that is a structural argument rather than a preference

The alternative is bus-master DMA, which is how any serious driver moves sectors. It needs three
things this kernel does not have:

1. a **physically contiguous landing buffer** for the data;
2. a **PRDT** — a physical-region descriptor table the controller reads to find that buffer;
3. somewhere to **put** both, which is a page allocator.

PIO needs a port number and a loop. It moves every byte through the CPU, which is slow and is
irrelevant at this size, and in exchange it needs **no memory manager at all**. That is the whole
reason this milestone was buildable while M7 is blocked: it is the one real storage path that does
not depend on the thing that is stuck.

Stated the other way round, so it is not oversold: **this is the slow way, and it was chosen because
it is the way that does not need what we do not have.** A DMA driver is strictly better and is a
post-allocator milestone.

---

## 4. What makes the driver correct rather than lucky

Three things, each of which would pass under QEMU if it were wrong.

### 4.1 BSY is honoured before DRQ, on every iteration

While `BSY` is set the drive owns every other bit of the status register and every other register on
the channel — ATA/ATAPI-6 §6.2. `DRQ`, `ERR` and `DF` read during `BSY` mean nothing.

`ataWait` therefore tests `BSY` first and looks at nothing else on an iteration where it is set. A
poll written the other way round can see a `DRQ` left over from a previous command and start reading
the data port before the drive has filled it. **Under QEMU that race is invisible** — `BSY` is clear
by the time the `out` instruction returns — and on hardware it is a corrupted sector. This is the
single most likely way to write a driver that passes this harness and fails on a real machine.

### 4.2 Every wait is bounded, and the bound is asserted in the compiled code

`docs/known-gaps.md` GAP-0058 already records an unbounded wait as a real hazard here: `uartPutc`
spins on THRE forever. A disk is a far better candidate for wedging than a UART, and a command runs
in task context with nothing that could break it out of a spin — so an unbounded poll on a dead
controller is a silent hang with **no diagnostic**, which is exactly the failure M4's fault work
exists to abolish.

`ataWait` is the only polling loop in the driver and it is iteration-counted (`ataPollLimit`,
2²¹). On expiry it returns `0x100 | lastStatus` — a status register is one byte, so any value above
`0xFF` is unambiguously not one — and the caller prints `DISK ERR TIMEOUT Pn ST xx`, where the phase
digit says *which* wait gave up.

`m6-disk/run.sh` disassembles `ataWait` and requires the bound to still be in the instruction stream,
because "it is bounded in the source" is not the claim; the claim is that the compiled loop has an
exit other than success.

It is an **iteration count, not a duration**, and that is a real limitation rather than a phrasing
choice — GAP-0073.

### 4.3 Every failure prints a value that was read out of the hardware

There are five diagnostics — `NODEV`, `TIMEOUT`, `ST/ER`, `NOTATA`, and the bad-LBA usage line — and
four of them print a byte or word the drive produced. `DISK READ END` and ` OK` are printed **only**
after the whole block has been drained and the status re-read clean, so they are claims about what
happened rather than lines that always follow a dump.

A device that is not an ATA disk is **not guessed at**: after IDENTIFY, a non-zero LBA-mid/high
signature (`EB14` = ATAPI, `9669` = SATA shim) stops the command and prints what it saw. Ploughing on
would report a failed read of something that was never a disk.

---

## 5. No donated `.bss`, and what that costs

`core/boot/kdata.S` is at **424 bytes** and this milestone left it there. The obvious driver shape —
`read(lba, buffer)` — would have needed 512 bytes, taking the total to 936: more than doubling the
measured cost of GAP-0053 in one milestone, for one command.

So `disk read` hexdumps each word **as it arrives**, and `disk id` prints the model and the capacity
as those words go past. The data port is read exactly 256 times either way, in order, and nothing is
retained.

Two consequences worth stating rather than discovering:

- **The output order is the word order.** The model is IDENTIFY words 27–46 and the capacity is words
  60–61, so the line reads `MODEL … SECTORS …` because that is the order the drive sends them in.
  Printing them the other way round would mean holding one, which would mean somewhere to hold it.
- **This driver can SHOW you a sector and cannot GIVE you one.** There is no `read(lba) -> bytes`,
  because there is nowhere for the bytes to go. A filesystem cannot be built on this, and that is
  GAP-0074 rather than a thing to be fixed by trying harder.

The one place a buffer would have been unavoidable — trimming the 40-byte space-padded model field —
is done with a **running count of deferred spaces** instead: spaces are counted, not printed, until a
non-space follows them. One word of a live local does the job of forty bytes of storage, and it works
*because* the characters arrive in order and are printed as they arrive.

---

## 6. Why `DCDART_PIN.txt` was not moved, even though three upstream changes would have helped

Three DCDart commits landed during this unit, and all three are relevant:

| commit | what it adds | what it would do here |
|---|---|---|
| `e3cfe18` | nested `while` loops | `ataDumpLine` folds back into `ataDumpSector` |
| `ff9aa89` | instance methods | nothing this driver needs |
| `b3f0ed9` | `Port.inw`/`outw`/`inl`/`outl` | `port_inw` becomes `Port.inw`; **`core/boot/portio.S` is deleted**, and four externs go with it (29 → 25 on `kmain.o`) |

**The pin was not moved, and the reason is scope rather than reluctance.** `DCDART_PIN.txt` says
`9e836a3 2026-08-21`, and CLAUDE.md's rule is that the pin names a commit this repo was *verified
against*. Moving it means re-verifying all eight harnesses on a new toolchain — and deleting
`portio.S` also rewrites `core/kernel/pci.dart`'s and `core/kernel/fb.dart`'s port access, which
puts M5's two subsystems inside a unit whose subject is a disk driver. That is two changes wearing
one commit, and the second one is exactly the kind that makes a regression hard to attribute.

By the time these landed the driver was written, built and passing against the pinned toolchain. The
honest sequencing is: **ship the driver against the pin it was verified on, and take the toolchain
bump as its own unit**, where "did anything change?" has a single answer. `docs/known-gaps.md`
GAP-0066 and GAP-0068 are both marked RESOLVED-UPSTREAM-NOT-ADOPTED with the commit hashes, so the
follow-up is a lookup rather than an archaeology exercise.

What this costs today, precisely: `ataDumpLine` is a separate function that would read better inline,
and `port_inw(u64(ataRegData))` is spelled through an assembly helper that no longer needs to exist.
Both are noted at the call site in `ata.dart`, so neither reads as a design choice.

---

## 7. Where this sits in the roadmap, and the argument against it

**M6 is the disk driver. The physical memory manager is now M7**, blocked on the same DCDart
mutable-statics decision it was blocked on after M5.

The case for building this first:

- **It was buildable.** M7 is not, and has not been for two milestones. Waiting produces nothing.
- **It did not consume the blocked resource.** Zero donated `.bss`, so it does not spend any of the
  budget the allocator's decision is about, and it does not prejudge that decision the way a device
  table or a sector cache would have.
- **It is the first data that came from outside the machine.** Every earlier milestone moved bytes
  that the kernel, the loader, or the emulator's device model had already produced.

The case against it, which is real:

- **It does not move the blocker one inch.** M7 is exactly as stuck as it was, and this is the second
  milestone in a row that routed around it.
- **It is a demonstration, not a foundation.** A driver that cannot return a sector is precisely the
  shape a filesystem cannot use. The thing that would make `disk` useful — somewhere to put 512
  bytes — *is* the blocked decision. So M6 sharpens the argument for M7 rather than reducing it: the
  kernel can now read a disk and still has nowhere to put what it read.

That second point is the honest summary of this milestone's position: **it proves the hardware path
end to end, and it proves it in the only shape that is possible without storage.**

---

## 8. Verification

`core/tests/conformance/m6-disk/run.sh` — three real QEMU boots plus four structural checks. The
assertions that matter:

- **The hexdump equals the image, and the expectation is DERIVED.** `make-image.py` generates 128
  sectors from `(31·s + 7·i + 0x21) & 0xFF`, re-reads the file to verify what it wrote, and the
  harness computes the expected hexdump by calling that same generator on the same file. Nobody typed
  the expected bytes and no capture was quoted.
- **Three sectors, not one:** `0000`, `002A` and `0005`. The pattern depends on the sector number, so
  an LBA off-by-one produces a wrong dump rather than a plausible one — and the harness also asserts
  each dump differs from its neighbour's.
- **The capacity is cross-checked against an independent source** — the image file's real byte count
  — and QEMU's own `info block` confirms the primary master is backed by that file.
- **Two `disk id` lines, byte-identical, the second after a deliberate `crash ud`.**
- **Negative control A: one flipped bit.** The same kernel, the same keystrokes, an image differing
  in exactly one bit. The dump must differ from the unflipped expectation at exactly that byte. This
  holds everything fixed except what is on the disk.
- **Negative control B: no drive.** Both commands report `DISK ERR NODEV ST 00`, and the harness
  greps for hexdump-shaped lines and for `DISK READ END` and requires that neither appears anywhere.
  **This is the boot that makes every other assertion mean something:** it is the proof that a
  hexdump is evidence of a disk rather than something this kernel can produce on its own.
- **Structural:** donated `.bss` still exactly 424; `port_inw` encodes as exactly `66 ed` (a byte or
  doubleword access to the data port would desynchronise the drive's buffer pointer); `ataWait`'s
  bound survives into the compiled code; and all 18 `@rodata` sizes match their call sites.
- 29 declared externs, **unchanged** — this milestone added no assembly.

Three earlier goldens were regenerated because `shellStrHelp` grew by two lines. That is a deliberate,
documented act with a diff that contains nothing else — GAP-0072.
