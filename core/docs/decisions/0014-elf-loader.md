# ADR-0014 — Loading a program this kernel did not compile: ELF64 off a disk, mapped where its own headers say, run at CPL 3

**Status:** accepted, implemented, verified (`core/tests/conformance/m10-elf/run.sh`)
**Date:** 2026-08-21
**Narrows:** GAP-0085 items 4 and 5, GAP-0081 item 3, GAP-0074 item 1.
**Depends on:** ADR-0010 (ATA PIO), ADR-0011 (frames), ADR-0012 (the address space and its permissions), ADR-0013 (ring 3 and the syscall boundary).

---

## 0. What was wrong, stated as the fact that made it wrong

**Nothing compiled separately had ever run on this operating system.**

M9 put code at CPL 3, and ADR-0013 §4 was explicit about what that code was: 136
bytes of hand-written machine code in this kernel's own `.rodata`, copied into
whatever frame `allocFrame()` handed out and jumped to at its first byte. It was
position-independent because it had to be — "there is no relocation step here
and there is deliberately no loader to perform one, so position-independence is
the payload's job."

The consequence was not that ring 3 was fake. It was that **every address the
machine used was one this kernel chose.** A program in an ELF file is the
opposite: `e_entry` and every `p_vaddr` were chosen by a linker on another
machine, at another time, and a kernel that does not honour them has not loaded
a program — it has copied some bytes. That difference is the whole of M10, and
it is why M10 needed a real `map(va, pa, flags)` and M9 did not.

GAP-0074 item 1 said the other half of it, from M6: *"the kernel can now read a
disk and has nowhere to put what it read."* M7 answered that in principle. This
is the first caller to take it up: `ataReadInto` reads a sector into an address
the caller owns, and every caller owns a frame from the allocator.

---

## 1. What was built

| Piece | Where | What |
|---|---|---|
| a sector read into memory | `core/kernel/ata.dart` | `ataReadInto(lba, dst)` — six status codes, no output, **zero donated `.bss`** |
| a real `map(va, pa, flags)` | `core/kernel/vm.dart` | `vmProgMap`, `vmProgUnmap`, `vmProgTableInstall`, `vmProgTableRemove`, `vmProgLeaf`, `vmProgFlush` — one 2MiB window |
| an ELF64 reader | `core/kernel/elf.dart` | `e_ident`, `e_type`, `e_machine`, the program headers, **25 named refusals** |
| a segment loader | `core/kernel/elf.dart` | a frame per page, file bytes copied in, the `p_memsz - p_filesz` tail zero, permissions from `p_flags` |
| the fault-report widening | `core/kernel/interrupts.dart`, `vm.dart` | `vmFetchSafe` — the `OP` field now works above 16MiB |
| 128 bytes of state | `core/boot/kdata.S` | `elf_store`, behind one accessor, reached from one function |
| the test program | `core/tests/conformance/m10-elf/prog.c`, `prog.ld` | freestanding C, no libc, static ELF64 |
| the disk | `core/tests/conformance/m10-elf/make-image.py` | seven programs, six of them the good one with **one field changed** |

One shell command: `run <lba>`.

**One new extern, 52 → 53.** That is a claim about the design: an ELF loader is
arithmetic and memory, and neither needs a new instruction. `elf_store_addr` is
the storage seam and nothing else.

---

## 2. The program is BUILT BY THE HARNESS, and the exact command is here

`core/tests/conformance/m10-elf/build-prog.sh`:

```
clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
      -fno-pic -fno-pie -mgeneral-regs-only -mno-red-zone \
      -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin \
      -O2 -Wall -Wextra -Werror  prog.c -o prog.o

x86_64-elf-ld -T prog.ld -z max-page-size=0x1000 --build-id=none \
      -o prog.elf prog.o
```

A committed binary would make "the kernel ran a real ELF" a claim about a blob
somebody produced once. A build makes it a claim about a toolchain anyone can
re-run — and, more importantly, it lets **every expectation in the harness be
derived from the output**: the entry point, the message bytes, the exit status
and the per-segment permissions are all read out of `prog.elf` by
`derive.py`'s own ELF reader. Change `prog.c` and the expectations change with
it.

### `-mgeneral-regs-only` is a finding, not a flag

`core/boot/boot.S` sets exactly one bit of CR4 (PAE). It has never set
`CR4.OSFXSR`, so **an SSE instruction is a #UD on this machine** — and at `-O2`,
clang emits SSE for an ordinary struct copy, a `memcpy`, or a vectorised loop.
The first build of `prog.c` without the flag would have died in ring 3 at
whatever instruction happened to get one, and the diagnosis would have looked
like a loader bug. `build-prog.sh` asserts the **disassembly** contains no
`%xmm` rather than trusting the flag. GAP-0092.

### Two deliberate awkwardnesses in `prog.ld`, both of them tests

**`.rodata` is linked BEFORE `.text`.** With `.text` first, `_start` would be
the first byte of the first `PT_LOAD`, so `e_entry == p_vaddr == vmProgBase` —
and a kernel that ignored `e_entry` entirely and jumped to the base of the
window would pass every behavioural check in the harness. It is 0x10000050
instead: a non-zero, non-page-aligned offset that only a kernel which read
`e_entry` can reach. **This was found by mutation** (§7), and `build-prog.sh`
now asserts the offset is non-zero and not a whole number of pages.

**The RW segment starts 0x40 into its page** (`. = ALIGN(0x1000) + 0x40`). A
segment whose `p_vaddr` is not page-aligned is a case the loader has to handle,
and handling it in code nobody exercises is the same as not handling it. Now
the program that actually runs exercises it, and the 0x40 bytes below `p_vaddr`
on that page — which belong to no segment at all — are required to read back as
zero.

---

## 3. Where a program is loaded, and why it is not the identity map

`vmMapUser` (M9) flips bits on a leaf that already exists inside the 4KiB
identity window. That is enough for a payload that can be copied anywhere and is
useless for a program linked at an address of its own. So M10 builds the real
thing — but in **one 2MiB window**, `[0x10000000, 0x10200000)`.

The address is not arbitrary. The window has to be somewhere nothing is already
mapped, or installing it would silently replace part of the kernel's own address
space:

| range | what is there |
|---|---|
| `[0, 4MiB)` | the 4KiB identity window: the kernel image, the VGA buffer |
| `[4MiB, 128MiB)` | 2MiB leaves; `vmMapBytes` says the allocator hands out frames from here |
| `[128MiB, 1GiB)` | **nothing. 62 unused page-directory entries.** |
| `[3GiB, 4GiB)` | the PCI hole |

0x10000000 is 256MiB — the first round 2MiB-aligned address in that gap — so
page-directory entry 128, untouched by anything M0–M9 built. The harness
multiplies all five constants out against each other, against `derive.py`'s
copies and against the address `prog.ld` actually links at.

**One level of table is created and the caller supplies its frame.** The PML4
entry, the PDPT entry and the page directory for `[0, 1GiB)` all already exist.
`vmProgTableInstall` takes a frame from the caller, zeroes it and writes one
page-directory entry; `vmProgMap` then writes leaves under it. Nothing inside
the mapping code allocates, so **no mapping can fail half-way through for want
of memory** — the failure happens at `vmProgTableInstall` or not at all.

**Teardown removes the page-directory entry, not just the leaves.** After a
program exits or dies, the whole window is unreachable and the page table's
frame is back in the allocator. `m10-elf` asserts `PD_low[128]` is *absent* out
of guest physical memory, which is a stronger statement than "the pages are
unmapped".

**TLB: 512 `invlpg`s, and GAP-0083's question asked a second time.** `invlpg`
invalidates the cached interior entries for the page it names as well as the
leaf, and there is no instruction that says "forget one page-directory entry".
So installing or removing the window names all 512 pages it covers, one at a
time.

---

## 4. There is no filesystem here, and this section is the admission

`run <lba>` is handed the sector number of a 32-byte header that this repo's own
test harness writes:

```
+0   8 bytes   "OSCXPRG1"
+8   u64       the image's length in bytes
+16  u64       the LBA its first sector is at
```

That is the entire metadata format. **There is no directory, no name, no
allocation, no free list, no writing, and no way to find a program whose sector
number you do not already know.** It exists so `run` takes one number instead of
three, and so that pointing it at an arbitrary sector is a diagnostic
(`ELF REFUSED 05 the header sector does not begin with OSCXPRG1`) rather than a
jump into whatever was there.

GAP-0090 lists what a real filesystem has to add, written down rather than
gestured at, because "we will add a filesystem later" is the kind of sentence
that hides how much of one is missing.

**Why not a real one now.** The same argument ADR-0013 §4 makes about the
loader: building a filesystem to prove a loader works would have made the
filesystem the thing under test. A filesystem is a milestone — allocation,
directories, a write path, crash consistency — and none of it is exercised by
loading one program from a known sector.

---

## 5. The loader, and why every refusal is named

Twenty-five refusal codes, twenty-five distinct sentences, each naming the field
that was wrong. An ELF file is a structure this kernel did not produce and cannot
trust: **every field is read from a disk**, and a loader that guessed at
something it did not recognise would be jumping to an address chosen by whatever
wrote that sector.

The rule is: *if this loader does not understand something, it says which thing
and stops.* Never a default, never a best effort. `ELF REFUSED 11 PT_INTERP or
PT_DYNAMIC: this loader does not link` is a useful sentence; a dynamically-linked
binary that loaded anyway and jumped into a PLT stub full of zeroes is not. The
harness reads the messages out of `kmain.o`'s `.rodata` and requires all
twenty-five to be different — twenty-five codes sharing four messages would
satisfy every behavioural test and would not be the claim.

### The order of the checks is the design

`e_ident` first, because until `EI_CLASS` and `EI_DATA` are known nothing else
in the file has a defined size or byte order. Then `e_type` and `e_machine`,
because a file for another machine may be perfectly well-formed. Then the
program-header geometry, because the walk indexes with it.

### The multi-byte decode is written out by hand, and that is not pedantry

`elfU16`/`elfU32`/`elfU64` compose bytes low-first. Two reasons, and the second
is the real one. **Alignment:** DC-IR's `Load` carries no alignment attribute and
these offsets are into a structure this kernel did not lay out. **And this IS
the little-endian decode `e_ident[EI_DATA]` promises** — writing it out is what
makes the check on that byte mean something. A wide load would be trusting the
host's byte order to match the file's.

### W^X applies to a guest, and it is refused twice

A `PT_LOAD` with both `PF_W` and `PF_X` is refused by `elfCheckPhdr` on
`p_flags`, and refused **again, independently**, by `vmProgMap` on its arguments
— so a future caller that forgot to check cannot create such a page. ADR-0012
bought that property for the kernel; a program that arrived on a disk does not
get an exemption from it. The harness tests both halves: the structural check
catches the second refusal being deleted, and the `wx` program on the disk
catches the first.

### `e_entry` must land somewhere this load actually put code

Read back out of the **live tables** rather than compared against the segment
list: "it is inside the range of a `PT_LOAD` I saw" is a weaker claim than "the
page it is on is present, is reachable from ring 3, and is executable". The
`badentry` program on the disk is `prog.elf` with `e_entry` moved onto the
writable segment; it is well-formed in every other respect and must be refused
before ring 3 is entered rather than taking an instruction-fetch fault there.

### The whole pre-flight happens before a single frame is allocated

Not tidiness. `elfLoadSegment` maps as it goes, so a rejection discovered
half-way through would leave a partially-mapped window for the refusal path to
unpick. Every header is checked first; the page table is taken second; the
segments third.

### Zeroing is not a step, it is the initial condition

`vmZeroFrame` runs on every frame before anything is copied into it. So `.bss`
is zero because the frame is zero, a page entirely past `p_filesz` needs no disk
access at all, and the partial page at the `p_filesz` boundary — the only page
where it is easy to be wrong — needs no special case. Zeroing *afterwards* would
need the same arithmetic run backwards.

Sectors are read into a **scratch frame** and then copied, rather than read
straight into the destination: a page whose file part is 8 bytes must not have
the other 4088 overwritten with whatever followed on the disk. (That mutation is
in §7; the harness catches it.)

### Every bound comes before the arithmetic it protects

ADR-0013 §5's rule, applied to numbers that came off a disk rather than out of a
register. DCDart's arithmetic traps on overflow with a real `ud2`
(DCDART_SPEC §4.1), so `p_vaddr + p_memsz` on a malformed file would take a #UD
**inside the check meant to reject it** — in the kernel, chosen by the file.
`p_vaddr`, `p_memsz`, `p_offset` and `p_filesz` are each bounded before they are
added to anything.

### A syscall pointer from a loaded program is checked PER PAGE

M9's payload owns two pages that are adjacent to nothing. A loaded program owns a
handful of pages in a 512-page window with unmapped gaps between them, so a
lo/hi range test would accept a pointer into a gap — and the kernel would then
page-fault dereferencing it, which is a ring-3 program choosing which instruction
the kernel executes next. `elfOwns` walks the pages the range touches and
requires each to be user-accessible in the live tables.

---

## 6. The fault report's `OP` field was wrong for exactly this milestone

`faultReport` prints the first two opcode bytes at the faulting RIP, guarded by
`rip < mappedLimit` — the 16MiB `boot.S` maps. That guard was right when it was
written, became conservative at M8 (the address space maps 128MiB), and was
**wrong at M10**: a loaded program runs at 256MiB, so every fault it took printed
`OP ----` for an address that was perfectly readable, throwing away the one field
that identifies the faulting instruction in exactly the case where that
instruction came off a disk.

`vmFetchSafe` asks the **live page tables** instead, and checks `vmMetaReady`
first — without that, a kernel whose `vmInit` refused would walk from address 0
as if the first page of memory were a PML4, which is precisely the "diagnosing a
fault kills the machine" outcome the guard exists to prevent.

Nothing below 16MiB reaches the new branch, so **no earlier golden moved for
this**. What it buys is `FAULT 0D ERR 0 OP 0F20` for the `gp` program: the
kernel reading back, out of the page it just mapped, the exact bytes
`make-image.py` patched into the file. GAP-0064 is narrowed.

---

## 7. How this is verified, and the mutation that was NOT caught

`m10-elf/run.sh`: 8 structural checks, `verify-freestanding.sh` clean, **four**
QEMU boots. `expected.txt` is a byte-exact golden **and** every claim in it is
recomputed from two sources the kernel does not control — the ELF file the
harness built, and guest physical memory.

**Nothing is taken from the kernel's own report.** `derive.py` contains a second
ELF64 reader, written independently of `core/kernel/elf.dart`, and a page-table
walker that spans **several disjoint dumped regions** — because the program's
page table comes from the allocator at run time and is nowhere near the six
frames at CR3. A walker that returned zeroes for the gap between them would
report a correctly-mapped program as unmapped.

**Boot B is the one that matters.** The `spin` program is `prog.elf` with `jmp .`
at `e_entry`, so the machine can be stopped with a loaded program on the CPU:
QEMU's own `info registers` says `CPL=3`, `CS=0023`, and `RIP` **exactly equal to
the ELF's `e_entry`** — 0x10000050, an address that is neither the segment base
nor a page boundary. Then every page of the window is checked against the file:
its permissions against `p_flags`, and **its 4096 bytes against what a correct
load must have put there** — the file's own bytes inside `[p_vaddr, p_vaddr +
p_filesz)` and zero everywhere else.

**Four refusals and a fault, each one program on the disk.** `badmagic`, `wx`,
`interp` and `badentry` are each `prog.elf` with **one field changed**, so the
difference between "runs" and "refused with this sentence" is exactly that field.
`gp` is `mov %cr3,%rax` written over the three bytes at `e_entry`: it loads, it
runs, and it dies in ring 3, which is what tests the fault path's teardown.

**Three negative controls.** A 32MiB machine (different memory map, different
frames, and the program must still exit with the status its *file* encodes); a
drained allocator (`run` must refuse rather than load into pages nobody
allocated, twice); and the allocator's free count compared before and after
seven loads.

### The mutations, run against deliberately broken kernels in the sandbox mirror

Each was built with the golden **regenerated from the broken kernel** — the
exact scenario "regenerating the golden cannot make it pass" claims to cover.

| mutation | caught by |
|---|---|
| ignore `p_flags`, map everything R+X | *"0x10001000 is W0 X1, but the segment's `p_flags` asks for W1 X0"*, then the program page-faulting on its first store |
| jump to `vmProgBase` instead of `e_entry` | the program faulting immediately; `gp` no longer #GP-ing at `e_entry`. **This mutation would NOT have been caught before `prog.ld` was changed to put `.rodata` first** |
| delete both W^X refusals | the structural check, before booting |
| delete both W^X refusals **and** the structural check | *"`run a0` (wx) ENTERED RING 3 with a file it should have refused"* |
| read sectors straight into the destination frame | *"the program reports `BSS[00] SUM=C2`"* and a wrong exit status |
| **delete `vmZeroFrame` from `elfLoadSegment`** | **NOTHING. See below.** |

### The one that got away, stated plainly

**Deleting the frame zeroing changed no observable behaviour at all.** The
program still reported `BSS[00] SUM=00`, the byte-for-byte comparison of every
loaded page against the file still passed, and the harness exited 0.

The reason is that a freshly-booted QEMU hands out RAM that is already zero, and
**nothing in this kernel dirties a frame before the loader gets one.** The
allocator is next-fit from a forward-moving cursor (ADR-0011), so no shell
sequence can make `run` land on a frame something else has written: `frames test`
dirties 64 frames and leaves the cursor past all of them; `frames drain` writes
to exactly one frame and returns the cursor to where it started. This was
measured, not assumed — the sequence `frames test; frames drain; frames refill;
run` was tried against the broken kernel and the program's frames came out of
the region just past the dirtied one.

So the zeroing is asserted where it can be: `m10-elf` requires every one of
`elf.dart`'s five `allocFrame()` calls to be paired with a zeroing. **A
structural check is weaker than a behavioural one and this ADR is not pretending
otherwise.** GAP-0094 records the measurement, and it records what would fix it:
something that can dirty a frame before the allocator hands it out.

---

## 8. `DCDART_PIN.txt` did not move

`e3cfe18`, unchanged since M7. Nothing in this milestone needed a language
capability that pin does not have — notably the nested `while` in
`elfLoadSegment` (a page loop containing a sector loop), which is the capability
that moved the pin at M7 in the first place.

**All eleven pre-existing harnesses were re-run against it, with the kernel
unchanged, before any M10 code was written — 11/11** — using an isolated clone of
DCDart at that commit mirrored beside a copy of this repo (ADR-0011 §7's method,
with GAP-0084's `core/frontend` step). That baseline mattered more than usual
this time: the shared checkout's `HEAD` is four commits ahead of the pin, and the
first build attempt against it failed with `no @bare top-level function found in
kmain.dart`. The cause was GAP-0003 — `kmain.dart` imports the prelude through a
hardcoded `../../../DCDart/...` path, so a clone of DCDart is only actually
isolated when a COPY of this repo is mirrored beside it. A symlink is not enough;
Dart resolves the import through the file's real path. GAP-0084 is extended with
that step.

---

## 9. Rejected alternatives

**A filesystem.** Rejected as scope, and named rather than half-built: §4 and
GAP-0090.

**Load the whole file into memory and parse it there.** Rejected: it needs a
contiguous run of frames the allocator does not promise, and it puts an
arbitrary size limit on a program for no reason. The loader reads the first page
(header plus program headers) into one frame and then streams each segment's
sectors through a second one. What it costs is the bound in `elfCheckHeader`:
the program headers must be inside the first 4096 bytes. That bound is checked
and named (`ELF REFUSED 10`), not assumed.

**Support `ET_DYN` by relocating.** Rejected: a position-independent executable
needs `R_X86_64_RELATIVE` processing and a `PT_DYNAMIC` walk, which is a
different milestone, and half of one is worse than none. `e_type != ET_EXEC` is
refused by name.

**Map a W+X segment and let the program deal with it.** Rejected twice, once in
each place that can refuse it. §5.

**Let the loader relocate a segment that does not fit the window.** Rejected: an
address a linker chose is not advice. A `PT_LOAD` outside
`[vmProgBase, vmProgStackPage)` is refused; it is not moved.

**Share the transfer loop between `ataReadInto` and `shellDiskRead`.** Rejected:
they differ in the middle (dump a word / store a word) and at both ends, and the
shape that would let them share — a callback, which DCDart cannot express, or a
flag threaded through the transfer loop — costs more than twenty duplicated
register writes. Merging them would also put a `@rodata` message write inside the
path an ELF load takes eighteen times.

**Fold the loader's state into `user_store`.** Rejected: the whole content of the
seam pattern (ADR-0011 §0) is that each subsystem's donated storage is one symbol
reached from one function, so the eventual mutable-statics migration is a
deletion per subsystem rather than an audit. `elf_store` is the fourth.

**Widen `mappedLimit` instead of asking the page tables.** Rejected: it would
have been another constant that is right today and wrong at the next milestone
that maps something new. §6.

---

## 10. What this closes, and what it does not

**Narrows GAP-0085 item 5.** There is an ELF loader. There is still no `fork`, no
`exec`, no relocation and no dynamic linking.

**Narrows GAP-0085 item 4.** The three syscalls now serve a program that arrived
from outside this repo, and `write`'s pointer check is a per-page walk of the
live tables rather than a two-frame comparison. There is still no `read`, no file
descriptor, no `brk` and no `mmap`.

**Narrows GAP-0081 item 3 a long way.** `vmProgMap` genuinely creates a mapping,
at an address the caller names, pointing at a frame the caller allocated, with
permissions the caller derived from a file. It is bounded to one 2MiB window and
one level of table, and it does not allocate.

**Narrows GAP-0074 item 1 to nothing.** The disk driver can now give you a
sector.

**Narrows GAP-0064.** The `OP` field works wherever the live tables say the
bytes are readable.

**What remains, and none of it is in scope here:**

* **No per-process address space.** One PML4, still the kernel's, with one 2MiB
  window temporarily carrying a program. GAP-0089.
* **No scheduler, no preemption, no processes, no `fork`, no `exec`.** One
  program at a time, entered synchronously from a shell command. GAP-0089.
* **No filesystem.** A header sector at an LBA you have to know. GAP-0090.
* **No dynamic linking, no relocation, no `ET_DYN`.** GAP-0091.
* **No SSE for a guest**, because the kernel never enables it. GAP-0092.
* **The frame-zeroing has no behavioural test that can fail on QEMU.** GAP-0094.
