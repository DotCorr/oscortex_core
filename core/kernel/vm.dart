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

/// **U/S — bit 2. The bit this whole kernel did not have until M9.**
///
/// With it clear, a page is SUPERVISOR-ONLY: any access from CPL 3 is a page
/// fault whatever else the entry says. Every page this kernel has ever mapped
/// has had it clear, which is why the `USER`/`SUPER` field of the page-fault
/// report had only ever printed one of its two values (docs/known-gaps.md
/// GAP-0081 item 1).
///
/// Like every other permission it is the AND of the whole chain, so a page is
/// user-accessible only if the PML4 entry, the PDPT entry, the page-directory
/// entry AND the leaf all set it. [vmBuild] sets it on the four interior
/// entries that lead to the 4KiB window and on NO leaf; [vmMapUser] sets it on
/// exactly the leaves a payload needs, and [vmClearUser] takes it away again.
/// That is what makes "the kernel's pages are not user-accessible" a property
/// of every leaf rather than of one interior entry someone might later change.
const int vmUser = 4;

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

/// The 128 bytes this subsystem owns, as a DCDart mutable static.
///
/// Until M17 (ADR-0021) this was `vm_store` in core/boot/kdata.S, reached through
/// `@extern u64 vm_store_addr()`. DCDart grew `@bss` (its ADR-0051), so the storage is
/// declared here, in the file that owns it, and the assembly and its accessor
/// are gone. The seam function below  is unchanged in name, arity and meaning;
/// only the expression it returns moved. That is the whole of ADR-0011 section
/// 0's claim, tested.
@bss
final Bss vmStore = const Bss(bytes: vmStoreBytes);

/// Base of the sixteen-word metadata block.
@bare
u64 vmMetaBase() {
  return Bss.addressOf(vmStore);
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

/// `invlpg (%rdi)` — drop the TLB entries for one page.
///
/// **M9 is the first thing in this kernel that edits a live mapping**, which is
/// exactly the moment docs/known-gaps.md GAP-0083 named. Until now there was
/// one `mov %rdi,%cr3` at boot and writing CR3 flushes everything, so no
/// invalidation was needed anywhere. [vmMapUser] and [vmClearUser] change two
/// leaf entries while the CPU is running on the table those entries are in; a
/// stale translation would make the payload's first instruction fetch fault for
/// a permission that is no longer in the table.
@extern
external void tlb_invlpg(u64 va);

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
  // M9. U/S on the four interior entries that lead into the 4KiB window, and on
  // nothing else. Exactly the same argument the comment above makes for W and
  // NX: an interior entry is not a permission, it is the ABSENCE OF A VETO. A
  // U/S=0 entry on `PML4[0]` would make every leaf under it supervisor-only no
  // matter what the leaf said, so a kernel that wanted ONE user page would have
  // to clear the veto for the whole gigabyte anyway.
  //
  // **Nothing becomes user-accessible because of these four bits.** Every leaf
  // in the table is written with U/S clear below, and the effective permission
  // is the AND. `[4MiB, 128MiB)`'s 2MiB entries and the PCI hole's are leaves,
  // and they do not get it. The conformance harness reads the U bit of all 1600
  // pages out of guest memory and requires every one of them to be 0 before any
  // payload is mapped, which is the only way this claim is worth anything.
  final u64 pwu = pw | u64(vmUser);

  vmSetEntry(pml4, u64(0), pdpt | pwu);
  vmSetEntry(pdpt, u64(0), pdLow | pwu);
  vmSetEntry(pdpt, u64(3), pdPci | pw | nx);
  vmSetEntry(pdLow, u64(0), pt0 | pwu);
  vmSetEntry(pdLow, u64(1), pt1 | pwu);

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
  //
  // `Volatile<u8>`, and here of all places the type is LOAD-BEARING twice
  // over. This is not MMIO — it is a store whose PURPOSE is to fault, i.e.
  // the access itself is the assertion. Since DCDart ADR-0069 made ordinary
  // `Pointer` stores optimizable, LLVM sees this store aiming at a global it
  // knows is `constant`, concludes it is undefined behaviour, and DELETES it
  // — measured, not assumed: built ordinary against the post-split toolchain,
  // `vmtest ro` produces NO fault and the boot's `VM FAULTS` total drops from
  // 2 to 1 (the GAP-0006 shape exactly: the output that says "the probe ran"
  // vanishes with it, so nothing looks wrong). `Volatile` is the spelling for
  // "this access happens, exactly as written", which is the entire point of a
  // probe. `core/scripts/verify-mmio-volatile.sh` asserts this store survives
  // -O2 per site.
  Volatile<u8>.fromAddress(a).value = u8(0xFF);
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
  // `Volatile<u64>` for the same reason `vmtest ro`'s store is: this pair is
  // a control whose value IS the memory access. Written ordinary, -O2
  // forwards the store to the load and prints OK without ever touching the
  // page — the control would then "pass" even on a kernel whose writable
  // mapping was broken. Volatile forces the store to land and the read-back
  // to really read.
  Volatile<u64>.fromAddress(a).value = want;
  if (Volatile<u64>.fromAddress(a).value == want) {
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

// ---------------------------------------------------------------------------
// M9 (docs/decisions/0013-ring-3-and-the-syscall-boundary.md): THE NARROWEST
// POSSIBLE map/unmap API.
//
// GAP-0081 item 3 said this kernel had no `map(va, pa, flags)` / `unmap(va)`
// and that they were "the obvious next thing", deliberately not built because
// nothing needed them. Something needs them now: a ring-3 payload has to have
// two pages the CPU will let CPL 3 touch, and there is no way to express that
// in a table where every leaf is supervisor-only.
//
// WHAT IS BUILT IS NOT `map(va, pa, flags)`. These two functions do not create
// a mapping, do not choose an address, do not allocate a page table and cannot
// map anything that is not already mapped. They flip the U/S bit and the
// W/NX pair of a leaf that already exists inside the 4KiB window, and put it
// back. That is the whole of what M9 needs, and it is a much smaller claim: no
// new level of table can be required, no frame can be needed part-way through,
// and the refusals are three range checks rather than an allocation path.
//
// The general API is still unbuilt and still GAP-0081 item 3. What has changed
// is that the TLB half of it (GAP-0083) is no longer theoretical: both
// functions invalidate, and they invalidate because they were measured to need
// it, not because it seemed prudent.
// ---------------------------------------------------------------------------

/// [vmMapUser] / [vmClearUser] status codes.
const int vmUserOk = 0;

/// The address space was never installed — `vmInit` refused, and the kernel is
/// running on `boot.S`'s bootstrap tables, which this code does not own.
const int vmUserNotReady = 1;

/// Outside `[0, vmFineBytes)`. Only the 4KiB window has per-page leaves; a
/// 2MiB page cannot be given to one payload without giving it 511 more.
const int vmUserOutside = 2;

/// The leaf is not present. Nothing here creates a mapping — see the header.
const int vmUserNotMapped = 3;

/// Address of the page-table ENTRY that maps [va], or 0 if [va] is outside the
/// 4KiB window.
///
/// The window is two page tables, `pt0` covering `[0, 2MiB)` and `pt1` covering
/// `[2MiB, 4MiB)`, and the index within either is bits 20..12 of the address.
/// The frames come from [vmFrame] rather than from a walk, because these two
/// tables are the ones this kernel built and their addresses are recorded; a
/// walk would be a longer way of reaching the same words and would also succeed
/// on a 2MiB page, which is precisely the case that must fail here.
@bare
u64 vmFineLeafSlot(u64 va) {
  if (va >= u64(vmFineBytes)) {
    return u64(0);
  }
  u64 t = vmFrame(u64(vmIxPt0));
  if (va >= u64(vmBigBytes)) {
    t = vmFrame(u64(vmIxPt1));
  }
  return t + (((va >> u64(vmPageShift)) & u64(511)) << u64(3));
}

/// Makes the 4KiB page at [va] reachable from ring 3.
///
/// [exec] selects which of the two shapes a payload page can have, and there
/// are only two on purpose:
///
/// | [exec] | bits | for |
/// |---|---|---|
/// | 1 | present, user, **not writable**, executable | the payload's code |
/// | 0 | present, user, writable, **not executable** | the payload's stack |
///
/// **W^X applies to ring 3 as well, and that is not decoration.** The code page
/// holds the payload's instructions and its message bytes and nothing writes to
/// it after the copy, so it does not need to be writable; the stack is written
/// on every push and nothing is ever fetched from it. A payload that could
/// write its own code, or execute its own stack, would be the same hole this
/// kernel closed for itself at M8, reopened for the one program that is
/// actually untrusted.
///
/// The physical address is preserved out of the existing entry rather than
/// taken from [va], even though the map is identity throughout: this function's
/// job is to change permissions, and reading the frame number back out of the
/// entry means it cannot silently re-point a page at itself if the map ever
/// stops being identity.
@bare
u64 vmMapUser(u64 va, u64 exec) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(vmUserNotReady);
  }
  final u64 slot = vmFineLeafSlot(va);
  if (slot < u64(1)) {
    return u64(vmUserOutside);
  }
  final u64 old = Pointer<u64>.fromAddress(slot).value;
  if ((old & u64(vmPresent)) < u64(1)) {
    return u64(vmUserNotMapped);
  }
  u64 bits = u64(vmPresent) | u64(vmUser);
  if (exec < u64(1)) {
    bits = bits | u64(vmWritable) | vmNxBit();
  }
  Pointer<u64>.fromAddress(slot).value = vmEntryAddr(old) | bits;
  tlb_invlpg(va);
  return u64(vmUserOk);
}

/// Puts the 4KiB page at [va] back the way [vmBuild] would have written it.
///
/// The restored bits come from [vmPageFlags], the same function that wrote them
/// at boot, so there is one definition of what a kernel page's permissions are
/// and this cannot drift from it. In particular the page goes back to
/// **supervisor**: after this returns, ring 3 cannot reach it, and the `user`
/// command's second permission report says so from a fresh walk of the tables.
///
/// Called on the normal exit path from `shellUser` and on the fault path from
/// `userAbort`, so a payload that dies with a #GP does not leave a
/// user-accessible page behind. That is the difference between a privilege
/// boundary and a privilege boundary that is open whenever something went
/// wrong.
@bare
u64 vmClearUser(u64 va) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(vmUserNotReady);
  }
  final u64 slot = vmFineLeafSlot(va);
  if (slot < u64(1)) {
    return u64(vmUserOutside);
  }
  final u64 old = Pointer<u64>.fromAddress(slot).value;
  if ((old & u64(vmPresent)) < u64(1)) {
    return u64(vmUserNotMapped);
  }
  Pointer<u64>.fromAddress(slot).value = vmEntryAddr(old) | vmPageFlags(va);
  tlb_invlpg(va);
  return u64(vmUserOk);
}

/// The EFFECTIVE permissions of [va], combined across all four levels, packed
/// into one `u64` because `@bare` DCDart has no tuple, record or struct.
///
/// | bit | meaning |
/// |---|---|
/// | 0 | present |
/// | 1 | user-accessible (U/S set at EVERY level) |
/// | 2 | writable (RW set at every level) |
/// | 3 | executable (NX clear at every level) |
///
/// **The AND, not the leaf**, for the reason `m8-paging/derive.py` gives: a
/// directory entry with U/S clear makes everything under it supervisor-only
/// whatever the leaf says, so a report that read only the leaf would claim a
/// page was user-accessible when the CPU would refuse it — and, worse, would
/// claim a page was NOT user-accessible for the wrong reason.
///
/// Zero means "not mapped", unambiguously: a present page always has bit 0.

/// The physical address of the PML4 the CPU is ACTUALLY WALKING, or 0.
///
/// **M11 changed what "the live tables" means, and this function is where.**
/// Until M11 there was exactly one address space and `vmMeta(vmMetaPml4)` — the
/// root this kernel built at boot — was the same number CR3 held, forever. A
/// process has its own PML4 (ADR-0015 §3) and CR3 changes when one is entered,
/// so a walk rooted at the kernel's remembered PML4 would report the KERNEL's
/// view of an address while a process was on the CPU. Every doc comment in this
/// file already said "the live tables"; this makes that true when there is more
/// than one set of them.
///
/// [vmMetaReady] is checked first and it is not a formality: if `vmInit`
/// refused, CR3 still holds `boot.S`'s bootstrap tables, which this kernel did
/// not build and whose shape it does not know. Zero — "nothing is mapped" — is
/// the safe answer, and it is what every caller already treats an unmapped
/// address as.
@bare
u64 vmLivePml4() {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(0);
  }
  return vmEntryAddr(cr3_read());
}

@bare
u64 vmEffective(u64 va) {
  final u64 pml4 = vmLivePml4();
  if (pml4 < u64(1)) {
    return u64(0);
  }
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
  u64 both = e4 & e3;
  both = both & e2;
  u64 either = e4 | e3;
  either = either | e2;
  if ((e2 & u64(vmHuge)) < u64(1)) {
    final u64 e1 = vmGetEntry(vmEntryAddr(e2), (va >> u64(vmPageShift)) & u64(511));
    if ((e1 & u64(vmPresent)) < u64(1)) {
      return u64(0);
    }
    both = both & e1;
    either = either | e1;
  }
  u64 r = u64(1);
  if ((both & u64(vmUser)) > u64(0)) {
    r = r | u64(2);
  }
  if ((both & u64(vmWritable)) > u64(0)) {
    r = r | u64(4);
  }
  // NX is a VETO, so it combines the other way: any level with bit 63 set makes
  // the page non-executable. On a CPU with no NX, `vmNxBit()` is 0, the mask is
  // empty, and every present page reads back executable — which is the truth
  // about that machine rather than a default.
  if ((either & vmNxBit()) < u64(1)) {
    r = r | u64(8);
  }
  return r;
}

/// How many 4KiB pages in `[lo, hi)` are user-accessible.
///
/// The kernel's own half of M9's central claim, and a COUNT rather than a
/// yes/no on purpose: `user` prints it over the whole 4MiB window, so the
/// statement is "none of the 1024 pages" before a payload is mapped, "exactly
/// two" while one is running, and "none" again afterwards. A boundary that held
/// only for the pages somebody thought to check would not be one.
///
/// `tests/conformance/m9-ring3/run.sh` performs the same scan out of guest
/// physical memory with its own walk, because the kernel's report is evidence
/// and not proof.
@bare
u64 vmCountUser(u64 lo, u64 hi) {
  u64 n = u64(0);
  u64 a = lo;
  while (a < hi) {
    if ((vmEffective(a) & u64(2)) > u64(0)) {
      n = n + u64(1);
    }
    a = a + u64(vmPageBytes);
  }
  return n;
}

// ---------------------------------------------------------------------------
// M10 (docs/decisions/0014-elf-loader.md): A REAL `map(va, pa, flags)`, IN ONE
// 2MiB WINDOW.
//
// M9 built the narrowest possible map/unmap API and said so: `vmMapUser` and
// `vmClearUser` flip bits on a leaf that ALREADY EXISTS inside the 4KiB
// identity window. That is enough for a payload that can be copied into
// whatever frame the allocator hands out, and it is not enough for a program
// linked at an address of its own choosing -- which is what an ELF executable
// is. `e_entry` and every `p_vaddr` in the file are addresses the LINKER
// picked, and honouring them is the difference between loading a program and
// copying some bytes.
//
// So this is the real thing: it CREATES a mapping, at an address the caller
// names, pointing at a frame the caller allocated, with permissions the caller
// derived from `p_flags`. GAP-0081 item 3 is narrowed a long way further.
//
// WHAT IS STILL NOT GENERAL, stated here so the next reader does not have to
// measure it:
//
//   * ONE 2MiB window, `[vmProgBase, vmProgEnd)`, and one page table for it.
//     An address outside that range is refused, not mapped somewhere else.
//   * The page table's frame is supplied by the CALLER. Nothing here allocates,
//     so no mapping can fail half-way through for want of memory -- the failure
//     happens at `vmProgTableInstall` or not at all.
//   * ONE level of table is created. The PML4 entry, the PDPT entry and the
//     page directory for `[0, 1GiB)` all already exist, because M8 built them
//     for the identity map; this writes one page-directory entry and then leaf
//     entries under it.
//
// WHY 256MiB. The window has to be somewhere that is NOT already mapped, or
// installing it would silently replace part of the kernel's own address space.
// `[0, 4MiB)` is the 4KiB identity window and holds the kernel image;
// `[4MiB, 128MiB)` is 2MiB leaves and `vmMapBytes` says the allocator hands out
// frames from it; `[3GiB, 4GiB)` is the PCI hole. `[128MiB, 1GiB)` is the gap
// between the top of RAM this kernel maps and the top of the page directory it
// already has -- 62 unused page-directory entries. 0x10000000 is the first
// 2MiB-aligned address in it that is a round number, and PD entry 128 is
// consequently untouched by anything M0-M9 built.
//
// W^X IS ENFORCED HERE, not only by the caller. `vmProgMap` REFUSES a request
// that asks for writable and executable together, so an ELF segment with
// PF_W|PF_X cannot be mapped even by a caller that forgot to check. ADR-0012
// bought that property for the kernel; a guest does not get an exemption from
// it.
// ---------------------------------------------------------------------------

/// Base of the program window: 256MiB. See the block comment above for why.
const int vmProgBase = 0x10000000;

/// One past its end: 258MiB. Exactly one page-directory entry's worth, so it
/// needs exactly one page table.
const int vmProgEnd = 0x10200000;

/// Its size, and the number of 4KiB pages in it. Spelled out rather than
/// computed for GAP-0077's reason (`dcc` at `DCDART_PIN.txt`'s commit refuses a
/// `u64` literal built from a constant expression);
/// `tests/conformance/m10-elf/run.sh` multiplies them against each other.
const int vmProgBytes = 2097152;
const int vmProgPages = 512;

/// Index of the window's entry in the page directory for `[0, 1GiB)`:
/// `vmProgBase / vmBigBytes`. Entries 0 and 1 are the 4KiB window's two page
/// tables and 2..63 are the 2MiB leaves of `[4MiB, 128MiB)`, so 128 is well
/// clear of everything M8 built.
const int vmProgPdIndex = 128;

/// The stack the loaded program is entered on: the LAST page of the window,
/// with RSP starting at its top.
const int vmProgStackPage = 0x101FF000;
const int vmProgStackTop = 0x10200000;

// [vmProgMap] / [vmProgTableInstall] status codes.
const int vmProgOk = 0;

/// The address space was never installed — `vmInit` refused.
const int vmProgNotReady = 1;

/// The address is outside `[vmProgBase, vmProgEnd)`. Nothing here maps anything
/// anywhere else, on purpose.
const int vmProgOutside = 2;

/// No page table is installed for the window, so there is no leaf to write.
const int vmProgNoTable = 3;

/// Something is already there — a second `vmProgTableInstall`, or a second
/// mapping of the same page. **Refused rather than overwritten**: two ELF
/// segments that share a page is a file this loader does not understand, and
/// silently letting the second one win would load half a program.
const int vmProgBusy = 4;

/// A virtual or physical address that is not 4KiB-aligned.
const int vmProgBadAlign = 5;

/// The caller asked for a page that is both writable and executable. See the
/// block comment: this kernel does not have such pages and does not make one
/// for a guest.
const int vmProgWx = 6;

/// Physical address of the window's page table, or 0 if none is installed.
///
/// Read out of the live page directory rather than remembered, for
/// [vmFineLeafSlot]'s inverse reason: this entry is one this kernel writes and
/// clears at runtime, so the only trustworthy answer is the one in the table.
/// A 2MiB leaf in that slot answers 0 as well — it would not be a page table
/// and walking it as one is how a loader corrupts an address space.

/// Physical address of the page directory covering `[0, 1GiB)` of the LIVE
/// address space, or 0 if there is not one.
///
/// **M11: this is the one line that made the whole program-window API
/// per-process.** It used to be `vmFrame(vmIxPdLow)` — the kernel's own page
/// directory, spelled as a constant, because there was only ever one. Walking
/// to it from CR3 instead means [vmProgTableInstall], [vmProgMap] and
/// [vmProgUnmap] edit whichever address space is installed, and not one line of
/// `core/kernel/elf.dart` had to learn that processes exist: the loader runs
/// with the target process's CR3 already in the register (ADR-0015 §4).
///
/// Under the kernel's own CR3 this returns exactly `vmFrame(vmIxPdLow)`, which
/// is what M10's `run` command still gets, byte for byte. That equality is not
/// left to the reader — `vm` prints both and `m11-proc/run.sh` requires them
/// equal with no process running, and DIFFERENT with one running.
///
/// Every level is checked for present-and-not-huge before it is followed. A
/// 1GiB leaf in `PDPT[0]` would not be a page directory, and walking one as if
/// it were is how a loader writes a page-table entry into the middle of
/// somebody's data.
@bare
u64 vmProgPd() {
  final u64 pml4 = vmLivePml4();
  if (pml4 < u64(1)) {
    return u64(0);
  }
  final u64 e4 = vmGetEntry(pml4, u64(0));
  if ((e4 & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  if ((e4 & u64(vmHuge)) > u64(0)) {
    return u64(0);
  }
  final u64 e3 = vmGetEntry(vmEntryAddr(e4), u64(0));
  if ((e3 & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  if ((e3 & u64(vmHuge)) > u64(0)) {
    return u64(0);
  }
  return vmEntryAddr(e3);
}

@bare
u64 vmProgTable() {
  final u64 pd = vmProgPd();
  if (pd < u64(1)) {
    return u64(0);
  }
  final u64 e = vmGetEntry(pd, u64(vmProgPdIndex));
  if ((e & u64(vmPresent)) < u64(1)) {
    return u64(0);
  }
  if ((e & u64(vmHuge)) > u64(0)) {
    return u64(0);
  }
  return vmEntryAddr(e);
}

/// Drops the TLB and paging-structure cache entries for the whole window.
///
/// **Every page, not only the ones that were mapped.** `invlpg` invalidates the
/// cached INTERIOR entries for the page it names as well as the leaf, and the
/// page directory entry this file installs and removes is exactly such an
/// interior entry. There is no instruction that says "forget one page-directory
/// entry", so the 512 pages it covers are named one at a time. GAP-0083's
/// question, asked for the second time and answered the same way.
@bare
void vmProgFlush() {
  u64 a = u64(vmProgBase);
  while (a < u64(vmProgEnd)) {
    tlb_invlpg(a);
    a = a + u64(vmPageBytes);
  }
}

/// Installs [ptFrame] as the window's page table. Zeroes it first.
///
/// The frame comes from the caller — from `allocFrame()`, in practice — and it
/// is zeroed here rather than by the caller because 512 words of allocator
/// litter installed as a page table is 512 mappings the CPU will believe, with
/// the present bit set in roughly half of them. `vmZeroFrame`'s own note makes
/// the same argument for `boot.S`.
///
/// The page-directory entry gets `present | writable | user`, and no NX. An
/// interior entry is the ABSENCE of a veto (ADR-0012 §5, ADR-0013 §5): the leaf
/// decides, and an interior entry that withheld W, U or X would make every leaf
/// under it unable to have them whatever `p_flags` said.
@bare
u64 vmProgTableInstall(u64 ptFrame) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(vmProgNotReady);
  }
  if ((ptFrame & u64(vmPageMask)) > u64(0)) {
    return u64(vmProgBadAlign);
  }
  if (vmProgTable() > u64(0)) {
    return u64(vmProgBusy);
  }
  // M11: the LIVE page directory, which is the process's if one is installed.
  // Refused rather than defaulted to the kernel's if the walk cannot reach one:
  // installing a program's page table in the wrong address space is not a thing
  // to guess at.
  final u64 pd = vmProgPd();
  if (pd < u64(1)) {
    return u64(vmProgNotReady);
  }
  vmZeroFrame(ptFrame);
  vmSetEntry(pd, u64(vmProgPdIndex),
      ptFrame | u64(vmPresent) | u64(vmWritable) | u64(vmUser));
  vmProgFlush();
  return u64(vmProgOk);
}

/// Takes the window's page table back out of the page directory.
///
/// After this the whole of `[vmProgBase, vmProgEnd)` is unmapped again and
/// `vmEffective` reports it as such — which is what makes "the program's
/// address space is gone" a property of the tables rather than of a flag. The
/// caller still owns the page-table frame and must free it.
@bare
u64 vmProgTableRemove() {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(vmProgNotReady);
  }
  final u64 pd = vmProgPd();
  if (pd < u64(1)) {
    return u64(vmProgNotReady);
  }
  vmSetEntry(pd, u64(vmProgPdIndex), u64(0));
  vmProgFlush();
  return u64(vmProgOk);
}

/// Address of the page-table ENTRY for [va], or 0 if [va] is outside the window
/// or no page table is installed.
@bare
u64 vmProgLeafSlot(u64 va) {
  if (va < u64(vmProgBase)) {
    return u64(0);
  }
  if (va >= u64(vmProgEnd)) {
    return u64(0);
  }
  final u64 t = vmProgTable();
  if (t < u64(1)) {
    return u64(0);
  }
  return t + (((va >> u64(vmPageShift)) & u64(511)) << u64(3));
}

/// The leaf ENTRY for [va] — the raw `u64`, including its flag bits — or 0 if
/// there is none. Used by the teardown to recover the frame it has to free.
@bare
u64 vmProgLeaf(u64 va) {
  final u64 slot = vmProgLeafSlot(va);
  if (slot < u64(1)) {
    return u64(0);
  }
  return Pointer<u64>.fromAddress(slot).value;
}

/// Maps the frame at physical address [pa] into the window at virtual address
/// [va], user-accessible, with [write] and [exec] deciding the other two bits.
///
/// **This is the function `p_flags` turns into.** `PF_W` becomes [write] and
/// `PF_X` becomes [exec], and the refusals below are the whole of what this
/// kernel is willing to do for a guest:
///
///   * both set → [vmProgWx]. Not "the writable bit wins" and not "the
///     executable bit wins": refused, so the caller has to decide out loud. A
///     W+X page for a program that arrived on a disk is the hole ADR-0012
///     closed for the kernel, reopened for the one thing that is actually
///     untrusted;
///   * a page that is already mapped → [vmProgBusy]. Two `PT_LOAD` segments
///     sharing a page cannot both get their permissions, and whichever one lost
///     would be wrong silently;
///   * an address outside the window → [vmProgOutside]. Not relocated, not
///     clamped.
///
/// The physical address is taken from [pa] rather than from [va], which is the
/// difference between this and `vmMapUser`: there is no identity here, and
/// there cannot be — the program's addresses were chosen by a linker on another
/// machine.
@bare
u64 vmProgMap(u64 va, u64 pa, u64 write, u64 exec) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(vmProgNotReady);
  }
  if ((va & u64(vmPageMask)) > u64(0)) {
    return u64(vmProgBadAlign);
  }
  if ((pa & u64(vmPageMask)) > u64(0)) {
    return u64(vmProgBadAlign);
  }
  if (va < u64(vmProgBase)) {
    return u64(vmProgOutside);
  }
  if (va >= u64(vmProgEnd)) {
    return u64(vmProgOutside);
  }
  if (write > u64(0)) {
    if (exec > u64(0)) {
      return u64(vmProgWx);
    }
  }
  final u64 t = vmProgTable();
  if (t < u64(1)) {
    return u64(vmProgNoTable);
  }
  final u64 slot = t + (((va >> u64(vmPageShift)) & u64(511)) << u64(3));
  final u64 old = Pointer<u64>.fromAddress(slot).value;
  if ((old & u64(vmPresent)) > u64(0)) {
    return u64(vmProgBusy);
  }
  u64 bits = u64(vmPresent) | u64(vmUser);
  if (write > u64(0)) {
    bits = bits | u64(vmWritable);
  }
  if (exec < u64(1)) {
    bits = bits | vmNxBit();
  }
  Pointer<u64>.fromAddress(slot).value = pa | bits;
  tlb_invlpg(va);
  return u64(vmProgOk);
}

/// Clears the leaf for [va] and invalidates it. Returns [vmProgOk] even if
/// nothing was mapped: the postcondition is "nothing is mapped here", and a
/// teardown that walked 512 pages and reported a status per empty slot would
/// bury the one that mattered.
@bare
u64 vmProgUnmap(u64 va) {
  final u64 slot = vmProgLeafSlot(va);
  if (slot < u64(1)) {
    return u64(vmProgOutside);
  }
  Pointer<u64>.fromAddress(slot).value = u64(0);
  tlb_invlpg(va);
  return u64(vmProgOk);
}

/// 1 if the two bytes at [va] are present in the LIVE page tables, else 0.
///
/// **A safety question asked of the tables rather than of a constant.**
/// `faultReport` prints the first two opcode bytes at the faulting RIP, and
/// dereferencing an address that is not mapped INSIDE A FAULT HANDLER is a
/// double fault and then a triple fault -- so it has always been guarded. Until
/// M10 the guard was `rip < mappedLimit`, i.e. the 16MiB `boot.S` maps, which
/// was right when it was written and became conservative at M8 (the address
/// space maps 128MiB) and wrong at M10: a loaded program runs at 256MiB, so
/// every fault it took printed `OP ----` for an address that was perfectly
/// readable. That is not a false claim -- `----` means "not read" -- but it
/// throws away the one field that identifies the faulting instruction, in
/// exactly the case where the instruction came off a disk and is the thing in
/// question. docs/known-gaps.md GAP-0064 is narrowed accordingly.
///
/// **[vmMetaReady] is checked first and it is not a formality.** If `vmInit`
/// refused, the kernel is on `boot.S`'s bootstrap tables, `vmMetaPml4` is zero,
/// and walking from address 0 would follow whatever the first page of memory
/// contains as if it were a PML4 -- which is precisely the "diagnosing a fault
/// kills the machine" outcome the guard exists to prevent. With it, the walk is
/// over tables this kernel built, whose frames are all inside the mapped
/// window.
@bare
u64 vmFetchSafe(u64 va) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    return u64(0);
  }
  // Bounded before the +1, for the reason every other bound in this kernel
  // comes first: DCDart's arithmetic traps on overflow with a real `ud2`, and
  // this runs inside a fault handler.
  if (va >= u64(0xFFFFFFFFFFFFF000)) {
    return u64(0);
  }
  if ((vmEffective(va) & u64(1)) < u64(1)) {
    return u64(0);
  }
  if ((vmEffective(va + u64(1)) & u64(1)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}
