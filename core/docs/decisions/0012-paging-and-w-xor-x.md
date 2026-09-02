# ADR-0012 — Real paging, real permissions: W^X enforced by the hardware, and the bit that made it true

**Status:** accepted, implemented, verified (`core/tests/conformance/m8-paging/run.sh`)
**Date:** 2026-08-21
**Closes:** GAP-0050 for the kernel's own image (see §9 for what remains). **Narrows:** GAP-0079.
**Depends on:** ADR-0011 (the frame allocator — page tables have to come from somewhere).

---

## 0. What was wrong, stated as the fact that made it wrong

`core/link/kernel.ld` forced every section into ONE `PT_LOAD` with `FLAGS(7)`, and `core/boot/boot.S`
identity-mapped 128MiB with 2MiB pages that were present, writable, and nothing else:

```
LOAD  0x00100000  FileSiz 0x02ae2  MemSiz 0x0c008  Flg RWE
  Segment Sections: .multiboot .text .rodata .data .bss
```

So `.text` was writable and `.rodata` was writable, and the consequence was worse than a fault: a
store through a `Pointer` derived from a constant global **succeeded silently**. DCDart's `DCPointer`
carries no const-ness, `Store` accepts any `DCPointer`, and DC-IR has no verifier — so there was no
compile-time check, and on this target there was no runtime check either. GAP-0079 sharpened it when
LLVM lowered `pmmFreeStatus`'s dense dispatch into a jump table in `.rodata`: the kernel acquired
data whose *integrity is control-flow integrity*, sitting on a writable page.

GAP-0050 also said, in as many words, what not to do:

> It should NOT be started as a link-script-only change — separate segments without page-table
> enforcement would look like protection while providing none, which is worse than the honest single
> RWX segment we have now.

That instruction is the shape of this ADR. There are two halves and the second one is the real one.

---

## 1. What was built

| Piece | Where | What |
|---|---|---|
| three segments | `core/link/kernel.ld` | `.multiboot`+`.text` R E, `.rodata` R, `.data`+`.bss` RW, 4KiB-aligned |
| six section symbols | `core/link/kernel.ld` | `__kernel_start`, `__text_end`, `__rodata_start`, `__rodata_end`, `__data_start`, `__kernel_end` |
| `EFER.NXE`, `CR0.WP` | `core/boot/boot.S` | probed and set at boot, beside `LME` and `PG` |
| the page tables | `core/kernel/vm.dart` | a 4-level table built in DCDart from six `allocFrame()` frames |
| the control registers | `core/boot/isr.S` | `cr0_read`, `cr2_read`, `cr3_read`, `paging_install` |
| the fetch probes | `core/boot/isr.S` | `vm_exec_probe`, `vm_exec_ok` |
| the page-fault report | `core/kernel/vm.dart` | CR2 and a decoded error code, on the M4 recovery path |
| 128 bytes of state | `core/boot/kdata.S` | `vm_store`, one symbol, one accessor, **one** call site |

Two commands: `vm` (the address space, walked out of the live tables) and `vmtest ro|nx|rw|x` (two
deliberate faults and their two controls).

The map, all identity:

| range | pages | permissions | why |
|---|---|---|---|
| `[0, 1MiB)` | 4KiB | RW, NX | VGA text at `0xB8000`, the IVT, the BDA |
| `[__kernel_start, __rodata_start)` | 4KiB | **R, X** | `.multiboot` + `.text` |
| `[__rodata_start, __data_start)` | 4KiB | **R, NX** | `.rodata` |
| `[__data_start, 4MiB)` | 4KiB | RW, NX | `.data`, `.bss`, and the RAM above the image |
| `[4MiB, 128MiB)` | 2MiB | RW, NX | the rest of what the allocator manages |
| `[3GiB, 4GiB)` | 2MiB | RW, NX | the PC's PCI hole, where the framebuffer BAR lands |
| `[128MiB, 1GiB)` | — | **not present** | see §5 |

---

## 2. CR0.WP — the bit that made the difference between this milestone and a decoration

**A page-table entry with RW=0 does not stop a write from ring 0 unless `CR0.WP` is set.** Its
power-on state is clear, and this kernel had never set it.

This was not looked up and then guarded against. It was *measured*. With the three-segment image
linked, the new tables built and installed, and `vm` reporting

```
VM RODATA 0000000000113000 0000000000115000 P 00000002 W 00 X 00
```

— every `.rodata` page's entry saying not-writable, read back by walking the live tables — `vmtest ro`
printed:

```
VM TEST RO SURVIVED -- THE WRITE LANDED
```

and the next `vm` showed the canary as `EFBEADDEEFBEADDE`. The entries were right and the CPU was
ignoring them.

**The shape of that near-miss is the reason `vmtest` has four sub-commands and not two.** `vmtest nx`
faulted correctly in the same session, because NX is enforced whatever WP says. A milestone that had
tested only the NX half would have shipped "W^X works" with the W half completely absent, and every
piece of evidence it produced would have been true.

`CR0.WP` is now set in `boot.S` alongside `PG`, and `vm` prints it back **off the register** through
`cr0_read()` rather than asserting it. `m8-paging/run.sh` checks it three ways: the instruction is in
`boot.S`, the bit is set in QEMU's own `info registers`, and the write faults.

Recorded as GAP-0080 — not as a bug that was fixed, but as the class of bug this kind of work
produces: *the enforcement mechanism and the permission bits are two different things, and only one
of them is visible in a page-table dump.*

---

## 3. The storage seam, one notch tighter than M7's

DCDart still has no mutable static data (GAP-0053), so this subsystem's state is assembly-donated
`.bss`, exactly as the allocator's is. ADR-0011 §0 answered that objection by SHAPE rather than by
waiting, and this uses the same shape with one fewer function: **128 bytes in one symbol (`vm_store`)
behind one accessor (`vm_store_addr`) reached through one function (`vmMetaBase`).**

Migration, when DCDart grows mutable statics: declare one static block, rewrite one function, delete
`vm_store` and `vm_store_addr`. `m8-paging/run.sh` counts the call site — exactly one in `vm.dart`,
zero anywhere else in `core/kernel/`.

Donated `.bss` goes 5096 → **5224**. Every earlier harness still asserts its own milestone's number
by subtracting the blocks that came after it, so no earlier claim is diluted: m5-pci and m6-disk still
assert 424 excluding `pmm_store` and `vm_store`; m7-frames still asserts 5096 excluding `vm_store`.
The same discipline was applied to the extern count, which m5/m6/m7 now check by subtracting M8's
twelve **by name** rather than by bumping a total.

---

## 4. The page tables are the first kernel memory outside the kernel image

Before M8, everything the kernel could not afford to lose was inside `[__kernel_start, __kernel_end)`
— which is precisely what `pmmAllocatable` reserves. The six page-table frames are not: they come out
of `allocFrame()`.

So `pmmAllocatable` gained one clause, `vmHoldsFrame(f)`, and three things follow that are each
tested:

* `free <page-table-frame>` is refused with `ERR RESERVED` instead of handing the running address
  space back to the allocator;
* `frames refill` — which frees everything that was ever allocatable — skips them, so the
  drain/refill cycle cannot destroy the mapping;
* `frames`' BASELINE is **re-taken** after the tables are built (`pmmRebaseline()`), so
  `FREE == BASELINE` still means "nothing is leaked" rather than "six frames are missing and nobody
  counted them".

The predicate is asked of `vm.dart` rather than answered from a word in the allocator's metadata
block, because the set of frames is VM state and belongs behind the VM's own seam.

**Boot D of the harness is what proves the clause rather than its existence:** it drains every free
frame, runs `frames test` (which *writes* an address-derived value into 64 frames — on a live PML4
that is an immediate triple fault), refills, tries `free <PML4>` and requires `ERR RESERVED`, and then
dumps the tables out of guest memory and walks them again.

**The knock-on to M7 is real and it is derived, not patched.** `m7-frames/derive.py` now reserves the
`VM_FRAMES` lowest still-free frames as a sixth rule, so the free count, the first `alloc`'s address,
the drain's `SUM`/`XOR`/`LOW`, the refill's `GAVE` and the bit-for-bit bitmap comparison all follow
automatically. `m8-paging/run.sh` asserts that `derive.py`'s `VM_FRAMES` equals `vm.dart`'s
`vmFrameCount`, so the two cannot drift.

---

## 5. Decisions inside the map, and why each one

**Six frames, and the number is FIXED.** PML4, PDPT, the page directory for `[0, 1GiB)`, two page
tables covering `[0, 4MiB)`, and the page directory for `[3GiB, 4GiB)`. It is fixed because the 4MiB
fine window and the 128MiB bound are both fixed — and it has to be fixed for the harnesses to
*derive* the allocator's post-boot free count rather than be told it. `vmInit` refuses (`TOOBIG`) if
the image ever outgrows 4MiB, and `m8-paging/run.sh` checks the image against that bound at build
time so the refusal is a diagnostic rather than a `READY 0` discovered three boots later.

**Interior entries are permissive; the leaf decides.** A page's effective permission is the AND of
every level above it, so an NX bit on `PML4[0]` would make `.text` non-executable no matter what its
own entry said. The one exception is `PDPT[3]`: nothing in the PCI hole is ever executed, and a
whole-gigabyte veto costs one bit. `derive.py` walks all four levels and ANDs them, so a table whose
interior entries silently overrode its leaves would fail rather than pass.

**`[128MiB, 1GiB)` is deliberately left UNMAPPED**, where the bootstrap tables mapped it. The
allocator manages 128MiB and a frame it cannot address is not a frame it can hand out (ADR-0011 §2);
an address above the bound is now a page fault that says so, rather than a silent write into RAM
nothing tracks. The harness spot-checks four addresses in that range and fails if any is mapped.

**Page 0 is mapped**, and that is a deliberate non-decision. Leaving it unmapped would be a free
null-pointer trap, but the brief for this unit was to keep the identity mapping the kernel currently
depends on, and a guard page is a separate claim with its own test. GAP-0081 item 6.

**The bootstrap tables are left intact.** They cost 16KiB of `.bss` that is never reused, and in
exchange the machine has a known-good table to fall back on: **every refusal in `vmInit` leaves a
running kernel** on the tables `boot.S` built. Freeing them would also require them to stop being
inside `[__kernel_start, __kernel_end)`, i.e. a change to M7, for 16KiB.

**`vmSelfCheck` walks the new tables before `CR3` is written**, for every address the kernel is
standing on: both ends of `.text`, both ends of `.rodata`, `.data`, the last byte of `.bss` (the boot
stack and the IDT are between them), both donated blocks by their own addresses, `0xB8000`, all six
page-table frames, the top managed frame and the PCI base. `mov %rdi,%cr3` is not recoverable — a
table that does not map the next instruction triple-faults with no output at all — so the check has
to happen before, because there is no "after" to add a diagnostic to.

**NX is probed, not assumed.** `EFER.NXE` is only architecturally present if CPUID leaf `0x80000001`
EDX bit 20 says so, and setting a reserved EFER bit raises #GP — before any IDT exists, i.e. a triple
fault. `boot.S` asks, records the answer in `nx_flag`, and `vm.dart` reads it through `nx_enabled()`:
with no NX, no entry carries bit 63 (where it would be a *reserved-bit violation* rather than a
protection), `.rodata` is read-only but executable, and `vm` prints `NX 0` rather than pretending.

---

## 6. How this is verified, and why the golden cannot launder a broken map

`m8-paging/run.sh`: 12 structural checks, `verify-freestanding.sh` clean, **four** QEMU boots.

**The permissions are never taken from the kernel's own report.** They are read out of guest physical
memory with the monitor, at the CR3 **QEMU** reports through `info registers`, and walked by
`derive.py`'s own independent implementation of the x86-64 four-level walk — which also checks that
every page is *identity*-mapped, not merely present. `vm`'s eighteen region lines (six per report,
three reports) are then required to agree with that walk, page count and all/any permission pair.
Two implementations, same bytes, same answer.

**The proof is a fault, and the controls come first.** In the session, `vmtest rw` (a `u64` store to a
writable page) and `vmtest x` (an indirect call into `.text`) run **before** `vmtest ro` and
`vmtest nx`, so a kernel in which everything faulted would fail at the control rather than look like
a success. The harness also asserts that no fault is reported anywhere before the first deliberate
one.

**The canary is checked three times.** Not "a fault was reported" — the eight bytes `C34F534352575821`
are printed by every `vm` report and must be unchanged after the write attempt. Its first byte is
`0xC3` (`ret`) on purpose: on a kernel where `.rodata` were executable, `vmtest nx` returns
harmlessly and prints `SURVIVED`, rather than executing arbitrary bytes on the very machine whose
protection has just been shown not to work. That same byte shows up as ` OP C34F` in the fault line,
which is a second, independent statement of where the fetch was aimed.

**The harness was checked against deliberately broken kernels, not only against the working one.**
Two mutations were built in the sandbox mirror (never in the repo) and run:

* **`CR0.WP` cleared** in `boot.S`. The structural check caught it before booting; with that check
  disabled as well, the golden caught it; and with the golden **regenerated from the broken kernel** —
  the exact scenario "regenerating the golden cannot make it pass" claims to cover — the derived
  checks still failed, naming the cause: *"CR0.WP is CLEAR (CR0=80000011). A read-only page-table
  entry does not stop a ring-0 write without it, so every W=0 below is decorative."*
* **`.rodata` mapped writable** in `vmPageFlags`. This one never reached the harness's page walk,
  because `vmSelfCheck` refused to install the map: the kernel came up on `boot.S`'s bootstrap tables
  with `READY 0 STATUS 00000007`, and the harness reported both the refusal and the bootstrap tables'
  permissions. That is the designed degradation working — a wrong map is a refusal with a reason, not
  a triple fault.

**Three negative controls, two of which are boots:**

* **`-cpu qemu64,nx=off`** — a CPU with no NX. `vm` must report `NX 0` and `.rodata` as executable *in
  the live tables*; `vmtest nx` must **SURVIVE**; and `vmtest ro` must **still fault with error code
  3**. This is what makes the fetch fault in the main session attributable to the NX bit and to
  nothing else, and it is what proves write protection and NX are independent rather than entangled.
  It also requires `READY 1`: losing NX should cost NX, not the whole address space.
* **`-m 32M`** — a different machine, a different memory map, and the address space must still come up
  W^X. The tables are built at runtime out of whatever the allocator gives them; this is the boot that
  says so.
* **the drain/refill boot** (§4), which is a control on the allocator rather than on the CPU.

---

## 7. `DCDART_PIN.txt` did not move

`e3cfe18`, unchanged from M7. Nothing in this milestone needed a language capability that pin does not
have. All nine pre-existing harnesses were re-run against it, **with the kernel unchanged**, before any
M8 code was written — 9/9 — using an isolated clone of DCDart at that commit mirrored beside a copy of
this repo, because GAP-0003 fixes the sibling layout. That is ADR-0011 §7's method, reused; the one
addition is that the clone needs `core/frontend/` copied in from the shared checkout, because the
vendored dart-lang/sdk sparse clone under it is `.gitignore`d and cannot be fetched (GAP-0084).

Two constants are spelled out rather than computed (`vmPageMask`, and the shift/size pairs) for
GAP-0077's reason — `dcc` at this pin refuses a `u64` literal built from a constant expression. The
cost is small and the harness multiplies every pair out against the others, so a drift fails a check
rather than mapping the wrong memory.

---

## 8. Rejected alternatives

**Split the segments in the link script and stop there.** Rejected because GAP-0050 said so, and it
was right: this milestone's own near-miss (§2) is the proof. Correct-looking `PT_LOAD` flags and
correct-looking page-table entries coexisted with a `.rodata` write that landed.

**Build the tables in `boot.S`.** Rejected. CLAUDE.md rule 4 puts in the boot stub what must run
before a `@bare` DCDart function can be called at all; per-section permissions are not that, they
need the linker's symbols and the frame allocator, and the point of M7 was to make this expressible in
DCDart. What did stay in assembly is exactly what DCDart cannot do: `mov %cr3`, `mov %cr2`, `cpuid`,
and an indirect call.

**Put the page tables in `.bss` like the bootstrap ones.** Rejected: the brief was to take page-table
management off static tables and onto the allocator, and it is also the honest design — an address
space is dynamic state, and `.bss` tables cannot grow.

**Give the VM's frame list a word in the allocator's metadata block** (which ADR-0011 §0 explicitly
invites for new allocator state). Rejected: the set of frames the page tables occupy is *VM* state,
not allocator state, and putting it in `pmm_store` would have moved M7's `META`/`STORE`/`LEDGER`
numbers and its golden for a reason that says nothing about the allocator. `pmmAllocatable` asks
`vm.dart` instead — one call, six word comparisons.

**Relax `m1-interrupts`' `.rodata` abutment check.** Writing the canary through a `Pointer<u64>` gave
that one table 8-byte alignment and opened a five-byte hole in front of it, failing ADR-0040's
"elements only, no header" assertion. The check was **not** relaxed; the deliberate write was made
byte-wide instead, which is also the more faithful statement of the hazard. An assertion a milestone
weakens in order to pass is not an assertion. GAP-0082 records the toolchain behaviour so the next
milestone that needs a wide access to a `@rodata` table changes the check deliberately.

**Unmap page 0 as a null-pointer trap.** Deferred, not rejected — see §5 and GAP-0081 item 6.

---

## 9. What this closes, and what it does not

**Closes GAP-0050 for the kernel's own image**, and closes it with the evidence GAP-0050 asked for:
`.text` is not writable, `.rodata` is neither writable nor executable, `.data`/`.bss` are not
executable, the hardware enforces all of it, and a deliberate violation of each is a reported,
survivable page fault.

**What remains, and none of it is in scope here** (GAP-0081):

* **No user/supervisor separation.** Every page is supervisor (U/S = 0). There is no ring 3, no TSS to
  enter one from, and no syscall path — so the `USER`/`SUPER` field in the fault report has only ever
  printed one of its two values.
* **No per-process address spaces.** There is one PML4 and it is the kernel's. Processes, a scheduler
  and a second `CR3` are all still absent.
* **No TLB shootdown, and no `invlpg`.** Nothing changes a mapping after the one switch, and there is
  one CPU. Writing `CR3` flushes every non-global entry (PGE is never enabled), which is why the
  install needs no invalidation at all — and is exactly why the *next* thing that edits a live mapping
  will need both.
* **No demand paging, no swap, no copy-on-write, no guard page, no null-page trap.**
* **`.rodata` is protected against the kernel's own stray pointers. It is not protected against a
  DCDart type error**, because DCDart still has no const-ness on `Pointer` and DC-IR still has no
  verifier. A store into `.rodata` is now a *fault* instead of silent corruption, which is the whole
  difference this milestone buys; catching it at compile time is DCDart's side of the same problem.

**Narrows GAP-0079.** The jump table LLVM put in `.rodata` is still there and is still an indirect
branch through memory — but that memory is now read-only and non-executable, so the "data whose
integrity is control-flow integrity" is on a page the CPU will not let the kernel write. The structural
half of GAP-0079 (the abutment assertion) is untouched and, per §8, was defended rather than relaxed.

**Partially unblocks GAP-0076 item 3** ("no virtual memory. Nothing maps anything at runtime").
Something maps something at runtime now — once, at boot, for the kernel's own image. What is still
absent is *changing* a mapping, which is the API (`map(va, pa, flags)`, `unmap(va)`) that everything
after this needs and that this milestone deliberately did not build: there is no caller for it yet,
and the first one will bring the `invlpg` question with it.
