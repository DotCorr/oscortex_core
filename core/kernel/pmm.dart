// core/kernel/pmm.dart
//
// oscortex_core M7: THE PHYSICAL MEMORY MANAGER -- a bitmap allocator over
// 4KiB physical page frames, initialised from the Multiboot memory map the
// kernel has been reading and throwing away since M0.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS CLOSES
// ---------------------------------------------------------------------------
// Three subsystems in this kernel re-derive their results from scratch on every
// use because there was nowhere to keep them: the Multiboot memory map
// (`mbReport`), the PCI bus (`pci`, GAP-0067 item 1) and every sector the ATA
// driver reads (GAP-0074 item 1). They are three faces of one missing
// capability. This file closes it for physical memory and for nothing else --
// see the end of this header for what is still open.
//
// ---------------------------------------------------------------------------
// THE STORAGE SEAM, AND WHY IT IS THE MOST IMPORTANT THING IN THIS FILE
// ---------------------------------------------------------------------------
// DCDart has no mutable static data of any kind (docs/known-gaps.md GAP-0053),
// so the bitmap can only be assembly-donated `.bss` today. A previous unit
// argued against building the allocator on that workaround, because it would
// make the workaround load-bearing for the kernel's most important subsystem
// and turn the eventual language fix into a rewrite. That objection is correct.
//
// It is neutralised BY SHAPE, not by waiting. Every mutable byte this allocator
// owns lives in ONE block behind ONE accessor (`pmm_store_addr`, core/boot/
// kdata.S), and this file reaches it through exactly three functions --
// [pmmBitmapBase], [pmmMetaBase], [pmmLedgerBase] -- marked below as the
// STORAGE SEAM. Nothing outside that seam knows where the storage came from:
// no other function in this file, and no function anywhere else in this kernel,
// calls `pmm_store_addr`.
//
// **The migration plan, stated here so it is a plan and not an intention.**
// When DCDart grows mutable statics, the change is:
//
//   1. declare the bitmap, the metadata and the ledger as DCDart mutable
//      statics in this file;
//   2. rewrite the three seam functions to take their addresses;
//   3. delete `pmm_store` and `pmm_store_addr` from `core/boot/kdata.S`, and
//      the `@extern` declaration below.
//
// Nothing else in this file moves. The allocator does not know, and must never
// learn, whether its bytes came from assembly or from the language.
//
// **What a reader must NOT do.** Do not call `pmm_store_addr` outside the seam,
// and do not add a second `@extern` accessor for a piece of allocator state.
// Either one turns the three-step migration above into an audit of the whole
// file, which is the exact failure mode this shape exists to prevent. If a new
// piece of allocator state is needed, give it a word in the metadata block.
//
// ---------------------------------------------------------------------------
// THE BOUND, AND WHY IT IS 128MiB
// ---------------------------------------------------------------------------
// A bitmap has to be sized before it can be filled, and three numbers want to
// be the same number:
//
//   * the bitmap's own size -- 8192 bytes is exactly two pages;
//   * the RAM that covers -- 8192 bytes * 8 bits * 4KiB = 256MiB;
//   * the extent boot.S identity-maps -- MAP_2MIB_PAGES = 128, so 256MiB.
//
// The third is the one that makes this a correctness argument rather than a
// budget. A frame the kernel cannot ADDRESS is not a frame it can hand out: if
// the allocator managed more RAM than the page tables map, the first write
// through a high frame would be a page fault inside whatever used it, not a
// diagnosable allocator bug. boot.S's own comment states the invariant and
// `tests/conformance/m7-frames/run.sh` asserts both halves of it.
//
// **Exceeding the bound is loud.** Usable frames above 256MiB are counted at
// init into the metadata's OVER word, reported by `frames` as
// `OVER nnnnnnnn CAPPED`, and never marked free. A 512MiB machine gets a
// working 256MiB allocator and a printed count of what it refused to manage --
// which is a different thing from silently truncating the memory map and
// pretending the machine is smaller than it is. The harness boots one.
//
// ---------------------------------------------------------------------------
// WHAT IS RESERVED, AND WHY EACH ONE
// ---------------------------------------------------------------------------
//   * everything the memory map does not call type-1 usable. The bitmap starts
//     as all-ones and regions are freed INTO it, so anything the loader did not
//     vouch for stays reserved by default -- the safe direction to be wrong in.
//   * the whole first megabyte, frames 0..255, even though Multiboot reports
//     0x00000000..0x0009FC00 as type-1 usable. The real-mode interrupt vector
//     table and the BIOS data area are inside that region and are not free
//     memory in any useful sense; the EBDA is reported inconsistently across
//     machines; and physical address 0 is the value [allocFrame] returns to
//     mean failure, which is only unambiguous because frame 0 can never be
//     handed out. 160 frames is a cheap price for removing a class of question.
//   * the kernel's own image, `[kernel_image_start(), kernel_image_end())`,
//     read from the linker script rather than guessed. That range includes
//     `.bss`, so it includes the boot stack, the four page-table pages, and
//     this allocator's own bitmap. Handing out the frame the bitmap lives in is
//     the most self-referential corruption available to this kernel and it is
//     one subtraction away at all times.
//
// ---------------------------------------------------------------------------
// NESTED `while` LOOPS ARE USED HERE, DELIBERATELY, AND THE PIN MOVED FOR IT
// ---------------------------------------------------------------------------
// GAP-0068 predicted this exact milestone: "a page-table walk and a memory-map
// merge are each naturally a loop inside a loop." They are. [pmmInit] is a loop
// over memory-map entries containing a loop over the frames in each entry, and
// [shellFramesTest]'s distinctness proof is a loop over ledger entries
// containing a loop over the ones after it. Decomposing either into a helper
// pushes loop-carried state through a parameter list for no reason other than a
// compiler limitation that has since been fixed.
//
// `DCDART_PIN.txt` therefore moved from `9e836a3` to `e3cfe18` for this
// milestone, and all eight pre-existing harnesses were re-verified against the
// new pin BEFORE any of this code was written -- see ADR-0011 section 7 and
// GAP-0068. `b3f0ed9` (word/doubleword port I/O, which deletes portio.S) was
// deliberately NOT taken: it rewrites M5's and M6's port access and is a
// different unit's work.
//
// ---------------------------------------------------------------------------
// WHAT THIS IS NOT
// ---------------------------------------------------------------------------
// It is a FRAME allocator: it hands out 4KiB-aligned physical addresses and
// takes them back. It is not virtual memory (nothing maps anything at runtime;
// boot.S's identity map is the whole address space this kernel has), it is not
// a heap (there is no `alloc(n) -> typed memory`, because DCDart `@bare` has no
// type that could be returned), and it allocates ONE frame at a time (there is
// no contiguous multi-frame request, which is what a DMA buffer would need).
// docs/known-gaps.md GAP-0076 lists all of it rather than leaving it to be
// discovered.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// EVERY BYTE COUNT BELOW WAS GENERATED, NOT TYPED. A `@rodata` table carries no
// length word, so each count is a hand-maintained literal repeated at the call
// site -- docs/known-gaps.md GAP-0060, which caused a real truncation incident
// at M4 when `shellStrHelp` grew and its one call site did not.
// `tests/conformance/m7-frames/run.sh` reads every symbol's real size out of
// the object file and compares it against the number the call site passes.
// ---------------------------------------------------------------------------

/// Report line 1 head, and the token the harness greps for the storage seam's address.
///
/// `"PMM BASE "` -- 9 bytes.
@rodata
final List<u8> pmmStrBase = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x42), u8(0x41), u8(0x53), u8(0x45), u8(0x20),
];

/// Report: total donated bytes of the one storage block.
///
/// `" STORE "` -- 7 bytes.
@rodata
final List<u8> pmmStrStore = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x4F), u8(0x52), u8(0x45), u8(0x20),
];

/// Report: bytes of that block that are bitmap.
///
/// `" BITMAP "` -- 8 bytes.
@rodata
final List<u8> pmmStrBitmap = const [
  u8(0x20), u8(0x42), u8(0x49), u8(0x54), u8(0x4D), u8(0x41), u8(0x50), u8(0x20),
];

/// Report: bytes that are metadata.
///
/// `" META "` -- 6 bytes.
@rodata
final List<u8> pmmStrMeta = const [
  u8(0x20), u8(0x4D), u8(0x45), u8(0x54), u8(0x41), u8(0x20),
];

/// Report: bytes that are the self-test's allocation ledger.
///
/// `" LEDGER "` -- 8 bytes.
@rodata
final List<u8> pmmStrLedger = const [
  u8(0x20), u8(0x4C), u8(0x45), u8(0x44), u8(0x47), u8(0x45), u8(0x52), u8(0x20),
];

/// Report line 2 head: the frame-count bound this allocator refuses to exceed.
///
/// `"PMM BOUND "` -- 10 bytes.
@rodata
final List<u8> pmmStrBound = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x42), u8(0x4F), u8(0x55), u8(0x4E), u8(0x44), u8(0x20),
];

/// Report: bytes per frame.
///
/// `" FRAME "` -- 7 bytes.
@rodata
final List<u8> pmmStrFrame = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x41), u8(0x4D), u8(0x45), u8(0x20),
];

/// Report: the bound expressed as MiB of RAM.
///
/// `" LIMIT "` -- 7 bytes.
@rodata
final List<u8> pmmStrLimit = const [
  u8(0x20), u8(0x4C), u8(0x49), u8(0x4D), u8(0x49), u8(0x54), u8(0x20),
];

/// Report: unit for the line above.
///
/// `" MIB"` -- 4 bytes.
@rodata
final List<u8> pmmStrMib = const [
  u8(0x20), u8(0x4D), u8(0x49), u8(0x42),
];

/// Report line 3 head: frames under management.
///
/// `"PMM MANAGED "` -- 12 bytes.
@rodata
final List<u8> pmmStrManaged = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x4D), u8(0x41), u8(0x4E), u8(0x41), u8(0x47), u8(0x45), u8(0x44), u8(0x20),
];

/// Shared separator: a free-frame count follows.
///
/// `" FREE "` -- 6 bytes.
@rodata
final List<u8> pmmStrFreeL = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x20),
];

/// Report: used-frame count.
///
/// `" USED "` -- 6 bytes.
@rodata
final List<u8> pmmStrUsedL = const [
  u8(0x20), u8(0x55), u8(0x53), u8(0x45), u8(0x44), u8(0x20),
];

/// Shared separator: the free count as it stood immediately after init.
///
/// `" BASELINE "` -- 10 bytes.
@rodata
final List<u8> pmmStrBaseL = const [
  u8(0x20), u8(0x42), u8(0x41), u8(0x53), u8(0x45), u8(0x4C), u8(0x49), u8(0x4E), u8(0x45), u8(0x20),
];

/// Report line 4 head: lifetime successful allocations.
///
/// `"PMM ALLOCS "` -- 11 bytes.
@rodata
final List<u8> pmmStrAllocs = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x41), u8(0x4C), u8(0x4C), u8(0x4F), u8(0x43), u8(0x53), u8(0x20),
];

/// Shared separator: rejected operations counted since boot.
///
/// `" ERRORS "` -- 8 bytes.
@rodata
final List<u8> pmmStrErrorsL = const [
  u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x4F), u8(0x52), u8(0x53), u8(0x20),
];

/// Report: usable frames ABOVE the bound. Non-zero is the loud failure.
///
/// `" OVER "` -- 6 bytes.
@rodata
final List<u8> pmmStrOverL = const [
  u8(0x20), u8(0x4F), u8(0x56), u8(0x45), u8(0x52), u8(0x20),
];

/// Appended to the report when OVER is non-zero, so the truncation is a word and not just a number.
///
/// `" CAPPED"` -- 7 bytes.
@rodata
final List<u8> pmmStrCapped = const [
  u8(0x20), u8(0x43), u8(0x41), u8(0x50), u8(0x50), u8(0x45), u8(0x44),
];

/// `alloc` result head.
///
/// `"PMM ALLOC "` -- 10 bytes.
@rodata
final List<u8> pmmStrAlloc = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x41), u8(0x4C), u8(0x4C), u8(0x4F), u8(0x43), u8(0x20),
];

/// `free <addr>` result head.
///
/// `"PMM FREE "` -- 9 bytes.
@rodata
final List<u8> pmmStrFreeCmd = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x20),
];

/// Verdict: the check passed.
///
/// `"OK"` -- 2 bytes.
@rodata
final List<u8> pmmStrOk = const [
  u8(0x4F), u8(0x4B),
];

/// Verdict: the check failed.
///
/// `"FAIL"` -- 4 bytes.
@rodata
final List<u8> pmmStrFail = const [
  u8(0x46), u8(0x41), u8(0x49), u8(0x4C),
];

/// free: the address is not 4KiB-aligned.
///
/// `"ERR ALIGN"` -- 9 bytes.
@rodata
final List<u8> pmmStrErrAlign = const [
  u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x41), u8(0x4C), u8(0x49), u8(0x47), u8(0x4E),
];

/// free: the frame is outside the managed range.
///
/// `"ERR RANGE"` -- 9 bytes.
@rodata
final List<u8> pmmStrErrRange = const [
  u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x52), u8(0x41), u8(0x4E), u8(0x47), u8(0x45),
];

/// free: that frame is already free. The double-free this allocator must catch.
///
/// `"ERR DOUBLE"` -- 10 bytes.
@rodata
final List<u8> pmmStrErrDouble = const [
  u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x44), u8(0x4F), u8(0x55), u8(0x42), u8(0x4C), u8(0x45),
];

/// free: that frame was never allocatable (kernel image, low 1MiB, or a non-type-1 region).
///
/// `"ERR RESERVED"` -- 12 bytes.
@rodata
final List<u8> pmmStrErrRsvd = const [
  u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x52), u8(0x45), u8(0x53), u8(0x45), u8(0x52), u8(0x56), u8(0x45), u8(0x44),
];

// There is deliberately no `ERR PARSE` table. An unparseable argument to
// `free` prints the usage line instead, which says what a valid one looks
// like; a table with no call site would be dropped by the linker and could not
// satisfy the "every table's length is checked at its call site" discipline
// GAP-0060 exists for. Found by that check failing, not by review.

/// Any operation before pmmInit() ran. Should be unreachable; printed rather than assumed.
///
/// `"ERR NOTREADY"` -- 12 bytes.
@rodata
final List<u8> pmmStrErrReady = const [
  u8(0x45), u8(0x52), u8(0x52), u8(0x20), u8(0x4E), u8(0x4F), u8(0x54), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x59),
];

/// Self-test line head.
///
/// `"PMM TEST "` -- 9 bytes.
@rodata
final List<u8> pmmStrTest = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20),
];

/// Self-test: how many frames it took.
///
/// `"N "` -- 2 bytes.
@rodata
final List<u8> pmmStrTestN = const [
  u8(0x4E), u8(0x20),
];

/// Self-test: pairwise-distinctness verdict follows.
///
/// `" DISTINCT "` -- 10 bytes.
@rodata
final List<u8> pmmStrDist = const [
  u8(0x20), u8(0x44), u8(0x49), u8(0x53), u8(0x54), u8(0x49), u8(0x4E), u8(0x43), u8(0x54), u8(0x20),
];

/// Self-test: every frame inside a usable region verdict follows.
///
/// `" RANGE "` -- 7 bytes.
@rodata
final List<u8> pmmStrRangeL = const [
  u8(0x20), u8(0x52), u8(0x41), u8(0x4E), u8(0x47), u8(0x45), u8(0x20),
];

/// Self-test: write-then-read-back verdict follows.
///
/// `" RW "` -- 4 bytes.
@rodata
final List<u8> pmmStrRwL = const [
  u8(0x20), u8(0x52), u8(0x57), u8(0x20),
];

/// Self-test: how many frames it gave back.
///
/// `" FREED "` -- 7 bytes.
@rodata
final List<u8> pmmStrFreedL = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// Self-test overall verdict.
///
/// `"PASS"` -- 4 bytes.
@rodata
final List<u8> pmmStrPass = const [
  u8(0x50), u8(0x41), u8(0x53), u8(0x53),
];

/// The write/read-back proof line: address, then the value stored there.
///
/// `"PMM RW "` -- 7 bytes.
@rodata
final List<u8> pmmStrRw = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x52), u8(0x57), u8(0x20),
];

/// Exhaustion line head.
///
/// `"PMM DRAIN "` -- 10 bytes.
@rodata
final List<u8> pmmStrDrain = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x44), u8(0x52), u8(0x41), u8(0x49), u8(0x4E), u8(0x20),
];

/// Drain: allocations performed before the allocator said no.
///
/// `"TOOK "` -- 5 bytes.
@rodata
final List<u8> pmmStrTook = const [
  u8(0x54), u8(0x4F), u8(0x4F), u8(0x4B), u8(0x20),
];

/// Line label for the partial drain.
///
/// `"PMM LEAVE "` -- 10 bytes.
@rodata
final List<u8> pmmStrLeave = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x4C), u8(0x45), u8(0x41), u8(0x56), u8(0x45), u8(0x20),
];

/// Field label: how many free frames the caller asked to be left.
///
/// `"WANT "` -- 5 bytes.
@rodata
final List<u8> pmmStrWant = const [
  u8(0x57), u8(0x41), u8(0x4E), u8(0x54), u8(0x20),
];

/// Field separator. Distinct from [pmmStrTook], which has no leading
/// space because `frames drain` prints it immediately after its own label.
///
/// `" TOOK "` -- 6 bytes.
@rodata
final List<u8> pmmStrTookL = const [
  u8(0x20), u8(0x54), u8(0x4F), u8(0x4F), u8(0x4B), u8(0x20),
];

/// Drain: sum of every frame index handed out.
///
/// `" SUM "` -- 5 bytes.
@rodata
final List<u8> pmmStrSumL = const [
  u8(0x20), u8(0x53), u8(0x55), u8(0x4D), u8(0x20),
];

/// Drain: xor-fold of every frame index handed out.
///
/// `" XOR "` -- 5 bytes.
@rodata
final List<u8> pmmStrXorL = const [
  u8(0x20), u8(0x58), u8(0x4F), u8(0x52), u8(0x20),
];

/// Drain: lowest physical address handed out.
///
/// `"LOW "` -- 4 bytes.
@rodata
final List<u8> pmmStrLowL = const [
  u8(0x4C), u8(0x4F), u8(0x57), u8(0x20),
];

/// Drain: highest physical address handed out.
///
/// `" HIGH "` -- 6 bytes.
@rodata
final List<u8> pmmStrHighL = const [
  u8(0x20), u8(0x48), u8(0x49), u8(0x47), u8(0x48), u8(0x20),
];

/// Drain: the highest frame handed out is written and read back, proving the
/// identity map really reaches the allocator's bound.
///
/// `"TOUCH "` -- 6 bytes.
@rodata
final List<u8> pmmStrTouch = const [
  u8(0x54), u8(0x4F), u8(0x55), u8(0x43), u8(0x48), u8(0x20),
];

/// Drain: the verdict of the allocation attempted AFTER exhaustion.
///
/// `"NEXT "` -- 5 bytes.
@rodata
final List<u8> pmmStrNextL = const [
  u8(0x4E), u8(0x45), u8(0x58), u8(0x54), u8(0x20),
];

/// Refill line head.
///
/// `"PMM REFILL "` -- 11 bytes.
@rodata
final List<u8> pmmStrRefill = const [
  u8(0x50), u8(0x4D), u8(0x4D), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x49), u8(0x4C), u8(0x4C), u8(0x20),
];

/// Refill: frames handed back.
///
/// `"GAVE "` -- 5 bytes.
@rodata
final List<u8> pmmStrGave = const [
  u8(0x47), u8(0x41), u8(0x56), u8(0x45), u8(0x20),
];

/// The usage line, printed for `frames <anything this shell cannot parse>`.
///
/// TWO LINES since the shakedown added `frames leave <n>`: one line carrying
/// five forms would be 85 columns, and this shell is read on an 80-column VGA
/// text console. The continuation is indented to the width of `frames: usage: `
/// so the forms line up, which is the shape `procStrUsage2` already uses.
///
/// `"frames: usage: frames | frames test | frames drain | frames refill\n        frames leave <n>\n"` -- 92 bytes.
@rodata
final List<u8> pmmStrUsage = const [
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67),
  u8(0x65), u8(0x3A), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x7C), u8(0x20),
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20),
  u8(0x7C), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x64), u8(0x72), u8(0x61),
  u8(0x69), u8(0x6E), u8(0x20), u8(0x7C), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20),
  u8(0x72), u8(0x65), u8(0x66), u8(0x69), u8(0x6C), u8(0x6C), u8(0x0A), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x20), u8(0x20), u8(0x20), u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x6C), u8(0x65),
  u8(0x61), u8(0x76), u8(0x65), u8(0x20), u8(0x3C), u8(0x6E), u8(0x3E), u8(0x0A),
];

/// `free` with no argument or an unparseable one.
///
/// `"free: usage: free <physical address in hex>\n"` -- 44 bytes.
@rodata
final List<u8> pmmStrFreeUsage = const [
  u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A),
  u8(0x20), u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20), u8(0x3C), u8(0x70), u8(0x68), u8(0x79), u8(0x73), u8(0x69),
  u8(0x63), u8(0x61), u8(0x6C), u8(0x20), u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x20),
  u8(0x69), u8(0x6E), u8(0x20), u8(0x68), u8(0x65), u8(0x78), u8(0x3E), u8(0x0A),
];

/// Command name, matched both exactly and as a prefix.
///
/// `"frames"` -- 6 bytes.
@rodata
final List<u8> pmmCmdFrames = const [
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73),
];

/// Whole-line command name -- there is no tokenizer (GAP-0057 item 3).
///
/// `"frames test"` -- 11 bytes.
@rodata
final List<u8> pmmCmdTest = const [
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x74), u8(0x65), u8(0x73), u8(0x74),
];

/// Whole-line command name.
///
/// `"frames drain"` -- 12 bytes.
@rodata
final List<u8> pmmCmdDrain = const [
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x64), u8(0x72), u8(0x61), u8(0x69), u8(0x6E),
];

/// Command name matched as a PREFIX -- a hex frame count follows it.
///
/// `"frames leave "` -- 13 bytes.
@rodata
final List<u8> pmmCmdLeaveSp = const [
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x6C), u8(0x65), u8(0x61), u8(0x76), u8(0x65),
  u8(0x20),
];

/// Whole-line command name.
///
/// `"frames refill"` -- 13 bytes.
@rodata
final List<u8> pmmCmdRefill = const [
  u8(0x66), u8(0x72), u8(0x61), u8(0x6D), u8(0x65), u8(0x73), u8(0x20), u8(0x72), u8(0x65), u8(0x66), u8(0x69), u8(0x6C),
  u8(0x6C),
];

/// Whole-line command name.
///
/// `"alloc"` -- 5 bytes.
@rodata
final List<u8> pmmCmdAlloc = const [
  u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F), u8(0x63),
];

/// Command name matched as a PREFIX -- a physical address follows it.
///
/// `"free "` -- 5 bytes.
@rodata
final List<u8> pmmCmdFree = const [
  u8(0x66), u8(0x72), u8(0x65), u8(0x65), u8(0x20),
];


// ---------------------------------------------------------------------------
// Geometry. Every one of these is asserted somewhere: the frame size and the
// bound by `tests/conformance/m7-frames/run.sh`'s structural checks, the block
// layout by `pmm_store`'s own `.size` directive in core/boot/kdata.S.
// ---------------------------------------------------------------------------

/// log2 of the frame size. A physical address is `frame << pmmFrameShift`.
const int pmmFrameShift = 12;

/// Bytes per frame. 4KiB, the x86-64 base page size.
const int pmmFrameBytes = 4096;

/// `pmmFrameBytes - 1`, as its own constant, and `pmmFrameBytes - 8`, likewise.
///
/// **Spelled out rather than computed, because `dcc` at `DCDART_PIN.txt`'s
/// commit refuses the computed form.** `u64(pmmFrameBytes - 1)` is rejected
/// with
///
///     DccLowerError: "pmmInit": a Instance of 'DCInt' literal constructed
///     from a non-constant expression InstanceInvocation(...4096.-(1)...)
///     -- the argument must be an integer literal or a compile-time integer
///     constant
///
/// which is a clear, named error rather than a miscompile. DCDart commit
/// `fbd21e4` ("Fold compile-time integer arithmetic in sized-int literals",
/// ADR-0046) fixes it upstream and was not taken for this milestone -- the pin
/// moved exactly as far as the nested-`while` fix and no further (ADR-0011
/// section 7). Recorded in docs/known-gaps.md GAP-0077.
const int pmmFrameMask = 4095;
const int pmmFrameLastWord = 4088;

/// Frames this allocator will manage, and refuse to exceed. 65536 frames is
/// 256MiB, which is an 8192-byte bitmap and is exactly what `core/boot/boot.S`
/// identity-maps (`MAP_2MIB_PAGES` = 128). ADR-0155 raised this with the
/// identity map so a named platform process can plant the full 189 MiB CEF
/// `.text` window. See this file's header.
const int pmmMaxFrames = 65536;

/// Bytes of bitmap: one bit per frame. Two pages.
const int pmmBitmapBytes = 8192;

/// The bound expressed as MiB, for the report.
const int pmmBoundMib = 256;

/// Byte offsets inside the one donated block.
const int pmmMetaOffset = 8192;
const int pmmLedgerOffset = 8256;

/// Total donated bytes: bitmap + metadata + ledger.
const int pmmStoreBytes = 8768;

/// Metadata block: eight `u64` words at [pmmMetaOffset].
const int pmmMetaBytes = 64;

/// Self-test ledger: [pmmLedgerN] physical addresses.
const int pmmLedgerN = 64;
const int pmmLedgerBytes = 512;

/// Frames below 1MiB, reserved unconditionally. See this file's header.
const int pmmLowReserved = 256;

// Metadata word indices.
const int pmmMetaReady = 0;
const int pmmMetaManaged = 1;
const int pmmMetaFree = 2;
const int pmmMetaBaseline = 3;
const int pmmMetaCursor = 4;
const int pmmMetaOver = 5;
const int pmmMetaErrors = 6;
const int pmmMetaAllocs = 7;

// [freeFrame] status codes. `u64` rather than an enum because DCDart `@bare`
// has neither enums nor booleans (GAP-0023).
const int pmmFreeOk = 0;
const int pmmFreeNotReady = 1;
const int pmmFreeAlign = 2;
const int pmmFreeRange = 3;
const int pmmFreeReserved = 4;
const int pmmFreeDouble = 5;

// ---------------------------------------------------------------------------
// ===========================  THE STORAGE SEAM  ============================
//
// The ONLY three functions in this kernel that know where the allocator's
// mutable state lives, and the ONLY call sites of `pmm_store_addr`.
//
// Read this file's header before changing anything here. Adding a fourth call
// site, or a second `@extern` accessor for allocator state, is the change that
// turns the mutable-statics migration from three functions into an audit.
// ---------------------------------------------------------------------------

/// The 8768-byte block that holds the entire allocator, as a DCDart mutable
/// static (ADR-0021, DCDart ADR-0051).
///
/// Until M17 this was `pmm_store` in `core/boot/kdata.S`, reached through an
/// `@extern u64 pmm_store_addr()`. DCDart grew `@bss`, so the storage is now
/// declared here, in the file that owns it, and the assembly and its accessor
/// are gone. The three functions below are unchanged in name, arity and
/// meaning — only the expression they return moved, which is exactly what
/// ADR-0011 §0 promised.
@bss
final Bss pmmStore = const Bss(bytes: pmmStoreBytes);

/// Base of the frame bitmap: one bit per frame, 1 = used or reserved.
@bare
u64 pmmBitmapBase() {
  return Bss.addressOf(pmmStore);
}

/// Base of the eight-word metadata block.
@bare
u64 pmmMetaBase() {
  return Bss.addressOf(pmmStore) + u64(pmmMetaOffset);
}

/// Base of the self-test's 64-entry allocation ledger.
@bare
u64 pmmLedgerBase() {
  return Bss.addressOf(pmmStore) + u64(pmmLedgerOffset);
}

// ======================  END OF THE STORAGE SEAM  ==========================

/// First byte of the loaded kernel image, from `core/link/kernel.ld`.
///
/// NOT storage -- a link-time constant, which is why it is not behind the seam
/// above. Read from the linker script rather than hardcoded because `.text`,
/// `.rodata` and `.bss` all move whenever anything is added to this kernel.
@extern
external u64 kernel_image_start();

/// One past the last byte of the image, AFTER `.bss` -- so it covers the boot
/// stack, the page tables and this allocator's own bitmap.
@extern
external u64 kernel_image_end();

// ---------------------------------------------------------------------------
// Metadata and bitmap primitives. Everything below goes through the seam.
// ---------------------------------------------------------------------------

/// Reads metadata word [i].
@bare
u64 pmmMeta(u64 i) {
  return Pointer<u64>.fromAddress(pmmMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void pmmSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(pmmMetaBase() + (i << u64(3))).value = v;
}

/// Counts one rejected operation. Every path that refuses to do something calls
/// this, so `frames` reporting `ERRORS 00000000` is a claim and not a default.
@bare
void pmmError() {
  pmmSetMeta(u64(pmmMetaErrors), pmmMeta(u64(pmmMetaErrors)) + u64(1));
}

/// 1 if frame [f] is marked used or reserved, 0 if it is free.
@bare
u64 pmmBitGet(u64 f) {
  final u8 b = Pointer<u8>.fromAddress(pmmBitmapBase() + (f >> u64(3))).value;
  return (b.toU64() >> (f & u64(7))) & u64(1);
}

/// Marks frame [f] used.
@bare
void pmmBitSet(u64 f) {
  final u64 a = pmmBitmapBase() + (f >> u64(3));
  final u8 old = Pointer<u8>.fromAddress(a).value;
  Pointer<u8>.fromAddress(a).value = old | (u64(1) << (f & u64(7))).toU8();
}

/// Marks frame [f] free.
@bare
void pmmBitClear(u64 f) {
  final u64 a = pmmBitmapBase() + (f >> u64(3));
  final u8 old = Pointer<u8>.fromAddress(a).value;
  Pointer<u8>.fromAddress(a).value = old & (u64(0xFF) ^ (u64(1) << (f & u64(7)))).toU8();
}

/// Reads ledger slot [i].
@bare
u64 pmmLedger(u64 i) {
  return Pointer<u64>.fromAddress(pmmLedgerBase() + (i << u64(3))).value;
}

/// Writes ledger slot [i].
@bare
void pmmSetLedger(u64 i, u64 v) {
  Pointer<u64>.fromAddress(pmmLedgerBase() + (i << u64(3))).value = v;
}

// ---------------------------------------------------------------------------
// The memory map, consulted rather than remembered.
// ---------------------------------------------------------------------------

/// The Multiboot information-structure pointer, from the shell's stash.
///
/// [shellInit] copies it there out of `kmain`'s argument, which is why
/// [pmmInit] must run after [shellInit] -- `kmain()` says so at both call
/// sites.
@bare
u64 pmmInfo() {
  return Pointer<u64>.fromAddress(shell_mbinfo_addr()).value;
}

/// 1 if frame [f] lies WHOLLY inside a type-1 (usable) region of the Multiboot
/// memory map, else 0.
///
/// Wholly, not partly: a frame that straddles the end of a usable region
/// contains bytes the loader did not vouch for, and half a page is not a page.
/// The last frame of the `0x00000000..0x0009FC00` region is exactly that case
/// on every QEMU boot this kernel is tested on.
///
/// **Deliberately re-walks the map on every call.** It is called once per
/// [freeFrame] (seven entries, a few loads) and once per frame by
/// [shellFramesRefill]. Caching it would need somewhere to put a parsed copy of
/// the memory map, which is the same missing thing this milestone is closing
/// for frames -- and a second copy of the map that could disagree with the
/// first is a worse bug than a slow loop. GAP-0076 item 8.
///
/// This is ALSO the predicate [pmmInit] marks with, expressed a second way --
/// init walks regions and frees ranges, this asks about one frame. The two
/// implementations check each other: `frames refill` frees exactly what this
/// says is allocatable, and the harness asserts the free count returns to the
/// baseline init computed. If they disagreed, that assertion fails.
@bare
u64 pmmInUsable(u64 f) {
  final u64 info = pmmInfo();
  if ((info & u64(3)) > u64(0)) {
    return u64(0);
  }
  final u8 flagsLow = Pointer<u8>.fromAddress(info).value;
  if ((flagsLow & u8(0x40)) < u8(1)) {
    return u64(0); // no memory map at all
  }
  final u64 mmapLen = mbU32(info + u64(44));
  final u64 mmapAddr = mbU32(info + u64(48));
  if ((mmapAddr & u64(3)) > u64(0)) {
    return u64(0);
  }
  final u64 lo = f << u64(pmmFrameShift);
  u64 off = u64(0);
  while (off < mmapLen) {
    final u64 entry = mmapAddr + off;
    if ((entry & u64(3)) > u64(0)) {
      return u64(0);
    }
    final u64 size = mbU32(entry);
    if (size < u64(1)) {
      return u64(0); // a zero-size entry would make this walk never advance
    }
    if (mbU32(entry + u64(20)) == u64(1)) {
      final u64 base = mbU32(entry + u64(4)) + (mbU32(entry + u64(8)) << u64(32));
      final u64 len = mbU32(entry + u64(12)) + (mbU32(entry + u64(16)) << u64(32));
      if (base <= lo) {
        // `lo - base` cannot underflow here, and `delta + pmmFrameBytes`
        // cannot overflow for any address this machine can express. Written
        // as a subtraction and an add rather than `lo + 4096 <= base + len`
        // on purpose: DCDart traps on overflow (DCDART_SPEC 4.1), and
        // `base + len` for a region at the top of the address space would be
        // a real trap in the middle of a predicate.
        final u64 delta = lo - base;
        if (len >= delta + u64(pmmFrameBytes)) {
          return u64(1);
        }
      }
    }
    off = off + size + u64(4);
  }
  return u64(0);
}

/// 1 if frame [f] overlaps the loaded kernel image at all.
@bare
u64 pmmHitsKernel(u64 f) {
  final u64 lo = f << u64(pmmFrameShift);
  if (lo + u64(pmmFrameBytes) <= kernel_image_start()) {
    return u64(0);
  }
  if (lo >= kernel_image_end()) {
    return u64(0);
  }
  return u64(1);
}

/// 1 if frame [f] is one this allocator may ever hand out.
///
/// The single predicate three different operations agree on: what [pmmInit]
/// leaves free, what [freeFrame] will accept back, and what
/// [shellFramesRefill] walks. A frame that fails this can never be allocated
/// and can never be freed, which is what makes `free` of a reserved address a
/// diagnosable error rather than silent bitmap corruption.
@bare
u64 pmmAllocatable(u64 f) {
  if (f < u64(pmmLowReserved)) {
    return u64(0); // the first megabyte is never handed out
  }
  if (f >= u64(pmmMaxFrames)) {
    return u64(0);
  }
  if (pmmHitsKernel(f) > u64(0)) {
    return u64(0);
  }
  // M8 (ADR-0012). The kernel's own page tables come out of THIS allocator, so
  // they are the first memory the kernel cannot afford to lose that is not
  // inside `[__kernel_start, __kernel_end)`. Without this clause
  // `free <page-table-frame>` would hand the running address space back, and
  // `frames refill` -- which frees everything that was ever allocatable --
  // would free all six of them, after which the next `frames drain` would write
  // test patterns into the live PML4.
  //
  // The predicate is asked of `core/kernel/vm.dart` rather than answered from a
  // word in this file's metadata block, because the set of frames is VM state
  // and belongs behind the VM's own storage seam. It is at most six word
  // comparisons and it answers 0 for every frame until `vmInit()` has taken
  // one, so `pmmInit()` -- which runs first and does not consult this function
  // at all -- is unaffected.
  if (vmHoldsFrame(f) > u64(0)) {
    return u64(0);
  }
  return pmmInUsable(f);
}

/// Re-takes the baseline free count. **Called once, by `vmInit()`.**
///
/// BASELINE means "the number `FREE` should return to when nothing is leaked",
/// and `pmmInit` sets it to the free count of a completely untouched allocator.
/// M8 then permanently spends six frames on the kernel's page tables, which is
/// not a leak -- it is the address space, and `pmmAllocatable` refuses to hand
/// those frames out or take them back. Leaving BASELINE at the pre-paging
/// number would make `frames refill` report `FREE` six short of `BASELINE`
/// forever, and the "free returns to baseline exactly" assertion that gives
/// M7's drain/refill cycle its meaning would be measuring the wrong thing.
///
/// It is a function here rather than a `pmmSetMeta` call in `vm.dart` so that
/// the metadata word indices stay private to this file -- the same reason
/// `vm.dart` does not read the bitmap directly.
@bare
void pmmRebaseline() {
  pmmSetMeta(u64(pmmMetaBaseline), pmmMeta(u64(pmmMetaFree)));
}

// ---------------------------------------------------------------------------
// Initialisation.
// ---------------------------------------------------------------------------

/// Builds the frame bitmap from the Multiboot memory map. Prints NOTHING.
///
/// Called from `kmain()` after [shellInit] (which stashes the Multiboot
/// pointer this reads) and before the first byte of M0's banner, so no golden
/// moves. Nothing in this kernel zeroes `.bss`, so this function giving every
/// byte of the donated block a known value is a correctness requirement, not
/// hygiene -- exactly the argument `vgaInit`, `shellInit` and `fbInit` already
/// make for their own words.
///
/// **All-reserved first, then free the usable regions into it.** The bitmap is
/// filled with 0xFF before anything is examined, so any frame the loader did
/// not explicitly vouch for stays reserved. That is the safe direction to be
/// wrong in: a bitmap read as free by accident hands out the kernel's own
/// image.
///
/// The region walk is a `while` inside a `while` -- entries outside, frames
/// inside. GAP-0068 named this exact shape as the thing its workaround would
/// cost, which is why `DCDART_PIN.txt` moved to `e3cfe18` for this milestone.
@bare
void pmmInit() {
  // 1. Everything reserved.
  final u64 bm = pmmBitmapBase();
  u64 i = u64(0);
  while (i < u64(pmmBitmapBytes)) {
    Pointer<u8>.fromAddress(bm + i).value = u8(0xFF);
    i = i + u64(1);
  }
  pmmSetMeta(u64(pmmMetaReady), u64(0));
  pmmSetMeta(u64(pmmMetaManaged), u64(pmmMaxFrames));
  pmmSetMeta(u64(pmmMetaFree), u64(0));
  pmmSetMeta(u64(pmmMetaBaseline), u64(0));
  pmmSetMeta(u64(pmmMetaCursor), u64(0));
  pmmSetMeta(u64(pmmMetaOver), u64(0));
  pmmSetMeta(u64(pmmMetaErrors), u64(0));
  pmmSetMeta(u64(pmmMetaAllocs), u64(0));

  // 2. Free every whole frame inside a type-1 region. The structural guards
  //    are the same ones `mbReport` and `mbUsableTotal` apply, in the same
  //    order: a malformed hand-off leaves the bitmap all-reserved, which is an
  //    allocator that refuses to allocate rather than one that corrupts.
  final u64 info = pmmInfo();
  u64 over = u64(0);
  if ((info & u64(3)) < u64(1)) {
    final u8 flagsLow = Pointer<u8>.fromAddress(info).value;
    if ((flagsLow & u8(0x40)) > u8(0)) {
      final u64 mmapLen = mbU32(info + u64(44));
      final u64 mmapAddr = mbU32(info + u64(48));
      if ((mmapAddr & u64(3)) < u64(1)) {
        u64 off = u64(0);
        while (off < mmapLen) {
          final u64 entry = mmapAddr + off;
          if ((entry & u64(3)) > u64(0)) {
            off = mmapLen; // structurally broken: stop, leave the rest reserved
          } else {
            final u64 size = mbU32(entry);
            if (size < u64(1)) {
              off = mmapLen; // a zero-size entry would never advance the walk
            } else {
              if (mbU32(entry + u64(20)) == u64(1)) {
                final u64 base =
                    mbU32(entry + u64(4)) + (mbU32(entry + u64(8)) << u64(32));
                final u64 len =
                    mbU32(entry + u64(12)) + (mbU32(entry + u64(16)) << u64(32));
                // First WHOLE frame at or after `base`, and one past the last
                // whole frame that fits inside the region.
                final u64 first =
                    (base + u64(pmmFrameMask)) >> u64(pmmFrameShift);
                u64 lastEx = (base + len) >> u64(pmmFrameShift);
                if (lastEx > first) {
                  if (first >= u64(pmmMaxFrames)) {
                    // Entirely above the bound: counted, never marked.
                    over = over + (lastEx - first);
                    lastEx = first;
                  } else {
                    if (lastEx > u64(pmmMaxFrames)) {
                      over = over + (lastEx - u64(pmmMaxFrames));
                      lastEx = u64(pmmMaxFrames);
                    }
                  }
                  u64 f = first;
                  while (f < lastEx) {
                    pmmBitClear(f);
                    f = f + u64(1);
                  }
                }
              }
              off = off + size + u64(4);
            }
          }
        }
      }
    }
  }

  // 3. Take back the first megabyte and the kernel's own image. Both are
  //    inside type-1 regions the step above just freed, which is precisely why
  //    they have to be taken back explicitly.
  u64 f = u64(0);
  while (f < u64(pmmLowReserved)) {
    pmmBitSet(f);
    f = f + u64(1);
  }
  final u64 kFirst = kernel_image_start() >> u64(pmmFrameShift);
  u64 kLastEx = (kernel_image_end() + u64(pmmFrameMask)) >> u64(pmmFrameShift);
  if (kLastEx > u64(pmmMaxFrames)) {
    kLastEx = u64(pmmMaxFrames);
  }
  f = kFirst;
  while (f < kLastEx) {
    pmmBitSet(f);
    f = f + u64(1);
  }

  // 4. Count what is left, by reading the bitmap back rather than by keeping a
  //    running total through steps 2 and 3. A running total would double-count
  //    every frame step 3 takes back and would be a second source of truth;
  //    counting the bitmap makes the bitmap the only one.
  u64 freeCount = u64(0);
  f = u64(0);
  while (f < u64(pmmMaxFrames)) {
    if (pmmBitGet(f) < u64(1)) {
      freeCount = freeCount + u64(1);
    }
    f = f + u64(1);
  }
  pmmSetMeta(u64(pmmMetaFree), freeCount);
  pmmSetMeta(u64(pmmMetaBaseline), freeCount);
  pmmSetMeta(u64(pmmMetaOver), over);
  pmmSetMeta(u64(pmmMetaReady), u64(1));
}

// ---------------------------------------------------------------------------
// Allocate and free.
// ---------------------------------------------------------------------------

/// Index of the first free frame in `[from, toEx)`, or [pmmMaxFrames] if there
/// is none. [pmmMaxFrames] is not a valid index, so it needs no sentinel
/// arithmetic and cannot be confused with a result.
@bare
u64 pmmScan(u64 from, u64 toEx) {
  u64 f = from;
  while (f < toEx) {
    if (pmmBitGet(f) < u64(1)) {
      return f;
    }
    f = f + u64(1);
  }
  return u64(pmmMaxFrames);
}

/// Allocates one frame. Returns its PHYSICAL ADDRESS, or **0 on failure**.
///
/// **0 is an unambiguous failure value here and that is a design consequence,
/// not a convention.** Frame 0 is inside the first megabyte, which this
/// allocator reserves unconditionally (see the header), so a successful
/// allocation can never be physical address 0. Every caller tests `< 1`.
///
/// Search is next-fit from a cursor rather than first-fit from zero: draining
/// 32768 frames first-fit is quadratic in the number of frames and takes
/// visible seconds under emulation, and the cursor makes it linear. On
/// exhaustion the scan wraps once and then gives up, so a full drain is exactly
/// one pass over the bitmap plus one wrap.
///
/// Exhaustion is NOT counted as an error -- it is the allocator working. Being
/// called before [pmmInit] is.
@bare
u64 allocFrame() {
  if (pmmMeta(u64(pmmMetaReady)) < u64(1)) {
    pmmError();
    return u64(0);
  }
  final u64 managed = pmmMeta(u64(pmmMetaManaged));
  final u64 cursor = pmmMeta(u64(pmmMetaCursor));
  u64 f = pmmScan(cursor, managed);
  if (f >= u64(pmmMaxFrames)) {
    f = pmmScan(u64(0), cursor);
  }
  if (f >= u64(pmmMaxFrames)) {
    return u64(0); // genuinely out of frames
  }
  pmmBitSet(f);
  pmmSetMeta(u64(pmmMetaFree), pmmMeta(u64(pmmMetaFree)) - u64(1));
  pmmSetMeta(u64(pmmMetaCursor), f + u64(1));
  pmmSetMeta(u64(pmmMetaAllocs), pmmMeta(u64(pmmMetaAllocs)) + u64(1));
  return f << u64(pmmFrameShift);
}

/// Frees the frame at physical address [addr]. Returns a `pmmFree*` code.
///
/// Four things are refused, each with its own code, and NONE of them touches
/// the bitmap:
///
///   * an address that is not frame-aligned -- the low bits would be silently
///     discarded by the shift, so `free 1001` would free frame 1;
///   * a frame outside the managed range;
///   * a frame that is not allocatable at all -- the kernel image, the first
///     megabyte, or anything the memory map does not call usable. Without this
///     check `free 100000` would mark a kernel-image frame free and the next
///     `alloc` would hand out the running kernel;
///   * a frame that is already free. **This is the double-free**, and catching
///     it is why the free count can be trusted at all: without it, freeing the
///     same frame twice would increment the count twice and the allocator would
///     believe it had more memory than exists.
@bare
u64 freeFrame(u64 addr) {
  if (pmmMeta(u64(pmmMetaReady)) < u64(1)) {
    pmmError();
    return u64(pmmFreeNotReady);
  }
  if ((addr & u64(pmmFrameMask)) > u64(0)) {
    pmmError();
    return u64(pmmFreeAlign);
  }
  // ---- M21: THE ONE BRANCH THAT MAKES SHARING SAFE ----
  //
  // A frame that belongs to a LIVE SHARED REGION is not this caller's to give
  // back, however it reached this function. `docs/design/memory.md` §2.1 works
  // the hazard through: A and B both map frame F, A exits, `procSpaceFree(A)`
  // sees F present in A's table and releases it, F is handed to somebody else,
  // and B is still writing it. The double-free check below catches B's LATER
  // free and reports it loudly -- but the corruption happened between the two,
  // and nothing detects that. So the fix is not to catch the second free; it is
  // to stop the FIRST from releasing a frame somebody still maps.
  //
  // HERE AND NOWHERE ELSE, because five paths give a frame back -- procSpaceFree,
  // heapRollback, elfUnload, shellFree and `frames refill` -- and all five
  // funnel through this function. Putting the guard in `procSpaceFree` would
  // need the same change in four more places and would still miss one
  // (memory.md §2.2).
  //
  // AFTER `ready` and AFTER the alignment check, which is also memory.md §2.2's
  // instruction and is not stylistic: the guard is keyed by frame number, and
  // an unaligned address must never be allowed to compute one. `free 1001` has
  // to keep being `pmmFreeAlign`, which `m7-frames` asserts.
  //
  // RETURNS `pmmFreeOk` AND FREES NOTHING. It cannot return a new code: every
  // caller in this kernel ADDS this status to a running error counter, which
  // works only because `pmmFreeOk == 0` (ADR-0011 §4, memory.md §2.3). A
  // distinct code would silently start adding a non-zero number to
  // `procHeadErrors` at four call sites. The retention is made visible in the
  // shared-memory subsystem's own counters instead -- and `procSpaceFree` asks
  // `shmFrameShared` itself, BEFORE calling this, so that it does not COUNT
  // what it did not free.
  if (shmFrameShared(addr) > u64(0)) {
    shmBumpMeta(u64(shmMetaRetained));
    return u64(pmmFreeOk);
  }
  final u64 f = addr >> u64(pmmFrameShift);
  if (f >= pmmMeta(u64(pmmMetaManaged))) {
    pmmError();
    return u64(pmmFreeRange);
  }
  if (pmmAllocatable(f) < u64(1)) {
    pmmError();
    return u64(pmmFreeReserved);
  }
  if (pmmBitGet(f) < u64(1)) {
    pmmError();
    return u64(pmmFreeDouble);
  }
  pmmBitClear(f);
  pmmSetMeta(u64(pmmMetaFree), pmmMeta(u64(pmmMetaFree)) + u64(1));
  return u64(pmmFreeOk);
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// Prints `OK` or `FAIL` for a 1/0 verdict. `u64` rather than `bool` because
/// DCDart `@bare` has no boolean operators at all (GAP-0023).
@bare
void pmmVerdict(u64 ok) {
  if (ok > u64(0)) {
    uartWrite(Rodata.addressOf(pmmStrOk), u64(2));
    return;
  }
  uartWrite(Rodata.addressOf(pmmStrFail), u64(4));
}

/// `frames` -- four lines describing the allocator and its own footprint.
///
///     PMM BASE 000000000010F1C0 STORE 00001240 BITMAP 00001000 META 00000040 LEDGER 00000200
///     PMM BOUND 00008000 FRAME 00001000 LIMIT 00000080 MIB
///     PMM MANAGED 00008000 FREE 00007C9F USED 00000361 BASELINE 00007C9F
///     PMM ALLOCS 0000000000000000 ERRORS 00000000 OVER 00000000
///
/// `PMM BASE` is the storage seam's address, printed so it can be checked from
/// OUTSIDE: `tests/conformance/m7-frames/run.sh` reads `pmm_store`'s link-time
/// address out of `kernel.elf` and asserts the kernel printed the same number,
/// then dumps the bitmap out of guest memory there.
///
/// `OVER` is the loud half of the bound. Non-zero means the machine has usable
/// RAM this allocator refuses to manage, and ` CAPPED` is appended so the line
/// says so in a word as well as a number.
@bare
void shellFrames() {
  uartWrite(Rodata.addressOf(pmmStrBase), u64(9));
  // Through the seam, NOT through `pmm_store_addr()` directly -- a fourth
  // call site outside the seam is exactly what this file's header forbids, and
  // `tests/conformance/m7-frames/run.sh` counts them. The bitmap's base is
  // also the block's base, and the bitmap is what the harness dumps.
  uartPutHex(pmmBitmapBase(), u64(16));
  uartWrite(Rodata.addressOf(pmmStrStore), u64(7));
  uartPutHex(u64(pmmStoreBytes), u64(8));
  uartWrite(Rodata.addressOf(pmmStrBitmap), u64(8));
  uartPutHex(u64(pmmBitmapBytes), u64(8));
  uartWrite(Rodata.addressOf(pmmStrMeta), u64(6));
  uartPutHex(u64(pmmMetaBytes), u64(8));
  uartWrite(Rodata.addressOf(pmmStrLedger), u64(8));
  uartPutHex(u64(pmmLedgerBytes), u64(8));
  uartNewline();

  uartWrite(Rodata.addressOf(pmmStrBound), u64(10));
  uartPutHex(u64(pmmMaxFrames), u64(8));
  uartWrite(Rodata.addressOf(pmmStrFrame), u64(7));
  uartPutHex(u64(pmmFrameBytes), u64(8));
  uartWrite(Rodata.addressOf(pmmStrLimit), u64(7));
  uartPutHex(u64(pmmBoundMib), u64(8));
  uartWrite(Rodata.addressOf(pmmStrMib), u64(4));
  uartNewline();

  final u64 managed = pmmMeta(u64(pmmMetaManaged));
  final u64 free = pmmMeta(u64(pmmMetaFree));
  uartWrite(Rodata.addressOf(pmmStrManaged), u64(12));
  uartPutHex(managed, u64(8));
  uartWrite(Rodata.addressOf(pmmStrFreeL), u64(6));
  uartPutHex(free, u64(8));
  uartWrite(Rodata.addressOf(pmmStrUsedL), u64(6));
  uartPutHex(managed - free, u64(8));
  uartWrite(Rodata.addressOf(pmmStrBaseL), u64(10));
  uartPutHex(pmmMeta(u64(pmmMetaBaseline)), u64(8));
  uartNewline();

  final u64 over = pmmMeta(u64(pmmMetaOver));
  uartWrite(Rodata.addressOf(pmmStrAllocs), u64(11));
  uartPutHex(pmmMeta(u64(pmmMetaAllocs)), u64(16));
  uartWrite(Rodata.addressOf(pmmStrErrorsL), u64(8));
  uartPutHex(pmmMeta(u64(pmmMetaErrors)), u64(8));
  uartWrite(Rodata.addressOf(pmmStrOverL), u64(6));
  uartPutHex(over, u64(8));
  if (over > u64(0)) {
    uartWrite(Rodata.addressOf(pmmStrCapped), u64(7));
  }
  uartNewline();
}

// ---------------------------------------------------------------------------
// `alloc` and `free <addr>` -- so a human can drive the allocator by hand.
// ---------------------------------------------------------------------------

/// `alloc` -- take one frame and print its physical address.
@bare
void shellAlloc() {
  final u64 a = allocFrame();
  uartWrite(Rodata.addressOf(pmmStrAlloc), u64(10));
  if (a < u64(1)) {
    uartWrite(Rodata.addressOf(pmmStrFail), u64(4));
    uartNewline();
    return;
  }
  uartPutHex(a, u64(16));
  uartNewline();
}

/// Prints the outcome of one [freeFrame] call.
@bare
void pmmFreeStatus(u64 code) {
  if (code == u64(pmmFreeOk)) {
    uartWrite(Rodata.addressOf(pmmStrOk), u64(2));
    return;
  }
  if (code == u64(pmmFreeAlign)) {
    uartWrite(Rodata.addressOf(pmmStrErrAlign), u64(9));
    return;
  }
  if (code == u64(pmmFreeRange)) {
    uartWrite(Rodata.addressOf(pmmStrErrRange), u64(9));
    return;
  }
  if (code == u64(pmmFreeReserved)) {
    uartWrite(Rodata.addressOf(pmmStrErrRsvd), u64(12));
    return;
  }
  if (code == u64(pmmFreeDouble)) {
    uartWrite(Rodata.addressOf(pmmStrErrDouble), u64(10));
    return;
  }
  uartWrite(Rodata.addressOf(pmmStrErrReady), u64(12));
}

/// 1 if the line from [from] to the end is 1..16 hex digits, else 0.
///
/// A separate pass from [pmmHexValue] rather than one pass with a sentinel,
/// because every 64-bit value is a possible address and there is no value left
/// over to mean "that was not a number." `pciFindName`'s two passes are the
/// same idiom for the same reason.
@bare
u64 pmmHexOk(u64 from) {
  final u64 len = shellLen();
  if (len < from + u64(1)) {
    return u64(0);
  }
  if (len - from > u64(16)) {
    return u64(0);
  }
  u64 i = from;
  while (i < len) {
    if (ataHexDigit(shellLineByte(i)) > u64(0xF)) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

/// The value of the hex digits from [from] to the end. Call [pmmHexOk] first.
@bare
u64 pmmHexValue(u64 from) {
  final u64 len = shellLen();
  u64 v = u64(0);
  u64 i = from;
  while (i < len) {
    v = (v << u64(4)) | ataHexDigit(shellLineByte(i));
    i = i + u64(1);
  }
  return v;
}

/// `free <addr>` -- give one frame back, by physical address.
@bare
void shellFreeCmd() {
  if (pmmHexOk(u64(5)) < u64(1)) {
    uartWrite(Rodata.addressOf(pmmStrFreeUsage), u64(44));
    return;
  }
  final u64 addr = pmmHexValue(u64(5));
  final u64 code = freeFrame(addr);
  uartWrite(Rodata.addressOf(pmmStrFreeCmd), u64(9));
  uartPutHex(addr, u64(16));
  uartSpace();
  pmmFreeStatus(code);
  uartNewline();
}

// ---------------------------------------------------------------------------
// `frames test` -- the self-test.
// ---------------------------------------------------------------------------

/// Allocates up to [pmmLedgerN] frames into the ledger, returning how many it
/// got. A separate function because DCDart has no `break` out of a `while`
/// (the same reason `cpuSkipSpaces` exists) -- an early `return` from a helper
/// is the idiom this language leaves.
@bare
u64 pmmFillLedger() {
  u64 n = u64(0);
  while (n < u64(pmmLedgerN)) {
    final u64 a = allocFrame();
    if (a < u64(1)) {
      return n;
    }
    pmmSetLedger(n, a);
    n = n + u64(1);
  }
  return n;
}

/// 1 if the `u64` at [addr] equals [want].
///
/// `Volatile<u64>`: this is the READ-BACK half of a memory test — its value
/// is the fact that the load really touched the frame. An ordinary load here
/// is legally forwardable from the store it verifies (DCDart ADR-0069), at
/// which point `frames test`'s RW check and `frames drain`'s touch verdict
/// would pass without ever reading memory. Same side-effect-only class as
/// vm.dart's `vmtest` probes; asserted per site by
/// `core/scripts/verify-mmio-volatile.sh`.
@bare
u64 pmmCheckWord(u64 addr, u64 want) {
  // `Volatile<u64>`: the READ-BACK half of a memory test — its value is the
  // fact that the load really touched the frame. An ordinary load here is
  // legally forwardable from the store it verifies (DCDart ADR-0069).
  if (Volatile<u64>.fromAddress(addr).value == want) {
    return u64(1);
  }
  return u64(0);
}

/// `frames test` -- allocate 64 frames, prove things about them, give them back.
///
/// Four claims, and each one would be a real allocator bug if it failed:
///
///   * **DISTINCT** -- pairwise comparison of all 64 addresses. Not a checksum:
///     every pair is compared, so no two allocations can be the same frame.
///     This is the nested loop GAP-0068 would have forced into a helper.
///   * **RANGE** -- every address is frame-aligned and every frame satisfies
///     [pmmAllocatable], which is what makes this the "no allocated frame
///     overlaps the kernel image or a reserved region" claim rather than a
///     bounds check.
///   * **RW** -- a value derived from each frame's own address is written to
///     the first and last `u64` of that frame, and only then is any of it read
///     back. Writing all 64 before verifying any is the half that matters: if
///     two ledger entries named the same physical page, the later write would
///     destroy the earlier one and the read-back would catch it. It also proves
///     the frames are real, mapped, writable RAM rather than bookkeeping
///     entries -- the last `u64` of the frame is at offset 4088, so it also
///     proves the whole frame is there and not just its first byte.
///   * **FREED / FREE / BASELINE** -- all 64 accepted back, and the free count
///     returned to exactly what it was before the test ran.
///
/// The `PMM RW` line names one frame and the value written into it, so the
/// harness can dump that address out of guest memory with the monitor and find
/// the value there -- the write is checked from outside the kernel as well as
/// by the kernel.
@bare
void shellFramesTest() {
  final u64 before = pmmMeta(u64(pmmMetaFree));
  final u64 got = pmmFillLedger();

  // DISTINCT -- every pair, a `while` inside a `while`.
  u64 distinct = u64(1);
  u64 i = u64(0);
  while (i < got) {
    u64 j = i + u64(1);
    while (j < got) {
      if (pmmLedger(i) == pmmLedger(j)) {
        distinct = u64(0);
      }
      j = j + u64(1);
    }
    i = i + u64(1);
  }

  // RANGE.
  u64 inRange = u64(1);
  i = u64(0);
  while (i < got) {
    final u64 a = pmmLedger(i);
    if ((a & u64(pmmFrameMask)) > u64(0)) {
      inRange = u64(0);
    }
    if (pmmAllocatable(a >> u64(pmmFrameShift)) < u64(1)) {
      inRange = u64(0);
    }
    i = i + u64(1);
  }

  // RW -- write every frame FIRST, then verify every frame.
  i = u64(0);
  while (i < got) {
    final u64 a = pmmLedger(i);
    // `Volatile<u64>`: these stores exist to be VERIFIED (the readback loop
    // below), i.e. the harness asserts their consequence, not their value.
    // Ordinary, the store/readback pair is legally forwardable at -O2 and
    // the RW test could pass without touching the frames (ADR-0069's split;
    // same class as vm.dart's vmtest probes).
    Volatile<u64>.fromAddress(a).value = a ^ u64(0xA5A5A5A5A5A5A5A5);
    Volatile<u64>.fromAddress(a + u64(pmmFrameLastWord)).value =
        a ^ u64(0x5A5A5A5A5A5A5A5A);
    i = i + u64(1);
  }
  u64 rwOk = u64(1);
  i = u64(0);
  while (i < got) {
    final u64 a = pmmLedger(i);
    rwOk = rwOk & pmmCheckWord(a, a ^ u64(0xA5A5A5A5A5A5A5A5));
    rwOk = rwOk &
        pmmCheckWord(a + u64(pmmFrameLastWord), a ^ u64(0x5A5A5A5A5A5A5A5A));
    i = i + u64(1);
  }
  if (got > u64(0)) {
    final u64 witness = pmmLedger(u64(0));
    uartWrite(Rodata.addressOf(pmmStrRw), u64(7));
    uartPutHex(witness, u64(16));
    uartSpace();
    uartPutHex(witness ^ u64(0xA5A5A5A5A5A5A5A5), u64(16));
    uartNewline();
  }

  // FREE THEM ALL BACK.
  u64 freed = u64(0);
  i = u64(0);
  while (i < got) {
    if (freeFrame(pmmLedger(i)) == u64(pmmFreeOk)) {
      freed = freed + u64(1);
    }
    i = i + u64(1);
  }
  final u64 after = pmmMeta(u64(pmmMetaFree));

  uartWrite(Rodata.addressOf(pmmStrTest), u64(9));
  uartWrite(Rodata.addressOf(pmmStrTestN), u64(2));
  uartPutHex(got, u64(8));
  uartWrite(Rodata.addressOf(pmmStrDist), u64(10));
  pmmVerdict(distinct);
  uartWrite(Rodata.addressOf(pmmStrRangeL), u64(7));
  pmmVerdict(inRange);
  uartWrite(Rodata.addressOf(pmmStrRwL), u64(4));
  pmmVerdict(rwOk);
  uartWrite(Rodata.addressOf(pmmStrFreedL), u64(7));
  uartPutHex(freed, u64(8));
  uartWrite(Rodata.addressOf(pmmStrFreeL), u64(6));
  uartPutHex(after, u64(8));
  uartWrite(Rodata.addressOf(pmmStrBaseL), u64(10));
  uartPutHex(pmmMeta(u64(pmmMetaBaseline)), u64(8));
  uartNewline();

  u64 pass = distinct & inRange & rwOk;
  if (got == u64(pmmLedgerN)) {
    if (freed == got) {
      if (after == before) {
        pass = pass & u64(1);
      } else {
        pass = u64(0);
      }
    } else {
      pass = u64(0);
    }
  } else {
    pass = u64(0);
  }
  uartWrite(Rodata.addressOf(pmmStrTest), u64(9));
  if (pass > u64(0)) {
    uartWrite(Rodata.addressOf(pmmStrPass), u64(4));
  } else {
    uartWrite(Rodata.addressOf(pmmStrFail), u64(4));
  }
  uartNewline();
}

// ---------------------------------------------------------------------------
// `frames drain` and `frames refill` -- exhaustion, and the way back.
// ---------------------------------------------------------------------------

/// `frames drain` -- allocate every free frame, then prove the next one fails.
///
///     PMM DRAIN TOOK 00007C9F SUM 000000000FA3C1E1 XOR 0000000000000001
///     PMM DRAIN LOW 0000000000110000 HIGH 0000000007FDF000
///     PMM DRAIN NEXT 0000000000000000 FREE 00000000
///
/// `SUM` and `XOR` are folds over the frame INDEX of every address handed out.
/// They exist so the harness can recompute both from the memory map and the
/// ELF's own kernel extents and compare -- an allocation that handed the same
/// frame out twice would have to skip a different one to keep `TOOK` right, and
/// that changes both folds. `LOW` and `HIGH` bound the whole set, so a frame
/// outside the managed range would be visible in the line rather than only in
/// the bitmap.
///
/// `NEXT` is the allocation attempted after exhaustion, printed as a raw
/// address: `0000000000000000` is the allocator correctly refusing. It is a
/// number rather than a verdict word on purpose -- if it were ever non-zero,
/// the line names the frame that should not have existed.
@bare
void shellFramesDrain() {
  u64 took = u64(0);
  u64 sum = u64(0);
  u64 fold = u64(0);
  u64 low = u64(0);
  u64 high = u64(0);
  u64 a = allocFrame();
  while (a > u64(0)) {
    final u64 f = a >> u64(pmmFrameShift);
    if (took < u64(1)) {
      low = a;
      high = a;
    } else {
      if (a < low) {
        low = a;
      }
      if (a > high) {
        high = a;
      }
    }
    took = took + u64(1);
    sum = sum + f;
    fold = fold ^ f;
    a = allocFrame();
  }

  uartWrite(Rodata.addressOf(pmmStrDrain), u64(10));
  uartWrite(Rodata.addressOf(pmmStrTook), u64(5));
  uartPutHex(took, u64(8));
  uartWrite(Rodata.addressOf(pmmStrSumL), u64(5));
  uartPutHex(sum, u64(16));
  uartWrite(Rodata.addressOf(pmmStrXorL), u64(5));
  uartPutHex(fold, u64(16));
  uartNewline();

  uartWrite(Rodata.addressOf(pmmStrDrain), u64(10));
  uartWrite(Rodata.addressOf(pmmStrLowL), u64(4));
  uartPutHex(low, u64(16));
  uartWrite(Rodata.addressOf(pmmStrHighL), u64(6));
  uartPutHex(high, u64(16));
  uartNewline();

  // TOUCH: write a value derived from its own address into the HIGHEST frame
  // the allocator just handed out, and read it back.
  //
  // This is the runtime half of the bound invariant. `boot.S` identity-maps
  // MAP_2MIB_PAGES * 2MiB and this allocator manages pmmMaxFrames * 4KiB, and
  // the two being the same number is a source-level claim that a structural
  // check can compare but cannot execute. A store to the top managed frame
  // executes it: if the map were short, this line would be a page fault
  // instead of a verdict. The frame is safe to write because the drain owns
  // every frame -- there is nothing else it could belong to.
  if (took > u64(0)) {
    // `Volatile<u64>`: this store is a MAPPING PROBE — "if the map were
    // short, this line would be a page fault". The access is the assertion
    // (same class as vmtest ro), so it must survive optimization exactly as
    // written.
    Volatile<u64>.fromAddress(high).value = high ^ u64(0xC3C3C3C3C3C3C3C3);
    uartWrite(Rodata.addressOf(pmmStrDrain), u64(10));
    uartWrite(Rodata.addressOf(pmmStrTouch), u64(6));
    uartPutHex(high, u64(16));
    uartSpace();
    uartPutHex(high ^ u64(0xC3C3C3C3C3C3C3C3), u64(16));
    uartSpace();
    pmmVerdict(pmmCheckWord(high, high ^ u64(0xC3C3C3C3C3C3C3C3)));
    uartNewline();
  }

  final u64 next = allocFrame();
  uartWrite(Rodata.addressOf(pmmStrDrain), u64(10));
  uartWrite(Rodata.addressOf(pmmStrNextL), u64(5));
  uartPutHex(next, u64(16));
  uartWrite(Rodata.addressOf(pmmStrFreeL), u64(6));
  uartPutHex(pmmMeta(u64(pmmMetaFree)), u64(8));
  uartNewline();
}

/// `frames refill` -- free every frame [pmmAllocatable] says was ever
/// allocatable, and report whether the free count came back to the baseline.
///
/// **This is the other half of the drain, and it is deliberately not a
/// re-initialisation.** It calls [freeFrame] once per frame -- 32768 times,
/// through every one of that function's checks -- so the count it produces is
/// the count `free` really kept. Re-running [pmmInit] would produce a correct
/// number while testing nothing.
///
/// It also cross-checks the two spellings of the allocatable predicate against
/// each other: [pmmInit] marks by walking regions, [pmmAllocatable] asks about
/// one frame. If they disagreed, either `ERRORS` moves (this tried to free
/// something init never freed) or `FREE` misses `BASELINE` (init freed
/// something this does not know about). Both are printed on the line.
@bare
void shellFramesRefill() {
  final u64 managed = pmmMeta(u64(pmmMetaManaged));
  final u64 errorsBefore = pmmMeta(u64(pmmMetaErrors));
  u64 gave = u64(0);
  u64 f = u64(0);
  while (f < managed) {
    if (pmmAllocatable(f) > u64(0)) {
      if (pmmBitGet(f) > u64(0)) {
        if (freeFrame(f << u64(pmmFrameShift)) == u64(pmmFreeOk)) {
          gave = gave + u64(1);
        }
      }
    }
    f = f + u64(1);
  }
  final u64 free = pmmMeta(u64(pmmMetaFree));
  final u64 baseline = pmmMeta(u64(pmmMetaBaseline));
  uartWrite(Rodata.addressOf(pmmStrRefill), u64(11));
  uartWrite(Rodata.addressOf(pmmStrGave), u64(5));
  uartPutHex(gave, u64(8));
  uartWrite(Rodata.addressOf(pmmStrFreeL), u64(6));
  uartPutHex(free, u64(8));
  uartWrite(Rodata.addressOf(pmmStrBaseL), u64(10));
  uartPutHex(baseline, u64(8));
  uartWrite(Rodata.addressOf(pmmStrErrorsL), u64(8));
  uartPutHex(pmmMeta(u64(pmmMetaErrors)) - errorsBefore, u64(8));
  uartSpace();
  if (free == baseline) {
    pmmVerdict(u64(1));
  } else {
    pmmVerdict(u64(0));
  }
  uartNewline();
}

/// `frames leave <n>` — allocate frames until exactly `<n>` are free.
///
///     PMM LEAVE WANT 00000003 TOOK 00007E89 FREE 00000003
///
/// **A PARTIAL DRAIN, AND IT EXISTS BECAUSE A REFUSAL CODE HAD NO REACHABLE
/// CALLER WITHOUT ONE.** `frames drain` takes every frame there is, and a
/// machine with NO frames at all cannot reach the ELF loader's own
/// out-of-memory refusal: ADR-0034 put `procCreate` in front of the loader, so
/// the process layer's five allocations (`procSpaceBuild`'s PML4, PDPT and PD,
/// plus the header and scratch frames `procCreate` takes) fail first and the
/// answer is always `PROC REFUSED 04`. `elfErrNoFrames` stayed a live guard
/// that nothing could reach — the same accident, from the same commit, as
/// GAP-0214's `chanRetNoProc`.
///
/// Leaving *some* frames free splits the two apart: enough for the process
/// layer's five and not enough for the loader's first reaches `ELF REFUSED 03`,
/// which is the boot `m10-elf/run.sh` now takes. The number is DERIVED there
/// from `proc.dart`'s own `allocFrame` count rather than written down twice.
/// docs/decisions/0039-four-guards-adr-0034-left-behind.md.
///
/// **The count is a target, not a quota.** The loop stops when the free count
/// reaches `<n>` OR when the allocator refuses, so `frames leave 0` is
/// `frames drain` without the folds and `frames leave FFFFFFFF` takes nothing.
/// `frames refill` is the way back from either.
@bare
void shellFramesLeave(u64 from) {
  if (pmmHexOk(from) < u64(1)) {
    shellFramesUsage();
    return;
  }
  final u64 want = pmmHexValue(from);
  u64 took = u64(0);
  u64 more = u64(1);
  while (more > u64(0)) {
    if (pmmMeta(u64(pmmMetaFree)) <= want) {
      more = u64(0);
    } else {
      final u64 a = allocFrame();
      if (a < u64(1)) {
        more = u64(0);
      } else {
        took = took + u64(1);
      }
    }
  }
  uartWrite(Rodata.addressOf(pmmStrLeave), u64(10));
  uartWrite(Rodata.addressOf(pmmStrWant), u64(5));
  uartPutHex(want, u64(8));
  uartWrite(Rodata.addressOf(pmmStrTookL), u64(6));
  uartPutHex(took, u64(8));
  uartWrite(Rodata.addressOf(pmmStrFreeL), u64(6));
  uartPutHex(pmmMeta(u64(pmmMetaFree)), u64(8));
  uartNewline();
}

/// `frames` with an argument this shell does not know.
@bare
void shellFramesUsage() {
  uartWrite(Rodata.addressOf(pmmStrUsage), u64(92));
}
