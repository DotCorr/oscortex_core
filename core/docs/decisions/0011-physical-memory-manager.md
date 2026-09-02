# ADR-0011 — The physical memory manager: a frame bitmap, and the seam that makes it safe to build now

**Status:** accepted, implemented, verified (`core/tests/conformance/m7-frames/run.sh`)
**Date:** 2026-08-21
**Supersedes:** nothing. **Unblocks:** partially, GAP-0074 item 1 and GAP-0067 item 1 — see §9.

---

## 0. The decision that had to be made first, because it is why this was not built four times

The physical memory manager has been the next structural milestone since M2. It was deferred at M3,
M4, M5 and M6, and the reason was never that it was hard. It was this:

> DCDart has no mutable static data of any kind (GAP-0053), so a page bitmap can only be
> assembly-donated `.bss`. Building the kernel's most important subsystem on that workaround would
> make the workaround load-bearing, and would turn the eventual language fix from a deletion into a
> rewrite.

**That objection is correct and this ADR does not overrule it. It removes it.**

The workaround becomes load-bearing only if knowledge of it is *spread*. So every mutable byte the
allocator owns lives in **one** donated block behind **one** accessor, and `core/kernel/pmm.dart`
reaches it through **three** functions — `pmmBitmapBase()`, `pmmMetaBase()`, `pmmLedgerBase()` —
marked in the source as the STORAGE SEAM. Nothing else in the allocator, and nothing else in the
kernel, knows where the bytes came from.

### The migration plan, stated as a plan

When DCDart grows mutable statics:

1. declare the bitmap, the metadata and the ledger as DCDart mutable statics in `pmm.dart`;
2. rewrite the three seam functions to take their addresses;
3. delete `pmm_store` and `pmm_store_addr` from `core/boot/kdata.S`, and the `@extern` declaration.

Nothing else moves. Not one line of the allocator, not one shell command, not one harness assertion.

### What a reader must not do

**Do not scatter `@extern` address calls through the allocator.** Do not call `pmm_store_addr()`
outside the seam, and do not add a second `@extern` accessor for a piece of allocator state. Either
one turns the three-step migration above into an audit of the whole file. If a new piece of state is
needed, give it a word in the metadata block — that is what the metadata block is for.

This is not left to good intentions. `m7-frames/run.sh` **counts the call sites**: exactly three
`return pmm_store_addr()` in `pmm.dart`, zero anywhere else in `core/kernel/`. A fourth fails the
harness. It is the only structural check in this project that exists to protect a *future* change
rather than a present property, and it is the reason this milestone could be built before the
language decision was made.

---

## 1. What was built

A bitmap allocator over 4KiB physical page frames.

| Piece | Where | What |
|---|---|---|
| bitmap | `pmm_store + 0`, 4096 bytes | one bit per frame, 1 = used or reserved |
| metadata | `pmm_store + 4096`, 64 bytes | ready, managed, free, baseline, cursor, over, errors, allocs |
| ledger | `pmm_store + 4160`, 512 bytes | 64 addresses, for the self-test only |

`allocFrame()` returns a physical address or **0**. `freeFrame(addr)` returns one of six status
codes. `pmmInit()` builds the bitmap from the Multiboot memory map at boot and prints nothing.

Six shell commands: `frames`, `frames test`, `frames drain`, `frames refill`, `alloc`,
`free <addr>`.

---

## 2. The bound is 128MiB, and it is the same number three times

Three quantities want to be one number, and the third is what makes it a correctness argument rather
than a budget:

* the bitmap's size — 4096 bytes is exactly one page;
* the RAM that covers — 4096 × 8 × 4KiB = 128MiB;
* **the extent `core/boot/boot.S` identity-maps** — `MAP_2MIB_PAGES` = 64, so 128MiB.

A frame the kernel cannot *address* is not a frame it can hand out. Before this milestone boot.S
mapped 16MiB; an allocator bounded at 128MiB on that map would have handed out frames whose first
write was a page fault inside whatever used them, not a diagnosable allocator bug. So boot.S's map
was raised to match, in boot-time assembly, which is where CLAUDE.md rule 4 says that decision
belongs.

`m7-frames/run.sh` reads `MAP_2MIB_PAGES` out of boot.S and `pmmMaxFrames`/`pmmFrameBytes` out of
pmm.dart, multiplies both out, and requires them equal. `frames drain` then *executes* the invariant:
it writes a value derived from its own address into the **highest** frame it hands out and reads it
back, and the harness confirms that write from outside with QEMU's own memory dump. A short map
would be a fault, not a verdict.

**Raising the bound later** is mechanical and linear: 4GiB would be 128KiB of bitmap and 2048 page-
directory entries. It is not free and it is not hard.

### Exceeding it is loud

Usable frames above the bound are counted at init into the metadata's OVER word and reported as
`OVER nnnnnnnn CAPPED`. They are never marked free, so they cannot be handed out. A 256MiB machine
gets a working 128MiB allocator **and a printed count of exactly what it refused to manage** — which
is a different thing from silently truncating the memory map and pretending the machine is smaller.
The harness boots one and checks the count against its own derivation.

---

## 3. What is reserved, and why each one

The bitmap starts **all ones** and regions are freed *into* it. Anything the loader did not vouch for
therefore stays reserved by default, which is the safe direction to be wrong in.

* **Everything the memory map does not call type-1 usable.** A frame must lie *wholly* inside a
  usable region — half a page is not a page, and the last frame of QEMU's `0..0x9FC00` region is
  exactly that case on every boot.
* **The whole first megabyte** (frames 0..255), even though Multiboot reports `0..0x9FC00` as usable.
  The real-mode interrupt vector table and the BIOS data area live there; the EBDA is reported
  inconsistently across machines; and physical address 0 being permanently unallocatable is what makes
  `allocFrame()` returning 0 an unambiguous failure value rather than a convention. 160 frames buys
  the removal of a class of question.
* **The kernel's own image**, `[__kernel_start, __kernel_end)`, exported by `core/link/kernel.ld` and
  read through two accessors in boot.S. `__kernel_end` is placed after `.bss`, not after `.data`,
  deliberately: `.bss` holds the boot stack, the four page-table pages, and **this allocator's own
  bitmap**. Handing out the frame the bitmap lives in is the most self-referential corruption
  available to this kernel and it is one subtraction away at all times. The harness asserts
  `pmm_store` is inside the reserved range.

### The predicate is written twice, on purpose

`pmmInit` marks by walking regions and freeing ranges. `pmmAllocatable(f)` asks about one frame, and
is what `freeFrame` and `frames refill` consult. They are two spellings of the same rule, and they
check each other: `frames refill` frees exactly what the second says is allocatable, and the harness
asserts the free count returns to the baseline the first computed. If they disagreed, either `ERRORS`
moves or `FREE` misses `BASELINE`. Both are printed on the refill line.

---

## 4. Why `freeFrame` refuses four different things

None of the refusals touches the bitmap, and each has its own status code:

* **not frame-aligned** — the shift would silently discard the low bits, so `free 1001` would free
  frame 1;
* **outside the managed range**;
* **not allocatable at all** — the kernel image, the first megabyte, a non-usable region. Without
  this, `free 100000` would mark a kernel-image frame free and the next `alloc` would hand out the
  running kernel;
* **already free** — the double-free. Catching it is why the free count can be trusted: without it,
  freeing the same frame twice increments the count twice and the allocator believes it has more
  memory than exists.

Every refusal increments `ERRORS`, so `frames` reporting `ERRORS 00000000` is a claim rather than a
default. Exhaustion is *not* an error — that is the allocator working.

---

## 5. Next-fit from a cursor, not first-fit from zero

Draining 32768 frames first-fit is quadratic and takes visible seconds under emulation. The cursor
makes a full drain one pass over the bitmap plus one wrap. It costs one metadata word and it is the
reason `frames drain` is a command a human can wait for.

---

## 6. How this is verified, and why the golden cannot launder a bug

`m7-frames/run.sh`: eight structural checks, `verify-freestanding.sh` clean, **four** QEMU boots.

The serial capture is a byte-exact golden **and** every number in it is independently recomputed by
`derive.py` from two sources the kernel does not control: the boot's own `MB E` memory-map lines
(which m1-interrupts' 544-byte golden already pins), and `__kernel_start`/`__kernel_end` read out of
`kernel.elf` with readelf. **Regenerating the golden cannot make a wrong allocator pass**, because
the derived checks run against the same capture. This is m6-disk's discipline — there, the expected
hexdump is computed by the image generator rather than quoted — applied to memory.

The strongest assertion is not a count. It is that the **whole 4096-byte bitmap is read out of guest
physical memory** with the monitor and compared bit-for-bit against one the harness computed, at the
address the *linker* put `pmm_store` at rather than the address the kernel printed — and the two
addresses are then asserted equal, so the storage seam is checked from outside as well.

**"No frame is handed out twice" is proved, not asserted.** A second boot stops at the drain, so the
bitmap can be dumped in the exhausted state: the drain reports N allocations and all 32768 bits are
set. There is no way to perform N allocations, leave every bit set, and have handed the same frame
out twice — a duplicate would leave some other frame free and its bit clear. The `SUM` and `XOR`
folds over every frame index handed out are checked against the derivation as well, and `LOW`/`HIGH`
bound the whole set.

The **negative control** is a 32MiB machine: same kernel, same keystrokes, less RAM. Every number
must change, must match a derivation for 32MiB, and the 128MiB golden must fail against it. It also
has to diverge from the golden *inside the boot-time memory-map report* — if it diverged only later,
the kernel would be reporting a memory map that does not depend on the memory.

---

## 7. `DCDART_PIN.txt` moved to `e3cfe18`, and exactly that far

GAP-0068 predicted this milestone by name: "a page-table walk and a memory-map merge are each
naturally a loop inside a loop." They are. `pmmInit` is a loop over memory-map entries containing a
loop over the frames in each entry, and the self-test's distinctness proof is a loop over ledger
entries containing a loop over the ones after it. Decomposing either pushes loop-carried state
through a parameter list for no reason but a compiler limitation that has since been fixed.

So the pin moved from `9e836a3` to `e3cfe18` (nested `while` lowering). **All eight pre-existing
harnesses were re-verified against `e3cfe18` with the kernel unchanged, before any of this code was
written** — 8/8, using an isolated clone of DCDart at that commit mirrored beside a copy of this
repo, because GAP-0003 fixes the sibling layout. The one failure in that run was a QMP ephemeral-port
collision, re-run and passed.

**`b3f0ed9` (word/doubleword port I/O) was deliberately not taken.** It deletes `core/boot/portio.S`
outright and rewrites M5's and M6's port access; that is a different unit's work, and taking it here
would have mixed a toolchain migration into an allocator. `fbd21e4` (compile-time folding in sized-int
literals) was not taken either — its absence cost two named constants and is recorded as GAP-0077.

---

## 8. Rejected alternatives

**Wait for DCDart mutable statics.** Rejected: the objection it answers is about *shape*, and shape
is something this repo controls. Five milestones have now been built around this hole. The seam gives
the same protection the wait was buying.

**Bound the allocator at the old 16MiB identity map instead of raising it.** Rejected: it would
manage 12% of a 128MiB machine and throw away the rest of the memory map — the exact behaviour this
milestone exists to stop. Raising the map is 64 page-directory entries in a loop that already exists.

**Reserve a fixed [1MiB, 2MiB) instead of the real image extents.** Rejected despite being more
stable across edits: it is a guess, it is wrong the moment the kernel exceeds it, and the linker
already knows the answer. The instability it would have avoided is recorded honestly as GAP-0078
instead.

**Two bitmaps, one for "reserved" and one for "allocated", so `free` can tell them apart.** Rejected:
it doubles the donated storage to answer a question `pmmAllocatable(f)` answers in seven memory-map
entries with no storage at all.

**A buddy allocator, or any multi-frame request.** Rejected as scope: nothing in this kernel needs
contiguous frames yet, and the first thing that will (DMA) needs a lot more than an allocator.
GAP-0076 item 2.

**Print the allocator's report at boot.** Rejected: `m1-interrupts/run.sh` asserts the entire 544-byte
serial capture. `pmmInit()` prints nothing, and `frames` reports from a prompt.

---

## 9. What this closes, and what it does not

**Closes:** the memory map is no longer read and discarded. 4KiB of retained, queryable state now
outlives the call that built it — the first thing in this kernel that does.

**Partially unblocks GAP-0074 item 1** (the ATA driver cannot return a sector). The reason was "there
is nowhere for 512 bytes to go." There is now: a frame. `disk read <lba>` into an allocated frame is
writable today and nobody has written it. That is a different, smaller statement than it was.

**Does not close GAP-0067 item 1** (PCI enumeration retains nothing). A frame is a physical address,
not a typed array; building a device list needs a way to *describe* records in memory, which is a
language question, not an allocator one.

**Still blocked:** virtual memory (nothing maps anything at runtime; boot.S's identity map is the
whole address space), processes and a scheduler, and a real allocator API returning typed memory.
The last one is the interesting one: `allocFrame()` returns a `u64`, and it returns a `u64` because
`@bare` DCDart has no type it could return instead. GAP-0076 has the full list.

**What the mutable-statics migration would change:** three functions, and the deletion of 4672 bytes
of assembly-donated `.bss` plus one accessor. It would not change the allocator, the commands, or a
single harness assertion except the two that count the donated bytes and the seam's call sites — and
those two exist precisely to be the things that change.
