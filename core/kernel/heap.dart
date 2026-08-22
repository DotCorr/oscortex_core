// core/kernel/heap.dart
//
// M12: A HEAP A USER PROCESS CAN GROW AT RUNTIME.
//
// A `part` of `kmain.dart`'s library rather than an import, for the reason every
// other file here is: `dcc` lowers exactly ONE library per object file, so a
// `@bare` function in an imported library is not compiled at all
// (docs/known-gaps.md GAP-0004 item 4).
//
// ---------------------------------------------------------------------------
// WHAT THIS ADDS, AND WHY IT IS THE SMALLEST THING THAT COUNTS
// ---------------------------------------------------------------------------
// At M11 a process's address space was exactly what its ELF asked for plus one
// stack page, FOREVER (docs/known-gaps.md GAP-0096 item 6). No `brk`, no
// `mmap`, no syscall that returns a page. That is the wall `malloc` is on the
// wrong side of, and therefore the wall every real C program is on the wrong
// side of: `malloc` is not a library problem, it is a kernel problem wearing a
// library's name.
//
// This file adds ONE syscall, `sbrk` (number 4). It takes a byte increment in
// RDI, rounds it up to whole 4KiB pages, takes those pages from the SAME frame
// allocator everything else here uses, maps them into THE CALLING PROCESS's
// address space user + writable + NX, and returns the OLD break -- the base of
// the region the caller now owns. See docs/decisions/0016 for why `sbrk` and
// not `brk` and not `mmap`.
//
// ---------------------------------------------------------------------------
// IT IS A MONOTONIC PAGE-GRANULAR BREAK WITH NO SHRINK AND NO REUSE, AND THIS
// COMMENT IS WHERE THAT IS SAID PLAINLY
// ---------------------------------------------------------------------------
// The break only ever moves UP. `sbrk(0)` reports it; a positive increment
// advances it; a negative increment is not expressible (`@bare` DCDart has no
// signed type -- GAP-0023 -- so RDI arrives as a `u64` and a "negative"
// increment is an enormous positive one, which is refused as [heapRetBadArg]).
// Nothing inside a process's lifetime ever gives a heap page back. A process
// that grows its heap and then stops using it holds those frames until it exits.
//
// That is a BUMP POINTER. It is the interface a first `malloc` wants and it is
// not an allocator: there is no free list, no coalescing and no reuse.
// docs/known-gaps.md GAP-0107 is the accounting.
//
// The pages ARE given back, all of them, when the process exits or faults --
// and not by anything in this file. `procSpaceFree` already walks the process's
// OWN window page table and frees every present leaf it finds, because M11 made
// the tables (rather than a remembered list) the thing a teardown is checked
// against. A heap page is a present leaf in that table, so it goes back through
// exactly the path a program page goes back through. `m12-heap/run.sh` asserts
// the PMM's free count is identical before and after, to the frame.
//
// ---------------------------------------------------------------------------
// WHERE THE HEAP LIVES, AND WHY THE WINDOW DID NOT HAVE TO GROW
// ---------------------------------------------------------------------------
// `[vmProgBase, vmProgEnd)` is 2MiB -- 512 pages, one page-directory entry, one
// page table (ADR-0014). A loaded program occupies the low end of it and its
// stack is the LAST page, `[vmProgStackPage, vmProgStackTop)`. Everything in
// between has been unmapped since M10 and nothing has ever been put there.
//
// So the heap starts at the first page above the program's highest mapped page
// -- `elfMetaHi`, which `procCreate` copies into `procSlotHi`, which is a number
// the LOADER computed from the file's own `p_vaddr`s -- and grows upward toward
// the stack. It stops one page short of the stack page: [heapTop] is
// `vmProgStackPage - 4096`, and that page is never mapped by anything.
//
// **THAT UNMAPPED PAGE IS A GUARD PAGE AND IT IS THE ONLY REASON THE TWO CAN
// SHARE A WINDOW.** Without it a heap grown to its limit would abut the stack,
// and a program that overran its stack downward would land in its own heap and
// corrupt it silently. With it, the overrun is a #PF at a page nothing maps --
// which this kernel already reports and already tears the process down for.
// The stack still does not grow (GAP-0096 item 5); the guard is what makes "it
// does not grow" a fault rather than a corruption.
//
// The window did not have to grow, and NOT growing it is the point: 512 pages
// minus the program minus the stack minus the guard is around 500 pages, about
// 2MiB, and that bound is REACHED by this milestone's own test program rather
// than being a number nobody ever gets near. A refusal path that cannot be
// walked is a sentence the machine cannot say (m11-proc/run.sh 3g's lesson).
//
// ---------------------------------------------------------------------------
// EVERY FAILURE IS A RETURN VALUE. NOTHING HERE FAULTS.
// ---------------------------------------------------------------------------
// The whole point of the exercise is that a program can ASK for memory and be
// TOLD NO. Three refusals, three distinct bit patterns in RAX, all of them in
// the top page of the address space so that no legal break can ever be confused
// with one:
//
//   * [heapRetNoSpace]  the window has no room left. Checked BEFORE a single
//                       frame is taken, so a request that cannot fit costs
//                       nothing.
//   * [heapRetNoMem]    the frame allocator ran out part-way. **Every page
//                       already mapped by THIS call is unmapped and freed
//                       before returning** ([heapRollback]) -- the break does
//                       not move, so the failure is atomic and a retry after
//                       something else exits is a clean retry.
//   * [heapRetBadArg]   an increment larger than the whole window. Refused
//                       before any arithmetic that could overflow, because
//                       DCDart traps on overflow with a real `ud2` and doing
//                       that inside a syscall handler would take the machine
//                       down instead of the request.
//
// A program checks with one comparison: `ret > 0xFFFFFFFFFFFFF000` is an error.
//
// ---------------------------------------------------------------------------
// THE PAGES ARE ZEROED, AND THAT IS AN ISOLATION PROPERTY RATHER THAN HYGIENE
// ---------------------------------------------------------------------------
// `allocFrame()` hands back whatever the frame last contained (GAP-0076 item 5)
// and this kernel recycles frames between processes. A heap page handed to a
// process unzeroed is a page of some previous process's data, user-readable, in
// the one place a program is guaranteed to look. Every frame goes through
// `vmZeroFrame` before its mapping is written -- BEFORE, so there is no window
// in which the page is reachable from ring 3 and still holds the old contents.
// The test program reads every byte of every page it is given before it writes
// one, and reports what it found (GAP-0094's complaint, answered for the one
// case where a behavioural test is actually possible).
//
// ---------------------------------------------------------------------------
// STORAGE (ADR-0011)
// ---------------------------------------------------------------------------
// The four numbers a heap needs -- base, break, page count, call count -- live
// in words 16..19 of the process's OWN slot, reached through `procGet`/`procSet`
// and therefore through proc.dart's existing three-function storage seam. **No
// new donated `.bss`, no new `@extern`, and no fourth call site of the seam's
// accessor** -- which m11-proc/run.sh enforces by refusing to see that symbol's
// name in any file but proc.dart, comments included, so this one does not spell
// it. M11 left slot words 16..31 unused on purpose so that a
// later field would land somewhere somebody chose; this is that field.
// ---------------------------------------------------------------------------

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The shape. Every number a literal rather than a constant expression, for
// GAP-0077's reason (`dcc` at `DCDART_PIN.txt`'s commit refuses a `u64` literal
// built from a constant expression). `tests/conformance/m12-heap/run.sh`
// multiplies them against each other and against vm.dart's window geometry.
// ---------------------------------------------------------------------------

/// Syscall 4 — `sbrk(increment)`.
///
/// Declared here rather than beside `userSysExitNo` in `user.dart` for
/// `procSysYieldNo`'s reason: the syscall does not exist without a process to
/// own the address space it grows, and it is refused when there is not one.
const int heapSysSbrkNo = 4;

/// One past the highest byte any heap may ever reach: `vmProgStackPage - 4096`.
///
/// The page `[heapTop, vmProgStackPage)` is the GUARD PAGE and nothing in this
/// kernel ever maps it. See the header.
const int heapTop = 0x101FE000;

/// Its page number inside the window, `(heapTop - vmProgBase) / 4096` = 510.
/// Spelled out so the harness can multiply it back out against
/// [heapTop], [vmProgBase] and [vmPageShift] instead of trusting either.
const int heapTopIndex = 510;

/// The guard page's own address, and its index. Named rather than computed so
/// that "there is a guard page" is a thing the harness can assert the ABSENCE
/// of a mapping at, by name.
const int heapGuardPage = 0x101FE000;
const int heapGuardIndex = 510;

/// The largest increment one call may ask for: the whole window, 2MiB.
///
/// Anything larger is [heapRetBadArg] and is refused BEFORE the round-up, which
/// is the arithmetic that would overflow. A `u64` increment of
/// 0xFFFFFFFFFFFFFFFF -- what a C program passing `-1` produces -- lands here.
const int heapMaxInc = 2097152;

/// Page-alignment mask as a positive literal: `~4095` in 64 bits.
const int heapPageAlignMask = 0xFFFFFFFFFFFFF000;

/// Anything at or above this in RAX is a refusal rather than an address.
///
/// The window ends at 258MiB, so no legal break is within eight billion of it.
/// A program tests `ret > heapRetFloor`.
const int heapRetFloor = 0xFFFFFFFFFFFFF000;

/// The three refusals. Distinct values, not a shared `-1`, because "the machine
/// is out of memory" and "your address space is full" are different facts and a
/// program that cannot tell them apart cannot do anything sensible about
/// either.
const int heapRetNoMem = 0xFFFFFFFFFFFFFFFC;
const int heapRetNoSpace = 0xFFFFFFFFFFFFFFFD;
const int heapRetBadArg = 0xFFFFFFFFFFFFFFFE;

// Slot words. M11's table left 16..31 free; these are the first four of them.
const int heapSlotBase = 16;
const int heapSlotBrk = 17;
const int heapSlotPages = 18;
const int heapSlotCalls = 19;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040). The length is
// carried at the CALL SITE by hand, which is GAP-0060; a wrong number prints
// the next table's bytes and `m12-heap/run.sh` checks every one of them against
// the linked image.
// ---------------------------------------------------------------------------

/// `'PROC HEAP '` -- 10 bytes.
@rodata
final List<u8> heapStrLine = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x48),
  u8(0x45), u8(0x41), u8(0x50), u8(0x20),
];

/// `' INC '` -- 5 bytes.
@rodata
final List<u8> heapStrInc = const [
  u8(0x20), u8(0x49), u8(0x4E), u8(0x43), u8(0x20),
];

/// `' OLD '` -- 5 bytes.
@rodata
final List<u8> heapStrOld = const [
  u8(0x20), u8(0x4F), u8(0x4C), u8(0x44), u8(0x20),
];

/// `' NEW '` -- 5 bytes.
@rodata
final List<u8> heapStrNew = const [
  u8(0x20), u8(0x4E), u8(0x45), u8(0x57), u8(0x20),
];

/// `' BASE '` -- 6 bytes.
@rodata
final List<u8> heapStrBase = const [
  u8(0x20), u8(0x42), u8(0x41), u8(0x53), u8(0x45), u8(0x20),
];

/// `' TOP '` -- 5 bytes.
@rodata
final List<u8> heapStrTop = const [
  u8(0x20), u8(0x54), u8(0x4F), u8(0x50), u8(0x20),
];

// ---------------------------------------------------------------------------
// The heap itself.
// ---------------------------------------------------------------------------

/// Gives slot [s] an empty heap, immediately above whatever the loader mapped.
///
/// Called from `procCreate` after `procSlotHi` has been filled in, and from
/// nowhere else. [hi] is `elfMetaHi` -- one past the highest page the LOADER
/// mapped, computed by the loader from the file's own `p_vaddr`s, and already
/// 4KiB-aligned because every address the loader maps is.
///
/// **Both bounds are re-checked here rather than assumed**, because `hi` is a
/// number derived from a file that arrived on a disk. A program whose segments
/// somehow ended above [heapTop] gets a heap of zero pages -- base == break ==
/// [heapTop] -- and every `sbrk` it makes is refused with [heapRetNoSpace].
/// That is a correct empty heap; the alternative is an underflow in
/// [heapRoom] inside a syscall, which DCDart turns into a `ud2`.
@bare
void heapInit(u64 s, u64 hi) {
  u64 base = hi;
  if (base < u64(vmProgBase)) {
    base = u64(vmProgBase);
  }
  if (base > u64(heapTop)) {
    base = u64(heapTop);
  }
  base = base & u64(heapPageAlignMask);
  procSet(s, u64(heapSlotBase), base);
  procSet(s, u64(heapSlotBrk), base);
  procSet(s, u64(heapSlotPages), u64(0));
  procSet(s, u64(heapSlotCalls), u64(0));
}

/// Clears slot [s]'s heap bookkeeping. Called from `procSpaceFree`, which has
/// already handed the pages themselves back.
@bare
void heapReset(u64 s) {
  procSet(s, u64(heapSlotBase), u64(0));
  procSet(s, u64(heapSlotBrk), u64(0));
  procSet(s, u64(heapSlotPages), u64(0));
  procSet(s, u64(heapSlotCalls), u64(0));
}

/// Bytes of address space slot [s]'s heap has left.
///
/// [heapInit] guarantees `brk` is in `[vmProgBase, heapTop]` and [heapSbrk] only
/// ever advances it to an address it has already proved fits, so the
/// subtraction cannot underflow -- but the guard is here anyway, because the
/// cost of being wrong about that is a `ud2` inside a syscall.
@bare
u64 heapRoom(u64 s) {
  final u64 brk = procGet(s, u64(heapSlotBrk));
  if (brk > u64(heapTop)) {
    return u64(0);
  }
  return u64(heapTop) - brk;
}

/// Undoes [n] pages of a half-finished [heapSbrk], starting at [from].
///
/// **The break has not moved when this runs**, so the pages being undone are
/// ones no ring-3 instruction has ever been able to reach: [heapSbrk] maps them
/// before it advances the break, and the process is inside a syscall the whole
/// time. Unmapping them is therefore invisible to the program, which is what
/// makes the failure atomic.
///
/// The frame is recovered from the LEAF ENTRY rather than from a remembered
/// list, for `procSpaceFree`'s reason: the tables are what the CPU obeys, so
/// they are what an undo has to be checked against. Every discarded `freeFrame`
/// status is ADDED to the process table's ERRORS word rather than dropped,
/// which works because `pmmFreeOk` is 0 (ADR-0011 §4).
@bare
void heapRollback(u64 from, u64 n) {
  u64 i = u64(0);
  while (i < n) {
    final u64 va = from + (i << u64(vmPageShift));
    final u64 le = vmProgLeaf(va);
    if ((le & u64(vmPresent)) > u64(0)) {
      // Bound rather than discarded: `dcc` refuses a dropped return value, and
      // `vmProgUnmap` only ever fails for an address outside the window, which
      // [heapSbrk] has already excluded. It is added to ERRORS anyway, so the
      // impossible case is a number rather than a silence.
      final u64 um = vmProgUnmap(va);
      procSetHead(u64(procHeadErrors),
          procHead(u64(procHeadErrors)) + um);
      procSetHead(u64(procHeadErrors),
          procHead(u64(procHeadErrors)) + freeFrame(vmEntryAddr(le)));
    }
    i = i + u64(1);
  }
}

/// Grows slot [s]'s heap by [inc] bytes. Returns the OLD break, or one of the
/// three `heapRet*` refusals.
///
/// **The caller must be the process whose CR3 is installed**, because
/// `vmProgMap` writes into the LIVE address space (M11's `vmProgPd`). That is
/// true of every path into this function: it is only reachable from
/// [heapSysSbrk], which is only reachable from `userSyscall`, which runs on the
/// calling process's CR3 because `isr_common` never changed it.
///
/// The order of the checks is the whole of the atomicity argument:
///
///   1. `inc == 0` is answered from the slot with no side effect at all -- this
///      is how a program asks "where is my break", and a `malloc` that starts by
///      asking must not consume a page to find out;
///   2. an increment bigger than the window is refused BEFORE the round-up,
///      because the round-up is the addition that would overflow;
///   3. the address-space bound is checked BEFORE the first `allocFrame`, so a
///      request that could never fit never touches the allocator;
///   4. only then are frames taken -- and if one cannot be, everything this call
///      already mapped is put back and the break does not move.
@bare
u64 heapSbrk(u64 s, u64 inc) {
  final u64 brk = procGet(s, u64(heapSlotBrk));
  if (inc < u64(1)) {
    return brk;
  }
  if (inc > u64(heapMaxInc)) {
    return u64(heapRetBadArg);
  }
  final u64 pages = (inc + u64(vmPageMask)) >> u64(vmPageShift);
  final u64 want = pages << u64(vmPageShift);
  if (want > heapRoom(s)) {
    return u64(heapRetNoSpace);
  }
  u64 done = u64(0);
  while (done < pages) {
    final u64 f = allocFrame();
    if (f < u64(1)) {
      heapRollback(brk, done);
      return u64(heapRetNoMem);
    }
    // ZEROED BEFORE IT IS MAPPED, not after. See the header: between the
    // mapping and the zeroing there would be a window in which the previous
    // owner's bytes are reachable from ring 3.
    vmZeroFrame(f);
    final u64 m = vmProgMap(brk + (done << u64(vmPageShift)), f, u64(1), u64(0));
    if (m > u64(0)) {
      // Unreachable by construction -- the range was bounded above and every
      // page in it was unmapped -- so it is treated as an address-space failure
      // rather than swallowed. The frame goes back first because nothing else
      // knows about it yet.
      procSetHead(u64(procHeadErrors),
          procHead(u64(procHeadErrors)) + freeFrame(f));
      heapRollback(brk, done);
      return u64(heapRetNoSpace);
    }
    done = done + u64(1);
  }
  procSet(s, u64(heapSlotBrk), brk + want);
  procSet(s, u64(heapSlotPages), procGet(s, u64(heapSlotPages)) + pages);
  return brk;
}

/// `PROC HEAP <s> INC <inc> OLD <old> NEW <new> PAGES <n>`, or
/// `PROC HEAP <s> INC <inc> ERR <ret> BASE <base> TOP <top>` on a refusal.
///
/// **Printed on EVERY call, including the refused ones**, for `procRefuse`'s
/// reason: a subsystem that reports zero refusals is making a claim only if a
/// refusal would have been recorded. The refusal line also prints the base and
/// the top, because "there is no room" is only checkable against the two numbers
/// that bound the room.
@bare
void heapLine(u64 s, u64 inc, u64 r) {
  uartWrite(Rodata.addressOf(heapStrLine), u64(10));
  uartPutHex(s, u64(2));
  uartWrite(Rodata.addressOf(heapStrInc), u64(5));
  uartPutHex(inc, u64(16));
  if (r > u64(heapRetFloor)) {
    uartWrite(Rodata.addressOf(vmStrErr), u64(5));
    uartPutHex(r, u64(16));
    uartWrite(Rodata.addressOf(heapStrBase), u64(6));
    uartPutHex(procGet(s, u64(heapSlotBrk)), u64(16));
    uartWrite(Rodata.addressOf(heapStrTop), u64(5));
    uartPutHex(u64(heapTop), u64(16));
    uartNewline();
    return;
  }
  uartWrite(Rodata.addressOf(heapStrOld), u64(5));
  uartPutHex(r, u64(16));
  uartWrite(Rodata.addressOf(heapStrNew), u64(5));
  uartPutHex(procGet(s, u64(heapSlotBrk)), u64(16));
  uartWrite(Rodata.addressOf(procStrPages), u64(7));
  uartPutHex(procGet(s, u64(heapSlotPages)), u64(8));
  uartNewline();
}

/// Syscall 4. Called from `userSyscall` with a PROCESS guaranteed live.
///
/// The count is bumped BEFORE the work, so a call that somehow did not return
/// is still counted -- the number means "asked", not "succeeded", and the
/// success count is the page count on the same line.
@bare
void heapSysSbrk(u64 frame) {
  final u64 s = procCurrent();
  final u64 inc = userFrame(frame, u64(userFrameRdi));
  procSet(s, u64(heapSlotCalls), procGet(s, u64(heapSlotCalls)) + u64(1));
  final u64 r = heapSbrk(s, inc);
  userSetFrame(frame, u64(userFrameRax), r);
  heapLine(s, inc, r);
}
