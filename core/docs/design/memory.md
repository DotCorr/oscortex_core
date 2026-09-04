# oscortex memory — the window, sharing, a kernel allocator, and the memory type nobody set

**Status: DESIGN. Not an ADR, not numbered, nothing implemented.** Same standing as
`display-protocol.md`: this exists so the agent who builds the first piece does not have to re-decide
anything, and so the five questions below stop being re-measured once per milestone. When a piece is
built it gets its own numbered ADR; this file is what those ADRs point back at.

**Everything here is a proposal except the measurements**, which are read out of the source and the
harnesses and are cited by file and line. Where I am unsure I say so.

### The four findings that matter most, for a reader in a hurry

| | finding | where |
|---|---|---|
| **The spare page-directory entries were undercounted by 7×** | `vm.dart`'s "62 unused PD entries" is the count of the entries that ARE used (indices 2..63). `[128 MiB, 1 GiB)` is **448 entries, 447 of them free**. A 64 MiB ring-3 window is 32 of them. | §1.1 |
| **The double-free check already catches half of the shared-frame hazard**, and that changes the fix | `freeFrame` refuses a second free with `pmmFreeDouble`. What is missing is not detection of the second free, it is **preventing the first** from releasing a frame somebody still maps. | §2.1 |
| **A shared BIT-PLANE beats a scanned table** | 4096 bytes — the same size and the same idiom as the frame bitmap — makes the `freeFrame` test O(1) instead of a linear scan on all 32768 calls of `frames refill`. It is the same one branch, and it costs the same bytes. | §2.4 |
| **The `.bss` ceiling is 4 MiB and `vmInit` already enforces it** | `vm.dart:1257` refuses to install the address space if `kernel_image_end() > vmFineBytes`. **That is the hard wall the "storage seam" pattern hits** — measured headroom today is **2.72 MB**, and one 800×600 window backing store is 1.92 MB of it. | §3.1 |

---

## 0. What this has to be true of

The same four constraints `display-protocol.md` §0 lists, plus three that are specific to memory:

1. **`@bare` DCDart has no array type, no generics, no `bool`, no `&&`/`||`, no signed integer, no
   struct in any signature, and one return value.** Every allocator interface below is
   `f(u64, u64) -> u64`, every refusal is a distinguished return value, and every guard is a chain of
   single-test `if`s. This is not a style preference, it is the language (GAP-0023; DCDart ADR-0011,
   GAP-0025).
2. **Every `Pointer<T>` load and store is emitted as LLVM `volatile`** (DCDart ADR-0041, GAP-0052).
   Data-structure traversals cost real memory traffic that the optimiser is forbidden to remove, so
   *the number of header words a design reads per operation is a real cost*, not a micro-optimisation.
3. **Arithmetic traps on overflow with a real `ud2`.** Every bound is checked BEFORE the arithmetic
   that could overflow, which is `heapSbrk`'s stated discipline (`heap.dart`, ADR-0016 §5) and is the
   reason a validator's argument order is load-bearing.

And one property of the project rather than the machine: **twenty harnesses assert byte-exact serial
captures**, and nine of them contain the window's addresses in those captures. Any change to a memory
constant is a change to goldens, and §1.4 counts them exactly rather than saying "some".

---

## 1. THE 2 MiB WINDOW

### 1.1 First, a correction: the spare entries were undercounted by a factor of seven

`vm.dart`'s "WHY 256MiB" block (lines 1958–1963) says:

> `[128MiB, 1GiB)` is the gap between the top of RAM this kernel maps and the top of the page
> directory it already has — **62 unused page-directory entries**.

**62 is wrong, and it is wrong in the direction that makes the constraint look tighter than it is.**
`display-protocol.md` §1.2 repeats it in good faith. The arithmetic:

| PD_low index | covers | status |
|---|---|---|
| 0, 1 | `[0, 4 MiB)` | pointers to `pt0`/`pt1`, the 4 KiB window (`vm.dart:1171`) |
| 2 .. 63 | `[4 MiB, 128 MiB)` | **62** 2 MiB leaves — `vmBigFirst = 2`, `vmBigLastEx = 64` |
| 64 .. 127 | `[128 MiB, 256 MiB)` | **free** — 64 entries |
| 128 | `[256 MiB, 258 MiB)` | the ring-3 window, `vmProgPdIndex` |
| 129 .. 511 | `[258 MiB, 1 GiB)` | **free** — 383 entries |

**62 is the count of the entries that are used.** The gap `[128 MiB, 1 GiB)` is `(1024 - 128) / 2` =
**448 entries, 447 of them unused today**, and 383 of those are *contiguous and immediately above the
window*. There is no scarcity here at all:

| window | PD entries | contiguous run needed | available? |
|---|---|---|---|
| 2 MiB (today) | 1 | 128 | — |
| 8 MiB | 4 | 128..131 | yes |
| 16 MiB | 8 | 128..135 | yes |
| 64 MiB | 32 | 128..159 | yes |
| 768 MiB | 384 | 128..511 | yes, to the end of the directory |

**And there is a second, larger reserve nobody has looked at.** The PDPT has 512 entries and this
kernel writes **two**: entry 0 (`pdLow`, `[0, 1 GiB)`) and entry 3 (`pdPci`, `[3 GiB, 4 GiB)`) —
`vm.dart:1168–1169`. **Entries 1 and 2 are free: `[1 GiB, 3 GiB)` of untouched virtual address
space.** That is where a kernel virtual arena goes (§3.5), and it costs one page-directory frame per
gigabyte claimed.

So "grow the window" is not constrained by page-directory entries. It is constrained by the four
things below.

### 1.2 What growing actually costs — the mechanism, before the file list

Four things change shape, and only the third is genuinely hard.

**(a) One page-directory entry becomes N.** Everything that says `vmProgPdIndex` singular becomes a
range `[vmProgPdIndex, vmProgPdIndex + N)`. Three functions in `vm.dart` (`vmProgTable`,
`vmProgTableInstall`, `vmProgTableRemove`) and three in `proc.dart` (`procSpaceBuild`'s clear,
`procSpaceFree`'s walk, `procPtOf`) become loops. All six are `while` loops over a constant, and one
of them (`procSpaceFree`) becomes a **nested** `while` — which the pin has supported since it moved
to `e3cfe18` for exactly this shape (ADR-0011 §7).

**(b) `vmProgLeafSlot` is the one line most likely to be wrong.** Today:

```dart
return t + (((va >> u64(vmPageShift)) & u64(511)) << u64(3));
```

The `& 511` is correct only because the window is exactly one page table. With N tables it must first
select the table — `(va - vmProgBase) >> vmBigShift` — and then index within it. **A version that
grows the window and forgets this aliases every 2 MiB of the window onto the first page table**, which
maps and unmaps the wrong pages silently and would still pass a test that only ever touches the first
2 MiB. It is the single mutation a MEM-1 harness must be built to kill.

**(c) `vmProgMap` must keep its "nothing here allocates" property, and that is the real design
decision.** ADR-0014's invariant is stated in `vm.dart`'s M10 block:

> The page table's frame is supplied by the CALLER. Nothing here allocates, so no mapping can fail
> half-way through for want of memory — the failure happens at `vmProgTableInstall` or not at all.

With N tables there are two ways to keep it and one way to lose it:

* **Pre-allocate all N at install.** Failure stays atomic and at one place. Costs N frames per process
  whether or not the program uses the space: 4 KiB → 16/32/**128 KiB** per process at 8/16/64 MiB,
  and with four slots that is 512 KiB of RAM held at 64 MiB. On the suite's 32 MiB machine (7842 free
  frames) that is 1.6% of memory; acceptable. **This is the recommendation.**
* **Allocate lazily on first map in each 2 MiB stripe.** Saves the frames, and moves a
  `heapRetNoMem`-class failure into the middle of `vmProgMap`, which currently cannot fail for want of
  memory and whose callers do not roll back for that reason. This is a real regression in the failure
  model and it should not be taken to save 128 KiB.
* **Require the N frames contiguous**, as `vmInit` does for its six. `allocFrame` has no contiguous
  multi-frame request (GAP-0076 item 1) and `vmInit`'s six are contiguous only because its cursor is
  at zero. Do not repeat that trick for a runtime allocation.

**Do not add N words to remember the table frames.** `elfMetaPtFrame` is one metadata word today;
the right answer is to delete the need rather than widen it. `procSpaceFree` already recovers the page
table from the page directory rather than from a list, for the stated reason that "the tables are what
the CPU obeys, so they are what a teardown has to be checked against" — extending that to N tables is
a loop over N PD entries and needs **no** new storage. That keeps M17's `.bss` accounting untouched,
which nine harnesses assert.

**(d) `vmProgFlush` gets 32× more expensive, and should be replaced rather than scaled.** It names
every page one at a time — 512 `invlpg` today, **16384 at 64 MiB** — on every install AND every
remove, i.e. twice per process lifetime. The reason it names every page is that there is no
instruction to forget one page-directory entry. But **there is an instruction to forget all of them**:
a `mov` to CR3 flushes every non-global entry, and this kernel never enables PGE (`vm.dart`'s
`procSpaceFree` comment says so explicitly). Rewriting `vmProgFlush` as a CR3 reload is one line,
gets *cheaper* as the window grows, and is correct because every caller is already running on the
address space it is editing. The one thing to check is that `vmProgTableInstall` can run before the
process's CR3 is installed — it cannot; `vmProgPd()` walks from CR3 and refuses if it cannot reach a
page directory.

### 1.3 The cheaper shape: do not grow the window, ADD a second region

`vmProgEnd` is currently doing two unrelated jobs, and separating them is most of the win for a
fraction of the churn:

| job | used by | wants to change? |
|---|---|---|
| **top of the loadable region** — the bound `elfCheckPhdr` refuses a segment past, and the address the stack page sits below | `elf.dart:1313,1319,1752`, `heap.dart`'s `heapTop`/guard, every `prog.ld` | **no** |
| **top of what ring 3 can reach** — the bound every user-pointer validator tests | `elf.dart:1549–1561`, `file.dart:753–765, 917–929` | **yes** |

Split them:

```dart
const int vmProgBase   = 0x10000000;  // unchanged
const int vmProgEnd    = 0x10200000;  // unchanged — load region, stack, heap, guard
const int vmUserEnd    = 0x14000000;  // NEW — one past the last ring-3 address (64 MiB)
```

The load region keeps its geometry exactly: program at the bottom, guard at index 510, stack at 511,
`heapTop` unchanged. Everything above `0x10200000` is a **second region** that only an explicit
mapping call puts anything into — surfaces, shared regions, large buffers (§2.5).

What this buys, concretely:

* **`prog.ld` × 9 unchanged.** Every existing binary still links at `0x10000000` and still fits.
* **`heapTop`, `heapTopIndex`, `heapGuardPage`, `heapGuardIndex`, `heapMaxInc` unchanged** — and
  `m12-heap`'s entire structural block (run.sh:241–274), which multiplies all five back out against
  `vm.dart`'s window, keeps passing verbatim.
* **`vmProgStackPage`/`vmProgStackTop` unchanged** — so `ELF ENTER … RSP`, `m19-argv/check-stack.py`
  and `m18-preempt/derive.py`'s RSP-in-range check are all untouched.
* **47 golden occurrences of `101FE000` / `101FF000` / `10200000` across nine `expected*.txt` files
  do not move.**
* `ELF WINDOW PAGES 00000200` stays `00000200`, because `elfWindowLine` counts the *load* region.
  A new region needs a new line, and a new line is an **insertion** — which is the golden change this
  project already knows how to do safely (`shellStrHelp`'s five-harness substitution at M19).

What it costs: two constants where there was one, and a reader has to know which is which. That is
worth writing into `vm.dart`'s header as a table rather than left to inference — the failure mode is
a future validator that bounds against the wrong one, and the right defence is that
`fileOwnsWrite`/`elfOwns`/`userOwns` all live in a handful of places and a harness can grep them.

**Recommendation: (1.3) first, then raise `vmUserEnd` as a separate, later decision.** Growing
`vmProgEnd` in place — the literal reading of `display-protocol.md` §1.2 option 1 — is strictly more
expensive and buys nothing the second region does not.

### 1.4 The file-by-file list

**Legend:** ✎ = must change; ○ = changes only if `vmProgEnd` itself moves (i.e. **not** under §1.3);
◇ = golden/derived value that moves with it.

#### Kernel

| file | what | ✎ / ○ |
|---|---|---|
| `core/kernel/vm.dart` | `vmProgEnd`, `vmProgBytes`, `vmProgPages` — or the new `vmUserEnd`, `vmUserBytes`, `vmUserPages`, `vmUserTables` | ✎ |
| | `vmProgPdIndex` becomes a base + count; add `vmProgPdCount` | ✎ |
| | `vmProgTable()` → `vmProgTableAt(i)`; `vmProgTableInstall` takes N frames or is called N times; `vmProgTableRemove` clears N entries | ✎ |
| | **`vmProgLeafSlot` — the table-selection bug of §1.2(b)** | ✎ |
| | `vmProgMap` / `vmProgUnmap` bounds (`va >= vmProgEnd` → `vmUserEnd`) | ✎ |
| | `vmProgFlush` — 512 `invlpg` → CR3 reload (§1.2(d)) | ✎ |
| | `vmCountUser(vmProgBase, vmProgEnd)` callers: the scan is now N×512 pages | ✎ |
| `core/kernel/proc.dart` | `procSpaceBuild`: `vmSetEntry(pd, vmProgPdIndex, 0)` → a loop over N | ✎ |
| | `procSpaceFree`: one PT walk → N PT walks (**nested `while`**) | ✎ |
| | `procPtOf`, `procCrossVa`: one table → N; `procCrossVa` becomes N×512 | ✎ |
| | `procSlotPt` (one remembered PT frame per slot) — delete the need, recover from the PD (§1.2c) | ✎ |
| | `procSet(s, procSlotRsp, vmProgStackTop)` at `proc.dart:1842` | ○ |
| `core/kernel/elf.dart` | `elfWindowLine` prints `vmProgPages` (`elf.dart:1090`) ◇ | ✎ |
| | `elfPageReport` loop `vmProgBase..vmProgEnd` — 512 → N×512 iterations, and it prints **one line per mapped page** | ✎ |
| | `elfUnload`'s teardown loop (`elf.dart:1465–1480`) — same, plus `vmProgTableRemove` × N | ✎ |
| | `elfOwns` bound (`elf.dart:1549–1561`) → `vmUserEnd` | ✎ |
| | `elfCheckPhdr` segment bounds (`elf.dart:1310–1319`), entry-point bound (`1749–1752`) | ○ |
| `core/kernel/heap.dart` | `heapTop`, `heapTopIndex`, `heapGuardPage`, `heapGuardIndex`, `heapMaxInc` | ○ |
| | nothing at all under §1.3 — the heap lives in the unchanged load region | — |
| `core/kernel/file.dart` | `fileOwnsRead`/`fileOwnsWrite` bounds (`753–765`, `917–929`) → `vmUserEnd`. The per-page `vmEffective` loop is bounded by `fileReadMax` (512 B), **not** by the window, so it does not get slower | ✎ |
| `core/kernel/args.dart` | `argsBuild`/`argsPhysOf` are expressed relative to `vmProgStackPage`; the formula survives any move | ○ |
| `core/kernel/user.dart` | `userOwns`, same treatment as `fileOwns*` | ✎ |

**`core/kernel/ata.dart:221` is a false positive.** `ataLba28Limit = 0x10000000` is 2^28 sectors and
has nothing to do with the window. Any grep-driven change must not touch it.

#### Harnesses that assert an exact page set

| harness | what it asserts | ✎ / ◇ |
|---|---|---|
| `m10-elf/derive.py` | **the source of truth for every other one.** `PROG_BASE`, `PROG_END`, `PROG_PAGES = 512`, `PROG_PD_INDEX = 128`, `PROG_STACK_PAGE`, `PROG_STACK_TOP` (lines 42–47). Re-exported by m11, m12, m13 and m18 — so this file is edited once and four inherit | ✎ |
| `m10-elf/run.sh:424–449` | multiplies `vmProgBase / vmBigBytes == vmProgPdIndex` and checks derive.py's copy against `vm.dart` | ✎ |
| `m10-elf/run.sh:1140–1158` | after every program: `PD_low[128]` absent, **and no PD entry from `MAP_BYTES/BIG_BYTES` (=64) to 512 present**. That loop is exactly the assertion a wider window inverts — it becomes "none present except `[128, 128+N)`" | ✎ |
| `m10-elf/run.sh:1285–1310` | while live: `PD_low[128]` present, not huge, U/S, RW, no NX, and equal to the frame the kernel printed. → per-entry, N times | ✎ |
| `m10-elf/run.sh:1420–1447` | `check_program_pages`: every page the ELF asks for, at its `p_vaddr`, with its `p_flags` — window-size independent | — |
| `m11-proc/run.sh:998` | the two processes report **different** window page tables | ✎ (N of them) |
| `m11-proc/run.sh:1046–1051` | the kernel's own address space has **no** mapped page in `[PROG_BASE, PROG_END)` | ✎ |
| `m11-proc/derive.py:check_isolation` | every commonly-mapped VA is backed by a **different** frame. §2.6 inverts exactly one address of this | ✎ |
| `m12-heap/run.sh:241–274` | `heapTop` × `heapTopIndex` × `heapGuardPage` × `heapMaxInc` × `vmProgBase`/`vmProgEnd`/`vmProgPages` all multiplied back out against each other | ○ |
| `m12-heap/run.sh:848–953` | both address spaces walked out of guest memory; every heap page present+user+writable+NX; nothing mapped above either break | ✎ |
| `m12-heap/build-progs.sh:86–90, 163` | its own copy of `PROG_BASE`/`PROG_END`/`STACK_PAGE`/`HEAP_TOP`, and `if room < 400: refuse` | ○ |
| `m13-libc/derive.py:61–62` | `PROG_BASE`/`PROG_END` from m12 | ✎ |
| `m18-preempt/derive.py:53–54, 203–205` | RSP must be inside `[PROG_BASE, PROG_END]` at every preemption | ○ |
| `m19-argv/run.sh:515–527`, `check-stack.py` | `vmProgStackTop`, `vmProgStackPage`, `argsMinStack`; nine stack assertions | ○ |
| `m9-ring3`, `m8-paging` | `vmCountUser` over the **4 MiB** window, not this one | — |

#### Goldens

| file | occurrences | of what |
|---|---|---|
| `m10-elf/expected.txt` | 6 | window addresses |
| `m10-elf/expected-screen.txt` | 2 | " |
| `m11-proc/expected.txt` | 2 | " |
| `m12-heap/expected.txt` | **18** | " — the heap milestone prints `BASE`/`TOP` on every refusal |
| `m13-libc/expected.txt` | 5 | " |
| `m14-fat/expected.txt` | 4 | " |
| `m15-fileio/expected.txt` | 2 | " |
| `m16-filewrite/expected.txt` | 2 | " |
| `m19-argv/expected.txt` | 6 | " |
| | **47 total** | **all of them unchanged under §1.3** |
| `ELF WINDOW PAGES 00000200` | 5 harnesses × 2 files (m10, m14, m15, m16, m19) | changes only if `elfWindowLine`'s region changes |

`prog.ld` × 9 (m10, m11, m12, m13, m14, m15, m16, m18, m19) contain the window's extent in prose and
`. = 0x10000000` in fact. Under §1.3 only the prose is stale.

### 1.5 Two consequences of a bigger window that are not obvious

**GAP-0108 closes as a side effect, and that is a good thing.** `heapRetNoMem` is a refusal path no
boot in the suite can walk: the window (507 pages) always fills before the allocator (7842 free frames
on the 32 MiB machine) does. Raise the heap's ceiling and that inverts:

| heap ceiling | pages a program can ask for | 32 MiB machine (7842 free) | 128 MiB machine (32417 free) |
|---|---|---|---|
| 2 MiB (today) | 507 | window fills first | window fills first |
| 8 MiB | 2045 | window fills first | window fills first |
| 16 MiB | 4093 | window fills first | window fills first |
| **64 MiB** | **16379** | **allocator exhausts first — `heapRetNoMem` is reached** | window fills first |
| 256 MiB | 65531 | reached | **reached** |

So 64 MiB is the first size at which the suite's small-machine boot exercises `heapRetNoMem` for real,
replacing `m12-heap`'s structural checks 2f/2g with a behavioural one. **GAP-0108's own text asks for
exactly this** and proposes a `frames drain` keep-count as the alternative; a bigger heap ceiling gets
it for free. Note this only applies if the *heap's* ceiling moves, which §1.3 deliberately does not do
— so if closing GAP-0108 is wanted, it is an argument for eventually moving `heapTop` too, and it
should be taken as its own decision with the 18 golden occurrences in `m12-heap/expected.txt` priced
in.

**The exhaustion test gets slow, and the number should be measured before it is chosen.** `heapSbrk`
calls `vmZeroFrame` on every page, and `vmZeroFrame` is 512 volatile `u64` stores that the optimiser
is forbidden to vectorise or elide (GAP-0052). `m12-heap`'s program walks the window to the guard
page: 507 pages ≈ 260,000 stores today, **16379 pages ≈ 8.4 million stores at 64 MiB**, under TCG,
twice (two processes). That is a harness runtime cost, not a correctness one, and it is the kind of
number this project measures before committing (GAP-0108's own M13 note is a precedent). It is also an
argument for the second region of §1.3: a region that is only mapped on request is not walked by a
test that fills the heap.

---

## 2. SHARED MEMORY

### 2.1 The hazard, stated more precisely than "use-after-free"

`display-protocol.md` §8 records it as: *`freeFrame` is a bit-clear and `procSpaceFree` frees every
present leaf in the window unconditionally, so any future feature that maps one physical frame into
two address spaces inherits a use-after-free.* That is right, and the precise sequence is worth having
because **the existing double-free check changes which half of it is dangerous**:

| step | what happens | what the kernel thinks |
|---|---|---|
| A and B both map frame F | two present leaves, two address spaces | nothing — no owner is recorded (GAP-0076 item 6) |
| A exits | `procSpaceFree(A)` walks A's page table, sees F present, calls `freeFrame(F)` | **bit cleared, free count +1.** F is now allocatable |
| **B is still mapped and still writing F** | | — |
| anything calls `allocFrame()` | F is handed out | — |
| C writes F | B's memory changes under it, and B's writes corrupt C | — |
| B exits | `freeFrame(F)` → `pmmBitGet(f) < 1` → **`pmmFreeDouble`**, `pmmError()`, bitmap untouched | **loud: `pmmMetaErrors` is non-zero and `frames` says so** |

So the double-free is already caught (`pmm.dart:1147–1150`), counted, and visible. **The window of
corruption is between A's exit and B's exit**, and nothing detects it. The fix is therefore not "add a
double-free check" — that exists — it is **stop the first free from releasing a frame somebody still
maps**.

There is a second, quieter half. `heapRollback` and `elfUnload` also call `freeFrame` on frames
recovered from leaves, and `frames refill` (`pmm.dart:1622`) frees **every allocatable frame in the
machine** as a test fixture. A shared frame that is not protected in `freeFrame` itself is exposed by
all four paths, not one.

### 2.2 Why the fix belongs in `freeFrame` and nowhere else

Every path that gives a frame back funnels through `freeFrame`:

```
procSpaceFree  ──┐
heapRollback   ──┤
elfUnload      ──┼──►  freeFrame(addr)  ──►  bit clear
shellFree      ──┤
frames refill  ──┘
```

Putting the guard at the top of `freeFrame` means **no teardown path has to learn that sharing
exists**. Putting it in `procSpaceFree` instead would need the same change in four places and would
miss the fifth. This is the strongest argument for `display-protocol.md`'s proposal and it is why the
alternatives in §2.4 are all judged against it rather than against each other.

It also matters *where* in `freeFrame` the branch goes. Not literally first: the `ready` check and the
**alignment** check must run before it, because the guard is keyed by frame address and an unaligned
address must never match a table entry — `free 1001` has to keep being `pmmFreeAlign`, not a lookup
that misses. The order is:

```dart
u64 freeFrame(u64 addr) {
  if (pmmMeta(pmmMetaReady) < 1) { ...pmmFreeNotReady }
  if ((addr & pmmFrameMask) > 0) { ...pmmFreeAlign }
  // ── THE ONE BRANCH ──
  if (pmmSharedBitGet(addr >> pmmFrameShift) > 0) {   // O(1), see §2.4
    return shmDrop(addr);                              // decrement; free only at zero
  }
  ...range, allocatable, double-free, bit clear
}
```

### 2.3 What `shmDrop` must return, and why it is not a new status code

Every caller of `freeFrame` in this kernel **adds the returned status to a running error counter**,
which works only because `pmmFreeOk == 0` (ADR-0011 §4). `heap.dart`'s `heapRollback` does it twice
in six lines; `heapSbrk` does it once more.

So `shmDrop` returns `pmmFreeOk` when it decrements a still-positive refcount, and returns whatever
the normal path returns when the count reaches zero and the frame really is freed. A new
`pmmFreeShared = 6` would be more expressive and would silently start incrementing `procHeadErrors`
by 6 at four call sites. **Do not add the code; make the sharing visible in a metadata word and a
shell command instead.**

The consequence for harnesses is real and should be stated in the ADR that builds it: `procSpaceFree`
returns "frames actually given back", and a shared frame retained on A's exit is not one. **The free
count bracket that nine harnesses assert must be taken across the LAST exit, not each one** — which
is a stronger assertion than the current one, not a weaker one, because it also proves the retention.

### 2.4 Evaluating the fixed-capacity table — and a strictly better version of it

`display-protocol.md` proposes *a small fixed-capacity shared-frame table plus ONE branch at the top of
`freeFrame`*. The shape is right. The lookup is the problem:

**A linear scan is not affordable in `freeFrame` specifically.** `frames refill` calls `freeFrame`
32768 times. With a 64-entry table that is 2.1 M volatile loads added to a fixture every harness from
m7 onward runs; with 256 entries it is 8.4 M. Under TCG, with `Pointer<T>` volatility forbidding any
hoisting, that is seconds of harness time added to nine harnesses to support a feature none of them
use.

**The fix is the idiom the file already has: a second bit-plane.**

```dart
// 4096 more bytes in pmmStore: one bit per frame, 1 = this frame is shared.
const int pmmSharedOffset = 4672;      // after bitmap + meta + ledger
const int pmmSharedBytes  = 4096;      // exactly one page, exactly the bitmap's size
```

* the test in `freeFrame` is **one bit-test, O(1)**, the same operation `pmmAllocatable` already does;
* `frames refill`'s 32768 calls cost 32768 bit-tests, which is the same order as the bitmap operations
  it is already doing — no measurable change;
* the linear scan over the count table happens **only for frames that are actually shared**, which is
  a handful;
* it is 4096 bytes, the same as a 256-entry pair table would be, and it comes with the same argument
  the frame bitmap comes with: *4096 bytes is exactly one page*;
* it goes inside `pmmStore` behind the **existing** three-function seam. No fourth accessor, no new
  `@bss` symbol, no new storage seam — which is what `m7-frames/run.sh:286–294` counts and would
  otherwise fail.

The count table then holds only `(frame, refs)` pairs for frames whose count is > 1. 64 pairs = 128
words = 1024 bytes, enough for 64 shared frames = **256 KB, which is exactly one 256×256 surface**
(`display-protocol.md` §1.2's own "comfortable" size). 256 pairs = 4096 bytes = 1 MiB shareable.
I would take 256 and spend the page.

**Alternatives, judged:**

| alternative | verdict |
|---|---|
| **Byte-per-frame refcount plane** (32768 bytes, one byte per frame, O(1), no capacity limit at all) | **The general answer, and it is not expensive.** 32 KB of `@bss`. The project's own convention absorbs it: a new block added LAST in `.bss` is subtracted by every earlier harness's accounting (ADR-0021 §5, and M14/M15/M16/M19 each did exactly this). Its only real cost is that 32 KB of a 4 MiB ceiling (§3.1) is a non-trivial fraction. **Take this the day COW or `fork` arrives**; it is the one shape that supports thousands of shared frames. |
| Teach `procSpaceFree` to skip shared pages | Misses `heapRollback`, `elfUnload`, `frames refill`. §2.2. |
| Never share frames (the display protocol's own answer: server-side drawing verbs) | **Correct for the display, and it does not generalise.** A NIC ring shared with a driver process, a `fork` with COW, and a device-shared buffer all want frame sharing, and none of them can be re-expressed as drawing verbs. |
| Owner tags per frame instead of counts | A different and much larger project (GAP-0076 item 6). A count answers "may I free this"; an owner answers "who leaked this". Only the first is needed here. |

**Does the fixed-capacity table generalise? Half.** The bit-plane generalises completely — every frame
in the machine can be marked shared at O(1). The *count* table is capacity-bounded and must therefore
have a refusal (`shmErrFull`) that a program can be told, in the style of `heapRetNoSpace`. That
refusal is the honest boundary, and it is reachable by a test (unlike `heapRetNoMem` — GAP-0108),
which is a point in its favour. The migration to the full byte-per-frame plane replaces the table and
keeps the bit-plane as the fast path, and touches nothing outside `pmm.dart` — which is the same
"neutralised by shape" argument ADR-0011 §0 made for donated `.bss`, and it worked.

### 2.5 What a sound `mmap`-like primitive looks like here

Not `mmap`. `mmap`'s signature is six arguments, a pointer return that overloads failure onto
`MAP_FAILED`, and file-backed semantics this kernel has no page cache for. ADR-0016 §1 already
declined `mmap` once, for `sbrk`, and the reasoning holds. Two syscalls, in the shape this kernel
uses:

```
  11  vmap(pages, flags)    -> va,  or a refusal above vmapRetFloor
  12  vunmap(va, pages)     -> status
```

and for sharing, two more that are deliberately *not* `vmap` with a flag, because `@bare` DCDart has
no boolean parameter and a validator whose meaning depends on an argument is one somebody calls
wrong (`file.dart`'s own stated reason for splitting `fileOwnsRead`/`fileOwnsWrite`):

```
  13  shmCreate(pages)      -> region id, or a refusal
  14  shmMap(id)            -> va,        or a refusal
```

Properties, each with the reason:

* **Addresses are chosen by the kernel, never by the caller.** A caller-chosen address needs a
  placement policy, an overlap check and an alignment negotiation; a kernel-chosen one is a bump
  pointer up from `0x10200000` inside the new region (§1.3) and is one word of per-process state. This
  is `display-protocol.md` §1.1's own argument about surface position, applied to addresses.
* **RW+NX always; executable is refused, not silently dropped.** `vmProgMap` already refuses W+X
  (`vmProgWx`); a shared *executable* page is a code-injection channel between processes and gets its
  own refusal rather than an exception. ADR-0012 bought W^X for the kernel and ADR-0014 refused a
  guest an exemption; this refuses one to a shared region too.
* **Pages are zeroed before they are mapped, not after.** `heapSbrk`'s exact discipline, for
  `heap.dart`'s exact reason: between the mapping and the zeroing there is a window in which the
  previous owner's bytes are reachable from ring 3.
* **Failure is atomic and every refusal is a distinct value above a floor.** `heapRetNoSpace` /
  `heapRetNoMem` / `heapRetBadArg` is the pattern; a partial `vmap` rolls back exactly like
  `heapRollback` and does not move the region's bump pointer.
* **File-backed demand map is ADR-0164 (`shmfile` / `mmap-file/`).**
  Anonymous eager shm stays ADR-0041. Say further MAP_SHARED write-through
  in a gap if needed rather than leaving it to be discovered.
* **Synchronisation is a shared word and `yield`, and nothing else.** Nothing on this machine can
  block (GAP-0141). There is no futex, there cannot be one, and a design that needs a client to *wait*
  for a shared buffer is a design for a different OS. `display-protocol.md` §2.2's "events ride the
  reply" is the same constraint answered one layer up.

**Region lifetime, stated as an invariant:** a region's frames are held by (number of address spaces
that map it) + (1 if a live handle names it). It dies when that reaches zero. The `+1` is what makes
`shmCreate` followed by an immediate `shmMap` in the same process not a race, and what makes a region
survive its creator exiting before its consumer maps it.

### 2.6 The one harness change, and why it is an improvement

`m11-proc/derive.py`'s `check_isolation` item 3 requires that every virtual address both processes map
is backed by a **different** physical frame. Shared memory makes that false for exactly one address.

**Invert it for exactly that address; do not relax it.** The assertion becomes: *these two address
spaces share exactly one page, at exactly this virtual address, backed by exactly this frame, and
every other commonly-mapped address is backed by different frames.* That is strictly stronger than
what it asserts today, because it now also proves the sharing worked. `display-protocol.md` §8 makes
the same call and it is the right one.

---

## 3. A REAL KERNEL ALLOCATOR

### 3.1 Where the `@bss` block pattern breaks — and the wall is closer than it looks

Today every subsystem gets a fixed `@bss` block behind a storage seam. Seventeen blocks, 14368 bytes
at M19, and it has worked for nineteen milestones. It works because every count is (a) known at
compile time and (b) small:

| subsystem | block | the fixed count inside it |
|---|---|---|
| `pmmStore` | 4672 | 32768 frames, 64 ledger entries |
| `procStore` | 4224 | **4 processes** (`procMaxSlot = 3`) |
| `fileStore` | 3584 | **36 file descriptors** (`fileRows = 9` × `fileMaxFds = 4`) |
| `fatStore` | 1824 | 256-entry cluster chain, one sector buffer |
| `argsStore` | 256 | 8 arguments, 128 bytes |
| `vmStore`, `userStore`, `elfStore` | 128 each | — |

**The wall is not aesthetic and it is not `.bss` being unfashionable. It is `vm.dart:1257`:**

```dart
if (kernel_image_end() > u64(vmFineBytes)) {   // 4 MiB
  ...TOOBIG; CR3 is not touched
}
```

The kernel image — `.text` + `.rodata` + `.data` + **`.bss`** — must fit in the 4 MiB 4 KiB-page
window, or the kernel refuses to install its own address space and runs on `boot.S`'s bootstrap
tables. Measured from `core/build/kernel.map` at M19: `__kernel_start = 0x00100000`,
`__kernel_end = 0x00148830` — an image of **296,496 bytes**, of which 14368 is `@bss`. Headroom to
`vmFineBytes` is `0x400000 - 0x148830` = **2,848,208 bytes, about 2.72 MB** — and it is a hard,
already-enforced, already-tested ceiling. Raising it means raising `vmFineBytes`,
which changes the number of page tables `vmInit` takes, which changes the "SIX FRAMES, AND WHY THE
NUMBER IS FIXED" argument that `m7-frames/derive.py` and `m8-paging/run.sh` both derive the allocator's
post-boot free count from. That is a real milestone, not a constant bump.

Now measure the three motivating cases against 2.72 MB:

**(1) Network buffers — needs kmalloc, and needs something kmalloc cannot give.**
A receive ring of 256 descriptors × 2 KB is 512 KB; two rings is 1 MB. That fits in `.bss` *once*,
for *one* NIC, at the cost of a quarter of the headroom for a device that may not be present. The
count depends on a device discovered at runtime, which is the definition of what a fixed block cannot
express. But the harder half is that **DMA ring buffers must be physically contiguous**, and
`allocFrame` returns one frame at a time with no contiguous request (GAP-0076 item 1). *A kmalloc does
not solve this.* A NIC needs a **contiguous multi-frame allocator** as a separate, named capability.
Two other properties are load-bearing and should be written down before a driver assumes them: the
kernel is **identity-mapped**, so a physical address handed to a device is the same number the kernel
dereferences (this breaks the day a higher-half kernel arrives); and `allocFrame` is **not
interrupt-safe** (GAP-0076 item 7), which stops being harmless the moment an interrupt handler
allocates a buffer — which is precisely what a NIC receive path wants to do.

**(2) Per-window backing store — needs kmalloc least of the three, and needs address space most.**
800 × 600 × 4 = **1,920,000 bytes = 469 frames** for one full-screen backing store. It cannot be
`@bss`: **one** of them is 1.92 MB of a 2.72 MB headroom and **two do not fit at all** — the kernel
stops installing its own address space and prints `TOOBIG`. It is also a poor fit
for a general kmalloc, because kmalloc's hard case is *variable small sizes with reuse* and this is
*one large size with a lifetime tied to a window*. The right primitive is different and it is
available today: **469 individually-allocated frames, addressed through the identity map, with a
page-indexed accessor.** `store_pixel(store, x, y)` resolves to `frame[(y*w+x)>>10] + offset`, which
is two more instructions than a flat pointer and needs no new machinery at all. Virtual contiguity
(§3.5) is nicer and is not required.

**(3) A device table — does NOT need kmalloc, and saying so is worth more than adding one.**
`pci` re-walks the bus on every use (GAP-0067 item 1) and `pmmAllocatable` re-walks the Multiboot map
on every call (GAP-0076 item 8). Both want a *cache*, and the number of devices on a PC bus is bounded
by the bus. **32 entries × 32 bytes = 1 KB of `@bss` behind one seam is the correct answer** and it is
cheaper, more testable and more in keeping with the rest of this kernel than a heap allocation. Do not
let a kmalloc milestone carry this one on its back; it is one more block in the existing pattern.

**So the honest scorecard: one of the three motivating cases (network) needs kmalloc plus a
contiguous allocator, one (backing store) needs address space and a page-vector accessor, and one
(device table) needs neither.** A kmalloc is still worth building — but it should be built for the
case it actually serves, which is *many small, variable-size, variable-lifetime kernel objects*: file
descriptors beyond 20, process slots beyond 4, per-surface metadata, per-connection state.

### 3.2 The smallest `kmalloc` that fits DCDart

**Do not invent an algorithm. Mirror `core/user/libc/malloc.c`.** It is a first-fit free list with
splitting and coalescing over `sbrk`; it is 16-byte aligned with a 16-byte header; its reuse is
already measured against a second build of the same source with `free()` disabled (m13-libc, ADR-0017
§6). The kernel version is *the same algorithm over `allocFrame` instead of `sbrk`*, which means the
design question is already answered and the mutation set already exists in a form that can be adapted.

The interface, in the only shape `@bare` DCDart permits:

```dart
/// Returns a 16-byte-aligned kernel address, or 0 on failure.
/// 0 is unambiguous for the same reason allocFrame's is: frame 0 is never allocatable.
@bare u64 kmalloc(u64 bytes);

/// Returns a kmemFree* status. kmemFreeOk == 0, for ADR-0011 §4's reason.
@bare u64 kfree(u64 addr);
```

Everything that follows is forced by the language, and each point names what forces it:

* **`u64` in, `u64` out. There is no typed allocation and there cannot be**, because `@bare` has no
  array, no `String`, and no type an allocation could be returned as (GAP-0076 item 2 states this as
  "the honest boundary between a physical memory manager and an allocator"). Callers do
  `Pointer<T>.fromAddress` and it is exactly as unchecked as it sounds. **Do not try to hide that**;
  ADR-0011 already decided that being loud about it is better than a false abstraction.
* **A one-word header, not two.** libc's is 16 bytes because it stores `size` and a `next` pointer.
  Every header field access is a **volatile** load (GAP-0052), so header words are a real per-operation
  cost. Pack the kernel's into one `u64`: size is 16-aligned, so bits 0–3 are free — bit 0 = in use,
  bit 1 = arena head, bit 2 = last block in arena. 16-byte payload alignment is then kept by making
  the header 16 bytes with 8 bytes of padding, or by accepting 8-byte alignment and saying so. **I
  would keep 16 bytes and use the spare word for a `prev size`**, because backward coalescing without
  it needs a linear sweep of the arena on every free, and a free that is O(arena) is a free that gets
  called in a teardown loop.
* **Forward and backward coalescing, both, or neither is worth having.** libc's `insertFree` merges
  with both neighbours and m13 measures the result. Copy it.
* **Arenas are whole frames from `allocFrame`.** When the free list cannot satisfy a request, take one
  frame, mark it an arena head, and put the remainder on the list. An arena that becomes entirely free
  is returned with `freeFrame`, which makes "the PMM free count returns to its baseline" the
  allocator's own exit criterion — the same bracket nine harnesses already use.
* **`kmallocMax` is one frame minus the header, and larger requests are refused by their own code.**
  A multi-frame allocation needs physically contiguous frames, which do not exist as a primitive
  (GAP-0076 item 1). Refusing is honest; silently allocating a run that happens to be contiguous
  because the cursor was in the right place is not. The contiguous allocator is a separate named
  milestone (§3.4).
* **Every bound is checked before the arithmetic.** `kmalloc(0xFFFFFFFFFFFFFFFF)` must be refused
  *before* the `+ header` and the round-up, because DCDart traps overflow with a real `ud2` and this
  runs in kernel context. `heapSbrk`'s check ordering is the template and `m12-heap/run.sh` check 2f
  is the precedent for asserting the ordering by parsing the function body.
* **No `&&`.** Every guard is a chain of single-test `if`s returning early. This is why `kfree`'s
  validity check ("is this address inside a live arena, 16-aligned, and marked in-use") is three
  separate refusals with three separate codes rather than one predicate — which is better anyway,
  because "you freed something that was never allocated" and "you freed it twice" are different facts.
* **Storage: ONE `@bss` block behind two or three functions, added LAST in `.bss`.** ADR-0011 §0's
  shape, ADR-0021's convention. Being last is what lets every earlier harness subtract it by name and
  keep its own accounting number meaning what it meant (M14, M15, M16 and M19 each did this in turn).
  The block is small — a free-list head, an arena list head, and counters — because the *data* lives
  in the frames, not in the block. That is the difference between this and every other subsystem here.
* **Not interrupt-safe, and today that is fine for a stated reason.** It inherits GAP-0076 item 7 from
  `allocFrame`. M18 preempts **from ring 3 only** — a syscall cannot be preempted (GAP-0138) — and no
  interrupt handler in this kernel allocates. Both halves must be written into the gap entry, because
  the day a NIC interrupt handler calls `kmalloc` is the day this becomes a real race, and that day
  arrives with motivating case (1).

### 3.3 What kmalloc must NOT do

* **No slab/size-class layer.** Two allocators is two sets of bugs. First-fit with splitting is what
  the userland one does and what m13 proves reuses memory.
* **No zero-on-free.** ADR-0011 rejected it for frames as "4 KiB of stores per free with no caller
  that needs it"; the same holds. Zero on *allocate* where the caller needs it, as `heapSbrk` does.
* **No `krealloc`.** Nothing wants it yet, and it is the operation that makes a header layout hard to
  change later.
* **No use by the boot path.** `pmmInit`, `vmInit` and the fault handler must never call it. A fault
  handler that allocates is a fault handler that can fault.

### 3.4 The contiguous allocator, named so it is not smuggled in

A DMA ring needs N *adjacent* frames. That is a different search over the same bitmap — scan for a run
of N zero bits — and it is one function, `allocFrames(n) -> physical address or 0`, plus a matching
`freeFrames(addr, n)`. It is genuinely small. What makes it a separate milestone rather than a
paragraph of this one is that its exit criterion is different: the run must be proved adjacent and
proved free-before/used-after **out of the 4096-byte bitmap**, and the fragmentation behaviour (a
next-fit cursor makes long runs progressively harder to find) is a property that needs measuring, not
asserting.

### 3.5 The kernel's own virtual address space, which does not exist yet

Everything the kernel touches is identity-mapped. That is why scattered frames cannot be presented as
one contiguous kernel buffer, and it is the only reason §3.1 case (2) needs a page-indexed accessor
instead of a flat pointer.

**PDPT entries 1 and 2 are free** (§1.1): `[1 GiB, 3 GiB)`, two gigabytes of untouched kernel virtual
address space, one page-directory frame per gigabyte claimed. Mapping `[1 GiB, 1 GiB + 2 MiB)` as one
page table gives 512 pages of kernel virtual arena into which arbitrary scattered frames can be mapped
contiguously, supervisor and NX. That is the general answer to "the kernel needs a 1.9 MB buffer", it
costs two frames of tables, and it is the smallest new capability in this document.

Its one real hazard is that a kernel virtual mapping is **not** in the per-process page directories
unless it is copied there — `procSpaceBuild` copies `PML4[0]`, `PDPT[0..511]` and `PD_low[0..511]` by
value at creation. A PDPT entry added to the kernel's tables *after* a process exists would not appear
in that process's space, and the kernel would fault at that address while running on the process's
CR3 — which is most of the time. **Establish the kernel arena's PDPT entry in `vmInit`, before any
process can exist**, and the problem does not arise. Say it in the ADR; it is exactly the kind of
thing that is discovered at 3 a.m.

---

## 4. PAT / MTRR

### 4.1 What GAP-0071 actually records, and the one thing it cannot know

`boot.S:110–129` maps `[3 GiB, 4 GiB)` as 512 identity 2 MiB pages, present + writable, **with no PCD
or PWT bit and no MTRR or PAT setup at all**. The gap entry is honest about the shape of the problem
("cacheable is wrong in principle for MMIO and right in practice for a linear framebuffer") but there
is a fact underneath it that the entry does not state and the kernel cannot currently discover:

**With PAT unprogrammed and PCD/PWT clear, the page-table contribution is WB — but the *effective*
memory type is the combination of that with the MTRR type, and UC wins every combination it is in.**
On a PC, firmware conventionally sets `IA32_MTRR_DEF_TYPE` to UC and marks RAM ranges WB with
variable-range registers, which leaves the PCI hole **UC**. So the likely truth on real hardware is
not "the framebuffer is cached", it is "the framebuffer is uncached and every store is a bus
transaction". Under QEMU/TCG neither is observable.

**The kernel does not read `IA32_MTRRCAP` (0xFE), `IA32_MTRR_DEF_TYPE` (0x2FF) or any variable-range
pair (0x200..0x20F). It has never read an MTRR.** So today the memory type of the framebuffer is
**unknown to the kernel**, and both possible answers are bad in different ways. That is the precise
statement GAP-0071 is missing.

### 4.2 What it costs, in the two cases

| if the effective type is | the cost | who notices |
|---|---|---|
| **UC** (most likely on hardware) | every framebuffer store is a separate bus transaction. `fbFill` is 480,000 volatile `u32` stores (GAP-0070 item 7); one glyph is 128. A window system composing at any rate is doing millions. **This is the single largest number in the display path** and it is invisible under TCG. | anything that animates — i.e. `display-protocol.md` in its entirety |
| **WB** | correct and fast for a linear framebuffer; **wrong for every other BAR in the same gigabyte.** A device register read served from a cache line is a stale value with no diagnostic. Nothing in this kernel touches a non-framebuffer BAR through memory yet, which is why it has not bitten. | the first MMIO device driver |

The second is why the whole-gigabyte blanket is the real defect: **one memory type for a gigabyte
containing both a framebuffer and device registers is wrong whichever type you pick.**

### 4.3 What fixing it involves, in the order the cost rises

**Step 1 — read and report. No behaviour change.** `rdmsr` on `IA32_MTRRCAP`, `IA32_MTRR_DEF_TYPE`
and the variable-range pairs, decode them in DCDart, and print the derived effective memory type for
the framebuffer BAR and for one other address. `boot.S` already contains an `rdmsr`/`wrmsr` pair for
EFER (`boot.S:585–591`), so the primitive exists in the file that is allowed to have it; a narrow
`@extern u64 msr_read(u32)` is the DCDart-side ask and it is genuinely narrow (CLAUDE.md rule 3, and
ADR-0029's port-I/O precedent is the exact shape). **This step alone converts an unknown into a
number, and it is where I would start**, because every later step's value depends on which of §4.2's
two cases is true on the target machine.

**Step 2 — program PAT, and set the bit on the framebuffer's entries only.** Write `IA32_PAT` (MSR
0x277) with one slot changed to **WC (0x01)** — conventionally PA4, leaving PA0..PA3 at their
architectural defaults so that every page not opting in behaves exactly as it does today. Then set the
PAT bit on the eight 2 MiB entries covering the 16 MiB BAR.

**The bit position is the trap.** In a 4 KiB PTE the PAT bit is **bit 7**. In a 2 MiB PDE, bit 7 is
**PS (huge)** and the PAT bit is **bit 12**. `vm.dart`'s `vmHuge` is bit 7 and the PCI hole is mapped
with 2 MiB pages, so a change that reaches for "the PAT bit" and finds `vmHuge` produces an entry that
is not a huge page and points at a page table that does not exist. This is a one-bit error with a
catastrophic and *immediate* failure mode, which is the good kind — but it is exactly what a harness
that reads the PD entries out of guest memory is for.

**Step 3 — MTRRs, only if step 1 says they are UC over the BAR.** The SDM's effective-type table is
unforgiving: **MTRR UC + PAT WC → UC.** PAT cannot upgrade a UC range. Getting WC therefore requires a
variable-range MTRR set to WC over `[0xFD000000, +16 MiB)`, and programming an MTRR is the full
ceremony: `CR0.CD=1, CR0.NW=0`, `wbinvd`, clear `CR4.PGE`, flush the TLB, `MTRRdefType.E=0`, write the
base/mask pair, re-enable, `wbinvd` again, restore CR0. **Every instruction in that sequence is
privileged and none of them is expressible in DCDart.** It belongs in `boot.S` or in one narrowly
scoped assembly helper — CLAUDE.md rule 4, and it is the kind of hardware decision the escalation rule
says to surface rather than take unilaterally.

**Step 4 — stop mapping the whole gigabyte.** GAP-0071's own "what would fix it" says page-table
entries created on demand rather than up front. That is now cheap: M7 gave the kernel an allocator and
M8 gave it a walker, which are the two things the gap said were missing. `[3 GiB, 4 GiB)` becomes
unmapped by default, and `fb.dart` maps its BAR after PCI enumeration finds it. This also closes the
third bullet of GAP-0071 item 1 — "a stray pointer into 3–4 GiB now silently succeeds where it used to
fault."

**The ordering problem nobody has hit yet.** `vmInit` runs *before* PCI enumeration, so at the moment
the PCI hole is mapped the kernel does not know where the framebuffer is. Steps 2 and 4 therefore both
need a function that re-types or creates entries *after* discovery — `vmSetPciType(base, bytes, type)`
— plus `invlpg` over the affected range (8 pages of 2 MiB for a 16 MiB BAR; trivial). That function is
the actual unit of work in this section.

### 4.4 The exit criterion cannot be a timing measurement, and that has to be said out loud

Under QEMU/TCG, WC, WB and UC all behave identically. A milestone that claimed "the framebuffer is
faster now" would be claiming something the harness cannot see. So the criterion is structural plus a
derived-value check, and it is honest about the residue:

* the kernel prints `IA32_PAT` after writing it; the harness compares it against a **derived** 64-bit
  constant, not a copy;
* the eight PD entries covering the BAR are read out of guest physical memory and have bit 12 set,
  bit 7 set (still huge), NX set, U/S clear; **and every other PCI-hole entry does not have bit 12** —
  the negative half, without which "we set a bit" is consistent with "we set all of them";
* the kernel's own decoded effective-type report says WC for the framebuffer address and UC for a
  non-framebuffer address in the same gigabyte, and the harness derives both independently from the
  MSR values the kernel printed;
* `m5-pci`'s existing pixel read-back at the BAR address is **byte-identical** — the screen still
  draws correctly, which is the thing a wrong memory type would most plausibly break;
* and the ADR states plainly that **the performance claim is unverified on this project's hardware**,
  in the way ADR-0009 states what it measured versus what it assumed.

---

## 5. Milestone ladder

Numbered MEM-n because these are not roadmap milestones yet; the roadmap is at M19 and whoever folds
these in assigns real numbers. **The verification style throughout is `m7-frames`'s**: the structure is
read out of guest physical memory with the monitor and compared **bit-for-bit** against one the
harness derives itself (`m7-frames/run.sh:931–968` dumps all 4096 bytes of the frame bitmap and
requires equality; :1034–1039 does it again in the drained state and requires all `0xFF`). Not "the
kernel printed the right number" — the kernel's report is evidence, the memory dump is proof. Every
milestone below therefore names **what is dumped**, **what it is compared against**, and **a negative
control that must fail**.

Dependencies: MEM-1 → MEM-2 → MEM-3; MEM-4 and MEM-6 are independent of all of them; MEM-5 is
independent but MEM-4 wants it eventually.

---

### MEM-1 — A second ring-3 region exists, and nothing is in it

Split `vmProgEnd` from `vmUserEnd` (§1.3). Install N window page tables per process. Nothing maps
anything above `0x10200000` yet.

**Binary:**
1. The process's page directory, dumped out of guest physical memory, has present entries at **exactly**
   `[128, 128+N)` and at no other index from 64 to 511 — the m10 loop at `run.sh:1152–1156` inverted
   rather than deleted. Each entry: present, U/S, RW, not NX, not huge, and pointing at a **distinct**
   frame.
2. **All N page tables are dumped in full — N × 4096 bytes — and required to be entirely zero**, word
   for word. This is the m7 bit-for-bit comparison applied to a structure whose correct value is
   known exactly.
3. The allocator's free count before and after the process's whole life is **identical to the frame**,
   and `procSpaceFree`'s returned count equals N + 3.
4. **All twenty existing harnesses pass byte-for-byte**, `ELF WINDOW PAGES 00000200` unchanged, all 47
   golden window addresses unchanged. This is the criterion that proves §1.3's claim rather than
   asserting it.

**Negative controls (each must fail, and the harness must require the failure):**
* the `vmProgLeafSlot` table-selection bug of §1.2(b) — a build that keeps `& 511` must map a page at
  `0x10400000` into table 0 and be caught by (1) or by a leaf dumped at the wrong table;
* a build with `procSpaceBuild`'s PD-clear loop shortened to one entry must show entry 129 inheriting
  the previous process's page table. (Note that today's single-entry version of that clear is
  **unfalsifiable** — GAP-0100 records that a kernel with it deleted passes all of `m11-proc`. With
  N entries and two live processes it becomes falsifiable, which closes GAP-0100 as a side effect.)

---

### MEM-2 — A program can ask for a region and be told where it is

Syscalls 11/12, `vmap`/`vunmap`, into MEM-1's region. RW+NX only.

**Binary:**
1. A program asks for 1, 2, 511, **513** and `vmUserPages + 1` pages. The first four succeed; the
   fifth is refused by its own value. **513 is the load-bearing case**: it must be mapped across two
   page tables, and both are dumped and checked.
2. Every leaf of every successful request is dumped out of guest memory and is present + user +
   writable + **NX** at exactly the derived virtual address, with pairwise-distinct physical frames.
3. Every page reads as **zero** before the program writes it — the program reports the count of
   non-zero words and the harness requires 0 — and the frame is dumped at its **physical** address
   after the program writes a signature derived from its own `.rodata`.
4. An `exec`-flagged request is refused with its own code. A request while the allocator is drained is
   refused rather than faulting.
5. Free count identical to the frame across the whole session; `pmmMetaErrors` zero.

**Negative control:** the same binary stopped two instructions earlier — m12-heap's technique — shows
**not one page** mapped above `0x10200000`, and the after-expectation must fail against that dump.

---

### MEM-3 — Two processes, one frame, and the frame outlives the first to die

The shared bit-plane, the count table, and the one branch in `freeFrame` (§2.2–2.4).

**Binary:**
1. A creates a region and writes a signature; B maps it and reads the signature back. Both address
   spaces are dumped and the leaf for that VA in each points at **the same** physical frame.
2. A exits. **The 4096-byte frame bitmap is dumped out of guest memory and compared bit-for-bit
   against a derivation in which that frame is still USED** — the m7 comparison, with the whole point
   of the milestone in one bit. The frame's contents at its physical address are unchanged.
3. B writes a second signature — after A is gone — and the harness reads it at the physical frame.
4. B exits. The bitmap is dumped again and now matches a derivation in which the frame is free, and
   the free count equals the pre-session baseline exactly.
5. `pmmMetaErrors` is **zero for the entire session** — in particular no `pmmFreeDouble` was recorded,
   which is what proves the fix prevented the first free rather than merely surviving it.
6. `m11-proc/derive.py:check_isolation` inverted for exactly one address (§2.6): these two spaces
   share exactly one page, at exactly this VA, on exactly this frame, and every other commonly-mapped
   address is on different frames.
7. `frames refill` still completes and the whole suite's timing is unchanged — the bit-plane's
   O(1) claim, measured (§2.4).

**Negative control, and it is the milestone:** the same session on a build **without** the `freeFrame`
branch must show, in the dump taken at step 2, the frame marked FREE while B still maps it — and then
`frames test` must hand that exact frame out again. The harness must require that control to fail the
step-2 assertion. `display-protocol.md` §6 D8 makes the same point: *that control is the whole point of
the milestone.*

---

### MEM-4 — A kernel allocator with a reconstructable free list

`kmalloc`/`kfree` per §3.2, plus a `kmem` shell command that prints every arena and every block.

**Binary:**
1. A typed sequence of allocations and frees — sizes chosen to force a split, a forward coalesce, a
   backward coalesce and an arena release — and the harness **replays the same sequence against its
   own model** and predicts every returned address. Every address matches. This is m10's "derive the
   expectation from the input, not from a memory of what the code once did".
2. **Every arena frame is dumped out of guest physical memory and the entire free list is
   reconstructed independently, header word by header word**, and required to match the model: block
   sizes, in-use bits, link order, and that the blocks exactly tile each arena with no gap and no
   overlap. This is the m7 bit-for-bit comparison applied to a structure the harness can compute.
3. Every returned address is 16-aligned — asserted from the printed addresses **and** from the
   reconstruction, because a printer and a data structure can disagree.
4. After the last `kfree`, every arena frame is returned and the PMM free count equals the baseline
   **to the frame**.
5. A request above `kmallocMax`, a `kfree` of an address never allocated, a `kfree` of an
   already-freed address, and a `kmalloc` while the allocator is drained: four distinct refusal values,
   all four reached by a real boot.
6. `.bss` grows by exactly the new block, the block is **last** in `.bss`, and every earlier
   harness's accounting number is unchanged after subtracting it — the M14/M15/M16/M19 convention.
7. `verify-freestanding.sh` clean; in particular no `dc_alloc`.

**Negative control:** a build with coalescing removed must satisfy (1) and (3) and **fail** (2) and (4)
— which is the same shape as m13's `free()`-disabled second build, and proves the reconstruction is
doing work the address predictions are not.

---

### MEM-5 — The kernel has virtual address space

PDPT entry 1, established in `vmInit` before any process exists (§3.5).

**Binary:**
1. 512 frames are allocated, **deliberately non-adjacent** (allocate 1024 and free every other one),
   and mapped into one contiguous 2 MiB kernel virtual range.
2. All 512 leaves are dumped and required present + writable + **NX** + **supervisor**, with
   pairwise-distinct physical frames that are **provably not ascending** — which is what proves the
   scatter rather than accidentally testing a contiguous run.
3. A per-page signature is written through the **virtual** address and read back at each page's
   **physical** address out of guest memory. Both directions, because one direction is consistent with
   an identity map that happens to line up.
4. The range is unmapped, the frames freed, and the free count returns to baseline to the frame.
5. Every process created afterwards has the entry in its own PDPT — dumped from **two** processes'
   tables and required equal to the kernel's and to each other.

**Negative control:** the entry established *after* a process exists must show that process's PDPT
without it, and a kernel access at that address while running on that process's CR3 must fault. This
control documents §3.5's hazard by executing it.

---

### MEM-6 — The framebuffer's memory type is a fact rather than an unknown

Steps 1 and 2 of §4.3. Step 3 (MTRR programming) and step 4 (on-demand PCI mapping) are separate
milestones, and step 3 is an escalation.

**Binary:** as §4.4 — derived `IA32_PAT` comparison; bit 12 set on exactly the eight BAR entries and
on no other PCI-hole entry, read out of guest memory; the kernel's decoded effective-type report
matching a harness-side derivation from the MSRs the kernel printed; `m5-pci`'s pixel read-back
byte-identical; and the ADR stating that the performance claim is unverified on hardware.

**Negative control:** a build that sets bit 7 instead of bit 12 must be caught by the PD-entry dump
(the entry is no longer a huge page) rather than by a boot failure — the harness must show it catches
it *structurally*, because on a machine where it happens to still boot, nothing else would.

---

### MEM-7 — The window actually grows

Raise `vmUserEnd`, and separately decide whether `heapTop` moves with it (§1.5). Only after MEM-1..3.

**Binary:**
1. Everything MEM-1 asserted, at the new N.
2. If `heapTop` moved: the exhaustion test walks to the new guard page, and **`heapRetNoMem` is
   reached by a real boot on the 32 MiB machine** — replacing `m12-heap`'s structural checks 2f/2g
   with a behavioural one and closing GAP-0108 with evidence instead of a source parse.
3. The harness's own runtime is reported (§1.5) so the cost of the number chosen is on the record.
4. All 47 golden window addresses re-derived rather than hand-edited, and `m1-interrupts`' 544-byte
   golden still a byte-exact prefix of every capture.

---

## 6. What I did not decide, and would rather be told

1. **Does the ring-3 window grow at all, or does the second region (§1.3) settle it permanently?**
   §1.3 is cheaper and I recommend it, but "how big is a program's address space" is the kind of thing
   `display-protocol.md` §1.2 correctly refuses to decide as a side effect, and I am refusing to
   decide it as a side effect of a memory document. The second region is the reversible choice.
2. **Byte-per-frame refcount plane now, or the bit-plane + bounded table first?** I recommend the
   latter and named the migration. If `fork` with COW is on anyone's horizon, the answer flips
   immediately, because COW wants thousands of shared frames and a bounded table is the wrong shape for
   it. Nobody has told me whether `fork` is planned (GAP-0141 lists it as absent).
3. **Is there a target machine other than QEMU?** §4 is worth very different amounts depending on the
   answer: on TCG only, the entire PAT/MTRR section is a correctness-of-form exercise; on real
   hardware it is the largest performance number in the display path.
4. **`vmFineBytes` — does the 4 MiB `.bss` ceiling (§3.1) ever move?** It is the wall the storage-seam
   pattern eventually hits, and moving it disturbs the derived free-frame counts that `m7-frames` and
   `m8-paging` are built on. Worth knowing before somebody proposes a 32 KB refcount plane and a 1 KB
   device cache in the same milestone. Measured headroom at M19 is 2.72 MB, and one full-screen
  backing store would be 1.92 MB of it.

---

## 7. Notes for the coordinator to fold in elsewhere

**I have not touched `known-gaps.md`, `ROADMAP.md` or any source file**, per instruction. These belong
in them:

* **`vm.dart`'s "62 unused page-directory entries" is wrong** and should be corrected to 448 / 447
  (§1.1). `display-protocol.md` §1.2 repeats it and should be corrected with it. The correction makes
  the constraint *looser*, so nothing built on the old number is unsafe — but the number is cited as
  load-bearing in two documents and will be cited again.
* **A GAP entry for the shared-frame hazard**, which `display-protocol.md` §8 already asked for, with
  §2.1's correction: the double-free half is already caught by `pmm.dart:1147–1150`; the dangerous
  half is the window between the two frees. This is true of `pmm.dart` and `proc.dart` today and
  nothing records it.
* **A GAP entry for the 4 MiB `.bss` ceiling** (§3.1). `vm.dart:1257` enforces it, the ADR-0011/0021
  storage-seam pattern trends toward it, and nothing currently states that the two are on a collision
  course. Current headroom: 2.72 MB (kernel.map, M19).
* **GAP-0071 should record that the kernel has never read an MTRR**, so the framebuffer's effective
  memory type is unknown to it, and that the likely-UC case is a *performance* defect in the display
  path rather than the *correctness* defect the entry currently emphasises (§4.1–4.2).
* **GAP-0076 item 1 (no contiguous multi-frame request) is upstream of any NIC driver**, not just of
  huge pages — a DMA ring cannot be built without it (§3.1 case 1, §3.4). It reads today as a
  completeness note; it is a blocker.
* **GAP-0100 (the unfalsifiable PD-clear) closes as a side effect of MEM-1**, and MEM-1's negative
  control is the test that closes it.
* **GAP-0108 (`heapRetNoMem` unreachable) closes as a side effect of MEM-7**, if and only if `heapTop`
  moves — cheaper than the `frames drain` keep-count that entry proposes (§1.5).
* **`ata.dart:221`'s `ataLba28Limit = 0x10000000` is a grep collision with `vmProgBase`** and must not
  be touched by any window change. Worth one line in whichever ADR does the work.
