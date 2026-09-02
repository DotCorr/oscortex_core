# ADR-0044 — MMIO and side-effect-only stores are spelled `Volatile<T>`: the kernel's side of DCDart's device/ordinary pointer split

**Status:** ACCEPTED (on branch `mmio-volatile-migration`, unmerged — the merge is COUPLED to the
`DCDART_PIN.txt` move, see "The coupled step")
**Date:** 2026-08-28
**Answers:** DCDart GAP-0069 ("oscortex_core MUST migrate before it next rebuilds against this
tree"), raised by DCDart ADR-0069
**Numbered 0044:** 0043 is the highest ADR claimed on any branch, in any worktree, and in the
shared checkout's uncommitted tree at assignment time (audited across all fifteen branches and
every physical worktree, including `/private/tmp` demo checkouts).

---

## Context

DCDart ADR-0069 (working tree / branch `neon-round3` @ 7669e77, not yet in this repo's pin) split
the pointer types: `Pointer<T>` is now an ORDINARY pointer — `.value` emits plain `load`/`store`,
and the optimizer may vectorize, reorder, hoist, CSE, coalesce or DELETE accesses exactly as it
may for a C `T*` — and `Volatile<T>` is the DEVICE pointer, whose `.value` emits
`load volatile`/`store volatile`.

Until that split, this kernel was safe by ADR-0041's blanket rule (every `Pointer` access
volatile). After it, two classes of access silently become elidable at -O2 on the next rebuild:

1. **Device memory** — the VGA text cells at 0xB8000 and the linear framebuffer. The store IS the
   operation; nothing reads it back, so it is textbook dead code.
2. **Side-effect-only stores** — accesses whose only purpose is their consequence: fault probes,
   canary writes, memory tests. A harness asserts what they CAUSE, not what they compute.

Class 2 is not hypothetical. It fired before this migration landed: `vmTestRo`'s W^X probe store
(`Pointer<u8>` into `.rodata`) aims at a global LLVM knows is `constant`, which makes the store
undefined behaviour, and the first post-split build DELETED it — `vmtest ro` faulted zero times,
the boot's `VM FAULTS` total dropped from 2 to 1, and the W^X security demonstration silently
proved nothing (measured here on an unmigrated baseline; independently found and fixed on branch
`b1-live-console` as its GAP-0261, commit 8a72cb7). This is DCDart's GAP-0006 defect class in its
purest form: **no error, a plausible transcript, and the only detection is reading the emitted
object.**

## Decision

Every genuinely-MMIO access and every side-effect-only/consequence-asserted access migrates to
`Volatile<T>`; every ordinary-memory access stays `Pointer<T>`. No blanket migration —
over-migrating ordinary walks would re-pay DCDart GAP-0034's optimization cost for no correctness
benefit and would hide which accesses REALLY carry their meaning in the access itself, which is
the information the type exists to record.

### The inventory (every `Pointer<T>` use in `core/kernel/`, classified)

**Migrated (9 functions, 12 access sites, 4 files):**

| site | class | why |
|---|---|---|
| `vga.dart` `vgaPutCellAt` (u16 store) | device register | VGA text cell at 0xB8000 — aperture into adapter VRAM |
| `vga.dart` `vgaBlankAt` (u16 store) | device register | same |
| `vga.dart` `vgaScroll` (u16 load + store) | device register | device reads AND writes; width/count are device-visible |
| `fb.dart` `fbPutPixel` (u32 store) | device register | linear framebuffer pixel (display controller BAR0) |
| `vm.dart` `vmTestRo` (u8 store) | side-effect-only store | the W^X fault probe — store to a known-`constant` global is UB; -O2 deletes it (measured: VM FAULTS 2 → 1) |
| `vm.dart` `vmTestRw` (u64 store + load) | side-effect-only store | the writable control — ordinary, the load is forwarded and the control never touches the page |
| `pmm.dart` `shellFramesTest` (2 × u64 store) | side-effect-only store | RW-test pattern writes, asserted by later read-back |
| `pmm.dart` `shellFramesDrain` (u64 store) | side-effect-only store | mapping probe — "if the map were short, this line would be a page fault" |
| `pmm.dart` `pmmCheckWord` (u64 load) | side-effect-only load | the read-back half both tests share; forwardable when ordinary |

**Ordinary — stays `Pointer<T>` (everything else, per file):**

| file | what its `Pointer` accesses walk |
|---|---|
| `vga.dart` (cursor/M2-phase words), `fb.dart` (state block, glyph reads) | `@bss` state words, `@rodata` tables |
| `uart.dart`, `pci.dart`, `keyboard.dart`, `ata.dart` | `@rodata` tables, RAM buffers and hexdump reads — the DEVICES are port I/O (`Port.inb/outb`, `port_inw/outw/inl/outl`: `asm sideeffect`, DCDart ADR-0029, untouched by the split) |
| `interrupts.dart`, `user.dart` | IDT gates, TSS, isr-stub table, tick counter — RAM consumed by the CPU around opaque `@extern` boundaries (`idt_load`, `tick_count`, …) |
| `vm.dart` (page-table walks) | RAM consumed by the MMU, always flushed via `@extern` `tlb_invlpg`/CR3 writes |
| `pmm.dart` (bitmap/ledger), `heap`, `proc`, `elf`, `fat`, `file`, `chan`, `ioctl`, `args`, `shell`, `multiboot` | bitmaps, ledgers, buffers, tables, multiboot info — plain RAM whose values are read on real paths |

Two classifications that deserve their reasoning stated:

- **IDT/page tables/tick counter are NOT migrated.** They are RAM read by an asynchronous consumer
  (CPU/MMU/IRQ handler), but every access is ordered by an opaque `@extern` call boundary which
  the optimizer can neither elide nor reorder across; `kmain.dart`'s tick-wait comment has
  recorded this discipline since M1. Migrating them would blur the line the type draws.
- **User-frame builders (args/elf/user copies) are NOT migrated.** Their stores escape into memory
  a later opaque `@extern` call (`enter_user`, `user_return`) hands to ring 3; LLVM must assume
  that call reads them, so they cannot be deleted.

## Verification — the access itself, per site, not "it compiles"

`core/scripts/verify-mmio-volatile.sh` (new; runnable standalone by the kernel owner; the
assertion pattern of DCDart's `core/tests/conformance/volatile/run.sh` applied to this kernel's
real sites):

1. **IR, per site:** emits the kernel's own IR through dcc's lowering and asserts exact volatile
   op counts per function (e.g. exactly 1 `store volatile i16` in `vgaPutCellAt`, exactly 1
   `store volatile i8` in `vmTestRo`, 2 `store volatile i64` in `shellFramesTest`, …).
2. **The exhaustive inventory:** those nine functions are the ONLY functions in the module
   containing any volatile operation — every ordinary `Pointer` walk emits ZERO volatile ops
   (ADR-0069's negative half, asserted by exhaustion, both directions: a missing function is a
   demoted access, an extra one is an unreviewed new site).
3. **Object level, at the exact flags dcc ships** (`-O2 -mno-red-zone -mgeneral-regs-only
   -ffreestanding …`), on the probe object AND on `build/kmain.o` (the shipped path): exact store
   counts and widths for straight-line sites; width-purity (no wider-than-16-bit access — 
   coalescing is the observable theft) plus loop residency for `vgaScroll`/`vgaClear`; the 0xFF
   probe store present in `vmTestRo`; genuine store+load in `vmTestRw`; pattern/touch stores and
   read-back load in the pmm tests; and the port-I/O polls (`uartPutc` THRE always; B1's
   `shellSerialIrq` drain poll and D1's `mouseWaitInput`/`mouseWaitOutput` on trees that have
   them) re-reading their port INSIDE their loops (backward-branch check).
4. **Negative control, every run:** strips `volatile` from the emitted IR, recompiles at -O2, and
   REQUIRES the width detector to fail (`vgaClear`'s adjacent cell stores coalesce into `movq`).
   A check never seen to fail is indistinguishable from one that cannot; if the optimizer stops
   exploiting the missing keyword, the control fails loudly and the detector must be redesigned.

Honest limit, so nobody over-reads a pass: for the straight-line DEVICE sites the store survives
-O2 even unprotected (a store through a computed address is not provably dead), so their negative
control bites at the IR level; the codegen counts guard a future optimizer. For `vmTestRo` the
codegen-level deletion is real today and the measured `VM FAULTS 2 → 1` regression is its negative
control. Same 4a/4b split DCDart's harness documents.

The script also validates end-to-end falsifiability: run on an UNMIGRATED tree it fails at step 1
with a per-site message (verified against `milestones-m1-m6` @ 45b9c7a built on the post-split
toolchain).

## The coupled step (for the owner session to sequence)

`DCDART_PIN.txt` still says 38f0b06, which predates the split; **this branch does not compile
against the pin** (no `Volatile<T>` in that prelude) and is not supposed to. The pin move to a
post-ADR-0069 DCDart (`neon-round3` @ 7669e77 — verified: its tree contains ADR-0069's split,
`Volatile<T>` in the prelude, and 4e1d571's freestanding no-FP default as an ancestor) and the
merge of this branch are ONE step: merging this first breaks the build against the pin; moving
the pin first makes every un-migrated MMIO/probe site unsafe-under-optimization.

## Consequences

- **Golden impact** (none regenerated here, per the migration's ground rules — see GAP-0263):
  `m8-paging`/`m9-ring3`/`m10-elf` embed the kernel's own section boundaries (`VM SECT` prints
  `kernel_text_end` etc.) and fail on ANY post-split build, migrated or not; this migration moves
  `.text` a further +0x2A0..0x380 (volatile forbids coalescing the VGA loops' cell stores). Their
  re-record belongs to the pin-move/merge commit. All other harnesses pass byte-exact
  (22 behavioural harnesses green on the migrated main-line tree; the remaining two reds are a
  DCDart `@rodata` constant-merging regression — `argsStrSp`/`fbStrBy` symbols vanish, b1's
  GAP-0262 — being fixed on the DCDart side, unrelated to this migration).
- The kernel's `.text` grows ~672 bytes on the main line: one `movw` per cell in the VGA
  clear/scroll loops instead of merged wide stores. The price of the guarantee, confined to the
  migrated functions.
- `core/scripts/verify-mmio-volatile.sh` should join the checks run on every kernel change, and
  any future MMIO consumer (E1000 BARs, APIC registers) must be added to its inventory — the
  inventory check fails on any new volatile emitter until it is named, which is the mechanism
  that keeps the classification honest.
- Branch `b1-live-console`'s own `vmTestRo` fix (GAP-0261 / 8a72cb7) is subsumed unchanged: this
  branch's sibling (`b1-live-console-volatile`) builds on it and adds the same remaining sites as
  everywhere else.
