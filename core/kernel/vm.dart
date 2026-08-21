// core/kernel/vm.dart
//
// oscortex_core M8: THE ADDRESS SPACE. A real 4-level page table, built in
// DCDart out of frames from the M7 allocator, with per-section permissions and
// NX, installed in CR3 while the kernel is running on the bootstrap tables
// `core/boot/boot.S` made.
//
// A `part of 'kmain.dart'` for the same forced reason every other kernel source
// file here is: `dcc` lowers exactly ONE library per object file, so a `@bare`
// function in an IMPORTED library is never compiled at all. See
// docs/known-gaps.md GAP-0004 item 4.
//
// ---------------------------------------------------------------------------
// WHAT THIS CLOSES: GAP-0050
// ---------------------------------------------------------------------------
// Until this milestone `core/link/kernel.ld` forced every section into ONE
// `PT_LOAD` with `FLAGS(7)` -- read, write AND execute on everything -- and
// `boot.S` identity-mapped 128MiB with 2MiB pages that were present and
// writable and nothing else. The consequences were not theoretical:
//
//   * `.text` was writable, so a stray pointer could rewrite code;
//   * `.rodata` was writable, so a store through a pointer derived from a
//     constant global SUCCEEDED SILENTLY -- no compile-time check (DCDart's
//     `DCPointer` carries no const-ness) and no runtime check either;
//   * GAP-0079 added a second reason when LLVM lowered `pmmFreeStatus` into a
//     jump table in `.rodata`: the kernel acquired data whose integrity is
//     control-flow integrity, sitting on a writable page.
//
// GAP-0050 also said, in as many words, that this must NOT be closed as a
// link-script-only change: separate segments without page-table enforcement
// look like protection while providing none. So there are two halves here and
// the second one is the real one. The link script now emits three segments
// (R E / R / RW); this file makes the hardware agree with them.
//
// **The proof is a fault, not a flag.** `vmtest ro` writes to a `@rodata`
// table and `vmtest nx` calls into one; both must #PF, be reported with the
// right address and the right decoded error code, and leave the shell alive.
// `vmtest rw` and `vmtest x` are the controls -- the same two operations
// against a writable page and an executable page, which must NOT fault. A test
// that only shows the faults would be equally consistent with "every store
// faults", which proves nothing about permissions.
//
// ---------------------------------------------------------------------------
// THE STORAGE SEAM -- ONE ACCESSOR, ONE CALL SITE
// ---------------------------------------------------------------------------
// DCDart still has no mutable static data of any kind (docs/known-gaps.md
// GAP-0053), so this subsystem's state is assembly-donated `.bss` exactly as
// the allocator's is. ADR-0011 §0 answered that objection by SHAPE rather than
// by waiting, and this file uses the same shape one notch tighter: 128 bytes in
// ONE symbol (`vm_store`, core/boot/kdata.S) behind ONE accessor
// (`vm_store_addr`) reached through exactly ONE function ([vmMetaBase]).
// Everything else goes through [vmMeta] / [vmSetMeta].
//
// `tests/conformance/m8-paging/run.sh` COUNTS that call site, the way
// m7-frames counts the allocator's three. When DCDart grows mutable statics:
// declare one static block, rewrite one function, delete `vm_store` and
// `vm_store_addr`. Nothing else in this file moves.
//
// ---------------------------------------------------------------------------
// THE MAP THIS BUILDS
// ---------------------------------------------------------------------------
// Identity throughout -- virtual address == physical address. There is no
// higher-half kernel, no user space and no second address space (GAP-0081).
//
//   [0, 1MiB)                    4KiB pages   RW, NX    the IVT, the BDA, VGA
//                                                       text at 0xB8000
//   [__kernel_start, __rodata_start)
//                                4KiB pages   R,  X     `.multiboot` + `.text`
//   [__rodata_start, __data_start)
//                                4KiB pages   R,  NX    `.rodata`
//   [__data_start, 4MiB)         4KiB pages   RW, NX    `.data`, `.bss`, and
//                                                       the RAM above the
//                                                       image up to 4MiB
//   [4MiB, 128MiB)               2MiB pages   RW, NX    the rest of what the
//                                                       frame allocator manages
//   [3GiB, 4GiB)                 2MiB pages   RW, NX    the PC's PCI hole,
//                                                       where BARs live
//
// WHY 4MiB IS THE 4KiB WINDOW. Permissions can only change at a page boundary,
// so every section boundary has to fall inside 4KiB-page territory. The kernel
// image starts at 1MiB and is ~115KiB; a 2MiB window would already be enough,
// but the window size has to be a CONSTANT for the number of page-table frames
// to be a constant (see the next paragraph), and a constant that is only just
// big enough is a constant that breaks on the next milestone. 4MiB is two page
// tables, costs two frames, and leaves the image room to triple.
//
// [vmInit] REFUSES rather than mis-maps if the image ever outgrows it: the
// check is `kernel_image_end() <= 4MiB`, the status word says `TOOBIG`, and
// CR3 is not touched. A kernel that would not fit keeps running on boot.S's
// bootstrap tables instead of running on a table that stops short of it.
//
// SIX FRAMES, AND WHY THE NUMBER IS FIXED. PML4, PDPT, the page directory for
// [0, 1GiB), two page tables for [0, 4MiB), and the page directory for
// [3GiB, 4GiB). That is 6 * 4KiB = 24KiB, taken from `allocFrame()` and never
// given back. It is fixed because the 4MiB window and the 128MiB bound are
// both fixed, which is what lets `m7-frames/derive.py` and `m8-paging/run.sh`
// DERIVE the allocator's post-boot free count instead of being told it.
//
// ---------------------------------------------------------------------------
// THE PAGE TABLES ARE THE FIRST KERNEL MEMORY OUTSIDE THE KERNEL IMAGE
// ---------------------------------------------------------------------------
// Before M8 everything the kernel could not afford to lose was inside
// `[__kernel_start, __kernel_end)`, which is exactly what `pmmAllocatable`
// reserves. These six frames are not: they come out of the allocator. So
// `pmmAllocatable` gained one clause -- [vmHoldsFrame] -- and with it three
// consequences that are all tested:
//
//   * `free <page-table-frame>` is refused with `ERR RESERVED` instead of
//     handing the running address space back to the allocator;
//   * `frames refill` (which frees everything that was ever allocatable) skips
//     them, so the drain/refill cycle cannot destroy the mapping;
//   * `frames`' BASELINE is re-taken after the tables are built, so
//     "FREE == BASELINE" still means "nothing is leaked" rather than
//     "six frames are missing and nobody counted them".
//
// ---------------------------------------------------------------------------
// WHAT IS DELIBERATELY NOT HERE -- docs/known-gaps.md GAP-0081
// ---------------------------------------------------------------------------
// No user/supervisor separation (every page is supervisor; there is no ring 3
// and no TSS to enter one from). No second address space and no per-process
// anything. No `invlpg` and no TLB shootdown -- nothing ever CHANGES a mapping
// after the one switch, and there is one CPU. No demand paging, no swap, no
// COW, no guard page below the stack, and page 0 is mapped rather than left
// unmapped as a null-pointer trap.

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// GENERATED, not hand-typed: a `@rodata` table carries no length (GAP-0060), so
// every byte count below is repeated at its call site by hand, and getting one
// wrong prints the wrong number of bytes. `tests/conformance/m8-paging/run.sh`
// reads every symbol's real size out of `kmain.o` and compares it against what
// the call site passes.
// ---------------------------------------------------------------------------

/// Line label.
///
/// `'VM CR3 '` -- 7 bytes.
@rodata
final List<u8> vmStrCr3 = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x43), u8(0x52), u8(0x33), u8(0x20),
];

/// Field separator.
///
/// `' PML4 '` -- 6 bytes.
@rodata
final List<u8> vmStrPml4 = const [
  u8(0x20), u8(0x50), u8(0x4D), u8(0x4C), u8(0x34), u8(0x20),
];

/// Field separator.
///
/// `' NX '` -- 4 bytes.
@rodata
final List<u8> vmStrNx = const [
  u8(0x20), u8(0x4E), u8(0x58), u8(0x20),
];

/// Field separator.
///
/// `' WP '` -- 4 bytes.
@rodata
final List<u8> vmStrWp = const [
  u8(0x20), u8(0x57), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' READY '` -- 7 bytes.
@rodata
final List<u8> vmStrReady = const [
  u8(0x20), u8(0x52), u8(0x45), u8(0x41), u8(0x44), u8(0x59), u8(0x20),
];

/// Field separator.
///
/// `' STATUS '` -- 8 bytes.
@rodata
final List<u8> vmStrStatus = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x54), u8(0x55), u8(0x53), u8(0x20),
];

/// Line label.
///
/// `'VM FRAMES '` -- 10 bytes.
@rodata
final List<u8> vmStrFrames = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x46), u8(0x52), u8(0x41), u8(0x4D), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' SPAN '` -- 6 bytes.
@rodata
final List<u8> vmStrSpan = const [
  u8(0x20), u8(0x53), u8(0x50), u8(0x41), u8(0x4E), u8(0x20),
];

/// Line label.
///
/// `'VM PAGES 4K '` -- 12 bytes.
@rodata
final List<u8> vmStrPages = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x53), u8(0x20), u8(0x34), u8(0x4B), u8(0x20),
];

/// Field separator.
///
/// `' 2M '` -- 4 bytes.
@rodata
final List<u8> vmStr2m = const [
  u8(0x20), u8(0x32), u8(0x4D), u8(0x20),
];

/// Line label.
///
/// `'VM SECT '` -- 8 bytes.
@rodata
final List<u8> vmStrSect = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x53), u8(0x45), u8(0x43), u8(0x54), u8(0x20),
];

/// Region label.
///
/// `'VM TEXT '` -- 8 bytes.
@rodata
final List<u8> vmStrText = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x58), u8(0x54), u8(0x20),
];

/// Region label.
///
/// `'VM RODATA '` -- 10 bytes.
@rodata
final List<u8> vmStrRodata = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x52), u8(0x4F), u8(0x44), u8(0x41), u8(0x54), u8(0x41), u8(0x20),
];

/// Region label.
///
/// `'VM DATA '` -- 8 bytes.
@rodata
final List<u8> vmStrData = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x44), u8(0x41), u8(0x54), u8(0x41), u8(0x20),
];

/// Region label.
///
/// `'VM LOW '` -- 7 bytes.
@rodata
final List<u8> vmStrLow = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x4C), u8(0x4F), u8(0x57), u8(0x20),
];

/// Region label.
///
/// `'VM HIGH '` -- 8 bytes.
@rodata
final List<u8> vmStrHigh = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x48), u8(0x49), u8(0x47), u8(0x48), u8(0x20),
];

/// Region label.
///
/// `'VM PCI '` -- 7 bytes.
@rodata
final List<u8> vmStrPci = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x50), u8(0x43), u8(0x49), u8(0x20),
];

/// Field separator.
///
/// `' P '` -- 3 bytes.
@rodata
final List<u8> vmStrP = const [
  u8(0x20), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' W '` -- 3 bytes.
@rodata
final List<u8> vmStrW = const [
  u8(0x20), u8(0x57), u8(0x20),
];

/// Field separator.
///
/// `' X '` -- 3 bytes.
@rodata
final List<u8> vmStrX = const [
  u8(0x20), u8(0x58), u8(0x20),
];

/// Line label.
///
/// `'VM CANARY '` -- 10 bytes.
@rodata
final List<u8> vmStrCanary = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x43), u8(0x41), u8(0x4E), u8(0x41), u8(0x52), u8(0x59), u8(0x20),
];

/// Line label.
///
/// `'VM FAULTS '` -- 10 bytes.
@rodata
final List<u8> vmStrFaults = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x46), u8(0x41), u8(0x55), u8(0x4C), u8(0x54), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' CR2 '` -- 5 bytes.
@rodata
final List<u8> vmStrCr2 = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x32), u8(0x20),
];

/// Field separator.
///
/// `' ERR '` -- 5 bytes.
@rodata
final List<u8> vmStrErr = const [
  u8(0x20), u8(0x45), u8(0x52), u8(0x52), u8(0x20),
];

/// Line label.
///
/// `'VM TEST RO ADDR '` -- 16 bytes.
@rodata
final List<u8> vmStrTestRo = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20), u8(0x52), u8(0x4F), u8(0x20), u8(0x41),
  u8(0x44), u8(0x44), u8(0x52), u8(0x20),
];

/// Complete line.
///
/// `'VM TEST RO SURVIVED -- THE WRITE LANDED\\n'` -- 40 bytes.
@rodata
final List<u8> vmStrTestRoOops = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20), u8(0x52), u8(0x4F), u8(0x20), u8(0x53),
  u8(0x55), u8(0x52), u8(0x56), u8(0x49), u8(0x56), u8(0x45), u8(0x44), u8(0x20), u8(0x2D), u8(0x2D), u8(0x20), u8(0x54),
  u8(0x48), u8(0x45), u8(0x20), u8(0x57), u8(0x52), u8(0x49), u8(0x54), u8(0x45), u8(0x20), u8(0x4C), u8(0x41), u8(0x4E),
  u8(0x44), u8(0x45), u8(0x44), u8(0x0A),
];

/// Line label.
///
/// `'VM TEST NX ADDR '` -- 16 bytes.
@rodata
final List<u8> vmStrTestNx = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20), u8(0x4E), u8(0x58), u8(0x20), u8(0x41),
  u8(0x44), u8(0x44), u8(0x52), u8(0x20),
];

/// Complete line.
///
/// `'VM TEST NX SURVIVED -- THE FETCH RAN\\n'` -- 37 bytes.
@rodata
final List<u8> vmStrTestNxOops = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20), u8(0x4E), u8(0x58), u8(0x20), u8(0x53),
  u8(0x55), u8(0x52), u8(0x56), u8(0x49), u8(0x56), u8(0x45), u8(0x44), u8(0x20), u8(0x2D), u8(0x2D), u8(0x20), u8(0x54),
  u8(0x48), u8(0x45), u8(0x20), u8(0x46), u8(0x45), u8(0x54), u8(0x43), u8(0x48), u8(0x20), u8(0x52), u8(0x41), u8(0x4E),
  u8(0x0A),
];

/// Line label.
///
/// `'VM TEST RW ADDR '` -- 16 bytes.
@rodata
final List<u8> vmStrTestRw = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20), u8(0x52), u8(0x57), u8(0x20), u8(0x41),
  u8(0x44), u8(0x44), u8(0x52), u8(0x20),
];

/// Line label.
///
/// `'VM TEST X ADDR '` -- 15 bytes.
@rodata
final List<u8> vmStrTestX = const [
  u8(0x56), u8(0x4D), u8(0x20), u8(0x54), u8(0x45), u8(0x53), u8(0x54), u8(0x20), u8(0x58), u8(0x20), u8(0x41), u8(0x44),
  u8(0x44), u8(0x52), u8(0x20),
];

/// Complete line.
///
/// `'vmtest: usage: vmtest ro | nx | rw | x\\n'` -- 39 bytes.
@rodata
final List<u8> vmStrTestUsage = const [
  u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x3A), u8(0x20), u8(0x75), u8(0x73), u8(0x61), u8(0x67),
  u8(0x65), u8(0x3A), u8(0x20), u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20), u8(0x72), u8(0x6F),
  u8(0x20), u8(0x7C), u8(0x20), u8(0x6E), u8(0x78), u8(0x20), u8(0x7C), u8(0x20), u8(0x72), u8(0x77), u8(0x20), u8(0x7C),
  u8(0x20), u8(0x78), u8(0x0A),
];

/// Line label.
///
/// `'PF CR2 '` -- 7 bytes.
@rodata
final List<u8> vmStrPf = const [
  u8(0x50), u8(0x46), u8(0x20), u8(0x43), u8(0x52), u8(0x32), u8(0x20),
];

/// Error-code bit 0 set.
///
/// `'PRESENT'` -- 7 bytes.
@rodata
final List<u8> vmStrPfPres = const [
  u8(0x50), u8(0x52), u8(0x45), u8(0x53), u8(0x45), u8(0x4E), u8(0x54),
];

/// Error-code bit 0 clear.
///
/// `'NOTPRES'` -- 7 bytes.
@rodata
final List<u8> vmStrPfNotPres = const [
  u8(0x4E), u8(0x4F), u8(0x54), u8(0x50), u8(0x52), u8(0x45), u8(0x53),
];

/// Error-code bit 1 set.
///
/// `'WRITE'` -- 5 bytes.
@rodata
final List<u8> vmStrPfWrite = const [
  u8(0x57), u8(0x52), u8(0x49), u8(0x54), u8(0x45),
];

/// Error-code bit 1 clear.
///
/// `'READ'` -- 4 bytes.
@rodata
final List<u8> vmStrPfRead = const [
  u8(0x52), u8(0x45), u8(0x41), u8(0x44),
];

/// Error-code bit 2 set.
///
/// `'USER'` -- 4 bytes.
@rodata
final List<u8> vmStrPfUser = const [
  u8(0x55), u8(0x53), u8(0x45), u8(0x52),
];

/// Error-code bit 2 clear.
///
/// `'SUPER'` -- 5 bytes.
@rodata
final List<u8> vmStrPfSuper = const [
  u8(0x53), u8(0x55), u8(0x50), u8(0x45), u8(0x52),
];

/// Error-code bit 4 set.
///
/// `'FETCH'` -- 5 bytes.
@rodata
final List<u8> vmStrPfFetch = const [
  u8(0x46), u8(0x45), u8(0x54), u8(0x43), u8(0x48),
];

/// Error-code bit 4 clear.
///
/// `'DATA'` -- 4 bytes.
@rodata
final List<u8> vmStrPfData = const [
  u8(0x44), u8(0x41), u8(0x54), u8(0x41),
];

/// Error-code bit 3 set; printed only then.
///
/// `' RSVD'` -- 5 bytes.
@rodata
final List<u8> vmStrPfRsvd = const [
  u8(0x20), u8(0x52), u8(0x53), u8(0x56), u8(0x44),
];

/// **THE CANARY, and it is the most load-bearing eight bytes in this file.**
///
/// `'\xC3OSCRWX!'` -- 8 bytes. Two commands aim at it and they aim at different
/// properties of the same page:
///
///   * `vmtest ro` STORES through its address. On a correctly mapped kernel
///     that is a #PF (write to a read-only page) and the store never lands; on
///     the kernel this milestone replaces it succeeded silently, which is
///     GAP-0050 stated as an executable fact. `vm` prints these eight bytes, so
///     a write that DID land is visible in the next report rather than only in
///     the absence of a fault.
///
///   * `vmtest nx` CALLS its address. That is why the first byte is `0xC3` --
///     an x86 `ret`. If the page were executable the call would return
///     harmlessly and the command would print `SURVIVED`; the alternative
///     (arbitrary bytes) would crash unpredictably on the very machine whose
///     protection had just been shown not to work, which is the least useful
///     possible behaviour for a negative result.
///
/// The remaining seven bytes spell `OSCRWX!` so that a corrupted table is
/// legible in a hexdump.
@rodata
final List<u8> vmCanary = const [
  u8(0xC3), u8(0x4F), u8(0x53), u8(0x43), u8(0x52), u8(0x57), u8(0x58), u8(0x21),
];

/// Whole-line command name.
///
/// `'vm'` -- 2 bytes.
@rodata
final List<u8> vmCmdVm = const [
  u8(0x76), u8(0x6D),
];

/// Whole-line command name.
///
/// `'vmtest ro'` -- 9 bytes.
@rodata
final List<u8> vmCmdTestRo = const [
  u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20), u8(0x72), u8(0x6F),
];

/// Whole-line command name.
///
/// `'vmtest nx'` -- 9 bytes.
@rodata
final List<u8> vmCmdTestNx = const [
  u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20), u8(0x6E), u8(0x78),
];

/// Whole-line command name.
///
/// `'vmtest rw'` -- 9 bytes.
@rodata
final List<u8> vmCmdTestRw = const [
  u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20), u8(0x72), u8(0x77),
];

/// Whole-line command name.
///
/// `'vmtest x'` -- 8 bytes.
@rodata
final List<u8> vmCmdTestX = const [
  u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74), u8(0x20), u8(0x78),
];

/// Command name, matched as a PREFIX.
///
/// `'vmtest'` -- 6 bytes.
@rodata
final List<u8> vmCmdTest = const [
  u8(0x76), u8(0x6D), u8(0x74), u8(0x65), u8(0x73), u8(0x74),
];

// ---------------------------------------------------------------------------
// Geometry. Every derived constant is SPELLED OUT rather than computed, for the
// reason `pmm.dart` spells out `pmmFrameMask`: `dcc` at `DCDART_PIN.txt`'s
// commit refuses a `u64` literal built from a constant expression
// (docs/known-gaps.md GAP-0077). `tests/conformance/m8-paging/run.sh` reads
// these out of this file and multiplies them out against each other, so a pair
// that stops agreeing fails a check rather than mapping the wrong memory.
// ---------------------------------------------------------------------------

/// 4KiB base page.
const int vmPageBytes = 4096;
const int vmPageShift = 12;
const int vmPageMask = 4095;

/// 2MiB large page (PS=1 at the page-directory level).
const int vmBigBytes = 2097152;
const int vmBigShift = 21;

/// The first megabyte: below the kernel, mapped because the VGA text buffer at
/// `0xB8000` is in it and the console writes there on every character.
const int vmLowBytes = 1048576;

/// How much of the bottom of memory is mapped with 4KiB pages. Two page tables.
/// The kernel image must fit inside this or [vmInit] refuses -- see the header.
const int vmFineBytes = 4194304;

/// Pages in that window: 4MiB / 4KiB.
const int vmFinePages = 1024;

/// The top of what is mapped at all in low memory. **Must equal
/// `pmmMaxFrames * pmmFrameBytes`** -- a frame the allocator hands out that
/// this does not map is a page fault inside whatever first uses it. m7-frames
/// already asserts boot.S's bootstrap map against the same number; m8-paging
/// asserts this one.
const int vmMapBytes = 134217728;

/// Page-directory entry index of the first and one-past-the-last 2MiB page in
/// low memory: `vmFineBytes / vmBigBytes` and `vmMapBytes / vmBigBytes`.
const int vmBigFirst = 2;
const int vmBigLastEx = 64;

/// The PC's PCI hole: [3GiB, 4GiB), where firmware puts BARs -- including the
/// framebuffer M5 draws into. 512 2MiB pages.
const int vmPciBase = 0xC0000000;
const int vmPciEnd = 0x100000000;

/// Entries in every level of an x86-64 page table.
const int vmEntries = 512;

/// Page-table frames taken from the allocator, and never returned. See the
/// header for the enumeration. **The harness derives the allocator's free count
/// from this number**, so changing it changes m7-frames' expectations too.
const int vmFrameCount = 6;

/// Indices into the frame list, for readability at the build site.
const int vmIxPml4 = 0;
const int vmIxPdpt = 1;
const int vmIxPdLow = 2;
const int vmIxPt0 = 3;
const int vmIxPt1 = 4;
const int vmIxPdPci = 5;

/// Page-table entry flag bits.
const int vmPresent = 1;
const int vmWritable = 2;
const int vmHuge = 128;

/// Donated storage: sixteen `u64` words. See `core/boot/kdata.S`.
const int vmStoreBytes = 128;
const int vmStoreWords = 16;

// Metadata word indices.
const int vmMetaReady = 0;
const int vmMetaStatus = 1;
const int vmMetaPml4 = 2;
const int vmMetaFrames = 3;
const int vmMetaPages4k = 4;
const int vmMetaPages2m = 5;
const int vmMetaScratch = 6;
const int vmMetaFaults = 7;
const int vmMetaCr2 = 8;
const int vmMetaErr = 9;
const int vmMetaFrame0 = 10;

// [vmInit] status codes. `u64` rather than an enum because DCDart `@bare` has
// neither enums nor booleans (GAP-0023). Every one of them means "CR3 was NOT
// switched and the kernel is still on boot.S's bootstrap tables".
const int vmStatusOk = 0;
const int vmStatusBadBase = 1;
const int vmStatusTooBig = 2;
const int vmStatusBadAlign = 3;
const int vmStatusBadOrder = 4;
const int vmStatusNoFrames = 5;
const int vmStatusNotContig = 6;
const int vmStatusSelfCheck = 7;

// Page-fault error-code bits (Intel SDM Vol.3 §4.7).
const int vmPfPresent = 1;
const int vmPfWrite = 2;
const int vmPfUser = 4;
const int vmPfReserved = 8;
const int vmPfFetch = 16;

/// The vector the CPU raises for a page fault.
const int vectorPageFault = 14;

// ---------------------------------------------------------------------------
// ===========================  THE STORAGE SEAM  ============================
//
// The ONLY function in this kernel that knows where the virtual-memory
// subsystem's mutable state lives, and the ONLY call site of `vm_store_addr`.
//
// Read this file's header before changing anything here. A second call site,
// or a second `@extern` accessor for VM state, is the change that turns the
// mutable-statics migration from one function into an audit.
// `tests/conformance/m8-paging/run.sh` counts it.
// ---------------------------------------------------------------------------

/// Address of the 128-byte donated block that holds the whole subsystem.
///
/// `core/boot/kdata.S`. Returns an ADDRESS rather than a `Pointer<T>` because
/// DCDart still forbids `Pointer<T>` in an extern signature (DCDart GAP-0025),
/// and lives in assembly because DCDart has no mutable static data of any kind
/// (docs/known-gaps.md GAP-0053). **Both are temporary and this function is the
/// seam they will be removed through.**
@extern
external u64 vm_store_addr();

/// Base of the sixteen-word metadata block.
@bare
u64 vmMetaBase() {
  return vm_store_addr();
}

// ======================  END OF THE STORAGE SEAM  ==========================

/// One past the last byte of `.text`, from `core/link/kernel.ld`.
///
/// NOT storage -- link-time constants, which is why these five are not behind
/// the seam. Read from the linker script rather than hardcoded because every
/// one of them moves whenever anything is added to this kernel, and a wrong
/// boundary here is either a writable `.text` or a #PF on the first instruction
/// fetch after the CR3 switch, which is a triple fault with no diagnostic.
@extern
external u64 kernel_text_end();

/// First byte of `.rodata`, 4KiB-aligned. Also one past the last TEXT page.
@extern
external u64 kernel_rodata_start();

/// One past the last byte of `.rodata`.
@extern
external u64 kernel_rodata_end();

/// First byte of `.data`, 4KiB-aligned. Also one past the last RODATA page.
@extern
external u64 kernel_data_start();

/// 1 if `EFER.NXE` was set at boot, else 0. `core/boot/boot.S` probes CPUID
/// leaf 0x80000001 EDX bit 20 and records the answer; see `nx_flag` there for
/// why it is asked rather than assumed.
@extern
external u64 nx_enabled();

/// `mov %cr3,%rax` -- the physical address of the LIVE PML4, read back from the
/// CPU rather than remembered, so `vm` reports what is actually installed.
@extern
external u64 cr3_read();

/// `mov %cr2,%rax` -- the linear address of the last page fault.
/// `mov %cr0,%rax`. Read for exactly one bit: **WP (bit 16)**, without which a
/// read-only page-table entry does not stop a supervisor write at all. See
/// `core/boot/boot.S`'s CR0 write.
@extern
external u64 cr0_read();

@extern
external u64 cr2_read();

/// `mov %rdi,%cr3` -- installs an address space. Never returns to a kernel that
/// the new table does not map. See `core/boot/isr.S`.
@extern
external void paging_install(u64 pml4Physical);

/// `call *%rdi` -- an instruction fetch from [addr]. Returns 1 if the fetch
/// happened; if the page is non-executable it raises #PF and never returns.
@extern
external u64 vm_exec_probe(u64 addr);

/// The address of a lone `ret` in `.text`, as data. The control for
/// `vmtest nx`: the same probe against an executable page.
@extern
external u64 vm_exec_ok_addr();

// ---------------------------------------------------------------------------
// Metadata primitives. Everything below goes through the seam.
// ---------------------------------------------------------------------------

/// Reads metadata word [i].
@bare
u64 vmMeta(u64 i) {
  return Pointer<u64>.fromAddress(vmMetaBase() + (i << u64(3))).value;
}

/// Writes metadata word [i].
@bare
void vmSetMeta(u64 i, u64 v) {
  Pointer<u64>.fromAddress(vmMetaBase() + (i << u64(3))).value = v;
}

/// The NX bit, or zero on a CPU that has no NX.
///
/// **Zero rather than "set it anyway" is a correctness requirement, not a
/// courtesy.** With `EFER.NXE` clear, bit 63 of a page-table entry is a
/// RESERVED bit; an entry that sets it faults on every access with the RSVD bit
/// in the error code. The entry meant to protect the page would instead make
/// the page unusable, which on `.rodata` means the kernel cannot read its own
/// message tables. On such a machine the kernel still gets W^X for `.text` (a
/// read-only page cannot be rewritten) and a read-only `.rodata`; what it loses
/// is "not executable", and `vm` prints `NX 0` rather than pretending.
@bare
u64 vmNxBit() {
  if (nx_enabled() > u64(0)) {
    return u64(0x8000000000000000);
  }
  return u64(0);
}

/// The 4KiB-aligned physical address inside a page-table entry: bits 51..12.
///
/// Spelled as a mask rather than `(e >> 12) << 12` because the top bits carry
/// NX and (on other CPUs) protection keys, and shifting would not remove them.
@bare
u64 vmEntryAddr(u64 e) {
  return e & u64(0x000FFFFFFFFFF000);
}

/// Writes entry [index] of the table at physical address [table].
@bare
void vmSetEntry(u64 table, u64 index, u64 value) {
  Pointer<u64>.fromAddress(table + (index << u64(3))).value = value;
}

/// Reads entry [index] of the table at physical address [table].
@bare
u64 vmGetEntry(u64 table, u64 index) {
  return Pointer<u64>.fromAddress(table + (index << u64(3))).value;
}

/// Fills one 4KiB frame with zeroes.
///
/// **Not hygiene.** `allocFrame()` hands back whatever the frame contained
/// (docs/known-gaps.md GAP-0076 item 5), and an unzeroed page table is 512
/// entries of leftover data every one of which the CPU will read as a mapping,
/// with the present bit set roughly half the time. This is the same argument
/// `boot.S` makes for zeroing its four bootstrap pages by explicit address
/// range before it fills any of them.
@bare
void vmZeroFrame(u64 base) {
  u64 o = u64(0);
  while (o < u64(vmPageBytes)) {
    Pointer<u64>.fromAddress(base + o).value = u64(0);
    o = o + u64(8);
  }
}

/// Physical address of page-table frame [i], `0 <= i < vmFrameCount`.
@bare
u64 vmFrame(u64 i) {
  return vmMeta(u64(vmMetaFrame0) + i);
}

/// 1 if physical frame number [f] is one of the frames this kernel's own page
/// tables live in, else 0.
///
/// **Called by `pmmAllocatable`, which is what makes the page tables safe.**
/// They are the first memory the kernel cannot afford to lose that is NOT
/// inside `[__kernel_start, __kernel_end)`, because they come out of the
/// allocator rather than out of the image. Without this clause `free <addr>`
/// would hand a live page table back, and `frames refill` -- which frees
/// everything that was ever allocatable -- would free all six and the next
/// `frames drain` would write test patterns into the running address space.
///
/// A linear scan of at most six words, not a range test: contiguity is checked
/// at boot and would be true today, but a range test would silently start
/// over-reserving if it ever stopped being true, and over-reserving is exactly
/// the kind of quiet drift the derived harness expectations cannot see.
///
/// Reads `vmMetaFrames` first, so it answers 0 for every frame until [vmInit]
/// has actually taken one. `.bss` is not zeroed by anything in this kernel;
/// [vmInit] zeroes the whole block before it allocates, and it runs from
/// `kmain()` before any command can call this.
@bare
u64 vmHoldsFrame(u64 f) {
  final u64 n = vmMeta(u64(vmMetaFrames));
  u64 i = u64(0);
  while (i < n) {
    if ((vmFrame(i) >> u64(vmPageShift)) == f) {
      return u64(1);
    }
    i = i + u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// The map.
// ---------------------------------------------------------------------------

/// The flag bits for the 4KiB page at virtual address [a], inside the
/// [vmFineBytes] window.
///
/// **This function IS the W^X policy**, and it is written as a chain of ranges
/// in ascending order so that the boundaries are visible in one place:
///
/// | range | bits | why |
/// |---|---|---|
/// | `[0, 1MiB)` | RW, NX | VGA text at 0xB8000, the IVT, the BDA. Data, and nothing here executes |
/// | `[__kernel_start, __rodata_start)` | R, X | `.multiboot` + `.text`. **Not writable** |
/// | `[__rodata_start, __data_start)` | R, NX | `.rodata`. Neither writable nor executable |
/// | `[__data_start, 4MiB)` | RW, NX | `.data`, `.bss`, and the RAM above the image |
///
/// The boundaries come from `core/link/kernel.ld` through the accessors above,
/// never from a literal. [vmInit] has already checked that
/// `__kernel_start == 1MiB` and that the two interior boundaries are
/// 4KiB-aligned and in ascending order, which is what makes this chain total.
@bare
u64 vmPageFlags(u64 a) {
  if (a < u64(vmLowBytes)) {
    return u64(vmPresent) | u64(vmWritable) | vmNxBit();
  }
  if (a < kernel_rodata_start()) {
    return u64(vmPresent); // read + execute: no W, no NX
  }
  if (a < kernel_data_start()) {
    return u64(vmPresent) | vmNxBit(); // read only
  }
  return u64(vmPresent) | u64(vmWritable) | vmNxBit();
}

/// Walks [pml4] for virtual address [va] and returns the leaf entry, or **0**
/// if any level along the way is not present.
///
/// 0 is an unambiguous "not mapped": a present entry always has bit 0 set, so
/// it can never be zero.
///
/// This is a SOFTWARE walk of the same tables the hardware walks, and it exists
/// so the kernel can answer questions about its own address space without
/// trusting what it meant to build: [vmSelfCheck] uses it before the switch and
/// [vmScan] uses it for every line of the `vm` report. The harness performs the
/// same walk a third time, out of guest physical memory, from the CR3 QEMU
/// reports.
@bare
u64 vmWalk(u64 pml4, u64 va) {
  final u64 e4 = vmGetEntry(pml4, (va >> u64(39)) & u64(511));
  if ((e4 & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  final u64 e3 = vmGetEntry(vmEntryAddr(e4), (va >> u64(30)) & u64(511));
  if ((e3 & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  final u64 e2 = vmGetEntry(vmEntryAddr(e3), (va >> u64(vmBigShift)) & u64(511));
  if ((e2 & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  if ((e2 & u64(vmHuge)) > u64(0)) {
    return e2; // a 2MiB page: the page-directory entry IS the leaf
  }
  final u64 e1 = vmGetEntry(vmEntryAddr(e2), (va >> u64(vmPageShift)) & u64(511));
  if ((e1 & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  return e1;
}

/// Folds the permissions of every page in `[lo, hi)`, stepping by [step].
///
/// Returns one packed `u64`, because DCDart `@bare` has no tuple, no record and
/// no struct -- there is nothing to return four numbers IN:
///
/// | bits | meaning |
/// |---|---|
/// | 31..0 | how many pages in the range are present |
/// | 32 | writable on EVERY page |
/// | 33 | writable on ANY page |
/// | 34 | executable on EVERY page |
/// | 35 | executable on ANY page |
///
/// The all/any pair is what makes the `vm` report a claim rather than a sample:
/// `W 00` means no page in the region is writable, `W 11` means every page is,
/// and `W 01` means the region is MIXED -- which for `.text` or `.rodata` would
/// be a bug this line would show.
///
/// A page that is not present makes both `all` bits false, so a hole inside a
/// region can never be reported as uniformly protected.
@bare
u64 vmScan(u64 lo, u64 hi, u64 step) {
  final u64 pml4 = vmMeta(u64(vmMetaPml4));
  final u64 nx = vmNxBit();
  u64 present = u64(0);
  u64 wAll = u64(1);
  u64 wAny = u64(0);
  u64 xAll = u64(1);
  u64 xAny = u64(0);
  u64 a = lo;
  while (a < hi) {
    final u64 e = vmWalk(pml4, a);
    if (e > u64(0)) {
      present = present + u64(1);
      if ((e & u64(vmWritable)) > u64(0)) {
        wAny = u64(1);
      } else {
        wAll = u64(0);
      }
      if ((e & nx) > u64(0)) {
        xAll = u64(0);
      } else {
        xAny = u64(1);
      }
    } else {
      wAll = u64(0);
      xAll = u64(0);
    }
    a = a + step;
  }
  return present |
      (wAll << u64(32)) |
      (wAny << u64(33)) |
      (xAll << u64(34)) |
      (xAny << u64(35));
}

/// 1 if [va] is mapped with exactly the permissions asked for, else 0.
///
/// [wantW] and [wantX] are 1 or 0. Used only by [vmSelfCheck].
@bare
u64 vmCheckPage(u64 pml4, u64 va, u64 wantW, u64 wantX) {
  final u64 e = vmWalk(pml4, va);
  if (e < u64(1)) {
    return u64(0);
  }
  u64 w = u64(0);
  if ((e & u64(vmWritable)) > u64(0)) {
    w = u64(1);
  }
  u64 x = u64(1);
  if ((e & vmNxBit()) > u64(0)) {
    x = u64(0);
  }
  if (w == wantW) {
    if (x == wantX) {
      return u64(1);
    }
  }
  return u64(0);
}

/// Walks the freshly built tables for every address the kernel is standing on,
/// BEFORE `CR3` is written. Returns 1 if all of them check out.
///
/// **This is the function that stands between a bug in [vmBuild] and a triple
/// fault.** `mov %rdi,%cr3` is not recoverable: if the new table does not map
/// the next instruction, the stack, or the return address, the CPU takes a page
/// fault, then a double fault trying to deliver it, then triple-faults and QEMU
/// reboots with no output at all. There is no diagnostic to add after the fact,
/// so the check has to happen before.
///
/// Each probe is a real address the kernel will use within microseconds:
///
///   * `kernel_image_start()` -- the first page of `.text`, executable and not
///     writable. This is the code that is about to run;
///   * the last byte of `.text`, likewise -- so a mapping that covered only the
///     first page would be caught;
///   * `vm_exec_ok_addr()` -- an address in `.text` reached as DATA, which
///     `vmtest x` will later fetch from;
///   * `kernel_rodata_start()` -- the message tables `uartWrite` reads, and
///     `boot.S`'s 64-bit GDT, which the CPU itself re-reads on every interrupt.
///     Read-only and, where NX exists, non-executable;
///   * `kernel_data_start()` and the last byte of `.bss` -- the boot stack, the
///     IDT, and every donated word live between them. Writable. The stack is
///     the one a fault would be delivered on;
///   * `vmMetaBase()` and `pmmBitmapBase()` -- the two donated blocks, checked
///     by their own addresses rather than assumed to be inside `.bss`;
///   * `0xB8000` -- the VGA text buffer, writable;
///   * every one of the six page-table frames, writable, because this code
///     keeps reading and writing them after the switch;
///   * the top 4KiB of what the allocator manages, writable -- the same
///     invariant `frames drain`'s TOUCH executes against the bootstrap map;
///   * the base of the PCI hole, writable, which is where the framebuffer BAR
///     lands.
@bare
u64 vmSelfCheck(u64 pml4) {
  u64 ok = u64(1);
  // On a CPU with NX every non-`.text` page reads back NON-executable; on one
  // without it, `vmNxBit()` is 0, no entry carries the bit, and every page
  // reads back executable. `roX` is the expected X for everything that is not
  // `.text`, so this function asks for what the machine can actually deliver
  // instead of failing the whole switch on a CPU that has no NX.
  u64 roX = u64(0);
  if (vmNxBit() < u64(1)) {
    roX = u64(1);
  }
  // `.text`: not writable, executable.
  ok = ok & vmCheckPage(pml4, kernel_image_start(), u64(0), u64(1));
  ok = ok & vmCheckPage(pml4, kernel_text_end() - u64(1), u64(0), u64(1));
  ok = ok & vmCheckPage(pml4, vm_exec_ok_addr(), u64(0), u64(1));
  // `.rodata`: not writable, not executable where NX exists.
  ok = ok & vmCheckPage(pml4, kernel_rodata_start(), u64(0), roX);
  ok = ok & vmCheckPage(pml4, kernel_rodata_end() - u64(1), u64(0), roX);
  // `.data` / `.bss`: writable, not executable where NX exists.
  ok = ok & vmCheckPage(pml4, kernel_data_start(), u64(1), roX);
  ok = ok & vmCheckPage(pml4, kernel_image_end() - u64(1), u64(1), roX);
  ok = ok & vmCheckPage(pml4, vmMetaBase(), u64(1), roX);
  ok = ok & vmCheckPage(pml4, pmmBitmapBase(), u64(1), roX);
  // The VGA text buffer.
  ok = ok & vmCheckPage(pml4, u64(vgaBase), u64(1), roX);
  // The page tables themselves.
  u64 i = u64(0);
  while (i < u64(vmFrameCount)) {
    ok = ok & vmCheckPage(pml4, vmFrame(i), u64(1), roX);
    i = i + u64(1);
  }
  // The top of the managed range, and the PCI hole.
  ok = ok & vmCheckPage(pml4, u64(vmMapBytes) - u64(vmPageBytes), u64(1), roX);
  ok = ok & vmCheckPage(pml4, u64(vmPciBase), u64(1), roX);
  return ok;
}

/// Fills all six tables. Records the page counts. Returns nothing.
///
/// The four levels, in the order they are written, and why each entry is what
/// it is:
///
///   * `PML4[0]` -> the PDPT, present and writable, **NX clear**. A cleared NX
///     at an interior level is not a permission, it is the ABSENCE of a veto:
///     the effective permission of a page is the AND of every level above it,
///     so an NX bit on `PML4[0]` would make `.text` non-executable no matter
///     what its own entry said. Writable is the same: interior entries are
///     permissive and the leaf decides.
///   * `PDPT[0]` -> the page directory for `[0, 1GiB)`, likewise.
///   * `PDPT[3]` -> the page directory for `[3GiB, 4GiB)`, **with NX**, because
///     nothing in the PCI hole is ever executed and a whole-gigabyte veto is
///     free at this level.
///   * `PD_low[0]`, `PD_low[1]` -> the two page tables covering `[0, 4MiB)`.
///   * `PD_low[2..63]` -> 2MiB pages, `[4MiB, 128MiB)`, writable and NX.
///     Entries 64..511 are left zero, so `[128MiB, 1GiB)` is NOT MAPPED -- the
///     bootstrap tables mapped it and this deliberately does not. The allocator
///     manages 128MiB and a frame it cannot address is not a frame it can hand
///     out (ADR-0011 §2); an address above the bound is now a page fault that
///     says so instead of a silent write into RAM nothing tracks.
///   * `PD_pci[0..511]` -> 2MiB pages, `[3GiB, 4GiB)`, writable and NX.
@bare
void vmBuild() {
  final u64 pml4 = vmFrame(u64(vmIxPml4));
  final u64 pdpt = vmFrame(u64(vmIxPdpt));
  final u64 pdLow = vmFrame(u64(vmIxPdLow));
  final u64 pt0 = vmFrame(u64(vmIxPt0));
  final u64 pt1 = vmFrame(u64(vmIxPt1));
  final u64 pdPci = vmFrame(u64(vmIxPdPci));

  u64 i = u64(0);
  while (i < u64(vmFrameCount)) {
    vmZeroFrame(vmFrame(i));
    i = i + u64(1);
  }

  final u64 nx = vmNxBit();
  final u64 pw = u64(vmPresent) | u64(vmWritable);

  vmSetEntry(pml4, u64(0), pdpt | pw);
  vmSetEntry(pdpt, u64(0), pdLow | pw);
  vmSetEntry(pdpt, u64(3), pdPci | pw | nx);
  vmSetEntry(pdLow, u64(0), pt0 | pw);
  vmSetEntry(pdLow, u64(1), pt1 | pw);

  // The 4KiB window: [0, 4MiB), one entry per page, permissions per section.
  u64 pages4k = u64(0);
  i = u64(0);
  while (i < u64(vmFinePages)) {
    final u64 a = i << u64(vmPageShift);
    u64 t = pt0;
    if (i >= u64(vmEntries)) {
      t = pt1;
    }
    vmSetEntry(t, i & u64(511), a | vmPageFlags(a));
    pages4k = pages4k + u64(1);
    i = i + u64(1);
  }

  // 2MiB pages: [4MiB, 128MiB).
  u64 pages2m = u64(0);
  i = u64(vmBigFirst);
  while (i < u64(vmBigLastEx)) {
    vmSetEntry(pdLow, i, (i << u64(vmBigShift)) | pw | u64(vmHuge) | nx);
    pages2m = pages2m + u64(1);
    i = i + u64(1);
  }

  // 2MiB pages: [3GiB, 4GiB), the PCI hole.
  i = u64(0);
  while (i < u64(vmEntries)) {
    vmSetEntry(pdPci, i,
        (u64(vmPciBase) + (i << u64(vmBigShift))) | pw | u64(vmHuge) | nx);
    pages2m = pages2m + u64(1);
    i = i + u64(1);
  }

  vmSetMeta(u64(vmMetaPml4), pml4);
  vmSetMeta(u64(vmMetaPages4k), pages4k);
  vmSetMeta(u64(vmMetaPages2m), pages2m);
}

/// Builds the kernel's real address space and installs it. Prints NOTHING.
///
/// Called from `kmain()` after [pmmInit] -- it needs frames -- and before the
/// first byte of output, for the reason [pmmInit] is: `m1-interrupts/run.sh`
/// asserts the ENTIRE 544-byte serial capture, and one diagnostic line here
/// would break a green milestone. The address space is reported by `vm`, from a
/// prompt, not at boot.
///
/// **Every refusal leaves a running kernel.** If a precondition fails, if the
/// allocator cannot produce six contiguous frames, or if [vmSelfCheck] finds a
/// single page it does not like, this function writes a status word and
/// returns WITHOUT touching CR3 -- and the kernel carries on with the bootstrap
/// tables `boot.S` built, which are the tables it has been running on since M0.
/// `vm` prints `READY 0` and the reason. That is the only design here that
/// degrades gracefully, and it is deliberate: the alternative failure mode for
/// this milestone is a triple fault, which is a VM that reboots with no output
/// at all and nothing to debug.
///
/// The six frames are required to be CONTIGUOUS and that is checked rather than
/// assumed. It is true by construction today -- the allocator is untouched at
/// this point, its cursor is 0, and next-fit from zero returns the six lowest
/// free frames, which are consecutive because the region above the kernel image
/// is -- and the harness derives exactly that. Checking it here means the
/// harness's derivation and the kernel's behaviour cannot silently diverge; if
/// the allocator's search ever changes, this refuses instead of mis-deriving.
@bare
void vmInit() {
  // 1. Give every word of the donated block a known value. `.bss` is not zeroed
  //    by anything in this kernel, and `vmHoldsFrame` reads the frame count on
  //    every `freeFrame` -- a garbage count would make the allocator scan
  //    garbage addresses and refuse random frames.
  u64 i = u64(0);
  while (i < u64(vmStoreWords)) {
    vmSetMeta(i, u64(0));
    i = i + u64(1);
  }

  // 2. Preconditions on the layout the linker produced. Each one is a thing
  //    `vmPageFlags` and `vmBuild` assume, made explicit.
  if (kernel_image_start() > u64(vmLowBytes)) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadBase));
    return;
  }
  if (kernel_image_start() < u64(vmLowBytes)) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadBase));
    return;
  }
  if (kernel_image_end() > u64(vmFineBytes)) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusTooBig));
    return;
  }
  if ((kernel_rodata_start() & u64(vmPageMask)) > u64(0)) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadAlign));
    return;
  }
  if ((kernel_data_start() & u64(vmPageMask)) > u64(0)) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadAlign));
    return;
  }
  if (kernel_rodata_start() <= kernel_image_start()) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadOrder));
    return;
  }
  if (kernel_data_start() < kernel_rodata_start()) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadOrder));
    return;
  }
  if (kernel_text_end() > kernel_rodata_start()) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadOrder));
    return;
  }
  if (kernel_rodata_end() > kernel_data_start()) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusBadOrder));
    return;
  }

  // 3. Six frames from the M7 allocator, contiguous. The count is written as
  //    each one arrives, so `vmHoldsFrame` covers a frame the moment it is
  //    taken -- even if a later step refuses and returns.
  u64 prev = u64(0);
  i = u64(0);
  while (i < u64(vmFrameCount)) {
    final u64 f = allocFrame();
    if (f < u64(1)) {
      vmSetMeta(u64(vmMetaStatus), u64(vmStatusNoFrames));
      return;
    }
    if (i > u64(0)) {
      if (f > prev + u64(vmPageBytes)) {
        vmSetMeta(u64(vmMetaStatus), u64(vmStatusNotContig));
        return;
      }
      if (f < prev + u64(vmPageBytes)) {
        vmSetMeta(u64(vmMetaStatus), u64(vmStatusNotContig));
        return;
      }
    }
    vmSetMeta(u64(vmMetaFrame0) + i, f);
    vmSetMeta(u64(vmMetaFrames), i + u64(1));
    prev = f;
    i = i + u64(1);
  }

  // 4. Fill them.
  vmBuild();

  // 5. Walk what was built, for every address the kernel is standing on, BEFORE
  //    the switch. See vmSelfCheck's own comment for why this is not optional.
  if (vmSelfCheck(vmMeta(u64(vmMetaPml4))) < u64(1)) {
    vmSetMeta(u64(vmMetaStatus), u64(vmStatusSelfCheck));
    return;
  }

  // 6. THE SWITCH. One instruction. The `ret` inside `paging_install` is the
  //    first thing that proves it worked: the return address is on the stack
  //    and points into `.text`, so if either were unmapped, control would not
  //    reach the next line.
  paging_install(vmMeta(u64(vmMetaPml4)));

  vmSetMeta(u64(vmMetaStatus), u64(vmStatusOk));
  vmSetMeta(u64(vmMetaReady), u64(1));

  // 7. Re-take the allocator's baseline, now that six frames are permanently
  //    spoken for. `frames`' BASELINE means "what FREE should return to when
  //    nothing is leaked", and six frames that can never be freed are not a
  //    leak -- they are the address space. Without this, `frames refill` would
  //    report FREE six short of BASELINE forever and the harness's
  //    "returns to baseline exactly" assertion would be measuring the wrong
  //    thing. See `pmmRebaseline`.
  pmmRebaseline();
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

/// One region line: `VM <LABEL> <lo:16> <hi:16> P <count:8> W <all><any> X <all><any>`.
///
/// The `W` and `X` fields are two hex digits each and they are an ALL/ANY pair,
/// not a value: `00` = no page in the region has the bit, `11` = every page
/// does, `01` = the region is mixed. See [vmScan].
@bare
void vmRegionLine(u64 label, u64 labelLen, u64 lo, u64 hi, u64 step) {
  final u64 r = vmScan(lo, hi, step);
  uartWrite(label, labelLen);
  uartPutHex(lo, u64(16));
  uartSpace();
  uartPutHex(hi, u64(16));
  uartWrite(Rodata.addressOf(vmStrP), u64(3));
  uartPutHex(r & u64(0xFFFFFFFF), u64(8));
  uartWrite(Rodata.addressOf(vmStrW), u64(3));
  uartPutHex((r >> u64(32)) & u64(1), u64(1));
  uartPutHex((r >> u64(33)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(vmStrX), u64(3));
  uartPutHex((r >> u64(34)) & u64(1), u64(1));
  uartPutHex((r >> u64(35)) & u64(1), u64(1));
  uartNewline();
}

/// `vm` -- twelve lines describing the address space the CPU is actually using.
///
///     VM CR3 0000000000122000 PML4 0000000000122000 NX 1 WP 1 READY 1 STATUS 00000000
///     VM FRAMES 00000006 SPAN 0000000000122000 0000000000127000
///     VM PAGES 4K 00000400 2M 0000023E
///     VM SECT 0000000000100000 00000000001123AF 0000000000113000 0000000000114C16 0000000000115000 0000000000121470
///     VM TEXT ... VM RODATA ... VM DATA ... VM LOW ... VM HIGH ... VM PCI ...
///     VM CANARY C34F534352575821
///     VM FAULTS 00000000 CR2 0000000000000000 ERR 00000000
///
/// `CR3` is read back OUT OF THE CPU (`mov %cr3,%rax`) rather than reprinted
/// from the metadata, so the line says what is installed rather than what was
/// intended; `PML4` beside it is what this kernel built, and the two being
/// equal is the claim. `tests/conformance/m8-paging/run.sh` compares both
/// against QEMU's own `info registers`, which is a third opinion neither of
/// them can influence.
///
/// The six region lines are produced by WALKING THE LIVE TABLES page by page
/// (1600 walks), not by restating what `vmBuild` wrote. A build that set the
/// wrong bit and a report that restated the intention would agree with each
/// other; a report that walks cannot.
///
/// `VM SECT` is the six link-time section boundaries, unrounded, so the exact
/// section sizes are visible next to the page-rounded region bounds and the
/// harness can assert that no byte of one section shares a page with another.
@bare
void vmReport() {
  uartWrite(Rodata.addressOf(vmStrCr3), u64(7));
  uartPutHex(vmEntryAddr(cr3_read()), u64(16));
  uartWrite(Rodata.addressOf(vmStrPml4), u64(6));
  uartPutHex(vmMeta(u64(vmMetaPml4)), u64(16));
  uartWrite(Rodata.addressOf(vmStrNx), u64(4));
  uartPutHex(nx_enabled(), u64(1));
  // WP, straight off CR0. Printed beside NX because the two together ARE the
  // enforcement: NX without WP is a kernel whose `.rodata` is executable-proof
  // and write-open, which is what this milestone measured before it set WP.
  uartWrite(Rodata.addressOf(vmStrWp), u64(4));
  uartPutHex((cr0_read() >> u64(16)) & u64(1), u64(1));
  uartWrite(Rodata.addressOf(vmStrReady), u64(7));
  uartPutHex(vmMeta(u64(vmMetaReady)), u64(1));
  uartWrite(Rodata.addressOf(vmStrStatus), u64(8));
  uartPutHex(vmMeta(u64(vmMetaStatus)), u64(8));
  uartNewline();

  final u64 n = vmMeta(u64(vmMetaFrames));
  uartWrite(Rodata.addressOf(vmStrFrames), u64(10));
  uartPutHex(n, u64(8));
  uartWrite(Rodata.addressOf(vmStrSpan), u64(6));
  if (n > u64(0)) {
    uartPutHex(vmFrame(u64(0)), u64(16));
    uartSpace();
    uartPutHex(vmFrame(n - u64(1)), u64(16));
  } else {
    uartPutHex(u64(0), u64(16));
    uartSpace();
    uartPutHex(u64(0), u64(16));
  }
  uartNewline();

  uartWrite(Rodata.addressOf(vmStrPages), u64(12));
  uartPutHex(vmMeta(u64(vmMetaPages4k)), u64(8));
  uartWrite(Rodata.addressOf(vmStr2m), u64(4));
  uartPutHex(vmMeta(u64(vmMetaPages2m)), u64(8));
  uartNewline();

  uartWrite(Rodata.addressOf(vmStrSect), u64(8));
  uartPutHex(kernel_image_start(), u64(16));
  uartSpace();
  uartPutHex(kernel_text_end(), u64(16));
  uartSpace();
  uartPutHex(kernel_rodata_start(), u64(16));
  uartSpace();
  uartPutHex(kernel_rodata_end(), u64(16));
  uartSpace();
  uartPutHex(kernel_data_start(), u64(16));
  uartSpace();
  uartPutHex(kernel_image_end(), u64(16));
  uartNewline();

  // The six regions, each walked page by page in the LIVE tables.
  vmRegionLine(Rodata.addressOf(vmStrText), u64(8), kernel_image_start(),
      kernel_rodata_start(), u64(vmPageBytes));
  vmRegionLine(Rodata.addressOf(vmStrRodata), u64(10), kernel_rodata_start(),
      kernel_data_start(), u64(vmPageBytes));
  vmRegionLine(Rodata.addressOf(vmStrData), u64(8), kernel_data_start(),
      u64(vmFineBytes), u64(vmPageBytes));
  vmRegionLine(Rodata.addressOf(vmStrLow), u64(7), u64(0), u64(vmLowBytes),
      u64(vmPageBytes));
  vmRegionLine(Rodata.addressOf(vmStrHigh), u64(8), u64(vmFineBytes),
      u64(vmMapBytes), u64(vmBigBytes));
  vmRegionLine(Rodata.addressOf(vmStrPci), u64(7), u64(vmPciBase),
      u64(vmPciEnd), u64(vmBigBytes));

  // The canary's eight bytes, read back through its own address. If a write to
  // `.rodata` ever landed, this is the line it would show up in.
  uartWrite(Rodata.addressOf(vmStrCanary), u64(10));
  final u64 c = Rodata.addressOf(vmCanary);
  u64 i = u64(0);
  while (i < u64(8)) {
    uartPutHexByteAt(c + i);
    i = i + u64(1);
  }
  uartNewline();

  uartWrite(Rodata.addressOf(vmStrFaults), u64(10));
  uartPutHex(vmMeta(u64(vmMetaFaults)), u64(8));
  uartWrite(Rodata.addressOf(vmStrCr2), u64(5));
  uartPutHex(vmMeta(u64(vmMetaCr2)), u64(16));
  uartWrite(Rodata.addressOf(vmStrErr), u64(5));
  uartPutHex(vmMeta(u64(vmMetaErr)), u64(8));
  uartNewline();
}

/// The page-fault half of the fault diagnostic:
///
///     PF CR2 000000000010E000 ERR 00000003 PRESENT WRITE SUPER DATA
///
/// Printed by [faultReport] for vector 14 only, immediately after the generic
/// `FAULT 0E ERR ... OP ...` line. **CR2 is the whole reason this exists**: the
/// generic line reports the error code and the faulting INSTRUCTION, and for
/// every other fault that is the whole story, but a page fault's subject is an
/// ADDRESS the instruction touched, and that address is only in CR2.
///
/// The error code is decoded rather than left as a number because the four bits
/// answer four different questions and reading them off a hex digit is exactly
/// the kind of thing a diagnostic exists to stop a human doing:
///
/// | bit | set | clear |
/// |---|---|---|
/// | 0 | `PRESENT` -- a protection violation | `NOTPRES` -- nothing is mapped there |
/// | 1 | `WRITE` | `READ` |
/// | 2 | `USER` -- ring 3 | `SUPER` -- ring 0 |
/// | 3 | ` RSVD` appended: a reserved bit is set in some entry | (nothing) |
/// | 4 | `FETCH` -- an instruction fetch | `DATA` |
///
/// Bit 4 is only ever set when `EFER.NXE` is on, which is the mechanical reason
/// `boot.S` sets NXE at boot rather than leaving it to this file: without it a
/// fetch from a non-executable page is not merely permitted, it is
/// indistinguishable from a data read in the report.
///
/// It also RECORDS the fault in the donated block, so `vm` can report the count
/// and the last address long after the diagnostic has scrolled away.
@bare
void vmPageFaultReport(u64 errorCode) {
  final u64 cr2 = cr2_read();
  vmSetMeta(u64(vmMetaFaults), vmMeta(u64(vmMetaFaults)) + u64(1));
  vmSetMeta(u64(vmMetaCr2), cr2);
  vmSetMeta(u64(vmMetaErr), errorCode);

  uartWrite(Rodata.addressOf(vmStrPf), u64(7));
  uartPutHex(cr2, u64(16));
  uartWrite(Rodata.addressOf(vmStrErr), u64(5));
  uartPutHex(errorCode, u64(8));

  uartSpace();
  if ((errorCode & u64(vmPfPresent)) > u64(0)) {
    uartWrite(Rodata.addressOf(vmStrPfPres), u64(7));
  } else {
    uartWrite(Rodata.addressOf(vmStrPfNotPres), u64(7));
  }
  uartSpace();
  if ((errorCode & u64(vmPfWrite)) > u64(0)) {
    uartWrite(Rodata.addressOf(vmStrPfWrite), u64(5));
  } else {
    uartWrite(Rodata.addressOf(vmStrPfRead), u64(4));
  }
  uartSpace();
  if ((errorCode & u64(vmPfUser)) > u64(0)) {
    uartWrite(Rodata.addressOf(vmStrPfUser), u64(4));
  } else {
    uartWrite(Rodata.addressOf(vmStrPfSuper), u64(5));
  }
  uartSpace();
  if ((errorCode & u64(vmPfFetch)) > u64(0)) {
    uartWrite(Rodata.addressOf(vmStrPfFetch), u64(5));
  } else {
    uartWrite(Rodata.addressOf(vmStrPfData), u64(4));
  }
  if ((errorCode & u64(vmPfReserved)) > u64(0)) {
    uartWrite(Rodata.addressOf(vmStrPfRsvd), u64(5));
  }
  uartNewline();
}

// ---------------------------------------------------------------------------
// `vmtest` -- two deliberate faults and two controls.
// ---------------------------------------------------------------------------

/// `vmtest ro` -- STORE THROUGH A POINTER INTO `.rodata`.
///
/// **This is the command GAP-0050 was filed about.** Before this milestone the
/// store below succeeded and nothing anywhere noticed: no compile-time check
/// (DCDart's `Pointer` carries no const-ness and DC-IR has no verifier), and no
/// runtime check either, because every page in the image was writable. The
/// `@rodata` table simply changed.
///
/// Now the store is a #PF: present (the page is mapped), write, supervisor,
/// data -- error code 3. The handler prints it, records it, and
/// `fault_resume()` puts the shell back (M4, ADR-0007), so the session
/// continues and the next `vm` shows the canary unchanged.
///
/// **The address is printed BEFORE the store**, deliberately: it is the last
/// line this command emits on a working kernel, and its absence would mean the
/// fault happened somewhere else. `VM TEST RO SURVIVED` after it means the
/// store landed, i.e. GAP-0050 is open again.
@bare
void vmTestRo() {
  final u64 a = Rodata.addressOf(vmCanary);
  uartWrite(Rodata.addressOf(vmStrTestRo), u64(16));
  uartPutHex(a, u64(16));
  uartNewline();
  // A `u8` store, not a `u64` one, AND THE WIDTH IS NOT A DETAIL.
  //
  // A one-byte write is the more faithful statement of the hazard -- `table[0] =
  // x` is what a stray pointer into a `@rodata` byte table actually does, and a
  // byte is the smallest thing that can prove the page is writable.
  //
  // It is also the width that does not perturb the image. `@rodata` tables are
  // emitted 1-byte aligned and pack against each other with no padding, which
  // is the observable form of ADR-0040's "elements only, no header" promise and
  // is asserted table-by-table by `m1-interrupts/run.sh`. Writing this table
  // through a `Pointer<u64>` made the toolchain give it 8-byte alignment, which
  // opened a 5-byte hole in front of it and failed that assertion -- a real
  // finding, recorded as docs/known-gaps.md GAP-0082. The check was NOT relaxed
  // to accommodate it: an assertion that a milestone weakens in order to pass
  // is not an assertion.
  Pointer<u8>.fromAddress(a).value = u8(0xFF);
  uartWrite(Rodata.addressOf(vmStrTestRoOops), u64(40));
}

/// `vmtest nx` -- INSTRUCTION FETCH FROM `.rodata`.
///
/// The other half of W^X, and the half that needs `EFER.NXE`. `vm_exec_probe`
/// (core/boot/isr.S) does `call *%rdi` into the canary; the canary's first byte
/// is `0xC3` (`ret`), so on a kernel where `.rodata` is executable this returns
/// harmlessly and prints `SURVIVED` instead of executing arbitrary bytes on a
/// machine whose protection has just been shown not to work.
///
/// On this kernel it is a #PF with the instruction-fetch bit set: error code
/// 0x11 -- present, read, supervisor, fetch. The faulting RIP is the canary's
/// own address, so the generic line's ` OP C34F` field is the canary's first
/// two bytes, which is a second, independent statement of where the fetch was
/// aimed.
@bare
void vmTestNx() {
  final u64 a = Rodata.addressOf(vmCanary);
  uartWrite(Rodata.addressOf(vmStrTestNx), u64(16));
  uartPutHex(a, u64(16));
  uartNewline();
  final u64 got = vm_exec_probe(a);
  if (got > u64(0)) {
    uartWrite(Rodata.addressOf(vmStrTestNxOops), u64(37));
  }
}

/// `vmtest rw` -- THE CONTROL FOR `vmtest ro`.
///
/// A store through a `Pointer` -- the same shape as `vmtest ro`'s -- against a page
/// that IS writable: the scratch word in the donated block, which is in `.bss`.
/// It must not fault, and the value must read back.
///
/// **Without this the positive test proves nothing.** "The store to `.rodata`
/// faulted" is equally consistent with "stores fault", with "this kernel is
/// broken", and with "the shell crashed for an unrelated reason". The
/// difference between the two commands is the page, and nothing else.
@bare
void vmTestRw() {
  final u64 a = vmMetaBase() + (u64(vmMetaScratch) << u64(3));
  final u64 want = a ^ u64(0x5A5A5A5A5A5A5A5A);
  uartWrite(Rodata.addressOf(vmStrTestRw), u64(16));
  uartPutHex(a, u64(16));
  uartSpace();
  uartPutHex(want, u64(16));
  uartSpace();
  Pointer<u64>.fromAddress(a).value = want;
  if (Pointer<u64>.fromAddress(a).value == want) {
    uartWrite(Rodata.addressOf(pmmStrOk), u64(2));
  } else {
    uartWrite(Rodata.addressOf(pmmStrFail), u64(4));
  }
  uartNewline();
}

/// `vmtest x` -- THE CONTROL FOR `vmtest nx`.
///
/// The same operation -- `call *%rdi` through `vm_exec_probe` -- against a page
/// that IS executable: `vm_exec_ok`, a lone `ret` in `.text`. It must return.
///
/// Without it, "the call into `.rodata` faulted" would be equally consistent
/// with "indirect calls fault on this kernel", which would say nothing at all
/// about NX.
@bare
void vmTestX() {
  final u64 a = vm_exec_ok_addr();
  uartWrite(Rodata.addressOf(vmStrTestX), u64(15));
  uartPutHex(a, u64(16));
  uartSpace();
  if (vm_exec_probe(a) > u64(0)) {
    uartWrite(Rodata.addressOf(pmmStrOk), u64(2));
  } else {
    uartWrite(Rodata.addressOf(pmmStrFail), u64(4));
  }
  uartNewline();
}

/// `vmtest` with no argument, or with one this shell does not know.
@bare
void vmTestUsage() {
  uartWrite(Rodata.addressOf(vmStrTestUsage), u64(39));
}
