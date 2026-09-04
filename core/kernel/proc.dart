// core/kernel/proc.dart
//
// M11: PROCESSES.  A process table, one address space each, and a `yield`
// syscall that switches between them.
//
// A `part` of `kmain.dart`'s library rather than an import, for the reason
// every other file here is: `dcc` lowers exactly ONE library per object file,
// so a `@bare` function in an imported library is not compiled at all
// (docs/known-gaps.md GAP-0004 item 4).
//
// ---------------------------------------------------------------------------
// WHAT THIS ADDS THAT M10 DID NOT HAVE, AND WHAT IT STILL DOES NOT
// ---------------------------------------------------------------------------
// M10 loaded a static ELF64 off a disk and ran it at CPL 3 with the permissions
// its own `p_flags` asked for. What it did NOT have was a PROCESS: there was one
// address space -- the kernel's -- and the program lived in a single 2MiB window
// inside it, one program at a time (GAP-0089).
//
// This file gives each program:
//
//   * its OWN PML4, PDPT and page directory, from the frame allocator, with the
//     kernel's mappings copied in and its own program pages private. Switching
//     process switches CR3.
//   * a slot in a fixed-capacity process table: id, state, the four table
//     frames, entry, stack, a 512-byte FXSAVE area, and a saved copy of the
//     22-word interrupt frame that IS its continuation.
//   * 512 bytes of FPU/SSE state that is saved and restored across every switch
//     this kernel performs, so two processes cannot see each other's XMM
//     registers.
//
// **THE SWITCHING IS COOPERATIVE AND THIS FILE SAYS SO IN ITS OWN NAME.** There
// is no timer-driven scheduler and no preemption. A process runs until it calls
// `yield` (syscall 3) or `exit` (syscall 0); the timer interrupt fires while it
// runs and returns to it, exactly as it did at M9 and M10. A process that never
// calls either cannot be stopped. docs/known-gaps.md GAP-0097 is the accounting.
//
// ---------------------------------------------------------------------------
// THE INTERRUPT FRAME IS THE CONTINUATION, AND THAT IS THE WHOLE SWITCH
// ---------------------------------------------------------------------------
// `isr_common` (core/boot/isr.S) already pushes all fifteen general-purpose
// registers, and the CPU already pushed RIP/CS/RFLAGS/RSP/SS. Twenty-two
// consecutive words on the ring-0 stack therefore describe a suspended ring-3
// thread COMPLETELY -- M9 built that data structure for a DCDart handler to read
// and it turns out to be a context block.
//
// So a context switch here is: copy those 22 words OUT to the current slot,
// copy the next slot's 22 words IN, write CR3, and return normally. `isr_common`
// then pops fifteen registers and `iretq`s -- into the OTHER process. No second
// kernel stack, no stack switching, no assembly beyond the two instructions
// `fx_save`/`fx_restore` already are. RSP0 in the TSS is reloaded by the CPU on
// every entry from ring 3, so one ring-0 stack is enough for as many processes
// as there are, PRECISELY BECAUSE only one of them is ever inside the kernel at
// a time -- which is a property of the switching being cooperative, and would
// stop being true the day it is not.
//
// ---------------------------------------------------------------------------
// WHY `core/kernel/elf.dart` DID NOT HAVE TO CHANGE
// ---------------------------------------------------------------------------
// The loader writes through `vmProgMap`, and `vmProgMap` finds the page
// directory it edits by WALKING FROM CR3 (`vmProgPd`, M11) rather than from the
// kernel's remembered PML4. So `procCreate` installs the target process's CR3,
// calls `elfLoad` unchanged, and installs the kernel's again. The loader maps
// into whichever address space is on the CPU because that is what "the live
// tables" has always meant in vm.dart's doc comments; M11 is the milestone at
// which there is more than one set of them and the sentence acquired teeth.
// ---------------------------------------------------------------------------

part of 'kmain.dart';

// ---------------------------------------------------------------------------
// The table's shape.
//
// Every number here is spelled as a literal rather than computed, for GAP-0077's
// reason (`dcc` at `DCDART_PIN.txt`'s commit refuses a `u64` literal built from
// a constant expression). `tests/conformance/m11-proc/run.sh` multiplies them
// against each other and against `proc_store`'s `.size` in the linked image, so
// a pair that stopped agreeing fails before a boot does.
// ---------------------------------------------------------------------------

/// How many processes can exist at once. SIXTEEN: DESK plus every dock
/// app plus extra FILES/STUDIO documents. A seventeenth `procCreate` is
/// refused by name (`procErrNoSlot`). Raising it is `procStoreBytes`.
const int procMax = 16;

/// `procMax`, and `procMax - 1`, as their own literals. `@bare` DCDart has no
/// `>=` or `<=` (GAP-0023), so a half-open bound needs the number on each side
/// of the comparison and `dcc` will not fold `procMax - 1` inside `u64(...)`.
const int procMaxSlot = 15;
const int procMaxWrap = 17;

/// The whole donated block, and the three regions inside it. See `proc_store`
/// in `core/boot/kdata.S`.
///
/// **M18 GREW THE HEADER FROM EIGHT WORDS TO SIXTEEN, AND ONLY THE HEADER.**
/// The preemptive scheduler needs six words of its own (`procHeadPreempts`
/// through `procHeadBudget`) and the eight the header had were all in use. The
/// alternative was a SECOND `@bss` block with a SECOND storage seam, which is
/// exactly what `m11-proc/run.sh`'s "one symbol behind three offsets" check
/// exists to prevent: scheduler state is process-table state, so it lives in
/// the process table's block, reached through the process table's three seam
/// functions, and the seam is still three call sites. The cost is that every
/// harness that subtracts this block out of the kernel's `.bss` total moves by
/// 64 bytes, and each of those numbers is spelled out in ADR-0022 §4.
const int procStoreBytes = 16512;
const int procHeadWords = 16;
const int procTableOffset = 128;
const int procFxOffset = 8320;

/// One slot: 512 bytes, 64 `u64` words.
const int procSlotBytes = 512;
const int procSlotWords = 64;

/// One FPU save area: 512 bytes, the size `fxsave` writes. It is the SAME size
/// as a slot by coincidence and not by design -- 512 is the architectural size
/// of an FXSAVE image and 64 words is what a slot happened to need -- so the two
/// shifts below are named separately even though both are 9. The harness asserts
/// each against the thing it indexes rather than against the other.
const int procFxBytes = 512;

/// `log2(procSlotBytes)` and `log2(procFxBytes)`. Shifts rather than `*` because
/// a multiply by a power of two is a shift, and because the index is bounded by
/// [procMax] two lines above every use.
const int procSlotShift = 9;
const int procFxShift = 9;

/// x87 control word for a fresh process: 0x037F. All six exceptions masked,
/// round-to-nearest, 64-bit extended precision -- the value `fninit` leaves.
const int procFxCw = 0x037F;

/// MXCSR (low 32 bits) and MXCSR_MASK (high 32) at FXSAVE offset 24, as one
/// `u64` store. 0x1F80 masks every SSE exception, which is the reset value and
/// the only value this kernel ever puts there.
///
/// **A reserved bit set in the MXCSR image is a #GP inside `fxrstor`**, i.e.
/// inside a context switch, which is why no save area is ever allowed to hold
/// allocator litter or unzeroed `.bss`: every one of them is written by
/// [procFxInit] before any process can run.
const int procFxMxcsr = 0x0000FFBF00001F80;

// Header words, at `procHeadBase() + (i << 3)`.
const int procHeadReady = 0;
const int procHeadCreated = 1;

/// The RUNNING slot PLUS ONE, so that 0 means "no process is on the CPU" and
/// slot 0 is not ambiguous with nothing. Exactly why `allocFrame` returns 0 for
/// failure and physical page 0 is permanently reserved (ADR-0011 §3).
const int procHeadCurrent = 2;
const int procHeadSwitches = 3;
const int procHeadSse = 4;
const int procHeadLive = 5;
const int procHeadExits = 6;
const int procHeadErrors = 7;

// ---------------------------------------------------------------------------
// M18's six words. THE SCHEDULER'S OWN STATE, and every one of them is written
// from inside an interrupt handler.
// ---------------------------------------------------------------------------

/// INVOLUNTARY switches: the number of times [procTick] took a process off the
/// CPU that had not asked to leave.
///
/// **Deliberately NOT [procHeadSwitches].** The two counters are orthogonal
/// because the two events are: `SWITCHES` counts switches a process asked for
/// (`yield`, `exit`), `PREEMPTS` counts switches done to it. Keeping them apart
/// is what lets `m11-proc/run.sh` go on asserting `switches == yields + exits`
/// arithmetically — an identity a shared counter would have destroyed — while
/// M18 asserts `preempts > 0` with `yields == 0` in the same breath. A kernel
/// that counted both in one word could not say either sentence.
const int procHeadPreempts = 8;

/// Quantum expiries: the number of times the current process had been in ring 3
/// for [procQuantumTicks] ticks and the scheduler acted on it. Always >=
/// [procHeadPreempts], because an expiry with nobody else READY is still an
/// expiry — it just has nowhere to switch to. The DIFFERENCE between the two is
/// how much of the session had only one runnable process.
const int procHeadQuanta = 9;

/// Ticks the CURRENT process has taken in ring 3 since it was last scheduled.
/// Reset by [procSwitchTo], [procStart] and every quantum expiry, so it is a
/// per-slice count and not a running total.
const int procHeadSlice = 10;

/// [procPolicyCoop] or [procPolicyPreempt], for THIS session. See
/// [procQuantumTicks] for why this is a session property and not a constant.
const int procHeadPolicy = 11;

/// Ticks that arrived while a process was live and the interrupted CS was RING
/// 0 — i.e. ticks this scheduler DECLINED to preempt on.
///
/// **This is the price of "the kernel is not preemptible", counted rather than
/// asserted.** ADR-0022 §3 argues the number should be near zero on this kernel
/// because every kernel entry from ring 3 is through an INTERRUPT gate and
/// therefore runs with IF clear; a tick cannot even be delivered inside a
/// syscall, let alone preempt one. If this word is ever large, that argument
/// has stopped being true and the ADR is wrong rather than the machine.
const int procHeadKernTicks = 12;

/// Quantum expiries this session is allowed before the scheduler tears it down,
/// or 0 for "no limit".
///
/// **A runaway backstop, and the only thing in this kernel that can stop a
/// program which neither yields nor exits.** Preemption alone means a runaway
/// shares the CPU; it does not mean anybody can ever get the CPU BACK. There is
/// no keyboard-driven kill and no signal (GAP-0140), so `proc spin` states a
/// budget in quanta up front and the scheduler enforces it from the timer
/// interrupt. It is tick-driven and therefore assertable, which is the other
/// half of why it exists.
const int procHeadBudget = 13;

/// D3: 1 if this table holds processes that outlive the shell command that
/// created them (`proc spawn`), else 0. A classic `proc run` / `proc spin`
/// session leaves this word 0, which is what `m18-preempt` still reads out of
/// guest RAM after those commands. Header word 15 stays unused.
const int procHeadResident = 14;

// Slot words 0..31 are metadata; 32..53 are the saved interrupt frame; 54..63
// are unused and asserted zero by the harness, so a future field lands in a
// place somebody chose.
const int procSlotState = 0;
const int procSlotId = 1;
const int procSlotPml4 = 2;
const int procSlotPdpt = 3;
const int procSlotPd = 4;
const int procSlotPt = 5;
const int procSlotEntry = 6;
const int procSlotRsp = 7;
const int procSlotStackFrame = 8;
const int procSlotPages = 9;
const int procSlotExit = 10;
const int procSlotLba = 11;
const int procSlotLo = 12;
const int procSlotHi = 13;
const int procSlotSegments = 14;
const int procSlotProbe = 15;

/// M18: how many times THIS slot has been preempted. **Word 20, not 16.**
/// Words 16..19 are M12's per-process heap (`heapSlotBase` .. `heapSlotCalls`
/// in `core/kernel/heap.dart`) — this file's own "slot words 0..31 are
/// metadata" comment does not say WHICH of them are taken, and the first
/// version of M18 took 16 and 17. It booted, preempted, and printed
/// `N 10003001` for a preemption count: the process's heap break, read back as
/// a scheduler statistic. Nothing crashed. `m18-preempt/run.sh` now asserts
/// every slot-word constant in the kernel is distinct, so the next milestone
/// cannot repeat it. Per-process rather than
/// only global, because "both programs made progress" is a claim about each of
/// them and a global counter cannot distinguish two preemptions of one process
/// from one preemption of each. It is also what syscall
/// [procSysPreemptsNo] returns, which is how a program can be written to run
/// for a stated number of quanta and then stop — the difference between an
/// assertion about tick counts and an assertion about wall-clock.
const int procSlotPreempts = 20;

/// D3: 1 after this slot has been entered once. Word 54 was unused and
/// `m18-preempt` still requires 54..63 to be zero after a `proc run` session,
/// which never writes this word.
const int procSlotEntered = 54;

/// M18: how many times THIS slot has called `yield`. Zero for every program in
/// `m18-preempt`, and that zero is the point: it is the kernel's own record
/// that the switches it performed were not asked for.
const int procSlotYields = 21;

/// M21: physical frame of this slot's SHARED-REGION page table (`PD[129]`), or
/// 0 if it has never mapped a shared region.
///
/// Allocated lazily by `shmEnsureTable` on the first `shmcreate`/`shmmap` this
/// process performs, so a program that never touches shared memory is not
/// charged a frame for a table it will not use. Remembered here rather than
/// recovered from the page directory for one reason `procSpaceFree` cares
/// about: it is freed on a path that has already cleared `PD[129]`, and a
/// teardown that had to walk a directory it has just emptied would find
/// nothing. `procSpaceFree` still recovers the PAGES from the table itself,
/// which is the invariant that matters (the tables are what the CPU obeys).
const int procSlotShmPt = 22;

/// ADR-0124: 1 if this slot is a named platform process (`PLAT.ELF`)
/// and may use the 189 MiB window at [vmPlatBase]. Word 23 sat between
/// the SHM page-table word and the capability block; TAP/FILES ELFs
/// leave it 0 and keep the 2 MiB [heapTop] cap.
const int procSlotPlat = 23;

/// M21: first of [shmCapsPerProc] SHARED-REGION CAPABILITY words — 24..27.
///
/// **This is where "a capability cannot be forged" is actually true, and the
/// reason is the address of this table rather than the contents of a handle.**
/// The table lives inside the process slot, which is reached only through
/// `procGet(procCurrent(), ...)` — the scheduler's own state, which no syscall
/// argument reaches (`chanCallerId`'s discipline, ADR-0027 §4 item 1). A
/// ring-3 handle names an INDEX INTO THE CALLER'S OWN TABLE, so guessing one
/// can only ever reach a capability the kernel itself installed there. See
/// ADR-0041 §4.
///
/// Word layout is `shm.dart`'s [shmCapPack]; the words are zero for "no
/// capability", which is what `procSlotWipe` leaves behind and what a slot
/// reused by a later process therefore starts with.
const int procSlotShmCaps = 24;

/// ADR-0146: virtual address this BLOCKED slot is waiting on, or 0.
/// Word 28 sits after the four capability words (24..27) and before
/// the saved frame at 32. A scan of the table is the wait queue
/// (`blocking-and-threads.md` §1.3(b)): `procMax` is 4.
const int procSlotWaitAddr = 28;

/// ADR-0148: this slot's `IA32_FS_BASE` (TLS door). Word 29 sits
/// between the futex wait word and the saved frame. Written by
/// [procSysSetfs]; installed on every enter/switch via [msr_write].
/// Zero means "no TLS" — a `%fs:0` access then faults at VA 0.
const int procSlotFsBase = 29;

/// ADR-0169 / ADR-0170: VA of the official `memset@plt` trampoline
/// after plant bind (points at OUR libc face in the RX slab).
/// Word 30 sits between FS.base and the saved frame.
/// Zero means unbound — a call through the PLT still hits the
/// unmapped GOT and #PF (anti-vacuity).
const int procSlotCefMemset = 30;

/// First word of the saved 22-word interrupt frame.
const int procSlotSaved = 32;

/// The frame `isr_common` builds: 15 pushed registers, the stub's vector and
/// error code, and the CPU's five. 22 words, 176 bytes. The offsets of the
/// individual fields are `user.dart`'s `userFrame*`; this file needs only the
/// COUNT and the RAX word's index, because it copies the frame wholesale.
const int procFrameWords = 22;

/// `userFrameRax >> 3`. The one word this file patches by hand: a process that
/// is switched away and later resumed must not come back with the syscall
/// NUMBER still in RAX. See [procYield].
const int procFrameRaxWord = 14;

// States. FREE is 0 so that a zeroed table is an empty table.
const int procStateFree = 0;
const int procStateReady = 1;
const int procStateRunning = 2;
const int procStateExited = 3;
const int procStateKilled = 4;
/// ADR-0146: waiting on a futex address ([procSlotWaitAddr]).
/// [procPickNext] skips it. Not `fdwait` (11 stays reserved).
const int procStateBlocked = 5;

// [procCreate] / `proc run` refusal codes. Each one has a sentence.
const int procErrOk = 0;
const int procErrNotReady = 1;
const int procErrBusy = 2;
const int procErrNoSlot = 3;
const int procErrNoFrames = 4;
const int procErrBadLba = 5;
const int procErrLoad = 6;
const int procErrNoSse = 7;
// 8 was `procErrElfLive` -- DELETED. See docs/decisions/0039-four-guards-adr-0034-left-behind.md.
//
// It guarded `procCreate` against building a process while an M10 `run`
// program owned page-directory entry 128 of the KERNEL's directory. ADR-0034
// deleted the only code that ever made such a program, and with it the only
// assignment of a non-zero value to `elfMetaLive` -- so `elfLive()` has been a
// compile-time zero ever since and this guard could not fire. The number is not
// reused: a refusal code that changes meaning is worse than a gap in the
// sequence, because a transcript from an older kernel is still readable.
const int procErrSameLba = 9;

/// M20: [argsBuild] would not fit `argc`, the pointer vector and the argument
/// text into the process's stack page while leaving [argsMinStack] bytes for the
/// program itself.
///
/// **It is not reachable with the bounds `args.dart` enforces** -- eight
/// arguments of 128 bytes total cannot approach a 4KiB page -- and it is a named
/// refusal anyway, because those bounds and the size of a page are two numbers
/// in two files, and a load that cannot build a stack must fail by name rather
/// than enter ring 3 with a stack pointer nobody computed.
const int procErrArgs = 10;

/// Syscall 3 — `yield`. Declared here rather than beside `userSysExitNo` in
/// `user.dart` because the syscall does not exist without a process table: with
/// nothing to switch to it is refused, and `user.dart`'s own payloads never
/// call it.
const int procSysYieldNo = 3;

/// Syscall 10 — `preempts`. Returns the number of times the CALLING process has
/// been taken off the CPU without asking. Refused, like `yield`, unless a
/// process is live.
///
/// **This is the syscall that makes a preemptive milestone assertable.** A test
/// program cannot time itself — it has no clock — so "run for a while and check
/// you were interrupted" is a wall-clock criterion and unassertable. "Run until
/// the kernel says it has taken you off the CPU three times" is a TICK-COUNT
/// criterion: it terminates after exactly three quantum expiries, the number is
/// the kernel's own, and the program's own `yield` count is still zero.
///
/// It does not switch, does not sleep and does not block. A process that calls
/// it in a loop is still a process that never yields.
const int procSysPreemptsNo = 10;

/// Syscall 26 — `spawn(namePtr, nameLen)`. A live process starts another
/// process by 8.3 FAT name. Assembled from [fatParseAt] + [fatLookup] +
/// [procCreate] (named). 11 stays `fdwait`, 21/22 stay taken on other
/// lines. No `oslibc.h` name — FRAME clients declare `SYS_SPAWN` in
/// `osframe.h`.
const int procSysSpawnNo = 26;

/// Spawn refusals sit above this floor so a success slot (0..3) cannot
/// be confused with a failure. Same idiom as `wmRet*`.
const int spawnRetFloor = 0xFFFFFFFFFFFFFF00;
const int spawnRetNoProc = 0xFFFFFFFFFFFFFFFE;
const int spawnRetBadPtr = 0xFFFFFFFFFFFFFFFC;
const int spawnRetBadLen = 0xFFFFFFFFFFFFFFFB;
const int spawnRetBadName = 0xFFFFFFFFFFFFFFFA;
const int spawnRetNotFound = 0xFFFFFFFFFFFFFFF9;
const int spawnRetNoSlot = 0xFFFFFFFFFFFFFFF8;
const int spawnRetLoad = 0xFFFFFFFFFFFFFFF7;

/// Syscall 28 — `clone(fn, stack) -> slot` for a named platform
/// process (ADR-0130). The child shares the caller's page tables
/// (CLONE_VM) and starts at [fn] with RSP = [stack]. 11 stays
/// `fdwait`. 21 and 22 stay reserved on other lines. 26 is `spawn`,
/// 27 is `mmap`. ASK.ELF of the same bytes is [cloneRetBadArg].
/// No `oslibc.h` name — a libc `clone()` would be Linux clone.
const int procSysCloneNo = 28;

/// Clone refusals sit above this floor so a success slot (0..3)
/// cannot be confused with a failure. [cloneRetBadArg] matches
/// [heapRetBadArg] so ASK.ELF prints the same `ASKED` bytes mmap
/// already used.
const int cloneRetFloor = 0xFFFFFFFFFFFFFF00;
const int cloneRetBadArg = 0xFFFFFFFFFFFFFFFE;
const int cloneRetBadPtr = 0xFFFFFFFFFFFFFFFC;
const int cloneRetNoSlot = 0xFFFFFFFFFFFFFFF8;

/// Syscall 30 — `futex(op, addr, val)` for a named platform
/// process (ADR-0146). Op 0 waits while `*addr == val`; op 1
/// wakes up to `val` waiters on `addr`. 11 stays `fdwait`. 21
/// and 22 stay reserved on other lines. 26 is `spawn`, 27 is
/// `mmap`, 28 is `clone`, 29 is `dlopen`. ASK.ELF of the same
/// bytes is [futexRetBadArg]. No `oslibc.h` name — a libc
/// `futex()` would be Linux's.
const int procSysFutexNo = 30;

const int futexOpWait = 0;
const int futexOpWake = 1;

const int futexRetFloor = 0xFFFFFFFFFFFFFF00;
const int futexRetBadArg = 0xFFFFFFFFFFFFFFFE;
const int futexRetBadPtr = 0xFFFFFFFFFFFFFFFC;
const int futexRetBadOp = 0xFFFFFFFFFFFFFFFB;
const int futexRetAlone = 0xFFFFFFFFFFFFFFF7;

/// Syscall 33 — `setfs(base)` for a named platform process
/// (ADR-0148). Plants [procSlotFsBase] and writes `IA32_FS_BASE`
/// so a `%fs:` load/store reaches [base]. 11 stays `fdwait`.
/// 21 and 22 stay reserved. 30 is `futex`, 31/32 are
/// `unlink`/`rename`. ASK.ELF of the same bytes is
/// [setfsRetBadArg]. No `oslibc.h` name — a libc `arch_prctl`
/// would be Linux's.
const int procSysSetfsNo = 33;

/// `IA32_FS_BASE` MSR index (Intel SDM).
const int procFsBaseMsr = 0xC0000100;

const int setfsRetFloor = 0xFFFFFFFFFFFFFF00;
const int setfsRetBadArg = 0xFFFFFFFFFFFFFFFE;
const int setfsRetBadPtr = 0xFFFFFFFFFFFFFFFC;

// ---------------------------------------------------------------------------
// M18: THE QUANTUM, AND THE POLICY.
// ---------------------------------------------------------------------------

/// **THE QUANTUM: EIGHT PIT TICKS.**
///
/// `core/kernel/interrupts.dart` programs channel 0 to 100.0 Hz, so a tick is
/// 10 ms and a quantum is 80 ms of RING-3 time. Not of wall-clock time: only a
/// tick that interrupted CPL 3 with a process live counts toward it
/// ([procHeadSlice]), so time the kernel spends in a syscall on the process's
/// behalf is not charged to the process's slice. That is a decision with a cost
/// and ADR-0022 §3 states it.
///
/// **WHY EIGHT AND NOT ONE.** Two reasons, and the second is the load-bearing
/// one:
///
///   1. A switch is ~700 bytes of copying plus an `fxsave`/`fxrstor` pair. At
///      one tick that overhead is paid 100 times a second for two processes
///      that are doing nothing but spinning.
///   2. **`m11-proc`'s byte-exact 4096-byte golden is an interleaving that only
///      a scheduler which does not preempt produces**, and its slices are
///      MICROSECONDS long — every one of M11's programs reaches a `yield`
///      within a few thousand instructions. For a quantum of eight to fire
///      inside one of those slices, eight 10 ms ticks would have to be
///      delivered inside a slice that lasts ten microseconds. One tick landing
///      there is merely unlikely; eight is not a race, it is arithmetic.
///      A quantum of ONE would have made M11's golden a coin flip.
const int procQuantumTicks = 8;

/// Scheduling policy for a session. **A session property rather than a kernel
/// constant**, and ADR-0022 §2 is the argument: `proc coop` exists so that
/// `m11-proc`'s hold boot can still park a process at its entry point and have
/// the harness walk two live address spaces out of guest RAM while it is
/// parked. That boot asserts things about a machine held by a non-yielding
/// program, which is precisely what a preemptive scheduler abolishes.
///
/// `proc run`, `proc cross` and `proc spin` are all PREEMPTIVE. `proc coop` is
/// the single opt-out and it is named for what it does.
const int procPolicyCoop = 0;
const int procPolicyPreempt = 1;

// ---------------------------------------------------------------------------
// Fixed message text -- `@rodata` byte tables (DCDart ADR-0040).
//
// Every one of these is a byte table rather than a string literal because
// `@bare` DCDart has no string type and no way to place one in `.rodata`
// (docs/known-gaps.md GAP-0060). The length is carried at the CALL SITE, by
// hand, which is the same gap: a wrong number here prints the next table's
// bytes and the only thing that catches it is a byte-exact golden.
// ---------------------------------------------------------------------------

/// Line label.
///
/// `'PROC SSE '` -- 9 bytes.
@rodata
final List<u8> procStrSse = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x53), u8(0x53), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' CR4 '` -- 5 bytes.
@rodata
final List<u8> procStrCr4 = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x34), u8(0x20),
];

/// Field separator.
///
/// `' CR0 '` -- 5 bytes.
@rodata
final List<u8> procStrCr0 = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x30), u8(0x20),
];

/// Line label.
///
/// `'PROC CAP '` -- 9 bytes.
@rodata
final List<u8> procStrCap = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x43), u8(0x41), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' USED '` -- 6 bytes.
@rodata
final List<u8> procStrUsed = const [
  u8(0x20), u8(0x55), u8(0x53), u8(0x45), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' LIVE '` -- 6 bytes.
@rodata
final List<u8> procStrLiveW = const [
  u8(0x20), u8(0x4C), u8(0x49), u8(0x56), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' SWITCHES '` -- 10 bytes.
@rodata
final List<u8> procStrSwitches = const [
  u8(0x20), u8(0x53), u8(0x57), u8(0x49), u8(0x54), u8(0x43), u8(0x48), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' CREATED '` -- 9 bytes.
@rodata
final List<u8> procStrCreated = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x45), u8(0x41), u8(0x54), u8(0x45), u8(0x44), u8(0x20),
];

/// Line label.
///
/// `'PROC PD '` -- 8 bytes.
@rodata
final List<u8> procStrPd = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x50), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' KPD '` -- 5 bytes.
@rodata
final List<u8> procStrKpd = const [
  u8(0x20), u8(0x4B), u8(0x50), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' CR3 '` -- 5 bytes.
@rodata
final List<u8> procStrCr3 = const [
  u8(0x20), u8(0x43), u8(0x52), u8(0x33), u8(0x20),
];

/// Field separator.
///
/// `' KPML4 '` -- 7 bytes.
@rodata
final List<u8> procStrKpml4 = const [
  u8(0x20), u8(0x4B), u8(0x50), u8(0x4D), u8(0x4C), u8(0x34), u8(0x20),
];

/// Line label.
///
/// `'PROC SLOT '` -- 10 bytes.
@rodata
final List<u8> procStrSlot = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x53), u8(0x4C), u8(0x4F), u8(0x54), u8(0x20),
];

/// Field separator.
///
/// `' STATE '` -- 7 bytes.
@rodata
final List<u8> procStrState = const [
  u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x54), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' ID '` -- 4 bytes.
@rodata
final List<u8> procStrId = const [
  u8(0x20), u8(0x49), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' PML4 '` -- 6 bytes.
@rodata
final List<u8> procStrPml4 = const [
  u8(0x20), u8(0x50), u8(0x4D), u8(0x4C), u8(0x34), u8(0x20),
];

/// Field separator.
///
/// `' PT '` -- 4 bytes.
@rodata
final List<u8> procStrPt = const [
  u8(0x20), u8(0x50), u8(0x54), u8(0x20),
];

/// Field separator.
///
/// `' PD '` -- 4 bytes.
///
/// A SEPARATE TABLE FROM [procStrPd], which is the LINE LABEL `'PROC PD '`.
/// Reusing the line label mid-line printed
/// `PML4 000000000013E000PROC PD 0000000000140000` -- a second line label
/// welded into the middle of a field, with no separator and a `PROC PD` a
/// reader would try to parse as its own line. The same distinction
/// [procStrExitF] makes against [procStrExit].
@rodata
final List<u8> procStrPdF = const [
  u8(0x20), u8(0x50), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' ENTRY '` -- 7 bytes.
@rodata
final List<u8> procStrEntry = const [
  u8(0x20), u8(0x45), u8(0x4E), u8(0x54), u8(0x52), u8(0x59), u8(0x20),
];

/// Field separator.
///
/// `' RSP '` -- 5 bytes.
@rodata
final List<u8> procStrRspF = const [
  u8(0x20), u8(0x52), u8(0x53), u8(0x50), u8(0x20),
];

/// Field separator.
///
/// `' PAGES '` -- 7 bytes.
@rodata
final List<u8> procStrPages = const [
  u8(0x20), u8(0x50), u8(0x41), u8(0x47), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' FX '` -- 4 bytes.
@rodata
final List<u8> procStrFx = const [
  u8(0x20), u8(0x46), u8(0x58), u8(0x20),
];

/// Field separator.
///
/// `' EXIT '` -- 6 bytes.
@rodata
final List<u8> procStrExitF = const [
  u8(0x20), u8(0x45), u8(0x58), u8(0x49), u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'PROC RUN LBA '` -- 13 bytes.
@rodata
final List<u8> procStrRun = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x52), u8(0x55), u8(0x4E), u8(0x20), u8(0x4C), u8(0x42), u8(0x41),
  u8(0x20),
];

/// Field separator.
///
/// `' '` -- 1 bytes.
@rodata
final List<u8> procStrGap = const [
  u8(0x20),
];

/// Line label.
///
/// `'PROC NEW SLOT '` -- 14 bytes.
@rodata
final List<u8> procStrNew = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x4E), u8(0x45), u8(0x57), u8(0x20), u8(0x53), u8(0x4C), u8(0x4F),
  u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'PROC START SLOT '` -- 16 bytes.
@rodata
final List<u8> procStrStart = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x53), u8(0x54), u8(0x41), u8(0x52), u8(0x54), u8(0x20), u8(0x53),
  u8(0x4C), u8(0x4F), u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'PROC YIELD '` -- 11 bytes.
@rodata
final List<u8> procStrYield = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x59), u8(0x49), u8(0x45), u8(0x4C), u8(0x44), u8(0x20),
];

/// Field separator.
///
/// `' -> '` -- 4 bytes.
@rodata
final List<u8> procStrArrow = const [
  u8(0x20), u8(0x2D), u8(0x3E), u8(0x20),
];

/// Line label.
///
/// `'PROC EXIT SLOT '` -- 15 bytes.
@rodata
final List<u8> procStrExitL = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x45), u8(0x58), u8(0x49), u8(0x54), u8(0x20), u8(0x53), u8(0x4C),
  u8(0x4F), u8(0x54), u8(0x20),
];

/// Field separator.
///
/// `' CODE '` -- 6 bytes.
@rodata
final List<u8> procStrCode = const [
  u8(0x20), u8(0x43), u8(0x4F), u8(0x44), u8(0x45), u8(0x20),
];

/// Field separator.
///
/// `' LEFT '` -- 6 bytes.
@rodata
final List<u8> procStrLeft = const [
  u8(0x20), u8(0x4C), u8(0x45), u8(0x46), u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'PROC END SWITCHES '` -- 18 bytes.
@rodata
final List<u8> procStrEnd = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x45), u8(0x4E), u8(0x44), u8(0x20), u8(0x53), u8(0x57), u8(0x49),
  u8(0x54), u8(0x43), u8(0x48), u8(0x45), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' EXITS '` -- 7 bytes.
@rodata
final List<u8> procStrExits = const [
  u8(0x20), u8(0x45), u8(0x58), u8(0x49), u8(0x54), u8(0x53), u8(0x20),
];

/// Field separator.
///
/// `' FREED '` -- 7 bytes.
@rodata
final List<u8> procStrFreed = const [
  u8(0x20), u8(0x46), u8(0x52), u8(0x45), u8(0x45), u8(0x44), u8(0x20),
];

/// Line label.
///
/// `'PROC REFUSED '` -- 13 bytes.
@rodata
final List<u8> procStrRefused = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x52), u8(0x45), u8(0x46), u8(0x55), u8(0x53), u8(0x45), u8(0x44),
  u8(0x20),
];

/// Line label.
///
/// `'PROC KILL SLOT '` -- 15 bytes.
@rodata
final List<u8> procStrKill = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x4B), u8(0x49), u8(0x4C), u8(0x4C), u8(0x20), u8(0x53), u8(0x4C),
  u8(0x4F), u8(0x54), u8(0x20),
];

/// Line label.
///
/// `'PROC PROBE VA '` -- 14 bytes.
@rodata
final List<u8> procStrProbe = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x50), u8(0x52), u8(0x4F), u8(0x42), u8(0x45), u8(0x20), u8(0x56),
  u8(0x41), u8(0x20),
];

/// Refusal text.
///
/// `'the address space was never installed\n'` -- 38 bytes.
@rodata
final List<u8> procStrE01 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x61), u8(0x64), u8(0x64), u8(0x72), u8(0x65), u8(0x73), u8(0x73), u8(0x20),
  u8(0x73), u8(0x70), u8(0x61), u8(0x63), u8(0x65), u8(0x20), u8(0x77), u8(0x61), u8(0x73), u8(0x20), u8(0x6E), u8(0x65),
  u8(0x76), u8(0x65), u8(0x72), u8(0x20), u8(0x69), u8(0x6E), u8(0x73), u8(0x74), u8(0x61), u8(0x6C), u8(0x6C), u8(0x65),
  u8(0x64), u8(0x0A),
];

/// Refusal text.
///
/// `'a process session is already running\n'` -- 37 bytes.
@rodata
final List<u8> procStrE02 = const [
  u8(0x61), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x65), u8(0x73), u8(0x73), u8(0x20), u8(0x73), u8(0x65),
  u8(0x73), u8(0x73), u8(0x69), u8(0x6F), u8(0x6E), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x61), u8(0x6C), u8(0x72),
  u8(0x65), u8(0x61), u8(0x64), u8(0x79), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x6E), u8(0x69), u8(0x6E), u8(0x67),
  u8(0x0A),
];

/// Refusal text.
///
/// `'the process table is full\n'` -- 26 bytes.
@rodata
final List<u8> procStrE03 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x65), u8(0x73), u8(0x73), u8(0x20),
  u8(0x74), u8(0x61), u8(0x62), u8(0x6C), u8(0x65), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x66), u8(0x75), u8(0x6C),
  u8(0x6C), u8(0x0A),
];

/// Refusal text.
///
/// `'the allocator has no frames\n'` -- 28 bytes.
@rodata
final List<u8> procStrE04 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x61), u8(0x6C), u8(0x6C), u8(0x6F), u8(0x63), u8(0x61), u8(0x74), u8(0x6F),
  u8(0x72), u8(0x20), u8(0x68), u8(0x61), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x66), u8(0x72), u8(0x61),
  u8(0x6D), u8(0x65), u8(0x73), u8(0x0A),
];

/// Refusal text.
///
/// `'that is not a pair of LBAs\n'` -- 27 bytes.
@rodata
final List<u8> procStrE05 = const [
  u8(0x74), u8(0x68), u8(0x61), u8(0x74), u8(0x20), u8(0x69), u8(0x73), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20),
  u8(0x61), u8(0x20), u8(0x70), u8(0x61), u8(0x69), u8(0x72), u8(0x20), u8(0x6F), u8(0x66), u8(0x20), u8(0x4C), u8(0x42),
  u8(0x41), u8(0x73), u8(0x0A),
];

/// Refusal text.
///
/// `'the program could not be loaded\n'` -- 32 bytes.
@rodata
final List<u8> procStrE06 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67), u8(0x72), u8(0x61), u8(0x6D), u8(0x20),
  u8(0x63), u8(0x6F), u8(0x75), u8(0x6C), u8(0x64), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x62), u8(0x65),
  u8(0x20), u8(0x6C), u8(0x6F), u8(0x61), u8(0x64), u8(0x65), u8(0x64), u8(0x0A),
];

/// Refusal text.
///
/// `'this CPU has no FXSAVE, so a process cannot own FPU state\n'` -- 58 bytes.
@rodata
final List<u8> procStrE07 = const [
  u8(0x74), u8(0x68), u8(0x69), u8(0x73), u8(0x20), u8(0x43), u8(0x50), u8(0x55), u8(0x20), u8(0x68), u8(0x61), u8(0x73),
  u8(0x20), u8(0x6E), u8(0x6F), u8(0x20), u8(0x46), u8(0x58), u8(0x53), u8(0x41), u8(0x56), u8(0x45), u8(0x2C), u8(0x20),
  u8(0x73), u8(0x6F), u8(0x20), u8(0x61), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x65), u8(0x73), u8(0x73),
  u8(0x20), u8(0x63), u8(0x61), u8(0x6E), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x6F), u8(0x77), u8(0x6E), u8(0x20),
  u8(0x46), u8(0x50), u8(0x55), u8(0x20), u8(0x73), u8(0x74), u8(0x61), u8(0x74), u8(0x65), u8(0x0A),
];

/// Refusal text.
///
/// `'the two programs must be at different LBAs\n'` -- 43 bytes.
@rodata
final List<u8> procStrE09 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x74), u8(0x77), u8(0x6F), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x67),
  u8(0x72), u8(0x61), u8(0x6D), u8(0x73), u8(0x20), u8(0x6D), u8(0x75), u8(0x73), u8(0x74), u8(0x20), u8(0x62), u8(0x65),
  u8(0x20), u8(0x61), u8(0x74), u8(0x20), u8(0x64), u8(0x69), u8(0x66), u8(0x66), u8(0x65), u8(0x72), u8(0x65), u8(0x6E),
  u8(0x74), u8(0x20), u8(0x4C), u8(0x42), u8(0x41), u8(0x73), u8(0x0A),
];

/// Refusal text.
///
/// `'the arguments do not fit on the initial stack\n'` -- 46 bytes.
@rodata
final List<u8> procStrE10 = const [
  u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x61), u8(0x72), u8(0x67), u8(0x75), u8(0x6D), u8(0x65), u8(0x6E), u8(0x74),
  u8(0x73), u8(0x20), u8(0x64), u8(0x6F), u8(0x20), u8(0x6E), u8(0x6F), u8(0x74), u8(0x20), u8(0x66), u8(0x69), u8(0x74),
  u8(0x20), u8(0x6F), u8(0x6E), u8(0x20), u8(0x74), u8(0x68), u8(0x65), u8(0x20), u8(0x69), u8(0x6E), u8(0x69), u8(0x74),
  u8(0x69), u8(0x61), u8(0x6C), u8(0x20), u8(0x73), u8(0x74), u8(0x61), u8(0x63), u8(0x6B), u8(0x0A),
];

/// Usage text for `proc` with an argument this shell cannot parse.
///
/// `'usage: proc | proc run <lbaA> <lbaB> | proc cross <lbaA> <lbaB>\n'` -- 64 bytes.
@rodata
final List<u8> procStrUsage = const [
  u8(0x75), u8(0x73), u8(0x61), u8(0x67), u8(0x65), u8(0x3A), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20),
  u8(0x7C), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20), u8(0x3C),
  u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E),
  u8(0x20), u8(0x7C), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x63), u8(0x72), u8(0x6F), u8(0x73),
  u8(0x73), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62),
  u8(0x61), u8(0x42), u8(0x3E), u8(0x0A),
];

/// Command name, with its trailing space: `proc run <lbaA> <lbaB>`.
///
/// `'proc run '` -- 9 bytes.
@rodata
final List<u8> procCmdRunSp = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x72), u8(0x75), u8(0x6E), u8(0x20),
];

/// Command name, with its trailing space: `proc cross <lbaA> <lbaB>`.
///
/// `'proc cross '` -- 11 bytes.
@rodata
final List<u8> procCmdCrossSp = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x63), u8(0x72), u8(0x6F), u8(0x73), u8(0x73), u8(0x20),
];

// ---------------------------------------------------------------------------
// M18's tables. Same GAP-0060 discipline as every table above: the length is a
// hand-written literal at the call site, and `m18-preempt/run.sh` checks every
// one of them against the size the linker emitted.
// ---------------------------------------------------------------------------

/// `PROC PREEMPT ` -- 13 bytes.
@rodata
final List<u8> procStrPreempt = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x45),
  u8(0x4D), u8(0x50), u8(0x54), u8(0x20),
];

/// ` N ` -- 3 bytes.
@rodata
final List<u8> procStrN = const [
  u8(0x20), u8(0x4E), u8(0x20),
];

/// `PROC BUDGET QUANTA ` -- 19 bytes.
@rodata
final List<u8> procStrBudget = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x42), u8(0x55), u8(0x44), u8(0x47),
  u8(0x45), u8(0x54), u8(0x20), u8(0x51), u8(0x55), u8(0x41), u8(0x4E), u8(0x54), u8(0x41),
  u8(0x20),
];

/// ` PREEMPTS ` -- 10 bytes.
@rodata
final List<u8> procStrPreempts = const [
  u8(0x20), u8(0x50), u8(0x52), u8(0x45), u8(0x45), u8(0x4D), u8(0x50), u8(0x54), u8(0x53),
  u8(0x20),
];

/// `PROC SCHED POLICY ` -- 18 bytes.
@rodata
final List<u8> procStrSched = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x53), u8(0x43), u8(0x48), u8(0x45),
  u8(0x44), u8(0x20), u8(0x50), u8(0x4F), u8(0x4C), u8(0x49), u8(0x43), u8(0x59), u8(0x20),
];

/// ` QUANTUM ` -- 9 bytes.
@rodata
final List<u8> procStrQuantum = const [
  u8(0x20), u8(0x51), u8(0x55), u8(0x41), u8(0x4E), u8(0x54), u8(0x55), u8(0x4D), u8(0x20),
];

/// ` QUANTA ` -- 8 bytes.
@rodata
final List<u8> procStrQuanta = const [
  u8(0x20), u8(0x51), u8(0x55), u8(0x41), u8(0x4E), u8(0x54), u8(0x41), u8(0x20),
];

/// ` KTICKS ` -- 8 bytes.
@rodata
final List<u8> procStrKticks = const [
  u8(0x20), u8(0x4B), u8(0x54), u8(0x49), u8(0x43), u8(0x4B), u8(0x53), u8(0x20),
];

/// ` SLICE ` -- 7 bytes.
@rodata
final List<u8> procStrSlice = const [
  u8(0x20), u8(0x53), u8(0x4C), u8(0x49), u8(0x43), u8(0x45), u8(0x20),
];

/// ` BUDGET ` -- 8 bytes.
@rodata
final List<u8> procStrBudgetW = const [
  u8(0x20), u8(0x42), u8(0x55), u8(0x44), u8(0x47), u8(0x45), u8(0x54), u8(0x20),
];

/// ` HEAD ` -- 6 bytes.
///
/// **The kernel saying where its own scheduler state lives.** `m18-preempt`
/// dumps guest physical memory from this address and reads the process table
/// out of it — the header words, and slot 0's saved 22-word interrupt frame —
/// so every number the harness checks about a preempted process comes from the
/// machine rather than from the serial log the same kernel wrote. The kernel
/// image is identity-mapped, so the virtual address printed here IS the
/// physical address the monitor's `xp` needs.
@rodata
final List<u8> procStrHead = const [
  u8(0x20), u8(0x48), u8(0x45), u8(0x41), u8(0x44), u8(0x20),
];

/// ` YIELDS ` -- 8 bytes.
@rodata
final List<u8> procStrYields = const [
  u8(0x20), u8(0x59), u8(0x49), u8(0x45), u8(0x4C), u8(0x44), u8(0x53), u8(0x20),
];

/// `proc spin ` -- 10 bytes.
@rodata
final List<u8> procCmdSpinSp = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x70), u8(0x69), u8(0x6E),
  u8(0x20),
];

/// `proc coop ` -- 10 bytes.
@rodata
final List<u8> procCmdCoopSp = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x63), u8(0x6F), u8(0x6F), u8(0x70),
  u8(0x20),
];

/// `proc sched` -- 10 bytes.
@rodata
final List<u8> procCmdSched = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x63), u8(0x68), u8(0x65),
  u8(0x64),
];

/// `proc spawn ` -- 11 bytes. D3; not in `help` (GAP-0304).
@rodata
final List<u8> procCmdSpawnSp = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x70), u8(0x61),
  u8(0x77), u8(0x6E), u8(0x20),
];

/// `proc spawn` -- 10 bytes. The bare form, so a missing LBA or name lands on usage.
@rodata
final List<u8> procCmdSpawn = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x70), u8(0x61),
  u8(0x77), u8(0x6E),
];

/// `go ` -- 3 bytes. Hidden named launch from the idle line (ADR-0099).
/// Not in `help`. Same residency door as the longer spawn form.
@rodata
final List<u8> procCmdGoSp = const [
  u8(0x67), u8(0x6F), u8(0x20),
];

/// `go` -- 2 bytes. Bare form, so a missing name lands on usage.
@rodata
final List<u8> procCmdGo = const [
  u8(0x67), u8(0x6F),
];

/// 8.3 `PLAT    ELF` -- 11 bytes. The only name that raises the
/// process window. Compared against [fatNameBase] after a named open.
@rodata
final List<u8> procStrPlatName = const [
  u8(0x50), u8(0x4C), u8(0x41), u8(0x54), u8(0x20), u8(0x20), u8(0x20), u8(0x20),
  u8(0x45), u8(0x4C), u8(0x46),
];

/// `'PROC PLAT '` -- 10 bytes.
@rodata
final List<u8> procStrPlat = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x50), u8(0x4C), u8(0x41),
  u8(0x54), u8(0x20),
];

/// `' WIN '` -- 5 bytes.
@rodata
final List<u8> procStrWin = const [
  u8(0x20), u8(0x57), u8(0x49), u8(0x4E), u8(0x20),
];

/// `GO` + newline -- 3 bytes. Marker that the hidden path ran.
@rodata
final List<u8> procStrGo = const [
  u8(0x47), u8(0x4F), u8(0x0A),
];

/// `PROC SPAWN ` -- 11 bytes.
@rodata
final List<u8> procStrSpawn = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x53), u8(0x50), u8(0x41),
  u8(0x57), u8(0x4E), u8(0x20),
];

/// `PROC CLONE ` -- 11 bytes. ADR-0130.
@rodata
final List<u8> procStrClone = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x43), u8(0x4C), u8(0x4F),
  u8(0x4E), u8(0x45), u8(0x20),
];

/// `PROC FUTEX ` -- 11 bytes. ADR-0146.
@rodata
final List<u8> procStrFutex = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x46), u8(0x55), u8(0x54),
  u8(0x45), u8(0x58), u8(0x20),
];

/// `PROC SETFS ` -- 11 bytes. ADR-0148.
@rodata
final List<u8> procStrSetfs = const [
  u8(0x50), u8(0x52), u8(0x4F), u8(0x43), u8(0x20), u8(0x53), u8(0x45), u8(0x54),
  u8(0x46), u8(0x53), u8(0x20),
];

/// ` WAIT ` -- 6 bytes.
@rodata
final List<u8> procStrWait = const [
  u8(0x20), u8(0x57), u8(0x41), u8(0x49), u8(0x54), u8(0x20),
];

/// ` WAKE ` -- 6 bytes.
@rodata
final List<u8> procStrWake = const [
  u8(0x20), u8(0x57), u8(0x41), u8(0x4B), u8(0x45), u8(0x20),
];

/// ` ADDR ` -- 6 bytes.
@rodata
final List<u8> procStrAddr = const [
  u8(0x20), u8(0x41), u8(0x44), u8(0x44), u8(0x52), u8(0x20),
];

/// ` VAL ` -- 5 bytes.
@rodata
final List<u8> procStrVal = const [
  u8(0x20), u8(0x56), u8(0x41), u8(0x4C), u8(0x20),
];

/// ` FN ` -- 4 bytes.
@rodata
final List<u8> procStrFn = const [
  u8(0x20), u8(0x46), u8(0x4E), u8(0x20),
];

/// ` SP ` -- 4 bytes.
@rodata
final List<u8> procStrSp = const [
  u8(0x20), u8(0x53), u8(0x50), u8(0x20),
];

/// `       proc sched | proc coop <lbaA> <lbaB> | proc spin <lbaA> <lbaB> <quanta>\n` -- 79 bytes.
@rodata
final List<u8> procStrUsage2 = const [
  u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x20), u8(0x70), u8(0x72),
  u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x63), u8(0x68), u8(0x65), u8(0x64), u8(0x20),
  u8(0x7C), u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x63), u8(0x6F),
  u8(0x6F), u8(0x70), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E),
  u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E), u8(0x20), u8(0x7C),
  u8(0x20), u8(0x70), u8(0x72), u8(0x6F), u8(0x63), u8(0x20), u8(0x73), u8(0x70), u8(0x69),
  u8(0x6E), u8(0x20), u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x41), u8(0x3E), u8(0x20),
  u8(0x3C), u8(0x6C), u8(0x62), u8(0x61), u8(0x42), u8(0x3E), u8(0x20), u8(0x3C), u8(0x71),
  u8(0x75), u8(0x61), u8(0x6E), u8(0x74), u8(0x61), u8(0x3E), u8(0x0A),
];

/// Command name, matched as a whole line: `proc`.
///
/// `'proc'` -- 4 bytes.
@rodata
final List<u8> procCmdProc = const [
  u8(0x70), u8(0x72), u8(0x6F), u8(0x63),
];


// ---------------------------------------------------------------------------
// ===========================  THE STORAGE SEAM  ============================
//
// The ONLY three functions in this kernel that know where the process table's
// mutable state lives, and the ONLY three call sites of `proc_store_addr`.
//
// ADR-0011's shape, for ADR-0011's reason: this block has three regions with
// three different jobs, so it gets three named offsets behind three named
// functions. A fourth call site, or a second `@extern` accessor for process
// state, is the change that turns the mutable-statics migration from three
// lines into an audit of this file.
// `tests/conformance/m11-proc/run.sh` counts them.
//
// The migration, stated as a plan (ADR-0011 §0):
//
//   1. declare the header, the table and the FPU areas as DCDart mutable
//      statics here;
//   2. rewrite the three functions below to take their addresses;
//   3. delete `proc_store` and `proc_store_addr` from `core/boot/kdata.S`, and
//      the `@extern` declaration.
//
// Nothing else moves. Not one line of the scheduler, not one shell command, not
// one harness assertion.
// ---------------------------------------------------------------------------

/// The 4160 bytes this subsystem owns, as a DCDart mutable static.
///
/// Until M17 (ADR-0021) this was `proc_store` in core/boot/kdata.S, reached
/// through `@extern u64 proc_store_addr()`. The three seam functions below are
/// unchanged in name, arity and meaning; only the expression they return moved.
///
/// **`align: 16` IS A CORRECTNESS REQUIREMENT, NOT HYGIENE.** `fxsave` and
/// `fxrstor` on an operand that is not 16-byte aligned raise `#GP` — a fault in
/// the middle of a context switch, on a machine where everything else worked.
/// It is declared here rather than asserted downstream because DCDart REJECTS a
/// non-power-of-two alignment at compile time (its ADR-0051), which `.align 15`
/// in an assembly file would not have. `m11-proc/run.sh` checks all three
/// links of the chain: this declaration, the offset and section alignment in
/// `kmain.o`, and the linked address in `core/build/kernel.map`.
@bss
final Bss procStore = const Bss(bytes: procStoreBytes, align: 16);

/// Base of the eight-word header.
@bare
u64 procHeadBase() {
  return Bss.addressOf(procStore);
}

/// Base of the four-slot table.
@bare
u64 procTableBase() {
  return Bss.addressOf(procStore) + u64(procTableOffset);
}

/// Base of the four 512-byte FXSAVE areas. **16-byte aligned or `fxsave` is a
/// #GP** — see `proc_store`'s note in `kdata.S`, and the harness check that
/// reads the alignment out of the linked image.
@bare
u64 procFxBase() {
  return Bss.addressOf(procStore) + u64(procFxOffset);
}

// ======================  END OF THE STORAGE SEAM  ==========================

/// 1 if `core/boot/boot.S` found FXSR and SSE on this CPU and set
/// `CR4.OSFXSR | CR4.OSXMMEXCPT`, else 0.
@extern
external u64 sse_enabled();

/// `mov %cr4,%rax` — what the CPU is actually holding, as opposed to what the
/// boot stub decided. `proc` prints both.
@extern
external u64 cr4_read();

/// `fxsave (%rdi)` — 512 bytes of x87 + SSE state out. **#GP if [area] is not
/// 16-byte aligned, #UD if the CPU has no FXSR.**
@extern
external void fx_save(u64 area);

/// `fxrstor (%rdi)` — the same 512 bytes back in.
@extern
external void fx_restore(u64 area);

/// `wrmsr` — write MSR [msr] with [value]. ADR-0148 TLS door:
/// only [procInstallFs] calls this, and only for `IA32_FS_BASE`.
@extern
external void msr_write(u64 msr, u64 value);

// ---------------------------------------------------------------------------
// Primitives. Everything below goes through the seam.
// ---------------------------------------------------------------------------

/// Reads header word [i].
@bare
u64 procHead(u64 i) {
  return Pointer<u64>.fromAddress(procHeadBase() + (i << u64(3))).value;
}

/// Writes header word [i].
@bare
void procSetHead(u64 i, u64 v) {
  Pointer<u64>.fromAddress(procHeadBase() + (i << u64(3))).value = v;
}

/// Adds one to header word [i].
@bare
void procBumpHead(u64 i) {
  procSetHead(i, procHead(i) + u64(1));
}

/// Base address of slot [s]. Callers bound [s] by [procMax] first; there is no
/// check here because every caller in this file either got [s] from
/// [procFreeSlot] / [procPickNext] (which return [procMax] for "none") or is a
/// loop over `0..procMax`.
@bare
u64 procSlotBase(u64 s) {
  return procTableBase() + (s << u64(procSlotShift));
}

/// Reads word [w] of slot [s].
@bare
u64 procGet(u64 s, u64 w) {
  return Pointer<u64>.fromAddress(procSlotBase(s) + (w << u64(3))).value;
}

/// Writes word [w] of slot [s].
@bare
void procSet(u64 s, u64 w, u64 v) {
  Pointer<u64>.fromAddress(procSlotBase(s) + (w << u64(3))).value = v;
}

/// Address of slot [s]'s 512-byte FXSAVE area.
@bare
u64 procFxArea(u64 s) {
  return procFxBase() + (s << u64(procFxShift));
}

/// Puts slot [s]'s FPU save area into the state a fresh process starts in:
/// every x87 register empty, control word 0x037F, MXCSR 0x1F80, all sixteen XMM
/// registers zero.
///
/// **Zeroed and then written, not `fninit; fxsave`.** `fxsave` would capture
/// whatever is in XMM0-15 at the moment it ran, which is the previous process's
/// data — the exact leak this subsystem exists to prevent. The initial state of
/// a process's registers is a thing this kernel gets to state, and this is where
/// it states it.
@bare
void procFxInit(u64 s) {
  final u64 a = procFxArea(s);
  u64 o = u64(0);
  while (o < u64(procFxBytes)) {
    Pointer<u64>.fromAddress(a + o).value = u64(0);
    o = o + u64(8);
  }
  Pointer<u64>.fromAddress(a).value = u64(procFxCw);
  Pointer<u64>.fromAddress(a + u64(24)).value = u64(procFxMxcsr);
}

/// Gives every word of the donated block a known value. Prints NOTHING.
///
/// Called from `kmain()` after [elfInit], for the reason every init above it is
/// called where it is: `.bss` is not zeroed by anything in this kernel, and
/// [procOnFault] reads the "a process is live" word on EVERY fault this kernel
/// takes — including M1's own deliberate #UD. A garbage word would make the
/// first fault of the boot try to tear down four address spaces read out of
/// `.bss` litter, freeing whatever frame numbers it found, in the middle of
/// diagnosing something else.
///
/// It must keep printing nothing: `tests/conformance/m1-interrupts/run.sh`
/// asserts the entire 544-byte serial capture.
@bare
void procInit() {
  u64 i = u64(0);
  while (i < u64(procHeadWords)) {
    procSetHead(i, u64(0));
    i = i + u64(1);
  }
  u64 s = u64(0);
  while (s < u64(procMax)) {
    u64 w = u64(0);
    while (w < u64(procSlotWords)) {
      procSet(s, w, u64(0));
      w = w + u64(1);
    }
    procFxInit(s);
    s = s + u64(1);
  }
  procSetHead(u64(procHeadSse), sse_enabled());
  // M18: the policy a session gets if nobody says otherwise. Written here, not
  // left as the zero the loop above wrote, so that "preemptive" is a thing this
  // kernel STATES rather than a thing that happens to be the non-zero value.
  procSetHead(u64(procHeadPolicy), u64(procPolicyPreempt));
  procSetHead(u64(procHeadReady), u64(1));
  // osmedia_guest.o calls [wmMediaFill]. dcc drops an unreferenced
  // @bare symbol, so the final link fails with an undefined C
  // reference. src==0 returns immediately (kmedia.dart).
  wmMediaFill(u64(0), u64(0), u64(0));
}

/// 1 if a process is on the CPU right now, else 0.
///
/// **Read on every fault and every syscall**, which is why it asks two
/// questions: the table has to be initialised at all, and a slot has to be
/// current. Either alone would be a claim about `.bss` litter before
/// [procInit] runs.
@bare
u64 procLive() {
  if (procHead(u64(procHeadReady)) < u64(1)) {
    return u64(0);
  }
  if (procHead(u64(procHeadCurrent)) < u64(1)) {
    return u64(0);
  }
  return u64(1);
}

/// The running slot. **Only meaningful when [procLive] is 1.**
@bare
u64 procCurrent() {
  return procHead(u64(procHeadCurrent)) - u64(1);
}

/// The lowest free slot, or [procMax] if the table is full.
@bare
u64 procFreeSlot() {
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (procGet(s, u64(procSlotState)) == u64(procStateFree)) {
      return s;
    }
    s = s + u64(1);
  }
  return u64(procMax);
}

/// The next READY slot after [cur], round-robin, or [procMax] if there is none.
///
/// **Round-robin from the caller rather than lowest-first**, because
/// lowest-first with two processes is not a scheduler, it is a coin that always
/// lands the same way: process 0 would yield to 1, and 1 would yield to 0 only
/// because 0 is the lowest. With three it would starve process 2 outright. The
/// policy is one line and it is stated rather than emergent.
@bare
u64 procPickNext(u64 cur) {
  u64 n = u64(1);
  while (n < u64(procMaxWrap)) {
    u64 c = cur + n;
    while (c > u64(procMaxSlot)) {
      c = c - u64(procMax);
    }
    if (procGet(c, u64(procSlotState)) == u64(procStateReady)) {
      return c;
    }
    n = n + u64(1);
  }
  return u64(procMax);
}

// ---------------------------------------------------------------------------
// The address space.
//
// Each process gets THREE table frames of its own -- a PML4, a PDPT and a page
// directory for [0, 1GiB) -- plus the one page-table frame `vmProgTableInstall`
// takes for its 2MiB window. The kernel's mappings are COPIED IN at every level
// above the leaf, which means:
//
//   * the kernel's 4KiB identity window [0, 4MiB) is shared BY REFERENCE: the
//     process's page directory holds the same two pointers to `pt0` and `pt1`
//     that the kernel's does, so a change to a kernel page is seen by every
//     process, which is what "the kernel's mappings are shared" has to mean;
//   * the 2MiB leaves for [4MiB, 128MiB) and the PCI hole are copied by value,
//     because a leaf IS its mapping and there is nothing to point at;
//   * page-directory entry 128 -- the program window -- is explicitly CLEARED
//     after the copy. Without it a process created while an M10 `run` program
//     happened to be live would inherit that program's page table and its
//     pages, in its own address space, user-accessible.
//
//     **AND NOTHING CAN CURRENTLY MAKE IT MATTER, WHICH WAS MEASURED RATHER
//     THAN ARGUED.** `shellProcRun` used to refuse to start while an M10
//     program was live (`procErrElfLive`), so the kernel's own `PD[128]` was
//     always zero at the moment this copy happened. A kernel built with this
//     line DELETED passed the whole of `m11-proc/run.sh`. It is the second of
//     two locks on a door the first lock already held shut, and
//     docs/known-gaps.md GAP-0100 records that no test can currently fail
//     because of it.
//
//     **ADR-0034 THEN REMOVED THE FIRST LOCK BY REMOVING THE DOOR.** There is
//     no longer any code that starts an M10 window program, `elfLive()` is a
//     compile-time zero, and `procErrElfLive` is deleted (ADR-0039). So this
//     line is now the ONLY thing standing between a process and a stale
//     `PD[128]`, and it stays for that reason rather than as a second lock.
//
// WHY NOT SHARE THE PML4 ENTRY AND GIVE EACH PROCESS A DIFFERENT WINDOW.
// Because that is not isolation, it is address allocation. Sharing `PML4[0]`
// shares the whole low 512GiB, so every process's pages would be reachable from
// every other process's tables and the only thing keeping them apart would be
// the programs not looking. The window stays at 0x10000000 for ALL processes --
// the same address M10's `run` uses, so the same linker script and the same
// binaries work under both -- and it is a DIFFERENT PAGE at that address in each
// one. That is the property `m11-proc/run.sh` reads out of guest memory: two
// page tables, at two frames, with disjoint contents, both reached from
// `PD[128]` of two different page directories.
// ---------------------------------------------------------------------------

/// Builds slot [s]'s address space: three frames, kernel entries copied in.
///
/// Returns [procErrOk] or [procErrNoFrames]. **Every frame it takes is recorded
/// in the slot the moment it is taken**, so a failure half-way leaves a slot
/// [procSpaceFree] can clean up completely — the same discipline `vmInit` uses
/// for its six frames (ADR-0012), and for the same reason: a partial address
/// space that nobody can name is a leak for the rest of the boot.
@bare
u64 procSpaceBuild(u64 s) {
  final u64 pml4 = allocFrame();
  if (pml4 < u64(1)) {
    return u64(procErrNoFrames);
  }
  procSet(s, u64(procSlotPml4), pml4);
  final u64 pdpt = allocFrame();
  if (pdpt < u64(1)) {
    return u64(procErrNoFrames);
  }
  procSet(s, u64(procSlotPdpt), pdpt);
  final u64 pd = allocFrame();
  if (pd < u64(1)) {
    return u64(procErrNoFrames);
  }
  procSet(s, u64(procSlotPd), pd);

  // Zeroed before anything is written, for `vmZeroFrame`'s reason: an unzeroed
  // page table is 512 entries of allocator litter every one of which the CPU
  // will read as a mapping, with the present bit set roughly half the time.
  vmZeroFrame(pml4);
  vmZeroFrame(pdpt);
  vmZeroFrame(pd);

  final u64 kpml4 = vmFrame(u64(vmIxPml4));
  final u64 kpdpt = vmFrame(u64(vmIxPdpt));
  final u64 kpd = vmFrame(u64(vmIxPdLow));
  u64 i = u64(0);
  while (i < u64(vmEntries)) {
    vmSetEntry(pml4, i, vmGetEntry(kpml4, i));
    vmSetEntry(pdpt, i, vmGetEntry(kpdpt, i));
    vmSetEntry(pd, i, vmGetEntry(kpd, i));
    i = i + u64(1);
  }

  // The two entries that make this a DIFFERENT address space rather than a copy
  // of the kernel's: the path from the root down to the page directory is the
  // process's own, so `PD[128]` can differ. `present | writable | user` and no
  // NX, for `vmProgTableInstall`'s reason -- an interior entry is the ABSENCE of
  // a veto (ADR-0012 §5) and one that withheld W, U or X would make every leaf
  // under it unable to have them whatever `p_flags` said.
  final u64 pwu = u64(vmPresent) | u64(vmWritable) | u64(vmUser);
  vmSetEntry(pml4, u64(0), pdpt | pwu);
  vmSetEntry(pdpt, u64(0), pd | pwu);
  vmSetEntry(pd, u64(vmProgPdIndex), u64(0));
  // M21: and the SHARED-REGION window, for exactly the same reason one line up.
  // The 512 entries above were copied from the kernel's page directory by value,
  // and if a previous boot-time or kernel mapping had ever installed `PD[129]`
  // this process would INHERIT it -- a brand-new address space silently able to
  // reach another process's shared region. `docs/design/memory.md` §1.3's own
  // warning, and it costs one line to be structurally impossible instead of
  // merely unlikely. `m21-shmem/run.sh` asserts both clears are present.
  u64 shmPdI = u64(0);
  while (shmPdI < u64(vmShmPdCount)) {
    vmSetEntry(pd, u64(vmShmPdIndex) + shmPdI, u64(0));
    shmPdI = shmPdI + u64(1);
  }
  // ADR-0124: the platform window, same inheritance lock. A new
  // address space must not inherit PD[131..] from a previous
  // platform process or from a kernel directory that never maps them.
  u64 p = u64(0);
  while (p < u64(vmPlatPdCount)) {
    vmSetEntry(pd, u64(vmPlatPdIndex) + p, u64(0));
    p = p + u64(1);
  }
  return u64(procErrOk);
}

/// Frees everything slot [s]'s address space owns and returns the frame count.
///
/// **The caller must not be running on it.** Every call site in this file writes
/// CR3 to some other address space FIRST -- the next process's, or the
/// kernel's -- because freeing the page tables the CPU is walking hands the MMU
/// to the allocator, and a `mov %rdi,%cr3` is the only way to be sure the TLB
/// has forgotten them (writing CR3 flushes every non-global entry, and this
/// kernel never enables PGE).
///
/// The program's pages are recovered from the process's OWN page table rather
/// than from a remembered list, for `elfUnload`'s reason: the tables are what
/// the CPU obeys, so they are what a teardown has to be checked against.
/// Returns the number of frames actually given back, which `proc` prints and the
/// allocator's free count is asserted against.
/// 1 if another live slot still walks slot [s]'s PML4.
///
/// ADR-0130: `clone` shares the caller's page tables. The first
/// sharer to exit must not free the frames the survivor is
/// standing on. The last one frees as today. Compared by PML4
/// frame, not by a new slot word — m18-preempt owns the indices.
@bare
u64 procSpaceShared(u64 s) {
  final u64 pml4 = procGet(s, u64(procSlotPml4));
  if (pml4 < u64(1)) {
    return u64(0);
  }
  u64 i = u64(0);
  while (i < u64(procMax)) {
    if (i != s) {
      if (procGet(i, u64(procSlotState)) > u64(procStateFree)) {
        if (procGet(i, u64(procSlotPml4)) == pml4) {
          return u64(1);
        }
      }
    }
    i = i + u64(1);
  }
  return u64(0);
}

@bare
u64 procSpaceFree(u64 s) {
  if (procSpaceShared(s) > u64(0)) {
    procSet(s, u64(procSlotPml4), u64(0));
    procSet(s, u64(procSlotPdpt), u64(0));
    procSet(s, u64(procSlotPd), u64(0));
    procSet(s, u64(procSlotPt), u64(0));
    procSet(s, u64(procSlotShmPt), u64(0));
    procSet(s, u64(procSlotPages), u64(0));
    heapReset(s);
    return u64(0);
  }
  u64 freed = u64(0);
  final u64 pd = procGet(s, u64(procSlotPd));
  if (pd > u64(0)) {
    final u64 e = vmGetEntry(pd, u64(vmProgPdIndex));
    if ((e & u64(vmPresent)) > u64(0)) {
      final u64 pt = vmEntryAddr(e);
      u64 i = u64(0);
      while (i < u64(vmEntries)) {
        final u64 le = vmGetEntry(pt, i);
        if ((le & u64(vmPresent)) > u64(0)) {
          if (freeFrame(vmEntryAddr(le)) == u64(pmmFreeOk)) {
            freed = freed + u64(1);
          }
        }
        i = i + u64(1);
      }
      vmSetEntry(pd, u64(vmProgPdIndex), u64(0));
      if (freeFrame(pt) == u64(pmmFreeOk)) {
        freed = freed + u64(1);
      }
    }
    // M21: THE SHARED-REGION WINDOW, torn down the same way and counted the
    // same way -- with one difference that is the entire point of the
    // milestone.
    //
    // The leaves here point at frames a REGION owns, not frames this process
    // owns, and a peer may still be reading them. They are still handed to
    // `freeFrame`, deliberately: `freeFrame` consults `shmFrameShared` and
    // gives a region's frame back to the region rather than to the allocator
    // (`docs/design/memory.md` §2.2 -- the guard belongs at the top of
    // `freeFrame` and nowhere else, because five teardown paths funnel through
    // it and putting it in this function would miss the other four). So this
    // loop is written exactly as the one above it, and the frames it must not
    // release are the ones it does not count.
    u64 shmPdI = u64(0);
    while (shmPdI < u64(vmShmPdCount)) {
      final u64 se = vmGetEntry(pd, u64(vmShmPdIndex) + shmPdI);
      if ((se & u64(vmPresent)) > u64(0)) {
        final u64 spt = vmEntryAddr(se);
        u64 j = u64(0);
        while (j < u64(vmEntries)) {
          final u64 sle = vmGetEntry(spt, j);
          if ((sle & u64(vmPresent)) > u64(0)) {
            final u64 pa = vmEntryAddr(sle);
            // Asked BEFORE the call, because the call is what may clear the bit.
            // This is the one place the count and the guard have to agree: a
            // frame the guard RETAINS was not given back, and `procSpaceFree`'s
            // contract is "frames actually given back" (`docs/design/memory.md`
            // §2.3). Counting a retained frame would make the free-count bracket
            // nine harnesses assert come out right for the wrong reason.
            final u64 shared = shmFrameShared(pa);
            if (freeFrame(pa) == u64(pmmFreeOk)) {
              if (shared < u64(1)) {
                freed = freed + u64(1);
              }
            }
          }
          j = j + u64(1);
        }
        vmSetEntry(pd, u64(vmShmPdIndex) + shmPdI, u64(0));
        // The TABLE, by contrast, is this process's own and is always freed.
        if (freeFrame(spt) == u64(pmmFreeOk)) {
          freed = freed + u64(1);
        }
      }
      shmPdI = shmPdI + u64(1);
    }
    // ADR-0124: platform-window tables and the leaves under them.
    // Every present leaf is a frame this process owns (sbrk), so they
    // go back through freeFrame the same way the 2 MiB window's do.
    u64 p = u64(0);
    while (p < u64(vmPlatPdCount)) {
      final u64 pe = vmGetEntry(pd, u64(vmPlatPdIndex) + p);
      if ((pe & u64(vmPresent)) > u64(0)) {
        final u64 ppt = vmEntryAddr(pe);
        u64 k = u64(0);
        while (k < u64(vmEntries)) {
          final u64 ple = vmGetEntry(ppt, k);
          if ((ple & u64(vmPresent)) > u64(0)) {
            // ADR-0168: skip host-plant alias frames.
            if (elfCefPlantOwns(vmEntryAddr(ple)) < u64(1)) {
              if (freeFrame(vmEntryAddr(ple)) == u64(pmmFreeOk)) {
                freed = freed + u64(1);
              }
            }
          }
          k = k + u64(1);
        }
        vmSetEntry(pd, u64(vmPlatPdIndex) + p, u64(0));
        if (freeFrame(ppt) == u64(pmmFreeOk)) {
          freed = freed + u64(1);
        }
      }
      p = p + u64(1);
    }
    if (freeFrame(pd) == u64(pmmFreeOk)) {
      freed = freed + u64(1);
    }
  }
  final u64 pdpt = procGet(s, u64(procSlotPdpt));
  if (pdpt > u64(0)) {
    if (freeFrame(pdpt) == u64(pmmFreeOk)) {
      freed = freed + u64(1);
    }
  }
  final u64 pml4 = procGet(s, u64(procSlotPml4));
  if (pml4 > u64(0)) {
    if (freeFrame(pml4) == u64(pmmFreeOk)) {
      freed = freed + u64(1);
    }
  }
  procSet(s, u64(procSlotPml4), u64(0));
  procSet(s, u64(procSlotPdpt), u64(0));
  procSet(s, u64(procSlotPd), u64(0));
  procSet(s, u64(procSlotPt), u64(0));
  procSet(s, u64(procSlotShmPt), u64(0));
  procSet(s, u64(procSlotPages), u64(0));
  // M12: the heap's pages were present leaves in the page table this function
  // just walked, so they have ALREADY gone back. This clears the bookkeeping.
  heapReset(s);
  return freed;
}

/// The slot index holding the LIVE process whose id is [id], or
/// [procMax] if there is none.
///
/// **[procMax] rather than 0 for "not found", because 0 is a valid slot.** The
/// caller tests `>= procMax`, which is the same shape `chanOwnerWord`'s callers
/// use and cannot be confused with a result.
///
/// Ids are monotonic (`procHeadCreated`) and slots are reused, which is exactly
/// why M21 stores a capability's owner as a SLOT and its authority check as an
/// id: `shmgrant` is handed a peer id by `chanPeerId` and has to reach that
/// process's capability table, and the only honest way to do that is to find
/// the slot that currently holds that id. A dead process's id matches nothing,
/// so a grant to a peer that has exited refuses rather than writing into
/// whatever took its slot.
@bare
u64 procSlotOfId(u64 id) {
  if (id < u64(1)) {
    return u64(procMax);
  }
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (procGet(s, u64(procSlotState)) != u64(procStateFree)) {
      if (procGet(s, u64(procSlotId)) == id) {
        return s;
      }
    }
    s = s + u64(1);
  }
  return u64(procMax);
}

/// Physical address of slot [s]'s window page table, read out of its OWN page
/// directory, or 0. Used by [procCrossVa] and by the reports.
@bare
u64 procPtOf(u64 s) {
  final u64 pd = procGet(s, u64(procSlotPd));
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

/// The first virtual address in the window that slot [a] has mapped and slot [b]
/// has NOT, or 0 if there is no such address.
///
/// **This is the isolation claim, computed by the kernel from the two page
/// tables it built, and it is what `proc cross` hands to process B to
/// dereference.** A `#PF` at an address process A is happily reading is the
/// difference between "two address spaces" and "two names for one".
///
/// It returns 0 -- and `proc cross` then refuses -- if the two programs happen
/// to map exactly the same set of pages, because in that case there is nothing
/// to prove and a probe would silently pass by reading B's own memory.
@bare
u64 procCrossVa(u64 a, u64 b) {
  final u64 pta = procPtOf(a);
  final u64 ptb = procPtOf(b);
  if (pta < u64(1)) {
    return u64(0);
  }
  if (ptb < u64(1)) {
    return u64(0);
  }
  u64 i = u64(0);
  while (i < u64(vmEntries)) {
    final u64 ea = vmGetEntry(pta, i);
    if ((ea & u64(vmPresent)) > u64(0)) {
      final u64 eb = vmGetEntry(ptb, i);
      if ((eb & u64(vmPresent)) < u64(1)) {
        return u64(vmProgBase) + (i << u64(vmPageShift));
      }
    }
    i = i + u64(1);
  }
  return u64(0);
}

// ---------------------------------------------------------------------------
// The switch itself.
// ---------------------------------------------------------------------------

/// Copies the 22-word interrupt frame at [frame] into slot [s].
@bare
void procSaveFrame(u64 s, u64 frame) {
  u64 i = u64(0);
  while (i < u64(procFrameWords)) {
    procSet(s, u64(procSlotSaved) + i,
        Pointer<u64>.fromAddress(frame + (i << u64(3))).value);
    i = i + u64(1);
  }
}

/// Copies slot [s]'s saved frame back over the interrupt frame at [frame].
///
/// **After this returns, `isr_common` pops fifteen registers and `iretq`s into a
/// different process.** Nothing else happens; there is no jump, no stack switch
/// and no second return path. That is the whole mechanism.
@bare
void procLoadFrame(u64 s, u64 frame) {
  u64 i = u64(0);
  while (i < u64(procFrameWords)) {
    Pointer<u64>.fromAddress(frame + (i << u64(3))).value =
        procGet(s, u64(procSlotSaved) + i);
    i = i + u64(1);
  }
}

/// Builds the frame a process that has never run resumes from.
///
/// Only the seven words the CPU and the ABI care about are non-zero: RIP, CS,
/// RFLAGS, RSP, SS and RDI. **The other fifteen are zero deliberately**, which
/// is `enter_user`'s register scrub (ADR-0013) restated as data: whatever is in
/// a register at the `iretq` is readable by ring 3, and at the moment a process
/// first runs those registers hold kernel addresses. RDI is the one channel in.
///
/// RFLAGS is 0x202 — IF set, IOPL 0 — the same constant `enter_user` pushes, so
/// a process that first runs by being SWITCHED to gets exactly the flags a
/// process that first runs by being ENTERED gets. The two paths producing
/// different starting flags is the kind of difference that shows up much later
/// as one program being interruptible and another not.
@bare
void procInitFrame(u64 s) {
  u64 i = u64(0);
  while (i < u64(procFrameWords)) {
    procSet(s, u64(procSlotSaved) + i, u64(0));
    i = i + u64(1);
  }
  final u64 w = u64(procSlotSaved);
  procSet(s, w + u64(9), procGet(s, u64(procSlotProbe)));    // RDI, offset 72
  procSet(s, w + u64(17), procGet(s, u64(procSlotEntry)));   // RIP, offset 136
  procSet(s, w + u64(18), u64(userCodeSel));                 // CS,  offset 144
  procSet(s, w + u64(19), u64(0x202));                       // RFLAGS
  procSet(s, w + u64(20), procGet(s, u64(procSlotRsp)));     // RSP, offset 160
  procSet(s, w + u64(21), u64(userDataSel));                 // SS,  offset 168
}

/// Makes slot [next] the running process and resumes it from its saved frame.
///
/// **The order below is a correctness argument, not a sequence.**
///
///   1. CR3 first, because everything after it must run in the address space it
///      is about to resume — and because the caller is often about to free the
///      address space it came from, which it may not do while the CPU is
///      walking it. The kernel is mapped identically in both, which is what
///      makes writing CR3 in the middle of a kernel function survivable at all
///      (`procSpaceBuild` copies every level above the leaf).
///   2. the FPU state, because it is the one piece of the process that
///      `isr_common` does NOT restore. Fifteen general-purpose registers come
///      back from the frame; the sixteen XMM registers, MXCSR and the x87 stack
///      come back from here or not at all. **Skipped entirely on a CPU with no
///      FXSR**, where a process simply has no FPU state and `proc` prints
///      `SSE 0` (docs/known-gaps.md GAP-0098).
///   3. the register frame last, because writing it is the point of no return:
///      from that store onwards the stack this function is standing on describes
///      somebody else.
///
/// Prints nothing. The callers print, because "switched because it yielded" and
/// "switched because it exited" are different events.
@bare
void procSwitchTo(u64 next, u64 frame) {
  procSet(next, u64(procSlotState), u64(procStateRunning));
  procSetHead(u64(procHeadCurrent), next + u64(1));
  paging_install(procGet(next, u64(procSlotPml4)));
  if (procHead(u64(procHeadSse)) > u64(0)) {
    fx_restore(procFxArea(next));
  }
  // ADR-0148: FS.base is per-slot. Without this write a clone that
  // set TLS would hand its sibling the wrong base on resume.
  procInstallFs(next);
  procLoadFrame(next, frame);
  procBumpHead(u64(procHeadSwitches));
  // M18: the incoming process starts a FRESH slice. Without this line a process
  // that was switched to just as the previous one's slice was nearly spent
  // would inherit the remainder and be preempted almost immediately — the
  // classic way a round-robin scheduler starves whichever process happens to be
  // scheduled late in a tick.
  procSetHead(u64(procHeadSlice), u64(0));
}

// ---------------------------------------------------------------------------
// ==========================  M18: PREEMPTION  ==============================
//
// Called from `isrDispatch`'s timer arm on EVERY PIT tick, after the EOI.
//
// ---------------------------------------------------------------------------
// ONLY RING 3 IS PREEMPTED, AND THAT IS A DECISION WITH A STATED COST
// ---------------------------------------------------------------------------
// The third line of the body reads the CS the CPU pushed and returns unless its
// low two bits are 3. So a tick that interrupted KERNEL code never preempts:
// **a syscall cannot be preempted**, and neither can the shell, the ELF loader,
// or a disk read.
//
// What that costs is bounded latency: a program that calls `read()` on a
// twenty-thousand-byte file holds the CPU for the whole of it, and no other
// process runs until it returns. On this kernel that is a smaller loss than it
// sounds, and the reason is not the CS check at all: EVERY gate in this IDT is
// an INTERRUPT gate, so IF is clear for the whole of every kernel entry from
// ring 3, and a timer tick inside a syscall is not merely un-preempted — it is
// not delivered. [procHeadKernTicks] counts the ticks that do arrive with a
// process live and CPL 0, and it is near zero for exactly that reason.
//
// What it BUYS is the reason to do it this way. Preempting ring 0 means:
//
//   * a second kernel stack per process, because the whole cooperative design
//     rests on "only one process is ever inside the kernel at a time" -- the
//     sentence `proc.dart`'s header already says stops being true the day the
//     switching is not cooperative. It is still true, because a preemption from
//     ring 3 puts the CPU back in ring 3;
//   * re-entrancy in every kernel data structure a syscall touches: the frame
//     allocator, the FAT cluster cache, the descriptor table. None of them is
//     re-entrant and none of them is guarded.
//
// Doing the ring-3-only version first is not a shortcut around those two; it is
// a scheduler that does not need them yet, and `docs/known-gaps.md` GAP-0138
// is what it would take.
// ---------------------------------------------------------------------------
/// One PIT tick, from the timer interrupt handler.
///
/// Returns normally in every case but one: when the session's quantum budget is
/// spent, [procBudgetEnd] abandons this interrupt frame and never comes back.
@bare
void procTick(u64 frame) {
  if (procLive() < u64(1)) {
    return;
  }
  if (procGet(procCurrent(), u64(procSlotState)) == u64(procStateKilled)) {
    procReapKilled(procCurrent());
    return;
  }
  if (procHead(u64(procHeadPolicy)) < u64(procPolicyPreempt)) {
    return;
  }
  // THE PRIVILEGE CHECK. `userFrameCs` is the CS the CPU pushed; its low two
  // bits are the privilege the interrupted code was running at.
  if ((userFrame(frame, u64(userFrameCs)) & u64(3)) < u64(3)) {
    procBumpHead(u64(procHeadKernTicks));
    return;
  }
  final u64 slice = procHead(u64(procHeadSlice)) + u64(1);
  if (slice < u64(procQuantumTicks)) {
    procSetHead(u64(procHeadSlice), slice);
    return;
  }
  // The quantum is spent. It is spent whether or not there is anywhere to go.
  procSetHead(u64(procHeadSlice), u64(0));
  procBumpHead(u64(procHeadQuanta));

  // THE BUDGET. `budget < quanta + 1` is `quanta >= budget`, spelled the way
  // `@bare` DCDart can spell it (GAP-0023: no `>=`). NOT `quanta == budget`,
  // even though the counter is incremented by one immediately above and could
  // not skip the value: an equality test on a counter is a test that stops
  // being true if anything ever sets the counter or the budget from anywhere
  // else, and it would fail OPEN -- the session would run forever.
  final u64 budget = procHead(u64(procHeadBudget));
  if (budget > u64(0)) {
    if (budget < procHead(u64(procHeadQuanta)) + u64(1)) {
      procBudgetEnd(); // never returns
      return;
    }
  }

  final u64 cur = procCurrent();
  final u64 next = procPickNext(cur);
  if (next == u64(procMax)) {
    // A quantum expired with exactly one runnable process. A classic
    // `proc run` session stays on the CPU -- the expiry was counted, which is
    // what makes a LONE runaway visible and, with a budget, stoppable.
    //
    // A RESIDENT session gives the CPU back to the shell: that is D3. The
    // process is saved and marked READY, the per-slot preempt counter
    // advances (the criterion `display-protocol.md` §6 names), and
    // `user_return` lands in the idle loop. `m18-preempt` uses `proc run`,
    // so this arm is not taken there.
    if (procHead(u64(procHeadResident)) < u64(1)) {
      return;
    }
    procSaveFrame(cur, frame);
    if (procHead(u64(procHeadSse)) > u64(0)) {
      fx_save(procFxArea(cur));
    }
    procSet(cur, u64(procSlotState), u64(procStateReady));
    procSet(cur, u64(procSlotPreempts),
        procGet(cur, u64(procSlotPreempts)) + u64(1));
    procBumpHead(u64(procHeadPreempts));
    procToKernel();
    procSetHead(u64(procHeadCurrent), u64(0));
    user_return(); // never returns; control reappears in procResume
    return;
  }

  // From here it is [procYield]'s body with two differences, and both of them
  // are the whole milestone:
  //
  //   * THE SAVED RAX IS NOT PATCHED. `procYield` overwrites it with 1 because
  //     the frame it saves was built by an `int $0x80` whose RAX held a syscall
  //     number. This frame was built by a TIMER INTERRUPT at an arbitrary
  //     instruction boundary; its RAX is the process's own live register and
  //     writing anything into it would corrupt the program. The one line that
  //     is right in the cooperative path is a bug in this one.
  //
  //   * IT PRINTS A DIFFERENT LINE. `PROC PREEMPT`, not `PROC YIELD`, so the
  //     two kinds of switch are distinguishable in a serial capture by a
  //     harness that has no other way to tell them apart. See
  //     [procPreemptLine].
  procSaveFrame(cur, frame);
  if (procHead(u64(procHeadSse)) > u64(0)) {
    fx_save(procFxArea(cur));
  }
  procSet(cur, u64(procSlotState), u64(procStateReady));
  procSet(cur, u64(procSlotPreempts),
      procGet(cur, u64(procSlotPreempts)) + u64(1));
  procBumpHead(u64(procHeadPreempts));
  procPreemptLine(cur, next);
  procSwitchTo(next, frame);
}

/// The session's quantum budget is spent: kill every process and return to the
/// shell. **NEVER RETURNS.**
///
/// This is [procOnFault]'s teardown with a different reason printed, and it is
/// deliberately the same shape: CR3 goes back to the kernel's FIRST, because
/// [procSpaceFree] may not run on the tables the CPU is standing on; then every
/// live slot is torn down; then `user_return` restores the RSP `enter_user`
/// recorded and reappears inside [shellProcRun].
///
/// **THE EOI HAS ALREADY BEEN SENT.** `isrDispatch` acknowledges the PIT and
/// THEN calls [procTick], precisely so that this path can abandon the interrupt
/// frame without leaving IRQ0 in the PIC's in-service register for the rest of
/// the boot — which would block IRQ1 with it, since the keyboard is a lower
/// priority line on the same PIC, and the shell we are returning to would
/// answer nothing at all. ADR-0022 §8 is the record.
@bare
void procBudgetEnd() {
  uartWrite(Rodata.addressOf(procStrBudget), u64(19));
  uartPutHex(procHead(u64(procHeadQuanta)), u64(8));
  uartWrite(Rodata.addressOf(procStrPreempts), u64(10));
  uartPutHex(procHead(u64(procHeadPreempts)), u64(8));
  uartNewline();
  procToKernel();
  procSetHead(u64(procHeadCurrent), u64(0));
  procSetHead(u64(procHeadLive), u64(0));
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (procGet(s, u64(procSlotState)) > u64(procStateFree)) {
      procSet(s, u64(procSlotState), u64(procStateKilled));
      procCleanup(s);
    }
    s = s + u64(1);
  }
  if (procHead(u64(procHeadResident)) > u64(0)) {
    procSetHead(u64(procHeadResident), u64(0));
    procSessionTimerOff();
  }
  user_return(); // never returns; control reappears in shellProcRun or the idle loop
}

/// `PROC PREEMPT <cur> -> <next> N <n>` — one line per involuntary switch.
///
/// **This prints from inside the timer interrupt**, which is safe here for the
/// same reason every other handler in this kernel prints: `uartWrite` polls the
/// Transmit-Holding-Register-Empty bit and every gate in this IDT is an
/// interrupt gate, so the handler cannot be re-entered by the next tick while
/// it is half way through a line. It would stop being safe the day a second CPU
/// existed (`docs/known-gaps.md` GAP-0136).
///
/// It is the observable difference between the two kinds of switch: `PROC
/// YIELD` is printed by a process that asked, `PROC PREEMPT` by a process that
/// did not. `m18-preempt/run.sh` requires the second and forbids the first.
@bare
void procPreemptLine(u64 cur, u64 next) {
  uartWrite(Rodata.addressOf(procStrPreempt), u64(13));
  uartPutHex(cur, u64(2));
  uartWrite(Rodata.addressOf(procStrArrow), u64(4));
  uartPutHex(next, u64(2));
  uartWrite(Rodata.addressOf(procStrN), u64(3));
  uartPutHex(procGet(cur, u64(procSlotPreempts)), u64(8));
  uartNewline();
}

/// Puts the kernel's own address space back on the CPU.
///
/// Read out of `vmMetaPml4` rather than remembered here, so there is exactly one
/// place in this kernel that knows what the kernel's root is.
@bare
void procToKernel() {
  paging_install(vmMeta(u64(vmMetaPml4)));
}

/// Syscall 3 — `yield`. Saves the caller, picks the next READY process, and
/// resumes it. Returns 1 to the process that yielded, WHEN IT COMES BACK.
///
/// **The RAX patch four lines in is the one subtle thing in this file.** The
/// frame being saved was built by a `int $0x80` whose RAX held the syscall
/// NUMBER, 3. Restoring it unaltered would hand the resumed process a 3 as its
/// syscall return value — a number that means nothing, arrived at by accident,
/// and indistinguishable from a real result. So the SAVED copy's RAX word is
/// overwritten with 1 before the switch: "you yielded, and you are back".
///
/// A yield with nobody else READY is not an error. It returns 0 — "there was
/// nothing to switch to" — and the process carries on. A scheduler that made
/// that a refusal would make a correct program's behaviour depend on how many
/// other programs happened to be loaded.
@bare
void procYield(u64 frame) {
  final u64 cur = procCurrent();
  if (procGet(cur, u64(procSlotState)) == u64(procStateKilled)) {
    procReapKilled(cur);
    return;
  }
  final u64 next = procPickNext(cur);
  if (next == u64(procMax)) {
    userSetFrame(frame, u64(userFrameRax), u64(0));
    return;
  }
  procSaveFrame(cur, frame);
  procSet(cur, u64(procSlotSaved) + u64(procFrameRaxWord), u64(1));
  if (procHead(u64(procHeadSse)) > u64(0)) {
    fx_save(procFxArea(cur));
  }
  procSet(cur, u64(procSlotState), u64(procStateReady));
  // M18: the per-process yield count, kept so that "this process was switched
  // away and never asked to be" is a statement the kernel makes about a
  // PARTICULAR process rather than about a session. `m18-preempt` asserts it is
  // zero for both of its programs while their preempt counts are not.
  procSet(cur, u64(procSlotYields), procGet(cur, u64(procSlotYields)) + u64(1));
  /* m11-proc needs every switch printed (those boots never set wm gfx).
   * Demo/release: no PROC YIELD on COM1 while wm gfx is live. Opt in with
   * `wm pace log` (wmPageFlagLog) for diagnostics/conformance. */
  u64 logYield = u64(1);
  if (wmMeta(u64(wmMetaGfx)) > u64(0)) {
    logYield = u64(0);
    if (wmPaceLogging() > u64(0)) {
      final u64 sw = procHead(u64(procHeadSwitches)) + u64(1);
      if (sw < u64(8)) {
        logYield = u64(1);
      } else {
        if ((sw & u64(255)) == u64(0)) {
          logYield = u64(1);
        }
      }
    }
  }
  if (logYield > u64(0)) {
    uartWrite(Rodata.addressOf(procStrYield), u64(11));
    uartPutHex(cur, u64(2));
    uartWrite(Rodata.addressOf(procStrArrow), u64(4));
    uartPutHex(next, u64(2));
    uartWrite(Rodata.addressOf(procStrSwitches), u64(10));
    uartPutHex(procHead(u64(procHeadSwitches)) + u64(1), u64(8));
    uartNewline();
  }
  procSwitchTo(next, frame);
}

// ---------------------------------------------------------------------------
// Creating a process.
// ---------------------------------------------------------------------------

/// Frees everything slot [s] owns, empties it, and says how many frames came
/// back. `PROC KILL SLOT <n> FREED <n>`
///
/// **The caller must already have moved CR3 off this address space.** Shared by
/// the load-refusal path, the exit path and the fault path, deliberately: a
/// teardown that only runs when things went well is not a teardown, and two of
/// the three callers here are failures.
@bare
void procCleanup(u64 s) {
  final u64 freed = procSpaceFree(s);
  // M15: this slot's file descriptors go with everything else it owned, and for
  // the same stated reason — two of this function's three callers are failures,
  // and a descriptor row that survived a killed process would be inherited by
  // whatever `proc run` put in the slot next.
  final u64 orphans = fileReleaseOwner(s);
  if (orphans > u64(0)) {
    fileOrphanLine(orphans);
  }
  // M20: this slot's IPC endpoints go with everything else it owned, and for
  // exactly the reason its descriptors do. This is the ONLY caller of
  // [chanReleaseOwner] and it is deliberately this function rather than the exit
  // syscall: two of the three callers here are failures, and an endpoint that
  // survived a KILLED process would leave its peer waiting forever on a
  // conversation nobody is on the other end of. Released by ID rather than by
  // slot, because slots are reused and IDs are not; the `id < 1` guard inside
  // handles the load-refusal path, where this slot's ID word is still the
  // previous occupant's or has never been written at all.
  chanReleaseOwner(procGet(s, u64(procSlotId)));
  // M21: and this slot's SHARED-REGION CAPABILITIES, here for the third time
  // for the same reason and with one difference worth stating.
  //
  // By SLOT rather than by id, unlike the line above it, because a capability
  // table IS slot storage (`procSlotShmCaps`) rather than a record keyed by
  // owner -- so "release what this slot holds" is the literal operation, and
  // there is no window in which an id lookup could find the wrong slot.
  //
  // AFTER `procSpaceFree`, deliberately: the mappings are already gone, so this
  // has only to drop the capabilities and the reference counts they stood for.
  // A region whose last capability this releases is destroyed here, and THAT is
  // where its frames actually go back to the allocator -- which is why the free
  // count is asserted across the LAST exit rather than each one
  // (`docs/design/memory.md` §2.3, ADR-0041 §5).
  shmReleaseOwner(s);
  // D7: this process's click rings. A process may own two windows.
  // Both are still LIVE until [wmReap]. A reused window that kept
  // a press would pop it for the next owner.
  wmeventResetOwned(procGet(s, u64(procSlotId)));
  procSet(s, u64(procSlotWaitAddr), u64(0));
  procSet(s, u64(procSlotFsBase), u64(0));
  procSet(s, u64(procSlotCefMemset), u64(0));
  procSet(s, u64(procSlotState), u64(procStateFree));
  uartWrite(Rodata.addressOf(procStrKill), u64(15));
  uartPutHex(s, u64(2));
  uartWrite(Rodata.addressOf(procStrFreed), u64(7));
  uartPutHex(freed, u64(8));
  uartNewline();
}

/// Tears down slot [s] from a close that landed while it was current.
/// CR3 goes back to the kernel first; then [user_return] to the idle
/// line. Same shape as the last-process arm of [procSysExit].
@bare
void procReapKilled(u64 s) {
  if (procGet(s, u64(procSlotState)) != u64(procStateKilled)) {
    return;
  }
  procToKernel();
  procSetHead(u64(procHeadCurrent), u64(0));
  if (procHead(u64(procHeadLive)) > u64(0)) {
    procSetHead(u64(procHeadLive), procHead(u64(procHeadLive)) - u64(1));
  }
  procCleanup(s);
  user_return();
}

/// Kills the process that holds [id]. Close is compositor policy: the
/// surface is already gone. If that process is on the CPU (IRQ12 during
/// its quantum) it is marked [procStateKilled] and [procReapKilled]
/// finishes on the next yield or tick — the page tables the CPU is
/// standing on are not freed from the mouse path.
@bare
void procKillId(u64 id) {
  final u64 s = procSlotOfId(id);
  if (s >= u64(procMax)) {
    return;
  }
  if (procGet(s, u64(procSlotState)) == u64(procStateFree)) {
    return;
  }
  if (procLive() > u64(0)) {
    if (procCurrent() == s) {
      procSet(s, u64(procSlotState), u64(procStateKilled));
      return;
    }
  }
  if (procHead(u64(procHeadLive)) > u64(0)) {
    procSetHead(u64(procHeadLive), procHead(u64(procHeadLive)) - u64(1));
  }
  procCleanup(s);
}

/// Loads the ELF whose header sector is at [lba] into a fresh slot.
///
/// **`core/kernel/elf.dart` is called UNCHANGED and does not know a process
/// exists.** The trick is one instruction wide: this function installs the new
/// process's CR3 before calling [elfLoad] and the kernel's again afterwards, and
/// `vmProgPd` — which the loader reaches through `vmProgMap` — walks from CR3.
/// So the loader maps into the address space that is on the CPU, which is the
/// only address space it has ever claimed to map into.
///
/// Running kernel code on a process's CR3 is safe because [procSpaceBuild]
/// copied every kernel mapping into it; it is the same thing that happens on
/// every syscall a process makes. The window is the only difference between the
/// two address spaces, and the loader is the thing filling the window in.
///
/// Returns [procErrOk] or a refusal code. **On any refusal the slot is emptied
/// completely** by [procCleanup] — the frames the loader took go back through
/// the same path a finished process's do, so a file rejected at its third
/// segment costs the machine nothing.
///
/// Every discarded `freeFrame` status is ADDED to the header's ERRORS word
/// rather than dropped, which works because `pmmFreeOk` is 0: a clean session
/// reports `ERRORS 00000000` as a claim rather than as a default (ADR-0011 §4).
/// M20: [named] chooses where the image comes from, exactly as it does in
/// `shellElfLoadAndEnter` -- 0 means [lba] is a sector number and the loader
/// reads contiguous sectors, and 1 means a FAT16 chain is already open and the
/// loader reads image-relative sectors through it. **The two forms differ in
/// nothing else**, which is why one parameter and two `if`s express the whole
/// difference rather than a second copy of this function.
/// 1 if the name already in [fatNameBase] is `PLAT.ELF`.
///
/// **Name, not a syscall argument.** A TAP/FILES ELF that asks for a
/// 3 MiB `sbrk` is refused by [heapCap]. Only this 8.3 name installs
/// the 16 MiB window. LBA spawn never matches: [fatNameBase] is not
/// consulted when [named] is 0.
@bare
u64 procPlatNameMatch() {
  final u64 have = fatNameBase();
  final u64 want = Rodata.addressOf(procStrPlatName);
  u64 i = u64(0);
  while (i < u64(fatNameBytes)) {
    if (Pointer<u8>.fromAddress(have + i).value !=
        Pointer<u8>.fromAddress(want + i).value) {
      return u64(0);
    }
    i = i + u64(1);
  }
  return u64(1);
}

@bare
u64 procCreate(u64 lba, u64 named) {
  final u64 s = procFreeSlot();
  if (s == u64(procMax)) {
    return u64(procErrNoSlot);
  }
  procSet(s, u64(procSlotPlat), u64(0));
  procSet(s, u64(procSlotCefMemset), u64(0));
  final u64 bs = procSpaceBuild(s);
  if (bs > u64(0)) {
    procCleanup(s);
    return bs;
  }

  final u64 hdr = allocFrame();
  if (hdr < u64(1)) {
    procCleanup(s);
    return u64(procErrNoFrames);
  }
  final u64 scratch = allocFrame();
  if (scratch < u64(1)) {
    procSetHead(u64(procHeadErrors), procHead(u64(procHeadErrors)) + freeFrame(hdr));
    procCleanup(s);
    return u64(procErrNoFrames);
  }
  vmZeroFrame(hdr);
  vmZeroFrame(scratch);

  elfSetMeta(u64(elfMetaHeaderLba), lba);
  elfSetMeta(u64(elfMetaPages), u64(0));
  elfSetMeta(u64(elfMetaSegments), u64(0));
  elfSetMeta(u64(elfMetaSectors), u64(0));
  elfSetMeta(u64(elfMetaZeroed), u64(0));
  elfSetMeta(u64(elfMetaExit), u64(0));
  elfSetMeta(u64(elfMetaPtFrame), u64(0));
  elfSetMeta(u64(elfMetaStackFrame), u64(0));
  elfSetMeta(u64(elfMetaScratch), scratch);

  // M14: a NUMERIC load takes LBAs and only LBAs, so the loader's sector reads
  // must go through the contiguous path. A `cat` or a named load earlier in the
  // session leaves a cluster chain open in `fat.dart`, and `elfImageLba` would
  // then read THAT file's sectors for these LBAs. One call closes it, in the
  // one place that knows this load is a numeric one.
  //
  // M20: a NAMED load must not close it -- the caller opened the chain and the
  // loader is about to read the image through it.
  if (named < u64(1)) {
    fatClose();
  }

  // ---- the two-instruction trick ----
  paging_install(procGet(s, u64(procSlotPml4)));
  u64 st = u64(elfErrOk);
  if (named > u64(0)) {
    st = elfLoadFile(hdr, scratch);
  } else {
    st = elfLoad(lba, hdr, scratch);
  }
  // M20 (ADR-0034): THE PAGE REPORT IS TAKEN HERE, WHILE THE PROGRAM'S OWN CR3
  // IS STILL INSTALLED, AND THAT IS THE ONLY PLACE IT CAN BE TAKEN.
  //
  // `elfPageReport` and `elfWindowLine` walk from CR3 -- `vmProgLeaf` and
  // `vmEffective` both do -- and before ADR-0034 the program's window lived in
  // the KERNEL's page directory, so the shell could walk it after the load had
  // finished. It cannot any more: the window belongs to this process, and the
  // shell runs on the kernel's CR3.
  //
  // It is inside the EXISTING bracket rather than in a second one of its own.
  // An earlier attempt at this milestone put a `paging_install`/`procToKernel`
  // pair in the shell launcher instead, after the slot was already READY and
  // LIVE, and the session then never came back from the program's last `exit` --
  // control was lost somewhere after `PROC KILL`. The mechanism was not run to
  // ground; the report was moved here, into the window this kernel has walked
  // process page tables in since M11, and the problem does not arise. Do not
  // reintroduce a second bracket without understanding that first.
  if (st < u64(1)) {
    elfPageReport();
    elfWindowLine();
    if (named > u64(0)) {
      if (procPlatNameMatch() > u64(0)) {
        procSet(s, u64(procSlotPlat), u64(1));
        if (vmPlatTablesInstall() > u64(0)) {
          st = u64(elfErrNoFrames);
        }
      }
    }
  }

  procToKernel();

  // The scratch frames go back BEFORE anything else, on every path, for
  // `shellElfRun`'s reason: they hold a copy of the file, which the program has
  // no business reading.
  final u64 b1 = freeFrame(scratch);
  final u64 b2 = freeFrame(hdr);
  procSetHead(u64(procHeadErrors), procHead(u64(procHeadErrors)) + b1 + b2);

  if (st > u64(0)) {
    elfReportError(st);
    procCleanup(s);
    return u64(procErrLoad);
  }

  procSet(s, u64(procSlotPt), elfMeta(u64(elfMetaPtFrame)));
  procSet(s, u64(procSlotEntry), elfMeta(u64(elfMetaEntry)));
  procSet(s, u64(procSlotStackFrame), elfMeta(u64(elfMetaStackFrame)));

  // -------------------------------------------------------------------------
  // M20 (ADR-0034): THE INITIAL PROCESS STACK, BUILT HERE RATHER THAN NOWHERE.
  //
  // Until this line a process was entered with RSP = `vmProgStackTop`: the top
  // of an EMPTY page. That is what "a heap but no argv" meant -- M19 taught the
  // M10 `run` path to build a System V initial stack and never taught this one,
  // so the two ways to start a program each had half of what a program needs.
  //
  // **THIS RUNS ON THE KERNEL'S CR3 AND THAT IS WHY IT IS HERE.**
  // [argsBuild] writes every byte through `argsPhys` -- the PHYSICAL address of
  // the stack frame, which the kernel's identity map covers -- rather than
  // through `[vmProgStackPage, vmProgStackTop)`, which only the process's own
  // tables map. So it neither needs nor wants the target address space
  // installed, and placing it AFTER `procToKernel()` keeps the window in which
  // this kernel runs on a process's page tables as narrow as it has ever been:
  // the loader call, and nothing else.
  //
  // A refusal tears the slot down through [procCleanup], the same path every
  // other refusal in this function uses, so a load that cannot build a stack
  // gives back every frame it took.
  // -------------------------------------------------------------------------
  final u64 rsp = argsBuild(elfMeta(u64(elfMetaStackFrame)));
  if (rsp < u64(1)) {
    procCleanup(s);
    // UNREACHABLE BY ARITHMETIC, NOT MERELY BY THIS SHELL. `args.dart` caps
    // staging at `argsMaxCount` arguments and `argsMaxBytes` bytes, whose worst
    // case is 240 bytes against a 4KiB page less `argsMinStack` — so
    // `argsBuild` is total and no caller of this function can produce the
    // failure. `m19-argv/run.sh` §2g multiplies the four numbers out and fails
    // the day one of them changes. GAP-0245.
    return u64(procErrArgs);
  }
  procSet(s, u64(procSlotRsp), rsp);
  procSet(s, u64(procSlotPages), elfMeta(u64(elfMetaPages)));
  procSet(s, u64(procSlotSegments), elfMeta(u64(elfMetaSegments)));
  procSet(s, u64(procSlotLo), elfMeta(u64(elfMetaLo)));
  procSet(s, u64(procSlotHi), elfMeta(u64(elfMetaHi)));
  procSet(s, u64(procSlotLba), lba);
  procSet(s, u64(procSlotExit), u64(0));
  // ADR-0126: RDI is the dyn `e_entry` when a platform `PT_INTERP`
  // load parked it in [elfMetaExit]. Zero on every other spawn.
  procSet(s, u64(procSlotProbe), elfMeta(u64(elfMetaExit)));
  procBumpHead(u64(procHeadCreated));
  procSet(s, u64(procSlotId), procHead(u64(procHeadCreated)));
  procFxInit(s);
  // M12: the heap starts at the first page above the highest page the LOADER
  // mapped -- a number elf.dart computed from this file's own p_vaddrs.
  heapInit(s, elfMeta(u64(elfMetaHi)));
  procInitFrame(s);
  procSet(s, u64(procSlotState), u64(procStateReady));
  procBumpHead(u64(procHeadLive));

  uartWrite(Rodata.addressOf(procStrNew), u64(14));
  uartPutHex(s, u64(2));
  uartWrite(Rodata.addressOf(procStrId), u64(4));
  uartPutHex(procGet(s, u64(procSlotId)), u64(8));
  uartWrite(Rodata.addressOf(procStrPml4), u64(6));
  uartPutHex(procGet(s, u64(procSlotPml4)), u64(16));
  uartWrite(Rodata.addressOf(procStrPdF), u64(4));
  uartPutHex(procGet(s, u64(procSlotPd)), u64(16));
  uartNewline();
  uartWrite(Rodata.addressOf(procStrNew), u64(14));
  uartPutHex(s, u64(2));
  uartWrite(Rodata.addressOf(procStrPt), u64(4));
  uartPutHex(procGet(s, u64(procSlotPt)), u64(16));
  uartWrite(Rodata.addressOf(procStrEntry), u64(7));
  uartPutHex(procGet(s, u64(procSlotEntry)), u64(16));
  uartWrite(Rodata.addressOf(procStrPages), u64(7));
  uartPutHex(procGet(s, u64(procSlotPages)), u64(8));
  uartWrite(Rodata.addressOf(procStrFx), u64(4));
  uartPutHex(procFxArea(s), u64(16));
  uartNewline();
  if (procGet(s, u64(procSlotPlat)) > u64(0)) {
    uartWrite(Rodata.addressOf(procStrPlat), u64(10));
    uartPutHex(s, u64(2));
    uartWrite(Rodata.addressOf(procStrWin), u64(5));
    uartPutHex(u64(vmPlatBytes), u64(16));
    uartNewline();
  }
  return u64(procErrOk);
}

// ---------------------------------------------------------------------------
// Leaving: the exit path and the fault path.
// ---------------------------------------------------------------------------

/// The `exit` syscall, when the thing calling it is a process.
///
/// Called from [userSysExit] instead of M9's teardown. **It returns normally if
/// another process is READY and NEVER RETURNS if this was the last one** — which
/// looks like two functions and is one, because the two cases differ only in
/// where control goes and not in what is torn down.
///
///   * another process READY: switch to it, THEN free the dead one's address
///     space (CR3 is no longer walking it), then return. `isr_common` pops and
///     `iretq`s into the survivor.
///   * nobody left: put the kernel's address space back, free the dead one, and
///     leave through `user_return` — which restores the RSP `enter_user`
///     recorded and returns into [shellProcRun], immediately after its call.
///
/// The order in the first case is the whole safety argument: freeing before the
/// switch would hand the allocator the page tables the CPU is standing on.
@bare
void procSysExit(u64 frame, u64 code) {
  final u64 cur = procCurrent();
  procSet(cur, u64(procSlotExit), code);
  procSet(cur, u64(procSlotState), u64(procStateExited));
  procBumpHead(u64(procHeadExits));
  procSetHead(u64(procHeadLive), procHead(u64(procHeadLive)) - u64(1));

  uartWrite(Rodata.addressOf(procStrExitL), u64(15));
  uartPutHex(cur, u64(2));
  uartWrite(Rodata.addressOf(procStrId), u64(4));
  uartPutHex(procGet(cur, u64(procSlotId)), u64(8));
  uartWrite(Rodata.addressOf(procStrCode), u64(6));
  uartPutHex(code, u64(16));
  uartWrite(Rodata.addressOf(procStrLeft), u64(6));
  uartPutHex(procHead(u64(procHeadLive)), u64(8));
  uartNewline();

  final u64 next = procPickNext(cur);
  if (next == u64(procMax)) {
    procToKernel();
    procSetHead(u64(procHeadCurrent), u64(0));
    procCleanup(cur);
    // ADR-0146: a BLOCKED waiter with no READY peer is deadlocked.
    // Tear those slots down with the session rather than leak tables.
    u64 s = u64(0);
    while (s < u64(procMax)) {
      if (procGet(s, u64(procSlotState)) == u64(procStateBlocked)) {
        procSetHead(u64(procHeadLive), procHead(u64(procHeadLive)) - u64(1));
        procCleanup(s);
      }
      s = s + u64(1);
    }
    if (procHead(u64(procHeadResident)) > u64(0)) {
      procSetHead(u64(procHeadResident), u64(0));
      procSessionTimerOff();
    }
    user_return(); // never returns; control reappears in shellProcRun or the idle loop
    return;
  }
  procSwitchTo(next, frame);
  procCleanup(cur);
}

/// A process took a fault. Called from [userOnFault].
///
/// **The whole session dies, not just the faulting process, and that is a
/// decision rather than an omission.** M4's recovery path (`fault_resume`)
/// abandons every stack frame between the fault and the shell loop, so
/// [shellProcRun] never runs again and never gets to clean up. A survivor left
/// READY would therefore be a process nothing can ever schedule, holding four
/// frames and a page table, for the rest of the boot — which is exactly the
/// state GAP-0085 item 10 warned a kernel WITH processes must not reach.
/// Killing all of them is the honest version of what M4 can currently recover
/// to. docs/known-gaps.md GAP-0097 records what a per-process kill would need.
///
/// CR3 goes back to the kernel's FIRST, before anything is freed, for
/// [procSpaceFree]'s stated precondition.
@bare
void procOnFault(u64 vector, u64 errorCode, u64 rip, u64 frame) {
  final u64 cur = procCurrent();
  userFaultLine(vector, errorCode, rip, userFrame(frame, u64(userFrameCs)));
  procToKernel();
  procSetHead(u64(procHeadCurrent), u64(0));
  procSet(cur, u64(procSlotState), u64(procStateKilled));
  procSetHead(u64(procHeadLive), u64(0));
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (procGet(s, u64(procSlotState)) > u64(procStateFree)) {
      procCleanup(s);
    }
    s = s + u64(1);
  }
  // M18: the fault path abandons `shellProcRun`'s stack through `fault_resume`,
  // so the mask restore at the end of that function never runs for a session
  // that died. It runs here instead, before the diagnostic, so a faulting
  // session leaves the PIC exactly as tidy as one that finished.
  procSessionTimerOff();
  procSetHead(u64(procHeadResident), u64(0));
  procEndLine();
  // The process is dead and `user_return` will never run for it, so the resume
  // point `enter_user` recorded describes a stack frame `fault_resume` is about
  // to discard. Clearing the guard is what stops a later, unrelated `int 0x80`
  // from returning onto it. `userOnFault`'s note, for the same reason.
  Pointer<u64>.fromAddress(user_resume_ok_addr()).value = u64(0);
}

// ---------------------------------------------------------------------------
// Reports.
// ---------------------------------------------------------------------------

/// `PROC END SWITCHES <n> EXITS <n> CREATED <n> ERRORS <n>`
@bare
void procEndLine() {
  uartWrite(Rodata.addressOf(procStrEnd), u64(18));
  uartPutHex(procHead(u64(procHeadSwitches)), u64(8));
  uartWrite(Rodata.addressOf(procStrExits), u64(7));
  uartPutHex(procHead(u64(procHeadExits)), u64(8));
  uartWrite(Rodata.addressOf(procStrCreated), u64(9));
  uartPutHex(procHead(u64(procHeadCreated)), u64(8));
  uartWrite(Rodata.addressOf(procStrLiveW), u64(6));
  uartPutHex(procHead(u64(procHeadLive)), u64(8));
  uartNewline();
}

/// Puts the PIC mask back the way the shell keeps it: IRQ1 unmasked, IRQ0
/// masked. Called at EVERY exit from a session — the ordinary end, the fault
/// path, and the refusals that happen after the timer was already turned on.
///
/// **Idempotent on purpose.** It writes the same two bytes
/// `picUnmaskKeyboardOnly` writes, so calling it on a path where the timer was
/// never unmasked (a cooperative session, or a refusal before the unmask) costs
/// two port writes and cannot be wrong. A version that tracked whether it
/// needed to run would be a second piece of state to get out of step with the
/// first.
@bare
void procSessionTimerOff() {
  picUnmaskKeyboardOnly();
}

/// Unmasks IRQ0 and IRQ1 for a preemptive session. **The one call site of
/// `picUnmaskTimerAndKeyboard` in this file**, so `m18-preempt` can still
/// require exactly one. [shellProcRun] and [shellProcSpawn] both come through
/// here.
@bare
void procSessionTimerOn() {
  picUnmaskTimerAndKeyboard();
}

/// `PROC SCHED POLICY <n> QUANTUM <n> QUANTA <n> PREEMPTS <n> KTICKS <n> SLICE <n> BUDGET <n>`
/// followed by one `PROC SLOT <n> PREEMPTS <n> YIELDS <n> STATE <n>` line per
/// slot, all four of them, whatever state they are in.
///
/// **A NEW COMMAND RATHER THAN A NEW FIELD ON AN EXISTING LINE, and that is
/// GAP-0105's rule being obeyed rather than a preference.** `PROC END`, `PROC
/// SSE` and `PROC PD` appear inside byte-exact goldens owned by five other
/// harnesses; appending one word to any of them moves five files that have
/// nothing to do with scheduling. M18 adds output and moves no golden.
///
/// All four slots are printed unconditionally, including FREE ones, because the
/// interesting moment is AFTER a session — when [procCleanup] has emptied the
/// slots but not the counters — and a report that only printed live slots would
/// have nothing to say exactly then.
@bare
void procSchedLine() {
  uartWrite(Rodata.addressOf(procStrSched), u64(18));
  uartPutHex(procHead(u64(procHeadPolicy)), u64(2));
  uartWrite(Rodata.addressOf(procStrQuantum), u64(9));
  uartPutHex(u64(procQuantumTicks), u64(2));
  uartWrite(Rodata.addressOf(procStrQuanta), u64(8));
  uartPutHex(procHead(u64(procHeadQuanta)), u64(8));
  uartWrite(Rodata.addressOf(procStrPreempts), u64(10));
  uartPutHex(procHead(u64(procHeadPreempts)), u64(8));
  uartWrite(Rodata.addressOf(procStrKticks), u64(8));
  uartPutHex(procHead(u64(procHeadKernTicks)), u64(8));
  uartWrite(Rodata.addressOf(procStrSlice), u64(7));
  uartPutHex(procHead(u64(procHeadSlice)), u64(2));
  uartWrite(Rodata.addressOf(procStrBudgetW), u64(8));
  uartPutHex(procHead(u64(procHeadBudget)), u64(8));
  uartWrite(Rodata.addressOf(procStrHead), u64(6));
  uartPutHex(procHeadBase(), u64(16));
  uartNewline();
  u64 s = u64(0);
  while (s < u64(procMax)) {
    uartWrite(Rodata.addressOf(procStrSlot), u64(10));
    uartPutHex(s, u64(2));
    uartWrite(Rodata.addressOf(procStrPreempts), u64(10));
    uartPutHex(procGet(s, u64(procSlotPreempts)), u64(8));
    uartWrite(Rodata.addressOf(procStrYields), u64(8));
    uartPutHex(procGet(s, u64(procSlotYields)), u64(8));
    uartWrite(Rodata.addressOf(procStrState), u64(7));
    uartPutHex(procGet(s, u64(procSlotState)), u64(2));
    uartNewline();
    s = s + u64(1);
  }
}

/// `proc sched` — the whole scheduler report, and nothing else.
@bare
void shellProcSched() {
  procSchedLine();
}

/// `PROC SSE <n> CR4 <cr4> CR0 <cr0>`
///
/// **Two independent claims on one line, on purpose.** `SSE` is the word
/// `core/boot/boot.S` wrote after asking CPUID; `CR4` is what the control
/// register is holding right now. A kernel whose probe said yes and whose CR4
/// bits are clear is a kernel that thinks it has SSE and does not, and that
/// discrepancy is visible here rather than as a #UD in somebody's program.
/// `m11-proc/run.sh` asserts bit 9 and bit 10 of the printed CR4 against the
/// printed SSE flag.
@bare
void procSseLine() {
  uartWrite(Rodata.addressOf(procStrSse), u64(9));
  uartPutHex(procHead(u64(procHeadSse)), u64(1));
  uartWrite(Rodata.addressOf(procStrCr4), u64(5));
  uartPutHex(cr4_read(), u64(16));
  uartWrite(Rodata.addressOf(procStrCr0), u64(5));
  uartPutHex(cr0_read(), u64(16));
  uartNewline();
}

/// `PROC PD <live pd> KPD <kernel pd> CR3 <cr3> KPML4 <kernel pml4>`
///
/// The four numbers that say whether an address space is installed and whose.
/// With nothing running, `PD == KPD` and `CR3 == KPML4`; with a process on the
/// CPU, both pairs differ — and that is the difference `vmProgPd` introduced.
@bare
void procPdLine() {
  uartWrite(Rodata.addressOf(procStrPd), u64(8));
  uartPutHex(vmProgPd(), u64(16));
  uartWrite(Rodata.addressOf(procStrKpd), u64(5));
  uartPutHex(vmFrame(u64(vmIxPdLow)), u64(16));
  uartWrite(Rodata.addressOf(procStrCr3), u64(5));
  uartPutHex(cr3_read(), u64(16));
  uartWrite(Rodata.addressOf(procStrKpml4), u64(7));
  uartPutHex(vmMeta(u64(vmMetaPml4)), u64(16));
  uartNewline();
}

/// `PROC CAP <n> USED <n> LIVE <n> SWITCHES <n> CREATED <n>`
@bare
void procCapLine() {
  u64 used = u64(0);
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (procGet(s, u64(procSlotState)) > u64(procStateFree)) {
      used = used + u64(1);
    }
    s = s + u64(1);
  }
  uartWrite(Rodata.addressOf(procStrCap), u64(9));
  uartPutHex(u64(procMax), u64(8));
  uartWrite(Rodata.addressOf(procStrUsed), u64(6));
  uartPutHex(used, u64(8));
  uartWrite(Rodata.addressOf(procStrLiveW), u64(6));
  uartPutHex(procHead(u64(procHeadLive)), u64(8));
  uartWrite(Rodata.addressOf(procStrSwitches), u64(10));
  uartPutHex(procHead(u64(procHeadSwitches)), u64(8));
  uartWrite(Rodata.addressOf(procStrCreated), u64(9));
  uartPutHex(procHead(u64(procHeadCreated)), u64(8));
  uartNewline();
}

/// One line per slot. `PROC SLOT <n> STATE <n> ID <n> PML4 <a> PT <a> EXIT <n>`
@bare
void procSlotLines() {
  u64 s = u64(0);
  while (s < u64(procMax)) {
    uartWrite(Rodata.addressOf(procStrSlot), u64(10));
    uartPutHex(s, u64(2));
    uartWrite(Rodata.addressOf(procStrState), u64(7));
    uartPutHex(procGet(s, u64(procSlotState)), u64(2));
    uartWrite(Rodata.addressOf(procStrId), u64(4));
    uartPutHex(procGet(s, u64(procSlotId)), u64(8));
    uartWrite(Rodata.addressOf(procStrPml4), u64(6));
    uartPutHex(procGet(s, u64(procSlotPml4)), u64(16));
    uartWrite(Rodata.addressOf(procStrPt), u64(4));
    uartPutHex(procPtOf(s), u64(16));
    uartWrite(Rodata.addressOf(procStrExitF), u64(6));
    uartPutHex(procGet(s, u64(procSlotExit)), u64(16));
    uartNewline();
    s = s + u64(1);
  }
}

/// `proc` with no argument: the whole picture, nothing running.
@bare
void procReport() {
  procSseLine();
  procPdLine();
  procCapLine();
  procSlotLines();
}

/// `PROC REFUSED <code> <sentence>`
///
/// A refusal is printed and named, never silent, for `userRefuse`'s reason: a
/// subsystem reporting zero refusals is making a claim only if a refusal would
/// have been recorded.
@bare
void procRefuse(u64 code) {
  uartWrite(Rodata.addressOf(procStrRefused), u64(13));
  uartPutHex(code, u64(2));
  uartWrite(Rodata.addressOf(procStrGap), u64(1));
  if (code == u64(procErrNotReady)) {
    uartWrite(Rodata.addressOf(procStrE01), u64(38));
    return;
  }
  if (code == u64(procErrBusy)) {
    uartWrite(Rodata.addressOf(procStrE02), u64(37));
    return;
  }
  if (code == u64(procErrNoSlot)) {
    uartWrite(Rodata.addressOf(procStrE03), u64(26));
    return;
  }
  if (code == u64(procErrNoFrames)) {
    uartWrite(Rodata.addressOf(procStrE04), u64(28));
    return;
  }
  if (code == u64(procErrBadLba)) {
    uartWrite(Rodata.addressOf(procStrE05), u64(27));
    return;
  }
  if (code == u64(procErrLoad)) {
    uartWrite(Rodata.addressOf(procStrE06), u64(32));
    return;
  }
  if (code == u64(procErrNoSse)) {
    uartWrite(Rodata.addressOf(procStrE07), u64(58));
    return;
  }
  if (code == u64(procErrArgs)) {
    uartWrite(Rodata.addressOf(procStrE10), u64(46));
    return;
  }
  uartWrite(Rodata.addressOf(procStrE09), u64(43));
}

// ---------------------------------------------------------------------------
// The shell command.
//
// `proc` takes TWO arguments, which is one more than any command in this shell
// has taken before, and there is still no tokenizer (GAP-0057 item 3). So the
// two fields are found by scanning for the space between them, which is three
// small functions rather than a parser -- and the parser is still the thing
// that is missing.
// ---------------------------------------------------------------------------

/// Index of the first space at or after [from], or the line's length.
@bare
u64 procFieldEnd(u64 from) {
  final u64 len = shellLen();
  u64 i = from;
  while (i < len) {
    if (shellLineByte(i) == u8(0x20)) {
      return i;
    }
    i = i + u64(1);
  }
  return len;
}

/// The hex value in `[from, to)`, or [ataLba28Limit] if it is not one.
///
/// [ataLba28Limit] rather than a separate error flag, for `ataParseLba`'s
/// reason: every failure is a value the caller must reject anyway, so there is
/// one check at the call site instead of two.
@bare
u64 procHexField(u64 from, u64 to) {
  if (to < from + u64(1)) {
    return u64(ataLba28Limit);
  }
  if (to - from > u64(7)) {
    return u64(ataLba28Limit);
  }
  u64 v = u64(0);
  u64 i = from;
  while (i < to) {
    final u64 d = ataHexDigit(shellLineByte(i));
    if (d > u64(0xF)) {
      return u64(ataLba28Limit);
    }
    v = (v << u64(4)) | d;
    i = i + u64(1);
  }
  return v;
}

/// Empties every slot and puts the table back to its post-[procInit] state.
///
/// Called at the START of a session rather than at the end of one, deliberately:
/// after a session the slots still hold the exit codes and table addresses the
/// harness reads with `proc`, and clearing them there would throw away the
/// evidence that anything ran. Everything they still OWN is already freed —
/// [procCleanup] runs on the exit path and the fault path both — so this is a
/// reset of bookkeeping, and it calls [procSpaceFree] anyway, because a reset
/// that assumed the previous session was tidy would be the place a leak hides.
@bare
void procSessionReset() {
  u64 s = u64(0);
  while (s < u64(procMax)) {
    procSetHead(u64(procHeadErrors),
        procHead(u64(procHeadErrors)) + procSpaceFree(s));
    u64 w = u64(0);
    while (w < u64(procSlotWords)) {
      procSet(s, w, u64(0));
      w = w + u64(1);
    }
    procFxInit(s);
    s = s + u64(1);
  }
  procSetHead(u64(procHeadCurrent), u64(0));
  procSetHead(u64(procHeadLive), u64(0));
  procSetHead(u64(procHeadSwitches), u64(0));
  procSetHead(u64(procHeadExits), u64(0));
  // M18. The policy is NOT reset here: it is written by the command that starts
  // the session, immediately after this call, and a reset that clobbered it
  // would make `proc coop` and `proc run` differ only by the order two lines
  // happen to be in. The budget IS reset, because a budget is a property of one
  // session and a leftover one would silently end the next.
  procSetHead(u64(procHeadPreempts), u64(0));
  procSetHead(u64(procHeadQuanta), u64(0));
  procSetHead(u64(procHeadSlice), u64(0));
  procSetHead(u64(procHeadKernTicks), u64(0));
  procSetHead(u64(procHeadBudget), u64(0));
  procSetHead(u64(procHeadResident), u64(0));
}

/// Enters the first READY process. **Returns only through `user_return`**, i.e.
/// only when the LAST process has called `exit`; a process that faults never
/// comes back here at all, because the fault path abandons this stack (ADR-0007).
///
/// The first process is entered with `enter_user` rather than by loading its
/// synthesised frame, and that is not a duplication of [procSwitchTo]. It is the
/// only way in: `enter_user` is what RECORDS the resume point that
/// `user_return` eventually returns to, and without it the last `exit` would
/// have nowhere to go. Every subsequent first-run of a process goes through its
/// synthesised frame ([procInitFrame]), which is why both paths exist and why
/// both produce the same starting register state.
@bare
void procStart(u64 s) {
  procSet(s, u64(procSlotState), u64(procStateRunning));
  procSetHead(u64(procHeadCurrent), s + u64(1));
  // M18: the first process gets a full quantum, like every process after it.
  // [procSessionReset] has already zeroed this word; it is written again here
  // so that the invariant "a process begins its slice at zero" is stated at
  // BOTH places a process can begin one, and not left as a consequence of the
  // order two functions happen to be called in.
  procSetHead(u64(procHeadSlice), u64(0));
  uartWrite(Rodata.addressOf(procStrStart), u64(16));
  uartPutHex(s, u64(2));
  uartWrite(Rodata.addressOf(procStrEntry), u64(7));
  uartPutHex(procGet(s, u64(procSlotEntry)), u64(16));
  uartWrite(Rodata.addressOf(procStrRspF), u64(5));
  uartPutHex(procGet(s, u64(procSlotRsp)), u64(16));
  uartNewline();
  procPdLine();
  paging_install(procGet(s, u64(procSlotPml4)));
  if (procHead(u64(procHeadSse)) > u64(0)) {
    fx_restore(procFxArea(s));
  }
  // ADR-0148: plant FS.base before the first ring-3 instruction.
  procInstallFs(s);
  enter_user(procGet(s, u64(procSlotEntry)), procGet(s, u64(procSlotRsp)),
      procGet(s, u64(procSlotProbe)), u64(userCodeSel), u64(userDataSel));
}

/// `proc run <lbaA> <lbaB>` and `proc cross <lbaA> <lbaB>`.
///
/// [cross] is 0 for the ordinary run and 1 for the ISOLATION NEGATIVE CONTROL:
/// process B is handed, in RDI, a virtual address that process A has mapped and
/// B has not — computed by [procCrossVa] from the two page tables this kernel
/// built — and dereferences it. It must take a `#PF`. The address is printed
/// before either process runs, so the harness can check it against its own read
/// of both page tables out of guest physical memory.
///
/// Everything is refused before anything is allocated, and each refusal has a
/// sentence.
/// M18 added [policy] and [budget]:
///
///   * [policy] is [procPolicyPreempt] for `proc run`, `proc cross` and
///     `proc spin`, and [procPolicyCoop] for `proc coop`.
///   * [budget] is the number of quantum expiries the session may take before
///     the scheduler tears it down, or 0 for no limit. Only `proc spin` passes
///     a non-zero one.
///
/// **NEITHER IS PRINTED ON THE SESSION LINE, and that is GAP-0105 again.** The
/// `PROC RUN` line is inside `m11-proc`'s byte-exact 4096-byte golden; a policy
/// field there would move a golden that has nothing to do with M18. `proc
/// sched` says both, and `m18-preempt/run.sh` reads them from there.
@bare
void shellProcRun(u64 lbaA, u64 lbaB, u64 cross, u64 policy, u64 budget) {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    procRefuse(u64(procErrNotReady));
    return;
  }
  if (procHead(u64(procHeadReady)) < u64(1)) {
    procRefuse(u64(procErrNotReady));
    return;
  }
  // NO FXSAVE, NO PROCESSES, AND THAT IS A REFUSAL RATHER THAN A DEGRADED MODE.
  //
  // [procErrNoSse] had a sentence and no `return` reaching it until this line
  // was written; the milestone's own harness found it dead. It is wired rather
  // than deleted because the sentence is the right answer: GAP-0092's argument
  // is that enabling SSE without somewhere to save it is worse than leaving it
  // off, and "two processes that share sixteen XMM registers" is the same
  // sentence read from the other end. On a CPU where `sse_enabled()` is 0 this
  // kernel has no save area it can legally `fxsave` into, so it declines to
  // create a process at all instead of creating one whose FPU state is a thing
  // nobody owns.
  //
  // `m11-proc/run.sh` boots `-cpu qemu64,-sse,-fxsr` and requires exactly this
  // refusal, which is also what proves the CPUID probe in `core/boot/boot.S` is
  // load-bearing: on that machine CR4 bits 9 and 10 are RESERVED, and a kernel
  // that set them unconditionally would #GP before any IDT existed.
  if (procHead(u64(procHeadSse)) < u64(1)) {
    procRefuse(u64(procErrNoSse));
    return;
  }
  // TWO RE-ENTRANCY GUARDS THAT NOTHING IN THIS KERNEL CAN REACH, KEPT ANYWAY.
  //
  // `shellMain` is the only caller of this function and it is not re-entrant:
  // `proc run` does not return the prompt until the session has ended and
  // `procSessionReset` has run, and a program that never exits never returns
  // the prompt either (GAP-0085). So `procLive()` and `userMetaLive` are both 0
  // at every moment control can arrive here.
  //
  // They are NOT deleted, and that is a decision rather than an oversight
  // (ADR-0039 §4). Deleting a re-entrancy guard because today's only caller
  // happens to be synchronous trades a real property for a test result; any
  // asynchronous launch reaches both at once. This is a different case from the
  // `elfLive()` guard that used to stand between them, which branched on a flag
  // NO CODE WRITES and so could not fire under any caller — that one is gone.
  //
  // docs/known-gaps.md GAP-0243 records them as live guards with no reaching
  // test, in the words GAP-0214 uses for `chanRetNoProc`.
  if (procLive() > u64(0)) {
    procRefuse(u64(procErrBusy));
    return;
  }
  if (userMeta(u64(userMetaLive)) > u64(0)) {
    procRefuse(u64(procErrBusy));
    return;
  }
  // D3: a spawn session owns the table until its last process exits. Starting
  // a classic two-program session on top of it would wipe those slots.
  if (procHead(u64(procHeadResident)) > u64(0)) {
    procRefuse(u64(procErrBusy));
    return;
  }
  // AND TWO THE SHELL ANSWERS FIRST, ON PURPOSE. `shellProcArgs` caps both
  // fields at `ataLba28Max` and prints its usage line, which is correct: the
  // shell should refuse a line it knows is malformed rather than build a
  // process to find out. These are the second line of defence for a caller that
  // is not the shell — and there is not one yet. GAP-0245.
  if (lbaA > u64(ataLba28Max)) {
    procRefuse(u64(procErrBadLba));
    return;
  }
  if (lbaB > u64(ataLba28Max)) {
    procRefuse(u64(procErrBadLba));
    return;
  }
  if (lbaA == lbaB) {
    procRefuse(u64(procErrSameLba));
    return;
  }

  procSessionReset();
  // M20: `proc run` names its programs by LBA and gives them no arguments, so
  // the staged vector is EMPTIED rather than inherited. Without this line the
  // arguments of whatever `run <name> ...` the user typed earlier in the
  // session would be built onto both of these processes' stacks -- an argv
  // belonging to a different program, which is worse than none.
  //
  // The processes still get a COMPLETE System V initial stack: `argc` = 0, the
  // `argv` NULL, the `envp` NULL and the AT_NULL pair. An empty argv is not the
  // same thing as no stack, and it is the first that a program is entitled to.
  argsReset();
  procSetHead(u64(procHeadPolicy), policy);
  procSetHead(u64(procHeadBudget), budget);
  // ---------------------------------------------------------------------
  // M18: THE TIMER IS UNMASKED FOR THE DURATION OF A PREEMPTIVE SESSION, AND
  // ONLY FOR THAT.
  //
  // The PIT has been MASKED at the PIC since M2. That was deliberate and it is
  // written down twice: `picUnmaskKeyboardOnly`'s own comment ("100 interrupts
  // a second would only add jitter between keystrokes"), and GAP-0058 -- with
  // IRQ0 masked at rest the tick counter HOLDS STILL, which is the only reason
  // `ticks` can print a number `m3-shell/run.sh`'s byte-exact golden asserts.
  //
  // A preemptive scheduler needs the tick. Turning it on for the whole boot
  // would move m3's golden and would make every later `ticks` reading depend on
  // how long the machine had been sitting at a prompt. So it is turned on HERE,
  // when a session that can use it begins, and off again at every exit from
  // that session ([procSessionTimerOff]): the shell's steady state is exactly
  // what it was before M18 existed.
  //
  // A COOPERATIVE session does not turn it on at all -- `proc coop` has nothing
  // to do with a tick, and `m11-proc`'s hold boot must be able to park a
  // process at its entry point with nothing at all interrupting it.
  // ---------------------------------------------------------------------
  if (policy > u64(procPolicyCoop)) {
    procSessionTimerOn();
  }

  uartWrite(Rodata.addressOf(procStrRun), u64(13));
  uartPutHex(lbaA, u64(8));
  uartWrite(Rodata.addressOf(procStrGap), u64(1));
  uartPutHex(lbaB, u64(8));
  uartWrite(Rodata.addressOf(procStrGap), u64(1));
  uartPutHex(cross, u64(1));
  uartNewline();
  procSseLine();

  final u64 sa = procCreate(lbaA, u64(0));
  if (sa > u64(0)) {
    procRefuse(sa);
    procSessionTimerOff();
    procEndLine();
    return;
  }
  final u64 sb = procCreate(lbaB, u64(0));
  if (sb > u64(0)) {
    procRefuse(sb);
    procSessionReset();
    procSessionTimerOff();
    procEndLine();
    return;
  }

  if (cross > u64(0)) {
    final u64 va = procCrossVa(u64(0), u64(1));
    uartWrite(Rodata.addressOf(procStrProbe), u64(14));
    uartPutHex(va, u64(16));
    uartNewline();
    if (va < u64(1)) {
      procRefuse(u64(procErrLoad));
      procSessionReset();
      procSessionTimerOff();
      procEndLine();
      return;
    }
    procSet(u64(1), u64(procSlotProbe), va);
    procInitFrame(u64(1));
  }

  procStart(u64(0)); // returns only through `user_return`

  procToKernel();
  procSessionTimerOff();
  procEndLine();
  procPdLine();
}

/// `proc` with an argument this shell cannot parse.
@bare
void shellProcUsage() {
  uartWrite(Rodata.addressOf(procStrUsage), u64(64));
  // M18's three commands, on a SECOND table rather than appended to the first.
  // `procStrUsage`'s size is asserted at 64 by `m11-proc/run.sh`; growing it
  // would move that assertion for no reason but formatting, and the check is
  // worth more than the single line.
  uartWrite(Rodata.addressOf(procStrUsage2), u64(79));
}

/// `proc run ...` / `proc cross ...` from the shell: find the two fields, parse
/// them, then run.
@bare
void shellProcArgs(u64 from, u64 cross, u64 policy) {
  final u64 e1 = procFieldEnd(from);
  final u64 a = procHexField(from, e1);
  if (a > u64(ataLba28Max)) {
    shellProcUsage();
    return;
  }
  final u64 e2 = procFieldEnd(e1 + u64(1));
  final u64 b = procHexField(e1 + u64(1), e2);
  if (b > u64(ataLba28Max)) {
    shellProcUsage();
    return;
  }
  shellProcRun(a, b, cross, policy, u64(0));
}

/// `proc spin <lbaA> <lbaB> <quanta>` — M18.
///
/// The only command in this shell that takes THREE arguments, and the third is
/// the reason the command exists: the two programs it is for do not yield and
/// one of them does not exit, so without a stated budget the session would run
/// until the machine was switched off. **`<quanta>` is a count of quantum
/// expiries, not milliseconds and not ticks**, which is what makes a boot of it
/// reproducible: `proc spin A B 0C` performs exactly twelve of them and then
/// tears the session down, on a fast host and a slow one alike.
///
/// A budget of zero is refused rather than treated as "no limit". `proc run`
/// already means "no limit"; a `proc spin` with no budget would be a command
/// whose entire purpose is defeated by a typo.
@bare
void shellProcSpinArgs(u64 from) {
  final u64 e1 = procFieldEnd(from);
  final u64 a = procHexField(from, e1);
  if (a > u64(ataLba28Max)) {
    shellProcUsage();
    return;
  }
  final u64 e2 = procFieldEnd(e1 + u64(1));
  final u64 b = procHexField(e1 + u64(1), e2);
  if (b > u64(ataLba28Max)) {
    shellProcUsage();
    return;
  }
  final u64 e3 = procFieldEnd(e2 + u64(1));
  final u64 q = procHexField(e2 + u64(1), e3);
  if (q > u64(ataLba28Max)) {
    shellProcUsage();
    return;
  }
  if (q < u64(1)) {
    shellProcUsage();
    return;
  }
  shellProcRun(a, b, u64(0), u64(procPolicyPreempt), q);
}

/// Lowest READY slot, or [procMax] if there is none.
@bare
u64 procPickReady() {
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (procGet(s, u64(procSlotState)) == u64(procStateReady)) {
      return s;
    }
    s = s + u64(1);
  }
  return u64(procMax);
}

/// 1 if the idle loop should hand the CPU to a resident process.
@bare
u64 procShouldResume() {
  if (procHead(u64(procHeadResident)) < u64(1)) {
    return u64(0);
  }
  if (procPickReady() == u64(procMax)) {
    return u64(0);
  }
  return u64(1);
}

/// The idle-loop body for D3. Kept in this file so `shellMain` does not
/// inline the slot walk: DCDart's overflow flags live in callee-saved
/// registers, and a walk inlined next to the prompt printer #UD's (0F0B)
/// the moment those registers are clobbered.
@bare
void procIdle() {
  if (procShouldResume() > u64(0)) {
    procResume();
    return;
  }
  idle_once();
}

/// Enters a READY resident process from the shell idle loop. **Returns only
/// through `user_return`**, after a quantum (lone-process D3 path) or after
/// the last process exits.
///
/// Uses [resume_user] rather than [enter_user]: the slot already has a
/// synthesised or saved 22-word frame, and `enter_user` would discard it and
/// restart at the entry point.
@bare
void procResume() {
  final u64 s = procPickReady();
  if (s == u64(procMax)) {
    return;
  }
  procSet(s, u64(procSlotState), u64(procStateRunning));
  procSetHead(u64(procHeadCurrent), s + u64(1));
  procSetHead(u64(procHeadSlice), u64(0));
  paging_install(procGet(s, u64(procSlotPml4)));
  if (procHead(u64(procHeadSse)) > u64(0)) {
    fx_restore(procFxArea(s));
  }
  // ADR-0148: FS.base before enter/resume (same as [procSwitchTo]).
  procInstallFs(s);
  // First time on a slot: `enter_user` is the proven door. Later times the
  // saved frame is a real interrupt snapshot and `resume_user` loads it.
  if (procGet(s, u64(procSlotEntered)) < u64(1)) {
    procSet(s, u64(procSlotEntered), u64(1));
    enter_user(procGet(s, u64(procSlotEntry)), procGet(s, u64(procSlotRsp)),
        procGet(s, u64(procSlotProbe)), u64(userCodeSel), u64(userDataSel));
    return;
  }
  resume_user(procSlotBase(s) + u64(256), u64(userDataSel));
}

/// Guards shared by the LBA and 8.3 forms of `proc spawn`. 1 if a
/// refusal was already printed.
@bare
u64 shellProcSpawnReady() {
  if (vmMeta(u64(vmMetaReady)) < u64(1)) {
    procRefuse(u64(procErrNotReady));
    return u64(1);
  }
  if (procHead(u64(procHeadReady)) < u64(1)) {
    procRefuse(u64(procErrNotReady));
    return u64(1);
  }
  if (procHead(u64(procHeadSse)) < u64(1)) {
    procRefuse(u64(procErrNoSse));
    return u64(1);
  }
  if (procLive() > u64(0)) {
    procRefuse(u64(procErrBusy));
    return u64(1);
  }
  if (userMeta(u64(userMetaLive)) > u64(0)) {
    procRefuse(u64(procErrBusy));
    return u64(1);
  }
  return u64(0);
}

/// Session start + [procCreate] + `PROC SPAWN` line. [named] is the
/// same flag [procCreate] already takes for `run <name>`: the FAT chain
/// is open and the loader reads through it. One [procSessionTimerOff]
/// site on the fail path, so m18's count does not move.
@bare
void shellProcSpawnCreate(u64 lba, u64 named) {
  if (procHead(u64(procHeadResident)) < u64(1)) {
    procSessionReset();
    argsReset();
    procSetHead(u64(procHeadPolicy), u64(procPolicyPreempt));
    procSetHead(u64(procHeadBudget), u64(0));
    procSetHead(u64(procHeadResident), u64(1));
    procSessionTimerOn();
  }
  final u64 st = procCreate(lba, named);
  if (st > u64(0)) {
    procRefuse(st);
    if (procHead(u64(procHeadLive)) < u64(1)) {
      procSetHead(u64(procHeadResident), u64(0));
      procSessionTimerOff();
    }
    return;
  }
  uartWrite(Rodata.addressOf(procStrSpawn), u64(11));
  if (named > u64(0)) {
    uartPutHex(elfMeta(u64(elfMetaImageLba)), u64(8));
  } else {
    uartPutHex(lba, u64(8));
  }
  uartNewline();
}

/// `proc spawn <lba>` — create one process and return to the prompt.
///
/// The first spawn of a session resets the table, marks it resident, and
/// unmasks the timer. Later spawns add a slot. The idle loop in [shellMain]
/// is what actually runs them.
@bare
void shellProcSpawn(u64 lba) {
  if (shellProcSpawnReady() > u64(0)) {
    return;
  }
  if (lba > u64(ataLba28Max)) {
    procRefuse(u64(procErrBadLba));
    return;
  }
  shellProcSpawnCreate(lba, u64(0));
}

/// `proc spawn <name>` — the same residency as the LBA form, image from
/// an 8.3 FAT file. Not in `help` (GAP-0304). `elfLoadFile` prints
/// `ELF FILE <name>`; this function does not grow a help line.
@bare
void shellProcSpawnName(u64 from, u64 end) {
  if (shellProcSpawnReady() > u64(0)) {
    return;
  }
  final u64 fs = fatOpenAt(from, end);
  if (fs > u64(fatErrOk)) {
    fatReportError(fs);
    return;
  }
  fatOpenLine();
  fatChainReport();
  shellProcSpawnCreate(u64(0), u64(1));
}

/// Hidden `go <name>` from the idle line. Prints `GO` then the same
/// named residency as the longer spawn form. Not in `help`. ADR-0099.
@bare
void shellGoArgs(u64 from) {
  uartWrite(Rodata.addressOf(procStrGo), u64(3));
  shellProcSpawnArgs(from);
}

/// `proc spawn ...` from the shell: one hex LBA, or an 8.3 name.
///
/// Told apart the way `run` is: [procHexField] returns above
/// [ataLba28Max] for anything that is not one to seven hex digits, so
/// `proc spawn 20` is still sector 0x20 and `proc spawn APP1.ELF` is a
/// name. Empty second word is still usage. Not in `help`.
@bare
void shellProcSpawnArgs(u64 from) {
  final u64 e1 = procFieldEnd(from);
  if (e1 < (from + u64(1))) {
    shellProcUsage();
    return;
  }
  final u64 a = procHexField(from, e1);
  if (a > u64(ataLba28Max)) {
    shellProcSpawnName(from, e1);
    return;
  }
  shellProcSpawn(a);
}

/// Syscall 26. `rdi` is a pointer to an 8.3 name, `rsi` is its length.
/// Returns the new slot (0..3) or a [spawnRet*] refusal.
///
/// **The caller stays on the CPU.** [procCreate] installs the child's
/// CR3 to load, then [procToKernel]. This function puts the CALLER's
/// PML4 back before the syscall returns, or the `iretq` would land in
/// an address space that does not map the studio.
///
/// No new `.bss`. The name is bounced through [fileBufBase], the same
/// buffer `open` already uses. GAP-0096 item 7 is the process-from-
/// process hole this call closes for a name; it is not APP7's full
/// `spawn(name, argv)` (no argv pointer).
@bare
void procSysSpawn(u64 frame) {
  if (procLive() < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetNoProc));
    return;
  }
  final u64 ptr = userFrame(frame, u64(userFrameRdi));
  final u64 len = userFrame(frame, u64(userFrameRsi));
  if (len < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetBadLen));
    return;
  }
  if (len > u64(fileNameMax)) {
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetBadLen));
    return;
  }
  if (elfOwns(ptr, len) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetBadPtr));
    return;
  }
  final u64 buf = fileBufBase();
  u64 i = u64(0);
  while (i < len) {
    Pointer<u8>.fromAddress(buf + i).value =
        Pointer<u8>.fromAddress(ptr + i).value;
    i = i + u64(1);
  }
  final u64 pn = fatParseAt(buf, len);
  if (pn > u64(fatErrOk)) {
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetBadName));
    return;
  }
  final u64 exist = wmFocusExistingStem();
  if (exist < u64(procMax)) {
    userSetFrame(frame, u64(userFrameRax), exist);
    return;
  }
  final u64 fs = fatLookup();
  if (fs > u64(fatErrOk)) {
    fatReportError(fs);
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetNotFound));
    return;
  }
  fatOpenLine();
  fatChainReport();
  final u64 slot = procFreeSlot();
  if (slot == u64(procMax)) {
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetNoSlot));
    return;
  }
  final u64 caller = procCurrent();
  final u64 callerPml4 = procGet(caller, u64(procSlotPml4));
  if (procHead(u64(procHeadResident)) < u64(1)) {
    procSetHead(u64(procHeadResident), u64(1));
    procSessionTimerOn();
  }
  final u64 st = procCreate(u64(0), u64(1));
  paging_install(callerPml4);
  if (st > u64(0)) {
    if (st == u64(procErrNoSlot)) {
      userSetFrame(frame, u64(userFrameRax), u64(spawnRetNoSlot));
      return;
    }
    userSetFrame(frame, u64(userFrameRax), u64(spawnRetLoad));
    return;
  }
  uartWrite(Rodata.addressOf(procStrSpawn), u64(11));
  uartPutHex(slot, u64(8));
  uartNewline();
  userSetFrame(frame, u64(userFrameRax), slot);
}

/// `PROC CLONE <s> FN <fn> SP <stack> PML4 <pa>`, or
/// `PROC CLONE <s> ERR <ret>` on a refusal. ADR-0130.
@bare
void procCloneLine(u64 s, u64 fn, u64 stack, u64 r) {
  uartWrite(Rodata.addressOf(procStrClone), u64(11));
  uartPutHex(s, u64(2));
  if (r > u64(cloneRetFloor)) {
    uartWrite(Rodata.addressOf(vmStrErr), u64(5));
    uartPutHex(r, u64(16));
    uartNewline();
    return;
  }
  uartWrite(Rodata.addressOf(procStrFn), u64(4));
  uartPutHex(fn, u64(16));
  uartWrite(Rodata.addressOf(procStrSp), u64(4));
  uartPutHex(stack, u64(16));
  uartWrite(Rodata.addressOf(procStrPml4), u64(6));
  uartPutHex(procGet(s, u64(procSlotPml4)), u64(16));
  uartNewline();
}

/// Syscall 28. `rdi` is the child entry, `rsi` is the child stack
/// top. Returns the child slot (0..3) or a [cloneRet*] refusal.
///
/// **The child walks the caller's page tables.** That is the door:
/// a later Content thread starts at a function that already lives
/// in this address space. A new `procCreate` would be `spawn`, and
/// a fake tid without a READY slot cannot print `CHILD`. ASK.ELF
/// of the same bytes is [cloneRetBadArg]. Not futex. Not TLS.
/// Not `dlopen`. 11 stays `fdwait`.
@bare
void procSysClone(u64 frame) {
  if (procLive() < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(cloneRetBadArg));
    return;
  }
  final u64 caller = procCurrent();
  final u64 fn = userFrame(frame, u64(userFrameRdi));
  final u64 stack = userFrame(frame, u64(userFrameRsi));
  if (heapIsPlat(caller) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(cloneRetBadArg));
    procCloneLine(caller, fn, stack, u64(cloneRetBadArg));
    return;
  }
  if (elfEntryMapped(fn) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(cloneRetBadPtr));
    procCloneLine(caller, fn, stack, u64(cloneRetBadPtr));
    return;
  }
  if (stack < u64(16)) {
    userSetFrame(frame, u64(userFrameRax), u64(cloneRetBadPtr));
    procCloneLine(caller, fn, stack, u64(cloneRetBadPtr));
    return;
  }
  if (elfOwns(stack - u64(16), u64(16)) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(cloneRetBadPtr));
    procCloneLine(caller, fn, stack, u64(cloneRetBadPtr));
    return;
  }
  final u64 child = procFreeSlot();
  if (child == u64(procMax)) {
    userSetFrame(frame, u64(userFrameRax), u64(cloneRetNoSlot));
    procCloneLine(caller, fn, stack, u64(cloneRetNoSlot));
    return;
  }
  procSet(child, u64(procSlotPml4), procGet(caller, u64(procSlotPml4)));
  procSet(child, u64(procSlotPdpt), procGet(caller, u64(procSlotPdpt)));
  procSet(child, u64(procSlotPd), procGet(caller, u64(procSlotPd)));
  procSet(child, u64(procSlotPt), procGet(caller, u64(procSlotPt)));
  procSet(child, u64(procSlotPlat), procGet(caller, u64(procSlotPlat)));
  procSet(child, u64(procSlotEntry), fn);
  procSet(child, u64(procSlotRsp), stack);
  procSet(child, u64(procSlotStackFrame),
      procGet(caller, u64(procSlotStackFrame)));
  procSet(child, u64(procSlotPages), u64(0));
  procSet(child, u64(procSlotLo), procGet(caller, u64(procSlotLo)));
  procSet(child, u64(procSlotHi), procGet(caller, u64(procSlotHi)));
  procSet(child, u64(procSlotLba), procGet(caller, u64(procSlotLba)));
  procSet(child, u64(procSlotSegments),
      procGet(caller, u64(procSlotSegments)));
  procSet(child, u64(procSlotProbe), u64(0));
  procSet(child, u64(procSlotExit), u64(0));
  procSet(child, u64(procSlotPreempts), u64(0));
  procSet(child, u64(procSlotYields), u64(0));
  procSet(child, u64(procSlotEntered), u64(0));
  procSet(child, u64(procSlotShmPt), u64(0));
  procSet(child, u64(procSlotWaitAddr), u64(0));
  // ADR-0148: a clone starts with no TLS. The parent keeps its FS.base;
  // the child must call setfs itself (Linux would pass a new TLS via
  // clone flags — we do not).
  procSet(child, u64(procSlotFsBase), u64(0));
  procSet(child, u64(procSlotCefMemset), u64(0));
  procBumpHead(u64(procHeadCreated));
  procSet(child, u64(procSlotId), procHead(u64(procHeadCreated)));
  procFxInit(child);
  procInitFrame(child);
  procSet(child, u64(procSlotState), u64(procStateReady));
  procBumpHead(u64(procHeadLive));
  procCloneLine(child, fn, stack, child);
  userSetFrame(frame, u64(userFrameRax), child);
}

/// `PROC FUTEX WAIT|WAKE|ERR …`. ADR-0146.
@bare
void procFutexLine(u64 s, u64 op, u64 addr, u64 val, u64 r) {
  uartWrite(Rodata.addressOf(procStrFutex), u64(11));
  uartPutHex(s, u64(2));
  if (r > u64(futexRetFloor)) {
    uartWrite(Rodata.addressOf(vmStrErr), u64(5));
    uartPutHex(r, u64(16));
    uartNewline();
    return;
  }
  if (op == u64(futexOpWait)) {
    uartWrite(Rodata.addressOf(procStrWait), u64(6));
  } else {
    uartWrite(Rodata.addressOf(procStrWake), u64(6));
  }
  uartWrite(Rodata.addressOf(procStrAddr), u64(6));
  uartPutHex(addr, u64(16));
  uartWrite(Rodata.addressOf(procStrVal), u64(5));
  uartPutHex(val, u64(16));
  uartNewline();
}

/// Wake up to [n] BLOCKED slots waiting on virtual address [addr].
/// Returns how many it made READY. The table is the queue.
@bare
u64 procFutexWake(u64 addr, u64 n) {
  u64 woken = u64(0);
  u64 s = u64(0);
  while (s < u64(procMax)) {
    if (woken == n) {
      return woken;
    }
    if (procGet(s, u64(procSlotState)) == u64(procStateBlocked)) {
      if (procGet(s, u64(procSlotWaitAddr)) == addr) {
        procSet(s, u64(procSlotWaitAddr), u64(0));
        procSet(s, u64(procSlotState), u64(procStateReady));
        woken = woken + u64(1);
      }
    }
    s = s + u64(1);
  }
  return woken;
}

/// Syscall 30. `rdi` is the op, `rsi` is the word address, `rdx`
/// is the expected value (WAIT) or the wake count (WAKE).
///
/// **WAIT blocks only when `*addr == val` and another slot is
/// READY.** A fake tid that never blocks cannot hand the child
/// the CPU, so the parent's derived SYNC line stays the zero
/// mix. ASK.ELF of the same bytes is [futexRetBadArg]. Not
/// TLS. Not glibc. Not OnPaint. 11 stays `fdwait`.
@bare
void procSysFutex(u64 frame) {
  if (procLive() < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(futexRetBadArg));
    return;
  }
  final u64 caller = procCurrent();
  final u64 op = userFrame(frame, u64(userFrameRdi));
  final u64 addr = userFrame(frame, u64(userFrameRsi));
  final u64 val = userFrame(frame, u64(userFrameRdx));
  if (heapIsPlat(caller) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(futexRetBadArg));
    procFutexLine(caller, op, addr, val, u64(futexRetBadArg));
    return;
  }
  if (op > u64(futexOpWake)) {
    userSetFrame(frame, u64(userFrameRax), u64(futexRetBadOp));
    procFutexLine(caller, op, addr, val, u64(futexRetBadOp));
    return;
  }
  if ((addr & u64(7)) > u64(0)) {
    userSetFrame(frame, u64(userFrameRax), u64(futexRetBadPtr));
    procFutexLine(caller, op, addr, val, u64(futexRetBadPtr));
    return;
  }
  if (elfOwns(addr, u64(8)) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(futexRetBadPtr));
    procFutexLine(caller, op, addr, val, u64(futexRetBadPtr));
    return;
  }
  if (op == u64(futexOpWake)) {
    final u64 n = val;
    final u64 woken = procFutexWake(addr, n);
    procFutexLine(caller, op, addr, woken, woken);
    userSetFrame(frame, u64(userFrameRax), woken);
    return;
  }
  // WAIT.
  final u64 seen = Pointer<u64>.fromAddress(addr).value;
  if (seen != val) {
    userSetFrame(frame, u64(userFrameRax), u64(0));
    return;
  }
  final u64 next = procPickNext(caller);
  if (next == u64(procMax)) {
    userSetFrame(frame, u64(userFrameRax), u64(futexRetAlone));
    procFutexLine(caller, op, addr, val, u64(futexRetAlone));
    return;
  }
  procSaveFrame(caller, frame);
  procSet(caller, u64(procSlotSaved) + u64(procFrameRaxWord), u64(0));
  if (procHead(u64(procHeadSse)) > u64(0)) {
    fx_save(procFxArea(caller));
  }
  procSet(caller, u64(procSlotWaitAddr), addr);
  procSet(caller, u64(procSlotState), u64(procStateBlocked));
  procFutexLine(caller, op, addr, val, u64(0));
  procSwitchTo(next, frame);
}

/// Write `IA32_FS_BASE` from [procSlotFsBase]. Called on every
/// path that returns a slot to ring 3. ADR-0148.
@bare
void procInstallFs(u64 s) {
  msr_write(u64(procFsBaseMsr), procGet(s, u64(procSlotFsBase)));
}

/// `PROC SETFS …`. ADR-0148.
@bare
void procSetfsLine(u64 s, u64 base, u64 r) {
  uartWrite(Rodata.addressOf(procStrSetfs), u64(11));
  uartPutHex(s, u64(2));
  if (r > u64(setfsRetFloor)) {
    uartWrite(Rodata.addressOf(vmStrErr), u64(5));
    uartPutHex(r, u64(16));
    uartNewline();
    return;
  }
  uartWrite(Rodata.addressOf(procStrAddr), u64(6));
  uartPutHex(base, u64(16));
  uartNewline();
}

/// Syscall 33. `rdi` is the TLS block address.
///
/// **Plants [procSlotFsBase] and writes the MSR now.** A fake
/// success that leaves FS.base at 0 makes the next `%fs:0`
/// store fault at VA 0, so the derived TLS line never prints.
/// ASK.ELF of the same bytes is [setfsRetBadArg]. Not glibc.
/// Not OnPaint. 11 stays `fdwait`.
@bare
void procSysSetfs(u64 frame) {
  if (procLive() < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(setfsRetBadArg));
    return;
  }
  final u64 caller = procCurrent();
  final u64 base = userFrame(frame, u64(userFrameRdi));
  if (heapIsPlat(caller) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(setfsRetBadArg));
    procSetfsLine(caller, base, u64(setfsRetBadArg));
    return;
  }
  if ((base & u64(7)) > u64(0)) {
    userSetFrame(frame, u64(userFrameRax), u64(setfsRetBadPtr));
    procSetfsLine(caller, base, u64(setfsRetBadPtr));
    return;
  }
  if (elfOwns(base, u64(8)) < u64(1)) {
    userSetFrame(frame, u64(userFrameRax), u64(setfsRetBadPtr));
    procSetfsLine(caller, base, u64(setfsRetBadPtr));
    return;
  }
  procSet(caller, u64(procSlotFsBase), base);
  procInstallFs(caller);
  procSetfsLine(caller, base, u64(0));
  userSetFrame(frame, u64(userFrameRax), u64(0));
}
