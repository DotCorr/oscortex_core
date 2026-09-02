# The oscortex executable format, and what it would take to link one — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered, nothing implemented, and no file outside this one was
touched to produce it.** `core/kernel/elf.dart` is owned by another agent as this is written. When a
piece of this is built it gets its own numbered ADR; this file is the thing those ADRs will point back
at, the same way `display-protocol.md` is for the window system.

**Provenance.** The owner wants (a) a native executable format called `.osx` and (b) eventually
applications of the ffmpeg class. Both were relayed to me by the coordinator and not witnessed by me.
Neither is treated here as settled: §1 argues both sides of (a) and lands on a recommendation the owner
can overrule, and §4 is the honest arithmetic on (b). Where I measured something I say so and give the
command; where I estimated, I say **estimate** and give the method.

### The five things this document concludes, for a reader in a hurry

| | conclusion | where |
|---|---|---|
| **A new format** | **Not worth it as a replacement for ELF. Worth it as a wrapper around one.** Everything `.osx` would genuinely buy is metadata *about* an image; nothing it would buy is a better way to *describe* an image. Replacing ELF costs an objcopy-equivalent, a linker-script-equivalent, and every tool. | §1 |
| **If `.osx` is wanted** | **A 64-byte header + a fixed-size manifest + an embedded, unmodified ELF at a 512-byte boundary.** `x86_64-elf-ld` still emits the payload; the host tool is `cat` with a header; the loader change is **one word of state and one addition** in `elfImageLba`. | §2 |
| **Dynamic linking** | **Blocked three levels below relocations.** There is no `mmap`, no `mprotect` and no way to set `FS.base`. Those are the gate, not `R_X86_64_RELATIVE`. Static linking is the right answer here **for years**, and the thing that eventually forces the change is disk and RAM footprint, not capability. | §3 |
| **ffmpeg** | **Not gated on linking. Gated on three hard caps that are 5×, 40× and 4000× too small**, on a **4096-byte stack**, and on a libc that has 33 functions where a measured 123 are needed by ffmpeg's four core libraries alone. | §4 |
| **What to build first** | **X1 and X3 — a program larger than 64 KiB, and a stack larger than one page.** Both are small, both are pure loader work, both are prerequisites for literally every application, and neither depends on the `.osx` question being settled. | §5 |

**And the finding that surprised me most:** the binding constraint on running real software here is not
the format and not the linker. **It is that a program's entire address space is 2 MiB and its stack is
one 4096-byte page.** `libavutil`'s `__text` section, on its own, measured on this host, is **355,944
bytes** — 5.4× the loader's whole-image cap and 87 pages of a 512-page window, for the library that
does *none* of the actual work. That number is §4.2 and it reframes everything else here.

---

## 0. What this has to be true of

Nine facts about this machine. All of them are read out of the tree at the commit this was written
against, and each is cited so the next agent can check whether it still holds.

| # | fact | where |
|---|---|---|
| 1 | The loader accepts **`ET_EXEC` and nothing else**, with 25 named refusals, and `PT_INTERP`/`PT_DYNAMIC` is `ELF REFUSED 11` by name | `elf.dart:788–802`, ADR-0014 §5, GAP-0091 |
| 2 | **The largest image the loader will read is 65536 bytes** (`elfImageMax`) | `elf.dart:767` |
| 3 | **The largest file the filesystem will hand back is 256 clusters = 256 KiB** (`fatChainMax`) | `fat.dart:202` |
| 4 | **A program's whole address space is one 2 MiB page-directory entry**, `[0x10000000, 0x10200000)` | `vm.dart:1976,1980` |
| 5 | **A program's stack is ONE PAGE.** `vmProgStackPage = 0x101FF000`, `vmProgStackTop = 0x10200000` | `vm.dart:1997,1998` |
| 6 | **At most 16 program headers, and they must all lie in the first 4096 bytes of the file** | `elf.dart:727`, ADR-0014 §9 |
| 7 | **There are eleven syscalls**, numbered 0–10: `exit write who yield sbrk open read close seek fdwrite preempts` | `user.dart:731–733`, `proc.dart:294,309`, `heap.dart:142`, `file.dart:256–276` |
| 8 | **The C library has 33 public functions**, `printf` has five conversions, and there is no `errno` | `core/user/libc/oslibc.h`, GAP-0112, GAP-0122 item 6 |
| 9 | **`boot.S` writes exactly one MSR — EFER.** There is no `FS.base` write, no `wrfsbase`, no `arch_prctl` | `boot.S:585–591` |

Two more that are properties of the *language*, not the kernel, and that shape §2 and §3:

10. **`@bare` DCDart has no function pointers and no dynamic dispatch** — `isrDispatch` is a branch
    chain and the shell's command table is an `if` chain (ROADMAP.md:141, :1036). Any loader design
    that wants "a table of format handlers" is not expressible today.
11. **DCDart's arithmetic traps on overflow with a real `ud2`.** ADR-0014 §5's rule applies to every
    number this document proposes reading out of a file: bound it *before* it is added to anything, or
    the check meant to reject a malformed file takes a `#UD` inside the kernel, chosen by the file.

---

## 1. IS A NEW FORMAT WORTH IT?

### 1.1 The case FOR `.osx`, stated as strongly as it deserves

These are the arguments I think are real, in descending order of how real they are.

**1. ELF has no place to put anything this OS wants to say about a program.** The gABI's extension
points are `PT_NOTE` and section names, and both are *conventions* — a note is a type/name/descriptor
triple that means whatever the vendor namespace says, and nothing enforces that a producer wrote one.
If oscortex wants "this program requires syscalls 0–9 and no more" or "this program's manifest version
is 2", ELF's honest answer is "put it in a note and hope". A container header is a place where the
field is *at a fixed offset* and its absence is a refusal.

**2. A container can be validated before a single ELF byte is parsed.** Today `elfCheckHeader` is the
first thing that ever looks at the image, and the `"OSCXPRG1"` header sector (ADR-0014 §4) exists
precisely because there was nowhere else to put a length. A container generalises that: one magic, one
length, one version, checked in the order §0 fact 11 demands, before anything indexes anything.

**3. Versioning is a genuine forward problem and it is cheap now.** This OS will change its syscall
numbering, its address window (§5 X2) and its entry-stack layout. A program built against M19's ABI
and run on M25's kernel will fail somewhere between subtly and catastrophically, and the diagnostic
will be a page fault. **A one-word ABI level in a header turns that into a sentence.** This is the
single most defensible reason to build a container, and it is worth more than the other four combined.

**4. Resources.** An icon, a font, a message table, a default configuration — things a desktop-class OS
needs and that today have to be a second file with a second 8.3 name in a flat root directory
(GAP-0116). A container that can carry N named blobs is a real answer to a real problem.

**5. Capabilities.** "This program may write files; this one may not." Attractive, and §2.6 is why it
is mostly aesthetic **today**.

### 1.2 The case AGAINST, which is the case I find stronger

**1. ELF is what the toolchain emits, and the toolchain is not yours.** `clang -target
x86_64-unknown-none-elf` and `x86_64-elf-ld -T prog.ld` are, verbatim, how every program on this
machine is built (ADR-0014 §2). A format the linker does not emit needs an **objcopy-equivalent**:
something that reads the linker's output and writes yours. That tool has to understand ELF anyway — so
you have not escaped ELF, you have added a second format *and kept the first*.

**2. Replacing ELF, rather than wrapping it, costs far more than the converter.** ELF is not a
container; it is a **description of an address space**. `p_vaddr`, `p_offset`, `p_filesz`, `p_memsz`
and `p_flags` are exactly the five numbers a loader needs and exactly the five a linker knows. A native
format that carries the same five has reinvented `Elf64_Phdr` with different field names, and a native
format that carries fewer cannot express `.bss` (that is `p_memsz > p_filesz`) or W^X (that is
`p_flags`). **There is no better answer available in that space, because the problem is not
underspecified.**

**3. Everything that reads ELF stops working.** `readelf`, `objdump`, `nm`, `size`, `gdb`, `addr2line`
— and, specifically and importantly for *this* project, **`derive.py`**. `m10-elf` derives every
expectation in its golden from an independent ELF reader on the host (ADR-0014 §7). A native format
means a native reader in `derive.py`, written by the same person as the kernel's, and the whole point
of the independent reader is that it was not.

**4. `verify-freestanding.sh` and the extern manifest assume ELF too.** The kernel's own build
discipline is ELF-shaped end to end.

**5. Most of what `.osx` would buy can be had without a new format.** A note segment, a second file
next to the program, or a directory-entry attribute all carry metadata. They are uglier. Ugly is
cheaper than a fork of the toolchain.

### 1.3 What is real and what is aesthetic — the honest table

| `.osx` would carry | real, or aesthetic? | why |
|---|---|---|
| **ABI / kernel version level** | **REAL, and the strongest single reason.** | The failure it prevents (an old binary on a new kernel) is certain to happen, is silent today, and costs one `u32` |
| **A length and a checksum over the image** | **REAL but small.** | The length already exists twice (the `OSCXPRG1` sector, the FAT directory entry). A checksum is new and is the difference between "the disk lied" and "the loader jumped into a bad page" |
| **Named resources** | **REAL, once there is anything to resource.** | The filesystem is a flat root of 8.3 names (GAP-0116). Bundling is a genuine answer. **But nothing needs it before there is a window system** |
| **A human name / version string** | **REAL and trivially cheap.** | `PROG.ELF` is an 8.3 name. A 32-byte display name costs 32 bytes |
| **Capabilities** | **AESTHETIC TODAY.** | §2.6. A capability is a promise the kernel must be able to break, and there is no enforcement point for most of them |
| **A signature** | **AESTHETIC TODAY, and misleadingly so.** | §2.7. There is no crypto in this tree, no key store, no clock, and no threat model. A signature field nothing verifies is worse than no field |
| **A better description of segments than `Elf64_Phdr`** | **AESTHETIC, and I could not construct one.** | §1.2 point 2 |
| **"It is ours"** | **AESTHETIC — and I am not dismissing it.** | This project has repeatedly chosen its own paradigm over Linux's (`display-protocol.md`'s provenance note; a native syscall ABI over a Linux compat layer). That is a coherent position and it is the owner's to hold. It is just not an engineering argument, and this document's job is to keep the two labelled |

### 1.4 Recommendation

**Keep ELF as the payload. Add `.osx` as a container around it, or add nothing at all.**

Ranked:

1. **Best value for effort: do nothing yet, and spend the effort on §5's X1/X2/X3.** Nothing that
   exists today is blocked by the format. Everything is blocked by size.
2. **If a format is wanted now: build §2's container.** It is genuinely small — I size it at one word
   of loader state, one addition, one refusal code group, and a ~60-line host script — and it is the
   version that costs nothing if it is later abandoned, because the payload is still an ELF you can
   `readelf`.
3. **Do not replace ELF.** I could not find a single capability a native segment format would buy, and
   I looked for one specifically.

**One thing that would change my answer:** if the owner intends oscortex to eventually *not* use
`clang`/`x86_64-elf-ld` — to have its own linker, driven by `dcc` — then the calculus inverts, because
the "the toolchain already emits ELF" argument is an argument about a toolchain that would no longer
exist. That is a much larger decision than a file format and it belongs to the owner, not to this
document. **CLAUDE.md's escalation rule applies: I am flagging it rather than assuming either way.**

---

## 2. IF `.osx` IS WANTED: the smallest design that keeps ELF as the payload

The design goal is stated as a constraint on the *diff*, not on the format: **`x86_64-elf-ld` still
produces the thing that runs, and `readelf` still reads it.**

### 2.1 The container

```
   offset  size   field
   ------  ----   -------------------------------------------------------------
     0x00     8   magic          "OSCXEXE1"  (an ASCII u64, like elfHeaderMagic)
     0x08     4   container      version of THIS layout. 1.
     0x0C     4   abiLevel       the kernel ABI this program was built against
     0x10     8   totalBytes     the whole .osx file, header included
     0x18     4   elfOffset      byte offset of the payload. MUST be 512-aligned
     0x1C     4   elfBytes       length of the payload
     0x20     4   manifestOffset  byte offset of the manifest. 512-aligned
     0x24     4   manifestBytes
     0x28     4   resOffset      resource table. 0 = none
     0x2C     4   resCount
     0x30     4   headerSum      sum of bytes 0x00..0x2F excluding this field
     0x34     4   elfSum         sum over the payload's elfBytes
     0x38     8   reserved       MUST BE ZERO
   ------  ----
     0x40          end of header. The payload begins at elfOffset >= 512.
```

**Everything is at a fixed offset and there are no variable-length fields in the header.** That is
deliberate: §0 fact 11 says every bound must precede the arithmetic it protects, and a header with no
computed offsets in it has almost no arithmetic to protect.

**`elfOffset` must be a multiple of 512, and this is the whole trick.** The loader reads the image
*by sector* — `elfReadSectors(from, n, buf)` at `elf.dart:1165` takes an **image-relative sector
number** and resolves it through `elfImageLba(i)` at `elf.dart:1155`. If the payload starts on a sector
boundary, then *every* existing offset in the loader becomes correct again by adding one constant to
one function:

```
u64 elfImageLba(u64 i) {
  final u64 base = elfMeta(u64(elfMetaElfSector));      // 0 for a bare ELF
  if (fatOpenActive() > u64(0)) {
    return fatFileSector(base + i);
  }
  return elfMeta(u64(elfMetaImageLba)) + base + i;
}
```

**That is the entire loader change to the load path.** `elfLoadImage`, `elfCheckHeader`,
`elfCheckPhdr`, `elfLoadSegment` and `elfCopyPageBytes` are untouched, because none of them ever knew
where in the file the ELF started — they only ever knew where in the *image* it started, and now that
is a variable instead of the constant zero.

`elfMetaElfSector` is one more word of loader state, reached through the existing
`elfSetMeta`/`elfMeta` accessors. **No new extern**, which is the same claim ADR-0014 §1 makes about
the loader itself.

**But `elfStore` is exactly full and that is worth knowing before starting.** It is 128 bytes / 16
words (`elf.dart:805–806`) and indices 0 through 15 are all assigned (`elfMetaLive` …
`elfMetaZeroed`, `elf.dart:809–824`). A seventeenth word means `elfStoreBytes` 128 → 136, which is a
`@bss` growth — and `.bss` growth moves every harness's accounting number unless the block that grew
is the **last** one, which `argsStore` currently is (ADR-0023's closing notes). So the honest cost is:
one word, plus re-deriving `.bss` totals across the suite, in the way M14, M15, M16 and M19 each
arranged in turn. It is a known, repeated, mechanical move — not a surprise — but it is not free and
it should be in the ADR's §1 table rather than discovered during the build.

### 2.2 The manifest

**A fixed-size record, not a key/value soup.** Nothing here parses text, and something that does is a
parser this kernel would have to be defended against.

```
   0x00    4   manifestVersion   1
   0x04    4   flags             bit 0: needs a heap. bit 1: needs the filesystem.
                                 bits 2..31 MUST BE ZERO
   0x08    8   minStackBytes     what the program says it needs (§4.2)
   0x10    8   minHeapBytes
   0x18    4   argcMax           the most arguments it wants
   0x1C    4   syscallHigh       the highest syscall number it will issue
   0x20   32   name              display name, NUL-padded, printable ASCII only
   0x40   16   version           "1.2.3", NUL-padded
   0x50   16   reserved          MUST BE ZERO
   ---
   0x60        96 bytes, one sector holds it five times over
```

**`syscallHigh` is the one field with teeth today**, and it is worth having for exactly the reason §1.1
point 3 gives: a program that says `syscallHigh = 12` running on a kernel whose highest is 10 is
refused *by name at load time* instead of getting `userRefused` back from a call it did not expect to
fail. That is the version check, expressed in the units the kernel actually has.

**`minStackBytes` is the second.** §4.2 shows the stack is one page; a program that declares it needs
64 KiB and is refused, rather than smashing into the heap guard page at some random depth, converts
this OS's most likely mysterious crash into a sentence.

### 2.3 What the loader does with it, in order

The order is ADR-0014 §5's rule applied one layer out:

```
   1. magic                       is this an .osx at all
   2. container version           do I understand this layout
   3. headerSum                   are these 48 bytes internally consistent
   4. totalBytes vs the file size the directory entry claims
   5. reserved == 0               refuse what I would otherwise ignore
   6. elfOffset 512-aligned, elfOffset + elfBytes <= totalBytes, elfBytes bounded
   7. manifest geometry, same three checks
   8. abiLevel <= kernel's        the version gate
   9. manifest: version, flags-reserved-bits, syscallHigh, minStackBytes
  10. elfSum over the payload     (read as it streams — see below)
  11. --- and only now does elfCheckHeader see a byte ---
```

**Eleven checks, eleven distinct sentences**, in the style ADR-0014 §5 already established and the
harness already enforces (25 refusals, 25 distinct messages, read back out of `kmain.o`'s `.rodata`).

**`elfSum` is the one that costs something.** Verifying it before loading means reading the payload
twice, or holding it, and §0 fact 2 says the loader deliberately streams. **Recommendation: compute
the sum as the segments stream through `elfCopyPageBytes`, and refuse *after* the load but before
`enter_user`** — the teardown path for that already exists and is exercised (`elfUnload`,
`elfTeardown`, and `m10-elf`'s `badentry` program takes exactly that path). Loading a program and then
refusing to run it is not elegant; loading a program that a checksum would have rejected is worse.

### 2.4 The host tool, which is where "we lose every existing tool" is answered

```sh
# tools/mkosx.sh  --  in full, conceptually
x86_64-elf-ld -T prog.ld -o prog.elf prog.o     # UNCHANGED. Still an ELF.
python3 tools/mkosx.py \
    --elf prog.elf --manifest prog.manifest \
    --abi 1 --out PROG.OSX
```

`mkosx.py` writes 64 bytes, pads to 512, writes the 96-byte manifest, pads to 512, and appends
`prog.elf` **byte for byte**. That is the objcopy-equivalent §1.2 warns about, and in this design it is
**a header and a `cat`** — because the payload is not transformed.

**And this is the property that makes the whole container defensible:**

```sh
dd if=PROG.OSX bs=512 skip=2 | readelf -l -    # still works
```

Every existing tool still reads the payload. `derive.py`'s independent ELF reader keeps working with a
two-sector skip. **A format you can `dd` back into the old format has not forked the toolchain.**

### 2.5 What is deliberately NOT in this container

Named, rather than left to be discovered — GAP-0116's discipline:

* **No compression.** A decompressor in the kernel is a parser in the kernel, and the disk is not the
  bottleneck (§4.2 says the *address space* is).
* **No relocations, no symbol table, no imports.** Those belong to §3 and half of §3 is worse than none
  (ADR-0014 §9's phrasing, which I think is right).
* **No key/value section, no strings the kernel parses beyond a fixed-width printable-ASCII name.**
* **No embedded second executable, no fat/universal binary.** One architecture (OSCORTEX_SPEC §1).
* **No mutable fields.** Nothing writes back into a `.osx`. It is a read-only artefact and the
  filesystem could not rewrite it in place anyway (GAP-0127: writes are append-only).

### 2.6 Capabilities: the honest version

A capability is only meaningful where the kernel has **an enforcement point** — a place it already
decides yes or no, into which one more condition can be added. Going through what a manifest might
declare:

| declared capability | is there an enforcement point? |
|---|---|
| "may not open files" | **YES.** `fileSysOpen` already refuses eleven ways. One more condition, one more refusal value. **Real, and cheap** |
| "may not write files" | **YES.** `openmode(name, O_WRITE)`. **Real, and cheap** |
| "may not grow its heap past N" | **YES.** `heapSbrk` already bounds against `heapTop`. **Real** |
| "may use at most N syscalls total" | **YES**, at the syscall entry. Real, and probably not useful |
| "may not touch the display" | not yet — there is no display syscall to refuse (`display-protocol.md` §2 proposes reusing `open`, which would make this fall under row 1) |
| "may not use the network" | **there is no network.** A field that refuses something that does not exist |
| "runs as user X" | **there are no users, no uid, no owner and no credentials anywhere in this tree** |

**So: two or three capability bits are real today, and they are real because file access already has a
refusal path. Everything else is a field with nothing behind it.** My recommendation is to ship
*those* bits and no others, and specifically **not** to define a general capability namespace — a
namespace whose entries are mostly unenforced trains the reader to believe the enforced ones are not
either.

### 2.7 Signatures: not yet, and this is not a close call

There is **no cryptography of any kind in this tree** (no hash, no cipher, no bignum), **no key
storage**, **no clock** (§4.3), and **no threat model** — the disk image is built by the harness that
also builds the kernel. A signature field would need: a hash the kernel computes, a public key the
kernel trusts, somewhere to keep that key that the thing being defended against cannot rewrite, and an
answer to "what happens on failure". None of the four exists.

**Recommendation: reserve nothing for it.** The header has an 8-byte `reserved` field that must be
zero; a signature is a container version 2, and version 2 is cheap because version 1 is checked
(§2.3 step 2). Reserving a 64-byte signature slot that is always zero would be the same mistake as an
unenforced capability bit — except larger, and about security, where the appearance of a property is
worse than its absence.

### 2.8 What the container costs, stated plainly

* **Two extra sectors per program** (1024 bytes of a 256 KiB file cap — 0.4%).
* **One more word of loader state, one addition in one function, eleven refusal codes and eleven
  sentences.** In the shape ADR-0014 already established — plus the `elfStore` 128 → 136 `.bss` move
  §2.1 sizes, which is mechanical but touches every harness's accounting.
* **`derive.py` and every `make-image.py` gain a two-sector skip**, and every harness whose golden
  contains a sector number or a byte count moves. That is the real cost and it is a day of harness
  work, not an hour.
* **Two ways to name an executable now exist** (`PROG.ELF` and `PROG.OSX`) unless one is removed. My
  recommendation: **the loader sniffs the first 8 bytes and dispatches on magic**, refuses a `.osx`
  whose payload is not an ELF and refuses an ELF presented where a container is required, and both
  refusals are named. `run` stays one command.

---

## 3. DYNAMIC LINKING — sized honestly

### 3.1 The pieces, and who owns each

| piece | lives in | what it actually is |
|---|---|---|
| `ET_DYN` accepted | `elf.dart` | drop one refusal; add a load bias to every `p_vaddr` |
| `PT_DYNAMIC` walk | `ld.so` (userland) or `elf.dart` | iterate `Elf64_Dyn`; find `DT_RELA`, `DT_RELASZ`, `DT_RELAENT`, `DT_JMPREL`, `DT_PLTRELSZ`, `DT_SYMTAB`, `DT_STRTAB`, `DT_GNU_HASH`, `DT_NEEDED`, `DT_RPATH`, `DT_INIT_ARRAY` |
| `R_X86_64_RELATIVE` | either | `*(u64*)(base + r_offset) = base + r_addend`. **This is the easy one and it is genuinely ~15 lines** |
| `R_X86_64_GLOB_DAT` / `_64` | `ld.so` | needs a symbol lookup across N objects, which needs a hash table walk, which needs `DT_GNU_HASH`'s bloom filter and bucket/chain arrays |
| `R_X86_64_JUMP_SLOT` | `ld.so` | same lookup, into the PLT's GOT slots |
| `R_X86_64_COPY` | `ld.so` | copy relocations for data symbols; needed by real programs, easy to forget |
| `R_X86_64_*TPOFF*` / `DTPMOD` | `ld.so` + **kernel** | TLS. Needs `FS.base` — §0 fact 9 |
| GOT/PLT | the linker | already emitted; nothing to build |
| lazy binding (`_dl_runtime_resolve`) | `ld.so`, in **assembly** | **skip it. Use `-z now`.** It is a register-preserving trampoline and it buys startup latency nobody is measuring |
| `PT_INTERP` handling | `elf.dart` + `args.dart` | load a *second* ELF at a base, put `AT_BASE`/`AT_PHDR`/`AT_PHENT`/`AT_PHNUM`/`AT_ENTRY`/`AT_PAGESZ` in the auxv, enter at the *interpreter's* entry |
| the auxiliary vector | `args.dart` | GAP-0147: it is currently `AT_NULL` and nothing else. **A dynamic loader cannot start without `AT_PHDR` and `AT_BASE`** |
| a search path | kernel + filesystem | "look in `/lib`" — there is no `/lib`, no subdirectories, and no paths (GAP-0116) |
| `dlopen`/`dlsym` | `ld.so` | strictly later; needs everything above plus `mmap` |

### 3.2 The three blockers that are NOT about relocations, and they are the reason this is far away

This is the part I would most want the owner to read.

**1. There is no `mmap`, and a userland `ld.so` is defined by having one.** A dynamic loader's job is
to open a file it discovers at run time and map its segments at addresses it chooses. Every real one is
a loop around `open` + `mmap(PROT_READ|PROT_EXEC)` + `mmap(PROT_READ|PROT_WRITE)`. This OS has no
`mmap` and no way for ring 3 to create a mapping at all — `sbrk` moves one break in one direction
(`heap.dart`). **Without `mmap`, `ld.so` cannot exist in user space**, and the only alternative is to
put the whole linker in the kernel — which is strictly worse than both options, because it is the
complexity of a dynamic linker with none of the isolation.

**2. There is no `mprotect`, and W^X is enforced twice on purpose.** `vmProgMap` refuses `PF_W|PF_X`
independently of `elfCheckPhdr` (ADR-0014 §5), which is a property worth keeping. A dynamic loader
needs to write into pages (GOT, `.data.rel.ro`) and then, for RELRO, make them read-only. The GOT is in
RW data so the *writing* is fine; **RELRO is simply unavailable**, and the honest statement is that
dynamic linking here would ship without it.

**3. There is no way to set `FS.base`, so there is no TLS — and this bites STATIC binaries too.**
§0 fact 9: `boot.S` writes EFER and nothing else. `musl`'s static startup calls `__init_tls`, which
needs `arch_prctl(ARCH_SET_FS)` or `set_thread_area`, because `errno` is `__thread`. **So "just link
statically against musl" does not escape this**; it is a prerequisite for using any real libc at all,
static or not. It is also the *cheapest* of the three: one MSR write behind one new extern, a per-
process `fsBase` word in `proc.dart`'s context, and a `wrmsr` in the switch path. Call it a small
milestone, not a large one.

### 3.3 Sizing

**Estimate**, by comparison with the smallest real implementations (musl's `ldso/dynlink.c`, dietlibc,
and the several thousand lines of glibc's `elf/dl-*.c` that are not optional):

| stage | new code | new syscalls | where it lands |
|---|---|---|---|
| `ET_DYN` + `R_X86_64_RELATIVE`, **kernel-applied, no interpreter** | ~150 lines DCDart | 0 | `elf.dart` |
| auxv with `AT_PHDR`/`AT_BASE`/`AT_ENTRY`/`AT_PHENT`/`AT_PHNUM`/`AT_PAGESZ` | ~60 lines DCDart | 0 | `args.dart` |
| `FS.base` per process | ~40 lines + 1 extern | 1 | `proc.dart`, `boot/`|
| `mmap`/`munmap`/`mprotect`, even a narrow file-backed subset | **large** — this is a memory-management milestone, not a linker one | 3 | `vm.dart`, `heap.dart`, `file.dart` |
| a search path (subdirectories, or a reserved-name convention) | **large** — GAP-0116 is the list | 0–2 | `fat.dart` |
| `ld.so` itself, `-z now`, no `dlopen`, no TLS | **1500–3000 lines of C**, and it must be built `-fno-pic` self-relocating or hand-relocate itself before its first call | — | `core/user/ld/` |
| `dlopen`/`dlsym`/`dlclose` | +800 lines, plus lifetime and refcount semantics | — | same |

**Sum: I would size the whole thing at four to six milestones**, of which **exactly one** (the first
row) is about relocations. The rest is memory management and filesystem. **Anyone who says "we just
need to handle three relocation types" has looked at the easy row.**

### 3.4 Is static linking the better answer for this OS, and for how long?

**Yes, and for a long time — years at this project's cadence — and here is the case on both sides.**

**What static linking gives up:**

* **Disk.** N programs each carrying their own libc. At today's scale (7 test programs, a 256 KiB file
  cap) this is not measurable. At 50 programs each embedding a 600 KiB libc it is 30 MB, which on a
  FAT16 volume is real.
* **RAM.** The decisive one, eventually. Two processes running the same statically-linked libc occupy
  two copies of its text frames. Shared libraries exist because **text is shared**, and this kernel
  already has the primitive that would make sharing possible — `vmProgMap(va, pa, flags)` maps a frame
  the caller names. What it does *not* have is refcounting, and `display-protocol.md` §1.3 records that
  mapping one frame into two address spaces is **unsound today** in a way that is silent at the machine
  level. So sharing is not one map call away; it is one map call plus a correct `freeFrame`.
* **Updating a library means rebuilding every program.** Correct, and irrelevant while the whole
  userland is rebuilt by one harness on every run.
* **No plugins.** ffmpeg does not need them; a browser-class application eventually would.

**What static linking gives:**

* **Every program is one file, complete, with no search path, no versioning, no `LD_LIBRARY_PATH`, no
  symbol interposition and no diamond dependency.**
* **It is the only thing that works today**, and it works *now*.
* **It preserves the loader's single strongest property.** ADR-0014 §5: if the loader does not
  understand something it says which thing and stops. A dynamic loader's failure modes — a missing
  symbol resolved to zero, an unhandled relocation type silently skipped, a version mismatch — are
  precisely the class of failure this project has designed itself against.

**When does it stop being the right answer?** Not when a program gets big — a big program links
statically fine. **It stops when there are many processes running the same code at once**, i.e. when
this becomes a desktop with a compositor plus a shell plus applications, all of which want the same
libc and the same drawing library in RAM at the same time. That is `display-protocol.md`'s D-ladder
territory, and the correct precursor is not `ld.so` — **it is frame refcounting and a shared read-only
mapping**, which is a much smaller and much more useful thing to build.

**My recommendation: `-static` for the foreseeable future. If shared text is ever needed, build
refcounted shared mappings first and evaluate `ld.so` after — the two are separable and the first one
is where the win is.**

---

## 4. WHAT FFMPEG SPECIFICALLY NEEDS

### 4.1 Method, so these numbers can be checked and disputed

Measured on this host against Homebrew's `ffmpeg 8.1.2` (`/opt/homebrew/Cellar/ffmpeg/8.1.2_1`), a
full-featured shared build:

```sh
# undefined symbols across the driver and all seven libav* libraries,
# minus everything those libraries define themselves,
# intersected with the platform C library's exported symbol set
nm -u <each>              -> 1504 distinct undefined symbols
nm -gU <each>             -> 1953 distinct defined symbols
comm -23                  ->  720 truly external
comm -12 (vs libsystem_{c,m,kernel,pthread,malloc}.tbd)
                          ->  204 libc symbols
```

**Caveats, stated up front.** This is a macOS build, so a handful of names are Apple-specific
(`__memcpy_chk`, `__stderrp`, `sysctlbyname`, `memset_pattern16`, `__sincos_stret`) and would be
different names for the same jobs against musl or glibc. It is also a *maximal* configuration —
network, TLS, AVFoundation capture, x264/x265/dav1d/opus. **It is an upper bound with a known shape,
not a target.** A `--disable-everything --disable-network --disable-pthreads` build is smaller, and my
**estimate** for that is **110–140 libc symbols**, because the floor is set by libm and stdio, neither
of which `--disable-` flags remove.

### 4.2 The three hard caps, and the number that reframes the project

**This is the section that matters.** Before any discussion of syscalls or symbols:

| this OS's limit | value | what ffmpeg needs | ratio |
|---|---|---|---|
| **`elfImageMax`** — largest image the loader reads | **65,536 bytes** | `libavutil.__text` **alone** is **355,944 bytes** (measured, `size -m`) | **5.4× too small for the utility library** |
| **`fatChainMax`** — largest file the filesystem returns | **262,144 bytes** | a minimal static ffmpeg, **estimate** 1.5–3 MB; the measured shared `libavcodec` is 9.6 MB | **≈10× too small, optimistically** |
| **the user address window** | **2,097,152 bytes total**, 512 pages, code + data + heap + stack | text alone, **estimate** 1.5–3 MB, plus decoder working buffers — a single 1080p YUV420 frame is 3,110,400 bytes | **the whole address space cannot hold one uncompressed frame** |
| **the stack** | **4096 bytes. One page.** | `libswscale` and `libavcodec` routinely use multi-kilobyte stack frames; ffmpeg's own recursion in filter graph setup is deeper than that | **the most likely silent failure on this list** |

**The stack is the one I would emphasise.** The other three fail loudly — the loader refuses, the
filesystem refuses. **A 4096-byte stack fails by running off the bottom of the page into the heap guard
page**, which does at least fault cleanly today (`heap.dart:146`), but which will look like a random
crash in whatever function happened to be deep. It is also the cheapest to fix: more pages at the top
of the window, and one guard page below them.

**So the honest headline: ffmpeg is not gated on dynamic linking. It is gated on the loader being able
to load a program that is measured in megabytes, into an address space measured in megabytes, with a
stack measured in tens of kilobytes.** None of that needs a relocation.

### 4.3 The syscalls — concretely

**What ffmpeg's core actually calls**, from the measured symbol list, reduced to the underlying kernel
operations:

| operation | this OS | status |
|---|---|---|
| `open` a file for reading | syscall 5 | **have** — but 8.3 names, root directory only, no paths, no flags |
| `read` | syscall 6 | **have** — 512 bytes max per call |
| `close` | syscall 7 | **have** |
| `lseek` | syscall 8 | **have, absolute only**; seek past EOF is refused, and there is **no `SEEK_END`** (GAP-0122 item 4) |
| `write` to a file | syscall 9 `fdwrite` | **have, APPEND ONLY.** No write-at-offset, no truncate-preserving open, no unlink (GAP-0127) |
| `write` to stderr/stdout | syscall 1 | **have but wrong shape.** 128 bytes max, prints `USER WRITE ` first, appends its own newline. One `printf` is one line. ffmpeg's logging would be unusable |
| `fstat` — **file size** | — | **MISSING, and needed.** `avio_size()` is used by essentially every demuxer. Today the only way to learn a file's size from ring 3 is a binary search on `seek`'s refusal |
| `brk`/`sbrk` | syscall 4 | **have** |
| `mmap`/`munmap` | — | **MISSING.** Used by `avio`'s file protocol and by `av_file_map`. Avoidable — the read path works without it |
| `clock_gettime`/`gettimeofday` | — | **MISSING.** `av_gettime()` is used for timestamps, rate control and progress. Not avoidable in the general case |
| `nanosleep` | — | **MISSING.** Avoidable in a non-realtime transcode |
| `isatty` / `tcgetattr` / `tcsetattr` | — | **MISSING.** Only the CLI's progress display; stub-able to "not a tty" |
| `sysconf(_NPROCESSORS)` / `sysctl` | — | **MISSING.** Only thread-count autodetection; stub to 1 |
| `pthread_*` (13 symbols measured) | — | **MISSING entirely.** No `fork`, no `clone`, no futex, nothing blocks (GAP-0141, `display-protocol.md` §0 constraint 4). **Avoidable: `--disable-pthreads`** |
| `getenv` | — | **MISSING.** No environment at all (GAP-0146). Stub to NULL |
| `arc4random_buf` | — | **MISSING.** Used for dither seeds and for `mkstemp`. Stub-able |

**The count.** ffmpeg's core needs roughly **13 distinct kernel operations** for a file-to-file
transcode: `open read write close lseek fstat brk exit clock_gettime` plus, if not disabled,
`mmap munmap nanosleep` and the thread primitives.

**This OS has eleven syscalls and seven of them are relevant.** The genuinely missing, genuinely
required ones are **three**:

1. **a file-size / `fstat`-equivalent** — small, and useful to everything, not just ffmpeg;
2. **write-at-offset** (or at minimum a seekable write) — because muxers patch headers, and an
   append-only file descriptor means only formats that never look back can be written at all;
3. **a clock** — some monotonic tick exposed to ring 3. The kernel already counts ticks
   (`isr.S`'s counter) so this is a syscall, not a driver.

Everything else on the list is either present, stub-able, or removable with a `configure` flag. **Three
syscalls is a small number and it deserves to be said plainly: the syscall surface is not what makes
ffmpeg hard here.**

### 4.4 The libc — concretely

**Measured**, across `libavcodec + libavutil + libswscale + libswresample` (i.e. excluding the CLI,
`libavformat`, `libavfilter` and `libavdevice`): **123 distinct libc symbols.** Across everything
including the driver binary: **204**.

Broken down:

| category | count (core four libs) | notes |
|---|---|---|
| **libm** | **42** | `sin cos tan asin acos atan atan2 exp exp2 log log2 log10 pow cbrt hypot fmod fabs frexp ldexp scalbn sinh cosh tanh` and their `f` variants |
| **string/memory** | 25 | `memcpy memmove memset memcmp memchr bzero strchr strrchr strcmp strncmp strlen strstr strspn strcspn strtod strtol strtoll strtoul strtoull strftime qsort bsearch wcslen` |
| **syscall wrappers + memory** | 24 | §4.3's list plus `malloc realloc free posix_memalign` |
| **pthread** | 13 | removable |
| **stdio** | 9 | `fopen fclose fread fseek fdopen fprintf fputs snprintf sscanf vsnprintf` |
| **misc/compiler runtime** | 10 | `abort assert errno stack_chk` |

**What this OS has, of those 123: eight — `open close free malloc memcpy memset strcmp strlen` — and
three of those eight have the wrong signature.** This OS's `open` takes a name and no flags and returns
a small integer; POSIX `open` takes flags and a mode. `read`/`write` differ likewise.

The C library is **33 public functions** (`oslibc.h`). **So the libc gap for ffmpeg's core is
approximately 115 functions**, and the two hardest clusters are:

* **libm, 42 functions.** This is not glue. `pow`, `exp`, `log` and the trig family to a defensible
  accuracy are real numerical work, and the only sane answer is to **port** one (musl's `libm` is the
  standard choice and is clean, freestanding-friendly C) rather than write one.
* **`printf`, properly.** This OS's has **five conversions and refuses everything else loudly**
  (GAP-0112) — which is exactly the right design for what it is for, and is nowhere near what
  `snprintf("%.3f")`, `%llu`, `%zu` and width/precision specifiers require. A real `printf` is
  ~600 lines and needs float formatting, which needs the float-to-decimal problem solved correctly.
* **`FILE`.** `rfile.c` is read-only by name and by design (`oslibc.h` explains why at length, and the
  reasoning is good). ffmpeg needs a read/write `FILE` with `fseek`, `fdopen` and buffering — which
  needs write-at-offset from §4.3 first.

### 4.5 The honest ordering

**ffmpeg is not the next application, and I do not think it should be the target that drives the
ladder.** It sits behind: a bigger address space, a bigger stack, a bigger image cap, a seekable write
path, a file-size call, a clock, a real `printf`, a real `FILE`, and a ported `libm`. That is five to
eight milestones of work in which ffmpeg itself is never once the thing under test — and this project's
own rule (ADR-0013 §4, ADR-0014 §4) is that you do not build X to prove Y, because then X becomes the
thing under test.

**A better forcing function is a program that is 500 KB, uses `libm` and a real `printf`, reads a file,
seeks in it and rewrites part of it.** That exercises everything on the list above, is buildable in an
afternoon, and produces a byte-exact golden. **`bzip2` or a PNG encoder is roughly the right size.**
When one of those runs, ffmpeg is a `configure` line and a lot of patience. Until one of them runs,
ffmpeg is not close.

---

## 5. THE MILESTONE LADDER

Binary exit criteria only, in this repo's discipline. **`X` for exec.** Items are ordered by
dependency; `X4` is the only one that is optional in the sense that the ladder works without it.

Each item names what must be *derivable from outside the kernel*, because that is what this project's
harnesses do (ADR-0014 §7: nothing is taken from the kernel's own report).

---

### X1 — A program larger than 64 KiB runs

`elfImageMax` is 65,536 (`elf.dart:767`) and is a bound, not a principle. The loader already streams
sectors; the cap is arithmetic.

**Exit:** a program whose `PT_LOAD` file bytes total **more than 512 KiB** loads and runs and exits
with a status `derive.py` computed from its own file. A program above the new cap is refused with
`elfErrImageSize`'s sentence. The frame allocator's free count is identical before and after, to the
frame. The 64 KiB constant appears nowhere in the tree.

---

### X2 — A program's address space is larger than 2 MiB

`vm.dart:1958` records 62 unused page-directory entries in `[128 MiB, 1 GiB)`. Widening the window uses
entries that already exist. This moves `vmProgEnd`, `heapTop`, `heapTopIndex`, `vmProgStackPage` and
every harness that asserts an exact page set. **`display-protocol.md` §1.2 asks for the same thing for
a different reason, and they should be one milestone, not two.**

**Exit:** a program with a **6 MiB `.bss`** runs, writes a byte at the top of it and reads it back;
`m12-heap`'s guard page is still asserted absent from the live tables, at its new index, read out of
guest physical memory; the window's page-directory entries are all absent after teardown; every one of
the five window constants is multiplied out against `derive.py`'s independent copies and against the
address `prog.ld` actually links at.

---

### X3 — A program's stack is larger than one page

`vmProgStackPage` is one page (`vm.dart:1997`). This is the item most likely to be skipped and it is
the one whose absence produces the least legible failure.

**Exit:** a program recurses to a **measured** depth requiring more than 64 KiB of stack and returns
the right answer; a program that recurses past the new limit takes a page fault on the **guard page
below the stack** and the kernel's report names it as such, with `RIP` and `OP` correct
(`vmFetchSafe`, ADR-0014 §6). `check-stack.py` still validates the ABI-conformant initial stack
(ADR-0023 §1) at the new top, unchanged in every other assertion.

---

### X4 — `.osx`, if it is wanted *(optional; §1.4 recommends deferring)*

**Exit:** `tools/mkosx.py` builds `PROG.OSX` from an unmodified `prog.elf`;
`dd if=PROG.OSX bs=512 skip=2 | readelf -l -` reproduces `readelf -l prog.elf` byte for byte;
`run PROG.OSX` runs it and `run PROG.ELF` still runs the bare ELF; **eleven refusals, eleven distinct
sentences**, each triggered by a container that is `PROG.OSX` with **one field changed** (the
`m10-elf` method); a container whose `abiLevel` exceeds the kernel's is refused **before a frame is
allocated**; a container whose `syscallHigh` exceeds the kernel's is refused likewise; a corrupted
payload byte is caught by `elfSum` and the program is **not** entered — proved by QEMU's own
`info registers` showing the machine never reached CPL 3.

---

### X5 — A program can learn a file's size and write at an offset

The three genuinely missing syscalls from §4.3, minus the clock.

**Exit:** a program `open`s a file, asks its size, and the number equals the FAT directory entry's size
as read **by a host tool on the image**; a program writes a placeholder header, writes a body, seeks
back, rewrites the header with the body's real length, closes — and the resulting file is byte-identical
to one the host produced; `mtools`/`fsck` still believe the volume (GAP-0130's discipline).

---

### X6 — A clock reaches ring 3

**Exit:** a program reads the clock twice around a busy loop of known length and the difference is
monotonic, non-zero, and within a stated tolerance of the PIT's known rate; two programs interleaved by
the preemptive scheduler each see monotonically increasing values; the value survives a `yield`.

---

### X7 — The C library is a real C library

`libm` ported (musl), `printf` with the full conversion set including floats, a read/write `FILE` over
X5. **This is the largest single item on the ladder and it is userland, not kernel.**

**Exit:** a manifest of required symbols is checked by `nm -u` against the built library with **zero
undefined**; `printf("%.6f", x)` for a table of derived values matches the host's `printf` byte for
byte; `pow`/`exp`/`log`/`sin` match a host-computed reference to a stated ULP bound over a derived
table of inputs; `%!` never appears in a capture.

---

### X8 — A 500 KB real application runs

`bzip2`, a PNG encoder, or equivalent — §4.5's forcing function. **Unmodified upstream source**, plus
a `configure`/`Makefile` patch that is committed and reviewable.

**Exit:** the program compresses a derived input file and the output is **byte-identical** to the
host's; it decompresses its own output back to the input; the harness builds it from upstream source at
a pinned version, and the patch is required to touch **no `.c` file**.

---

### X9 — `ET_DYN` and `R_X86_64_RELATIVE` *(the first genuinely linker-shaped item)*

Kernel-applied relocation, still no interpreter, still no shared libraries. This is §3.1's first row
and nothing else.

**Exit:** the **same source** built `-pie` and `-no-pie` produces identical program output and exit
status; the PIE is loaded at a base that is **not** its `p_vaddr`, proved by QEMU's `info registers`
showing `RIP` at `base + e_entry` and by a page-table walk out of guest physical memory; the auxv
carries `AT_PHDR`, `AT_BASE`, `AT_ENTRY`, `AT_PHENT`, `AT_PHNUM`, `AT_PAGESZ` and `check-stack.py`
validates every one out of memory; a file with a relocation type the kernel does not implement is
**refused by name**, never skipped.

---

### X10 — Shared read-only text between two processes *(not `ld.so`; §3.4's recommendation)*

Frame refcounting and a shared mapping. The thing that actually buys what dynamic linking is for.

**Exit:** two processes run the same program image and the frame allocator's free count shows the text
frames counted **once**; killing one process does not unmap the other's text; killing both returns
every frame; `display-protocol.md` §1.3's unsound-double-mapping hazard is closed and the harness
asserts the refcount out of the kernel's own structures **and** the page tables independently.

---

### X11 — `PT_INTERP` and an `ld.so` *(gated on `mmap`; see §3.2)*

Deliberately last, deliberately marked as gated on a memory-management milestone that is not on this
ladder because it belongs on someone else's.

**Exit:** two programs share one `libc.so`; the shared library's text frames are counted once by
`frames`; a missing `DT_NEEDED` library is a **named refusal at load time**, not a null call at run
time; an unresolved symbol is a named refusal, not a jump to zero; the link is `-z now` and the harness
asserts by disassembly that no lazy PLT stub is ever executed.

---

## 6. Open questions I am not answering

Six, and the first two are the ones that change this document.

**Q1. Does oscortex intend to keep using `clang` and `x86_64-elf-ld` indefinitely?** §1.4's whole
recommendation rests on "the toolchain already emits ELF". If the long-term plan is a `dcc`-driven
native linker, `.osx` becomes much more attractive and §2 becomes a waypoint rather than a destination.
**CLAUDE.md's escalation rule — hard-to-reverse toolchain decisions — applies.**

**Q2. Is `.osx` wanted as an identity statement, or as an engineering improvement?** Both are legitimate
and they lead to different designs. If it is identity, §2's container is the cheapest honest way to have
it, and I would recommend saying so in the ADR rather than constructing engineering reasons after the
fact — `display-protocol.md`'s provenance note is the model.

**Q3. Should `run` sniff magic and accept both, or should one form be removed?** §2.8. I recommend
sniffing; I have not thought about it as hard as whoever builds it will.

**Q4. Is the ffmpeg goal "ffmpeg specifically" or "an application of that class"?** §4.5's argument is
that a smaller forcing function gets there faster and produces better milestones. If it must be ffmpeg
by name, the ladder is the same but X8 becomes much longer.

**Q5. Where do libraries live when there are libraries?** GAP-0116: flat root, 8.3 names, no
subdirectories. `display-protocol.md` §2.4 has already proposed that `fatLookup` learn **one** reserved
name. A search path is a much bigger version of the same question and the two should be decided
together, not separately.

**Q6. What is `abiLevel` actually counting?** If §2's container ships, someone must define what
increments it — the syscall table, the initial stack layout, the address window, or all three. A
version number nobody knows when to increment is a version number that never increments.

---

## 7. One correction found while reading

`known-gaps.md` GAP-0147 cites **GAP-0096** for "there is no dynamic linking". GAP-0096 is *"What a
process does NOT do"*; the dynamic-linking gap is **GAP-0091**. One character, and it points a reader
at the wrong page. Recorded here rather than fixed, because this document's scope is one file and
`known-gaps.md` is not it.
