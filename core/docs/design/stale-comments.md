# Stale comments — claims the DCDart pin bump to `8713298` made false

**Audit date:** 2026-08-23 · **Scope:** comments only. No code was read for correctness and no code
was changed. This file is a report.

## Why this exists

`DCDART_PIN.txt` now reads `8713298 2026-08-23`. That pin is past four upstream DCDart changes this
tree's comments were written before:

| DCDart ADR | What it added | What it invalidates here |
|---|---|---|
| ADR-0044 (`e3cfe18`) | nested `while` loops | "the pinned `dcc` cannot compile a `while` inside a `while`" (GAP-0068) |
| ADR-0047 | `break` / `continue` | "DCDart has no `break` out of a `while`" |
| ADR-0045 (`b3f0ed9`) | `Port.inw`/`outw`/`inl`/`outl` | "`core/boot/portio.S` is the only way to reach any width but a byte" (GAP-0066) |
| ADR-0051 | mutable statics, `@bss` | "DCDart has no mutable static data of any kind" (GAP-0053) |

A false comment is worse than dead code in a repo with parallel agents: it does not merely fail to
help, it actively instructs the next author to write the worse shape *on purpose*. Every MISLEADING
row below names a helper function, a flag variable, or an assembly file that the comment says is
*required* and that the pinned toolchain no longer requires.

**Cross-cutting note.** Several of these comments are *paired* with an already-correct comment
elsewhere in the same file (e.g. `elf.dart:77` says there are no mutable statics; `elf.dart:838`
says `elfStore` is one). The M17 migration updated the declaration sites and missed the file
headers. A reader who lands on the header first draws the wrong conclusion.

---

## MISLEADING — would make an agent write worse code

### A. "The pinned `dcc` cannot nest a `while`" (GAP-0068 — resolved and adopted at M7)

Each of these says a helper function exists *only* to avoid a nested loop. An agent refactoring
near any of them will preserve the decomposition, or add a sixth one of its own.

| File:line | The claim | Why it is now false | One-line fix |
|---|---|---|---|
| `core/kernel/ata.dart:610-614` | `ataSpaces` is "A separate function ONLY because the PINNED `dcc` cannot compile a `while` inside a `while`… That limitation is fixed upstream and is **NOT** fixed in the toolchain this repo builds against" | The pin is `8713298`, well past `e3cfe18`. The second sentence is the exact inverse of the truth. | Replace with: "A separate function for trailing-space suppression (see `ataModelByte`); the nesting restriction it originally worked around is gone as of ADR-0044." |
| `core/kernel/ata.dart:798-809` | `ataDumpLine` is "**A separate function only because the PINNED `dcc` cannot compile a nested `while`**"; and, explicitly, "`DCDART_PIN.txt` is `9e836a3`, which predates it" | Both halves false: nesting compiles, and the pin is `8713298`, not `9e836a3`. This is the single most quotable wrong line in the kernel — it states a hash. | Delete the pin sentence; retain the paragraph as history, retitled "Was a separate function only because…" and note it may now be inlined into `ataDumpSector`. |
| `core/kernel/fb.dart:419-424` | `fbFillRow` is "A separate function rather than an inner loop because `dcc` rejects nested `while` loops" | Same. Framed as a live limitation "met a second time in the same milestone". | Past-tense it, or note the helper is now a free choice (it does read well) rather than a forced one. |
| `core/kernel/fat.dart:1789-1793` | `fatFindFree` does "**One pass over every cluster, modular, rather than two loops**, because the pinned `dcc` cannot compile a `while` inside a `while`" | The modular single pass is arguably still the better algorithm — but the *stated reason* is gone, so an agent cannot tell the shape is intentional. | Keep the shape, change the reason: "…rather than two loops, because the wrap makes the bound obvious and the cost identical." Drop the GAP-0068 clause. |
| `core/kernel/fat.dart:1930-1931` | `fatDirBlank` is "A separate function because its caller has a loop of its own and the pinned `dcc` cannot nest one" | Same. | Past-tense, or inline. |
| `core/kernel/pci.dart:424-431` | `pciScanFunctions1To7` is "**A separate function purely because `dcc` rejects a nested `while`**… DCDart cannot express that today, so the inner loop becomes a call" | "today" is now wrong. This was the *first* site to hit GAP-0068 and reads as the canonical statement of the rule. | Rewrite the paragraph in the past tense and add "…the limitation was lifted in ADR-0044; the decomposition is now kept for readability, not necessity." |

`core/kernel/pmm.dart:100-118, 940-941, 1372` is the counter-example: it already describes
nested `while` as used deliberately, and is correct. Nothing to fix there except item C2 below.

### B. "DCDart has no `break`" (ADR-0047)

These justify a helper function or a sentinel-flag variable by a language limitation that is gone.
The flag-variable ones are the more damaging: a `stop` variable threaded through a loop is a real
readability cost, and the comment tells the reader it is mandatory.

| File:line | The claim | Why it is now false | One-line fix |
|---|---|---|---|
| `core/kernel/pmm.dart:1339-1342` | `pmmFillLedger` is "A separate function because DCDart has no `break` out of a `while` (the same reason `cpuSkipSpaces` exists) — an early `return` from a helper is the idiom this language leaves" | `break` exists as of ADR-0047. It is no longer "the idiom this language leaves". | "…was a separate function because DCDart had no `break`; ADR-0047 added one, so this may be inlined." |
| `core/kernel/shell.dart:1117-1120` | `cpuSkipSpaces` is "A separate function rather than an inline loop because DCDart has no `break` out of a `while` and no boolean operators…" | The `break` half is false. The GAP-0023 half (no boolean operators, no `>=`) is **still true** — do not delete the whole sentence. | Strike the `break` clause, keep the GAP-0023 clause. |
| `core/kernel/file.dart:1229-1232` | `fileOwnsWrite`'s caller uses a tri-state `stop` flag: "A flag rather than a `break`, because `@bare` DCDart has no `break`" | False. The loop can now `break`. The flag also encodes *why* it stopped, which is a genuine second reason the comment does not give. | "A flag rather than a `break` because the flag also records **why** the loop stopped (refused vs. complete); `break` exists as of ADR-0047 but would lose that." |
| `core/kernel/pci.dart:278-282` | `pciFindName` does "Two passes, deliberately, rather than one pass that remembers a wildcard candidate: DCDart has no `break` and no boolean operators (GAP-0023)" | The `break` half is false; GAP-0023 half stands, and the comment's own third reason (order-independence) is the durable one. | Strike the `break` clause; lead with the order-independence argument, which survives. |

### C. Port I/O — `Port.inw`/`outw`/`inl`/`outl` now exist (GAP-0066, ADR-0045)

**Answer to "is `core/boot/portio.S` still needed?" — No. It is dead weight the pin made
removable, but removing it is a real unit of work, not a comment fix.**

Live call sites of the four assembly helpers, **10 in total across 3 files** (everything else that
greps is prose):

- `core/kernel/pci.dart:267-268` — `port_outl` / `port_inl`, the CONFIG_ADDRESS/CONFIG_DATA pair
- `core/kernel/fb.dart:348, 349, 355, 356` — `port_outw` ×3 and `port_inw` ×1, Bochs VBE dispi index/data
- `core/kernel/ata.dart:679, 815, 935` — `port_inw` on the ATA data register `0x1F0`
- `core/kernel/ata.dart:1079` — `port_outw` on the same register (M16 write path)

Declared as `external` in exactly two places: `core/kernel/fb.dart:139,143` (`port_inw`,
`port_outw`) and `core/kernel/pci.dart:78,82` (`port_inl`, `port_outl`).

`core/boot/portio.S` defines exactly those four and nothing else, and is still assembled and linked
(`core/scripts/build-kernel.sh:120,140`). Deleting it means: 10 call-site edits, 4 `external`
declarations removed, 4 fewer declared externs, and edits to the `verify-freestanding` extern counts
and the `portio.o` assertions in `tests/conformance/{m5,m6,m7,m9,m10,m11,m12,m14,m16}/run.sh`.
Until someone does that, the *code* is correct; only the comments below are wrong.

| File:line | The claim | Why it is now false | One-line fix |
|---|---|---|---|
| `core/kernel/ata.dart:93-100` | "**That argument has been won, and this file does not yet get to enjoy it.** … `DCDART_PIN.txt` is `9e836a3`, which predates the commit, so the toolchain that actually builds this kernel still has only the byte-wide forms and `port_inw` is still the only way to read `0x1F0`." | Every clause after the first is false. The pin is `8713298`; the toolchain **does** have `Port.inw`. The comment even spells out the migration ("`port_inw(u64(ataRegData))` becomes `Port.inw(u16(ataRegData))`, `core/boot/portio.S` is deleted outright") and then says it cannot happen. | Replace "does not yet get to enjoy it" with "and this file has not yet been migrated": keep the migration recipe, change *blocked* to *pending*. |
| `core/kernel/pci.dart:40-49` | "`Port.outb`/`Port.inb` (DCDart ADR-0029) are **the only port primitives the language has**" and "the real ask … is filed as GAP-0066" | ADR-0045 added the doubleword forms. `Port.outl`/`Port.inl` exist; the ask is answered, not filed. | "…were the only port primitives the language had until ADR-0045; `Port.outl`/`Port.inl` now exist and this seam is scheduled for deletion." |
| `core/kernel/pmm.dart:115-118` | "`b3f0ed9` (word/doubleword port I/O, which deletes `portio.S`) was **deliberately NOT taken**: it rewrites M5's and M6's port access and is a different unit's work." | True when written at M7; false now — the pin bump to `8713298` took it. An agent reading this believes the feature is unavailable. | "…was deliberately not taken *at M7*; the M17 pin bump to `8713298` includes it, and `portio.S`'s deletion is now unstarted work rather than blocked work." |
| `core/kernel/ata.dart:85-91` | "the third subsystem to need a width DCDart's `Port` does not have, which is the whole of the argument in GAP-0066" | Present tense "does not have" is false. | Past-tense the clause. |
| `core/docs/known-gaps.md:1416-1424` | GAP-0066 **Status: RESOLVED UPSTREAM, NOT YET ADOPTED HERE** … "This repo still builds against `DCDART_PIN.txt` = `9e836a3`, which predates that commit … The workaround is described below **in the present tense because it is still what the code does**." | The pin sentence is false. The status should be *adopted upstream, migration pending in-tree* — a different state with different next actions. | Change status to "RESOLVED UPSTREAM AND ON THE PIN; the in-tree migration (10 call sites, `portio.S` deletion) is the remaining work." Fix the hash. |
| `core/README.md:16` | "`boot/portio.S` … this file is deleted when it lands — **which it has: DCDart `b3f0ed9` adds all four, and this repo's pin predates it.**" | The pin no longer predates it. | Same fix as above. |

### D. "DCDart has no mutable static data" (GAP-0053 — **RESOLVED at M17**, ADR-0021/ADR-0051)

`core/docs/known-gaps.md:574` already reads *"GAP-0053 — RESOLVED at M17: DCDart grew mutable
statics, and 13952 of the 14048 donated bytes went home."* `core/boot/kdata.S` now declares only
`cpu_info`, `shell_resume_rsp`, `shell_resume_ok`, `user_resume_rsp`, `user_resume_ok` and three
`*_addr` accessors — 96 bytes. Every per-subsystem `*_store` symbol is now a `@bss` mutable static
declared in the `.dart` file that uses it.

The migration updated the declaration sites and **missed the file headers**, so most of these files
now contradict themselves. Highest damage: an agent adding state to any of these subsystems will
go edit `kdata.S` and add an `@extern` accessor, reintroducing the seam M17 spent a milestone
deleting.

| File:line | The claim | Why it is now false | One-line fix |
|---|---|---|---|
| `core/kernel/elf.dart:77-84` | "DCDart **still** has no mutable static data of any kind (GAP-0053), so this subsystem's state is assembly-donated `.bss` … 128 bytes in ONE symbol (`elf_store`, `core/boot/kdata.S`) behind ONE accessor (`elf_store_addr`)" | Contradicted 760 lines later by `elf.dart:838-846`, which declares `elfStore` as `@bss` and says "Until M17 (ADR-0021) this was `elf_store` in `core/boot/kdata.S`". `elf_store` is not in `kdata.S`. | Rewrite the header seam paragraph to describe the `@bss` block; keep "ONE symbol, ONE accessor, ONE call site" — that discipline survived the migration. |
| `core/kernel/user.dart:74-80` | Identical wording for `user_store` / `user_store_addr` | Contradicted by `user.dart:818-826` (`@bss`). | Same. |
| `core/kernel/user.dart:761,765` | "Donated storage: sixteen `u64` words. See `core/boot/kdata.S`." / "The layout is documented once, in `kdata.S`." | The layout is documented in `user.dart` now; `kdata.S` no longer carries it. Sends the reader to the wrong file. | Point at the `@bss` declaration below. |
| `core/kernel/elf.dart:804,808` | Same two sentences for `elf_store` | Same. | Same. |
| `core/kernel/fat.dart:88-94` | "DCDart has no mutable static data of any kind (GAP-0053), so every byte of filesystem state is assembly-donated `.bss`: ONE symbol, `fat_store`…" | Contradicted by `fat.dart:866-885`, which says the migration "HAPPENED (M17, ADR-0021)" and declares `fatStore` as `@bss`. | Rewrite header; keep the four-call-site rule, which the harness still counts. |
| `core/kernel/ata.dart:36-42` | "A 512-byte sector buffer is exactly the kind of thing this kernel cannot spell (GAP-0053: no mutable statics, no array type, no allocator), and `core/boot/kdata.S` is at 424 donated bytes already." | Mutable statics exist; there *is* an allocator (M7); `kdata.S` is at 96 bytes, not 424. Three wrong facts in one sentence. Note the *design* (dump-as-you-read, no buffer) is still deliberate and still good. | Keep the design decision, replace the justification: "…deliberately has no sector buffer: the dump-as-it-arrives shape is what makes 'this driver can show you a sector and cannot give you one' checkable." Drop the GAP-0053 clause. |
| `core/kernel/ata.dart:24-32` | "no PHYSICAL MEMORY MANAGER. This kernel does not have one and cannot have one until DCDart's mutable-statics decision lands" | Both false since M7/M17. | Past-tense; note M7 landed it. |
| `core/kernel/ata.dart:843-852` | "there was nowhere to put 512 bytes: DCDart has no mutable static data (GAP-0053)… so this adds nothing to `kdata.S`'s block" | First clause is correctly past-tense; the parenthetical and "`kdata.S`'s block" are present-tense and false. | Change "has no" → "had no"; "`kdata.S`'s block" → "the kernel's `@bss`". |
| `core/kernel/proc.dart:83, 92-93` | "Raising it is `procStoreBytes` and one number in `kdata.S`." / "See `proc_store` in `core/boot/kdata.S`." | `proc_store` is a `@bss` static at `proc.dart:966-980`. Editing `kdata.S` to raise the bound does nothing. | Point both at the `@bss` declaration in this file. |
| `core/kernel/proc.dart:959` | A to-do listing "delete `proc_store` and `proc_store_addr` from `core/boot/kdata.S`" | Already done at M17. A stale to-do reads as outstanding work. | Delete the item, or mark it DONE (M17). |
| `core/kernel/keyboard.dart:28` | "using one donated word in `core/boot/kdata.S` (`kbd_prefix`)" | `kbd_prefix` is not in `kdata.S`. | Repoint at the `@bss` symbol. |
| `core/kernel/shell.dart:837-838` | "Maximum bytes the line buffer holds. Matches `core/boot/kdata.S` **exactly**" | There is no line buffer in `kdata.S` to match; `shell.dart:580-663` holds the `@bss` blocks. An agent "fixing the mismatch" would edit the wrong file. | Repoint at the `@bss` declaration. |
| `core/kernel/pci.dart:53-60` | "the first one since M1 that does not grow `core/boot/kdata.S` (GAP-0053)… there is nowhere to put a device list" | The framing ("costs zero donated bytes") is obsolete; storage is now cheap to declare, so "nowhere to put a device list" is a design choice, not a constraint. GAP-0067 (walk the bus again) is still the real cost. | Reframe as a deliberate choice: "still retains nothing, now by choice rather than necessity — GAP-0067 records the cost." |
| `core/kernel/shell.dart:49-51` | "there is no input queue (GAP-0055 item 4 is still open, and a queue is another donated buffer, GAP-0053)" | GAP-0055 item 4 may well still be open, but "another donated buffer" is no longer the blocker. | Strike the GAP-0053 clause; the race argument above it is untouched and correct. |

---

## COSMETIC — wrong, but unlikely to change what anyone writes

| File:line | The claim | Why it is now false | One-line fix |
|---|---|---|---|
| `core/README.md:129-130` | "a second unplanned finding: `dcc` **cannot compile a nested `while` loop** … worked around by decomposition (GAP-0068)" | Historical narrative of M5, correct as history, but present-tense "cannot" in a README a new agent reads first. | Add "(lifted upstream in ADR-0044; adopted at M7)". |
| `core/README.md:198` | "also moved `9e836a3` → `e3cfe18` for nested `while` loops" | Accurate as M7 history; the current pin is `8713298`. | Add the current pin so the table's last row is the live one. |
| `core/README.md:16,21,22,23,24,25` | Repeated "donated `.bss` exactly 424 / 5096 / 5224 / 5368…" in the harness descriptions | These describe what each harness *asserted at the time*; the harnesses may still assert them. Not false about the harness, but reads as a live description of `kdata.S`. | Add one sentence to the table preamble: "'donated `.bss`' figures are historical; M17 moved this storage to DCDart `@bss`." |
| `core/kernel/kmain.dart:68, 77, 85, 142, 161, 172, 190` | Seven init-order comments describing each subsystem's "donated `.bss` (`core/boot/kdata.S`)" | The *ordering* argument is still exactly right and is the point of these comments; only the word "donated" and the file reference are stale. | Global substitution of "donated `.bss` (`core/boot/kdata.S`)" → "`@bss` block" in this file. |
| `core/kernel/elf.dart:838-841`, `user.dart:818-821`, `proc.dart:966-968`, `pmm.dart:670`, `fb.dart:248`, `vga.dart:92-101`, `shell.dart:561-564`, `fat.dart:866-872`, `args.dart:258`, `file.dart:492` | "Until M17 (ADR-0021) this was `…_store` in `core/boot/kdata.S`" | **These are correct.** Listed here so a later reader does not "fix" them — they are the model the stale headers should be rewritten toward. | None. |
| `core/kernel/ata.dart:610-612` | `ataSpaces`'s doc opens "Writes [n] spaces" and only then gives the false reason | The false reason precedes the true one ("Its real job is trailing-space suppression"). | Lead with the real job; demote the compiler history to a trailing sentence. |
| `core/tests/conformance/m7-frames/run.sh:357, 369, 371-372` | Pin and GAP-0068 assertions | **Correct and current** — line 371 already asserts `8713298`, and 372 guards `pmm.dart`'s inner loop against re-decomposition. | None. Cited as the example of a check that kept up with the pin. |

---

## Suggested order of repair

1. **`core/kernel/ata.dart`** — carries five separate false claims (nested `while` ×2, port I/O,
   mutable statics ×2) and is the only file that states a wrong pin hash twice.
2. **The six GAP-0068 helper-function comments** (section A) — each one is a standing instruction to
   keep a decomposition nobody wants.
3. **`core/docs/known-gaps.md` GAP-0066 status block** — it is the authority the file comments cite,
   so fixing it once removes the source of several downstream errors.
4. **Section D file headers** — mechanical, high volume, and each file already contains the correct
   replacement wording a few hundred lines below.
5. The `portio.S` deletion itself is a real milestone-sized change (10 call sites plus nine
   harnesses), not part of this cleanup. Filing it as its own gap entry would stop the next agent
   from starting it accidentally.
