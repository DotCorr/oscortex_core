# ADR-0021 — Mutable statics: the end of donated `.bss`. **13952 of 14048 bytes left `core/boot/kdata.S` and NOTHING OUTSIDE THE STORAGE SEAMS CHANGED.**

**Status:** accepted, implemented, verified (all eighteen harnesses in
`core/tests/conformance/`, against `DCDART_PIN.txt` = `8713298`)
**Date:** 2026-08-23
**Supersedes:** nothing. **Closes:** GAP-0053. **Opens:** GAP-0134, GAP-0135, GAP-0136, GAP-0137.
**Depends on:** DCDart ADR-0051 (`@bss` mutable statics).

---

## 0. The one number this milestone exists to produce

Eleven milestones (M2 through M16) were built on a workaround: DCDart had no mutable static data of
any kind, so every byte of kernel state that had to outlive a call was hand-written `.bss` in
`core/boot/kdata.S`, reached from DCDart through a `u64` address returned by an `@extern` accessor.
The bet, first stated in ADR-0011 §0 and repeated in ADR-0012 §3, ADR-0013, ADR-0015 §1, ADR-0018 and
ADR-0019 §8, was:

> Confine the workaround to **one block, one accessor, a named STORAGE SEAM of two to four
> functions**, and enforce that confinement with a harness that COUNTS the call sites. Then the day
> DCDart grows mutable statics, the migration is a rewrite of the seam functions and **nothing else**.

The bet is now settled. Across **ten source files, sixteen blocks and 13952 bytes**:

| | |
|---|---|
| Bytes moved out of `kdata.S` | **13952** of 14048 (13944 of storage + 8 of alignment padding) |
| Bytes deliberately left in `kdata.S` | **96** (§4) |
| Seam functions rewritten | **27** |
| `@extern` accessor declarations deleted | **16** |
| Declared externs on `kmain.o` | **60 → 44** |
| **Lines changed outside a storage seam** | **ZERO** |

Not one line of the frame allocator, the page-table walker, the ELF loader, the scheduler, the FAT
driver, the descriptor table, the line editor or the framebuffer console changed. Not one shell
command, not one `@rodata` table, not one syscall number. The eighteen harnesses' **behavioural**
goldens are byte-for-byte what they were at `cf2737f` except where they print an address — plus one
arithmetic consequence: the image is 8192 bytes bigger, so the frame allocator reserves two more
frames (§5a). `m1-interrupts`' 544-byte serial golden is byte-for-byte unchanged, addresses included.

That last row is the whole result. It is reported as a number because a design claim that cannot
produce a number is a preference.

---

## 1. What was built

`@bss` blocks declared in the DCDart file that owns them, in place of assembly-donated `.bss`:

```dart
@bss
final Bss procStore = const Bss(bytes: procStoreBytes, align: 16);

@bare
u64 procHeadBase() {
  return Bss.addressOf(procStore);
}
```

`Bss.addressOf(x)` composed with `Pointer<T>.fromAddress` is the same surface `Rodata.addressOf` has
had since ADR-0004, which is why no reader or writer of the state had to change: every one of them
already went through a seam function returning a `u64`.

| Owner | Block(s) | Bytes | Seam functions | Outside the seam |
|---|---|---|---|---|
| `pmm.dart` | `pmmStore` | 4672 | 3 — `pmmBitmapBase`, `pmmMetaBase`, `pmmLedgerBase` | 0 |
| `proc.dart` | `procStore` (`align: 16`) | 4160 | 3 — `procHeadBase`, `procTableBase`, `procFxBase` | 0 |
| `file.dart` | `fileStore` | 2560 | 4 — `fileMetaBase`, `fileTableBase`, `fileBufBase`, `fileSecBase` | 0 |
| `fat.dart` | `fatStore` | 1824 | 4 — `fatMetaBase`, `fatChainBase`, `fatSectorBase`, `fatNameBase` | 0 |
| `shell.dart` | `shellLineBuf`, `shellLenWord`, `shellStateWord`, `shellMbinfoWord`, `kbdPrefixWord`, `faultCountWord` | 296 | 6 — one per word, keeping the accessor NAMES (§3) | 0 |
| `elf.dart` | `elfStore` | 128 | 1 — `elfMetaBase` | 0 |
| `user.dart` | `userStore` | 128 | 1 — `userMetaBase` | 0 |
| `vm.dart` | `vmStore` | 128 | 1 — `vmMetaBase` | 0 |
| `fb.dart` | `fbStateBlock` | 32 | 2 — `fbState`, `fbSetState` | 0 |
| `vga.dart` | `vgaCursorWord`, `m2PhaseWord` | 16 | 2 — `vga_cursor_addr`, `m2_phase_addr` | 0 |
| **total** | **16 blocks** | **13944** | **27** | **0** |

The section is 13952 bytes: 13944 of declared storage plus the 8 bytes of padding `procStore`'s
`align: 16` inserts after `elfStore`. That is the same 8 bytes `.align 16` cost in `kdata.S`, charged
in the same place, which is why every historical total below reproduces exactly.

**The "one accessor and three seam functions" shape the earlier ADRs describe was never uniform.**
`pmm` and `proc` have three; `fat` and `file` have four; `vm`, `user` and `elf` have one; `shell` has
six single-word accessors and `vga` two. What was uniform — and what actually mattered — is that
every one of them is a **named, harness-counted set of functions that is the only thing in the kernel
that knows where the bytes are**. The count varied; the confinement did not, and the confinement is
what made the migration free.

---

## 2. `proc_store` was 16-byte aligned by an assembler directive; `procStore` is 16-byte aligned by a declaration, and that is stronger

`fxsave`/`fxrstor` on an operand that is not 16-byte aligned raise `#GP` — a fault in the middle of a
context switch, on a machine where everything else worked. ADR-0015 §1 made `.align 16` in `kdata.S`
a stated correctness requirement, and `m11-proc/run.sh` proved it by reading `proc_store`'s **linked
address** out of `kernel.elf`'s symbol table and checking it mod 16.

That proof is no longer available and could not simply be kept: **a DCDart `@bss` symbol is emitted
with LOCAL binding**, and `kernel.ld`'s `OUTPUT_FORMAT(elf32-i386)` container keeps no local symbols,
so `kernel.elf`'s symbol table cannot answer the question at all. Dropping the check would have been
the silent way to lose it. It was replaced with one that constrains **more**, in three links:

1. **The declaration says so.** `proc.dart` must literally declare
   `final Bss procStore = const Bss(bytes: procStoreBytes, align: 16);`, grep-asserted. This is
   stronger than the directive it replaces, because DCDart **rejects a non-power-of-two alignment at
   compile time** (its ADR-0051) — `.align 15` in an assembly file would have assembled quietly.
2. **The object agrees.** `procStore`'s offset inside `kmain.o`'s `.bss` is a multiple of 16, **and**
   that section's own alignment is at least 2\*\*4 — which is what makes the offset mean anything
   after linking, and is a claim the old check could not make at all.
3. **The linked image agrees.** The address is read out of `core/build/kernel.map` — the linker's own
   statement of where it placed `kmain.o`'s `.bss` — and checked mod 16, exactly as before, and each
   of the four FXSAVE areas is multiplied out from it exactly as before.

`core/scripts/build-kernel.sh` now passes `-Map core/build/kernel.map` for link 3. That is not a
convenience: it is the only artifact in which a `@bss` block's linked address is stated.

**Which of the three actually kills, disclosed.** Mutation-tested (GAP-0137): (1) and (2) each catch a
dropped `align: 16` on their own; **(3) does not.** Without `align:`, the section's alignment falls to
2\*\*3 so the linker places `kmain.o`'s `.bss` 8 short of a multiple of 16, and `procStore`'s offset
inside it is also 8 short — **the two errors cancel** and the linked address comes out aligned. That
blind spot is inherited: the pre-M17 check *was* (3), read from `kernel.elf`, so M16's version had it
too. (3) is kept because it is the only link that speaks about the linked image, but **(2) is what
makes this sound, and GAP-0137 exists so nobody deletes (2) believing (3) covers it.**

**The IDT did not migrate and needs no `align: 4096` here.** DCDart's ADR-0051 uses
`@bss final Bss idt = const Bss(bytes: 4096, align: 4096);` as its worked example, but in *this*
kernel the IDT is `core/boot/isr.S`'s own `.bss`: `idtr`'s `.quad idt` is resolved by the linker and
`idt_load` executes `lidt idtr(%rip)`. Assembly names it, so §4 applies and it stays. Its 4096-byte
alignment stays an `.align 4096` in `isr.S`, where it always was. The IDT is not part of `kdata.S`'s
14048 bytes and never was.

---

## 3. The accessor names did not change, deliberately

`shell_line_addr()`, `vga_cursor_addr()`, `fault_count_addr()` and their siblings read as C symbols
because they *were* C symbols. They are now ordinary `@bare` DCDart functions returning
`Bss.addressOf(...)`, and they kept their names.

The reason is the same reason this milestone has a "zero" in it. Those six shell accessors and two
vga accessors are called from **sixteen sites across two files** (`shell.dart` and `pmm.dart`). Renaming them would have
made this a sixteen-site change and would have made the "nothing outside the seam changed" claim
unmeasurable — the diff would have been full of exactly the noise the claim is about. A rename is
cosmetic, it is available to anyone who wants it, and it does not belong to the migration whose whole
point was to be small.

---

## 4. What did NOT move, and why it is not a language gap

**96 bytes stay in `core/boot/kdata.S`.** A DCDart `@bss` symbol is LOCAL; assembly in another object
file cannot name a local symbol. So any storage that **assembly itself writes, by name** cannot be a
`@bss` block:

| Symbol | Bytes | Written by |
|---|---|---|
| `cpu_info` | 64 | `cpu_probe` in `isr.S`: `leaq cpu_info(%rip)`, then four `cpuid` leaves stored through it |
| `shell_resume_rsp` | 8 | `shell_run_forever` in `isr.S`, read by `fault_resume` |
| `shell_resume_ok` | 8 | the guard for the word above |
| `user_resume_rsp` | 8 | `enter_user` / `user_return` in `isr.S` |
| `user_resume_ok` | 8 | the guard for the word above |

ADR-0007 and ADR-0013 both predicted, milestones before the language feature existed, that the four
resume words would still be here on the day mutable statics landed. They hold a **stack pointer**,
which DCDart cannot read or write at all, and they are written at fault time with no caller to pass an
address in from. They are assembly-owned forever.

`cpu_info` is the one that *could* move, at the price of changing `cpu_probe`'s signature to take a
destination pointer — a change to an assembly function rather than to a storage seam, which is not
what this milestone was for. **GAP-0134.**

Also deliberately not migrated, for the same rule: `isr.S`'s stub table and IDT, `boot.S`'s
`mb_info_ptr`, `nx_flag`, `sse_flag`, the GDT, the TSS and the three page-table pages the boot path
writes before DCDart runs.

**The residue is therefore not a measure of a missing language feature.** It is the true size of the
DCDart/assembly boundary in this kernel, which is why GAP-0053 closes rather than shrinking.

---

## 5. Eleven harnesses assert donated-`.bss` totals, and every one of them still asserts its own number

The totals were assertions about `kdata.o`'s `.bss` section size. The storage is now split across two
objects, so each of those harnesses computes `DART_BSS + ASM_BSS` — `kmain.o`'s `.bss` plus
`kdata.o`'s — and **reproduces its historical number byte for byte**:

`16` at M2, `304` at M3, `392` at M4, `424` at M5 and M6, `5096` at M7, `5224` at M8, `5368` at M9,
`5496` at M10, `9664` at M11/M12/M13, `11488` at M14, `14048` at M15/M16.

This was a substitution, not a relaxation, and three things make it one:

- **`ASM_BSS` is pinned to exactly 96**, by every harness that reads it. Storage cannot drift back
  into assembly unnoticed, and `m4-fault` and `m9-ring3` additionally assert that the four resume
  words are **defined in `kdata.o`** rather than merely present somewhere — "somewhere" would mean a
  local symbol assembly cannot reach.
- **Symbol sizes are read by their new names** (`pmmStore`, `procStore`, `fatStore`, `fileStore`,
  `elfStore`, `vmStore`, `userStore`, `fbStateBlock`, `shellLineBuf`, …) out of whichever object
  defines them, and the subtract-the-later-milestone's-block arithmetic every harness does is
  unchanged.
- **`m1-interrupts` got strictly stronger.** Its old assertion was "every `OBJECT` symbol `dcc` emits
  is in `.rodata`", which was only true because DCDart could not emit a mutable global. Relaxing it to
  "`OBJECT`s may be anywhere" would have thrown away the property it protected. It now **partitions**:
  every `@rodata` table in `.rodata`, every `@bss` block in `.bss`, nothing anywhere else, **and the
  set of `@bss` symbols in `kmain.o` matches, name for name, the set of `@bss` declarations in
  `core/kernel/*.dart`**. That last half is new and is the strongest of them: an unreferenced `@bss`
  block is dropped by LLVM silently, and this is what catches it.

The declared-extern checks **invert rather than disappear**. Every harness that used to assert
`fat_store_addr` is *present* now asserts each of the sixteen deleted accessors is *absent*, by name.
A count alone can be restored by an unrelated extern; a name cannot.

### 5a. The kernel image grew 8192 bytes, and that is the ONE observable consequence

`.bss` is the same size to the byte — 0x116f0 before and after, because the storage moved rather than
changed. **`.text` grew 6671 bytes** (0x2ca11 → 0x2e420, +2.4%), which after `kernel.ld`'s 4 KiB
group alignment pushes `.rodata`, `.data` and `.bss` up by **two pages** and `__kernel_end` from
`0x1436f0` to `0x1456f0`.

**Why:** an `@extern` accessor is an opaque call. `Bss.addressOf(...)` inside a `@bare` function with
internal linkage is not, so LLVM inlines the seam functions into their callers and materialises the
address there. The eight single-word accessors are 6 bytes each (`lea` + `ret`) and every one of them
is still emitted; the growth is entirely in the callers — `shellExecute` +3484, `pciReportDevice`
+705, `kmain` +667, and a long tail. **This was measured, not assumed:** the *unmigrated* sources at
`cf2737f` were rebuilt against the new pin `8713298` and produced `.text` of 0x2ca11 and
`__kernel_end` of `0x1436f0`, byte-identical to the M16 build. The toolchain bump contributes zero.
Every byte of the growth is the migration, and all of it is inlining.

**What it changes:** the frame allocator reserves the kernel image, so two more frames are reserved —
`PMM FREE 00007E96 → 00007E94`, `PMM USED 0000016A → 0000016C`, in the seven goldens that print them.
That is the only non-address difference in any golden in the tree, it is arithmetic rather than
behaviour, and `m7-frames` re-derives both figures from the image size rather than reading them from
a table, which is why it passes without any number being typed in.

**What it does not change:** the storage seam is a property of the SOURCE — the harnesses count
`return Bss.addressOf(x)` call sites in `.dart` files — so inlining the seam into fifty machine-code
sites does not widen it. Nothing else in the kernel gained the ability to name the storage.

**The behavioural goldens that moved, moved only in addresses.** `m7` through `m16`'s serial and
screen captures print kernel addresses, and the DCDart `.bss` lands at a different address than the
assembly one did. Each regenerated golden was checked to differ from its predecessor **only in
hexadecimal literals** — same lines, same order, same everything else — before it was accepted, and
then the kernel was required to reproduce the new file byte for byte. `m1-interrupts`' 544-byte
golden prints no address and is unchanged.

---

## 6. `DCDART_PIN.txt` moved to `8713298`, and exactly that far

`8713298` is DCDart's ADR-0051 — the `@bss` commit itself, and the first commit at which this kernel
builds. It is **not** DCDart's HEAD: `c51bb0b` (ADR-0052, monomorphized generics) is one commit
further on and this kernel needs nothing from it. Same discipline as ADR-0011 §7.

`m7-frames/run.sh`'s pin assertion moved with it and now names **both** facts the pin is load-bearing
for — nested `while` loops (`e3cfe18`, M7's reason) and `@bss` (`8713298`, M17's) — so a future bump
has to answer to both. The assertion stays a literal rather than an ordering because a git hash
carries no order, and the check exists to catch a silent revert to an older toolchain.

---

## 7. What this does NOT do

- **It gives `@bss` no atomicity story, and does not need to.** The PIT handler increments a tick
  counter that the shell reads — a read-modify-write that is correct only because interrupt entry
  serializes on a single core. That was true before this change and is true after it, in the same
  words, on the same counter, which is still in `isr.S`'s `.bss` and did not migrate. **Pre-existing,
  not introduced here.** GAP-0136.
- **It does not zero `.bss`.** Nothing in this kernel's Multiboot boot path clears `.bss`; `boot.S`
  zeroes only the three page-table pages and the TSS, by explicit address range. DCDart's `@bss` is
  zero-initialized in principle (ADR-0051) but that promise is the loader's, and this kernel does not
  rely on it: every subsystem's `init()` still writes its metadata before first use, and none of that
  initialization was removed. GAP-0135.
- **It does not migrate what assembly writes.** §4.
- **It does not rename anything.** §3.
- **It does not change one line of behaviour.** §0. It does change one *number*: the image is two
  pages bigger, so two more frames are reserved. §5a.

---

## 8. Exit criterion

**Binary:** all eighteen harnesses in `core/tests/conformance/` pass against `DCDART_PIN.txt` =
`8713298`; `core/boot/kdata.S`'s `.bss` is **exactly 96 bytes**; `kmain.o` declares **44** externs and
none of the sixteen deleted `_addr()` accessors; `m1-interrupts`' 544-byte golden is byte-for-byte
unchanged from `cf2737f`.
