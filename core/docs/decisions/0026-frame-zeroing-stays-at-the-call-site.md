# ADR-0026 — `allocFrame` still does not zero, deliberately. **The zeroing stays at the call site, and there is now a check that says so across the whole kernel.**

**Status:** accepted, implemented, verified (`core/tests/conformance/m7-frames/run.sh`, check 2i)
— **a SOURCE-SHAPE check. It proves nothing about a running machine and §4 says why.**
**Date:** 2026-08-23
**Part of:** a fix batch, not a milestone. No `ROADMAP.md` entry.
**Records:** GAP-0154. **Narrows:** GAP-0076 item 5, GAP-0094, GAP-0109.

---

## 0. First, the correction

`allocFrame()` does not zero the frame it returns. That much is true and has been since M7.

**It was described as a live hazard. It is not one today.** There are nineteen `allocFrame()` call
sites in `core/kernel/`, and every frame that goes anywhere — into a page table, into a ring-3
mapping, into a heap page, into an ELF segment — is already zeroed before anything reads it:

| where | frames | zeroed by |
|---|---|---|
| `elf.dart` segment pages, stack, header, scratch | 4 | `vmZeroFrame` beside the allocation |
| `elf.dart` program-window page table | 1 | `vmProgTableInstall`, which zeroes what it is handed |
| `proc.dart` PML4 / PDPT / PD, header, scratch | 5 | `vmZeroFrame` |
| `user.dart` M9 payload code and stack | 2 | `vmZeroFrame` |
| `heap.dart` `sbrk` page | 1 | `vmZeroFrame`, **before** the mapping is written |
| `vm.dart` `vmInit`'s six | 1 site | `vmBuild`'s own `vmZeroFrame(vmFrame(i))` loop |
| `pmm.dart` `alloc`, `frames self`, `frames drain` | 5 | nothing, and nothing needs it — see §3 |

The claim that motivated this — *"not harmless for anything a device reads as pointers, e.g. a UHCI
frame list at 1000 Hz"* — is a claim about a **future** DMA structure. This kernel has no DMA at all:
ATA is PIO, there is no USB, no NIC and no GPU. So the correct description is **a latent hazard for
work not yet done**, not a defect reachable today. That distinction is worth keeping straight, because
the two deserve different fixes and only one of them deserves a change to the allocator.

## 1. The decision

**Do not zero in `allocFrame`. Keep it at the call site.** Add a mechanical check that every call site
is accounted for.

## 2. The argument that decided it — `frames drain`

`shellFramesDrain` (`pmm.dart:1532`) exists to prove exhaustion is exact: it calls `allocFrame()` in a
loop until it returns 0, and `m7-frames` checks the count against a number derived from the Multiboot
memory map. On the `-m 128M` boot that is **32768 frames**.

If `allocFrame` zeroed, that command would write **128 MiB** — under TCG, with no host `memset` to
fall through to, a page at a time from a DCDart `while` loop. `m7-frames` runs the drain in four
separate boots and every one of them is under a `timeout`. The measured cost is not a guess: the same
harness already notes that draining 32768 frames *first-fit* "takes visible seconds under emulation",
which is why `allocFrame` uses a cursor at all.

So zeroing inside the allocator makes the allocator's own conformance test slower by two orders of
magnitude in the one operation that test exists to measure — to protect frames that are never mapped,
never handed to ring 3, and never read.

That is the decisive argument, and it is a **measurement**, not a taste. The taste-level arguments
point the same way and are worth one line each:

* **A call site that must zero states it.** `heap.dart`'s comment explains that the zero happens
  *before* the mapping is written so there is no window in which ring 3 can see the old bytes.
  Ordering like that is a property of the caller, and an allocator that zeroed would tempt the next
  author to stop thinking about it.
* **`vmProgTableInstall` zeroes what it is handed** because 512 words of litter installed as a page
  table is 512 mappings the CPU believes. That zero belongs to the *installer*, not the allocator —
  the frame is not a page table until it is installed as one.
* **Frames that never leave the allocator do not need it**, and there are five such sites.

## 3. Why the `pmm.dart` sites are exempt and not sloppy

`alloc` prints an address. `frames self` fills a ledger, checks the frames are pairwise distinct and
inside usable regions, writes and reads back one word of each, and frees all 64. `frames drain` takes
everything and writes one word into the highest frame by hand to prove the identity map reaches it.
None of them maps a frame, none of them enters ring 3, and none of them reads a byte it did not just
write. A zero there would be 128 MiB of stores to make a diagnostic look symmetrical.

## 4. What the new check proves, and what it does not

`m7-frames` check 2i reads `core/kernel/*.dart`, finds all nineteen `allocFrame()` call sites, and
requires each to name its frame to `vmZeroFrame` in the same file — or to be on an exemption table
with a reason, where the two delegating exemptions are themselves re-checked (`vmProgTableInstall`
must still contain its zero; `vmBuild` must still contain its loop). A stale exemption is a failure,
and so is a twentieth call site nobody has accounted for.

**It is a source-shape assertion. It does not prove a single frame is zero at runtime.**

This is the third unit to run into that wall and it is worth stating why once more, because it is a
property of the *machine* rather than of anyone's effort. QEMU hands out zeroed guest RAM
(GAP-0094, GAP-0109). On a **first** allocation an unzeroed frame and a zeroed one contain the same
4096 bytes, so no assertion about their contents can distinguish a kernel that zeros from one that
does not. Deleting every `vmZeroFrame` in the tree leaves every behavioural check in this repo
passing. That is exactly why m10-elf asserted the source shape for `elf.dart` at M10, and this
generalises that to the whole kernel — five of the nineteen sites were covered before; nineteen are
now.

**The one behavioural check that IS possible already exists and is not this one.** A *recycled* frame
is distinguishable, because the previous contents were written by the guest rather than by QEMU:
`m12-heap`'s program reads every byte of every heap page before it writes one and reports what it
found. That covers the heap path. Extending the same idea to the ELF loader — run a program that
fills its pages with a signature, let it exit, run another and have it read its own pages before
writing — is a real test that would really fail, and it is the thing to build next if this area is
worth more effort. It is written up in GAP-0154 rather than done here, because it needs a new program
pair and a fourth boot in `m10-elf`, and this is a fix batch.

## 5. What would change the decision

A DMA structure. The moment a device reads a frame's bytes as pointers — a UHCI frame list, a VirtIO
queue, an AHCI command list — the frame is read by something that has never heard of `vmZeroFrame`,
and "the call site zeroes it" becomes a rule enforced by whoever writes the driver at 3am. At that
point the right move is probably **not** to make `allocFrame` zero either, but to give the DMA path
its own `allocDmaFrame()` that does, so `frames drain` keeps costing what it costs. This paragraph is
here so that decision is taken deliberately rather than by whoever hits it first.
