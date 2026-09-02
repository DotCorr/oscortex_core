# The first oscortex app framework — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered.** FRAME1 is implemented
(`core/user/frame/osframe.h`, 8.3 `FRAME.H`, harness `frame1/`). FRAME2
is implemented (`core/user/frame/surf.c`, `SURF.ELF`, harness `frame2/`).
FRAME3 is implemented (same client, `kbdevent` + `THEME.DAT`, harness
`frame3/`). FRAME4 and later are not. This file is product intent stated against what the
machine can do today. When a piece is built it gets its own numbered ADR;
this document is the thing those ADRs will point back at.

**It cites rather than re-derives.** The two doors into ring 3, the 8.3 root, and the
absence of `opendir` are `applications.md`'s. The verb protocol that was designed and
the pixel surfaces that were actually built are `display-protocol.md`'s and ADR-0051's.
The device sigil and the `fileSysOpen` placement are `namespace.md`'s. The 65,536-byte
image and the 2 MiB window are `exec-format.md`'s. The libc counts are
`libc-roadmap.md`'s. Input-as-a-queue is ADR-0054. The resident process is ADR-0053.
The reflective membrane is GAP-0166, quoting DCDart escalation 0004 §6. **No syscall
is invented here. GPU, Wi-Fi and SSH are not claimed.**

**Provenance of the product ask.** The owner wants an in-built first "app" / SDK that
exposes OS APIs so more apps can be written in DCDart; a copy that ships on the
machine, with later copies downloadable; every app (and the OS) reflective so an AI
driver can inspect and drive the whole UI; and persist-or-discard of live edits
("right-click edit whatever you see"). That is the intent. The rest of this document
is what of that intent is true today, what is next, what is blocked on DCDart, and
what is fantasy.

---

### The five things this document lands on, for a reader in a hurry

1. **The first SDK is a host-side header and a syscall table, not a Dart runtime on
   the guest.** `oslibc.h` wraps eleven of the allocated numbers and none of
   `wmsurface` / `kbdevent` / `mouse` / the shm and channel calls
   (`syscall-registry.md`). A program that wants a window today copies constants
   into its own `.c`, the way `d2-compositor/prog.c` does. The framework's first
   deliverable is that those constants live in one place a second author can
   include, plus a copy of the same bytes on the FAT volume under an 8.3 name.
2. **The first in-built app is a tiny surface client**, the same four steps
   `d2-compositor/prog.c` already runs: `shmcreate`, `wmsurface` attach, paint,
   commit. It is freestanding C or `@bare` DCDart compiled **on the host**.
   DCDart is not Dart; see `dcdart.md`. It does not assume sockets, `mmap`,
   `poll`, a blocked state, `String`, or reflection.
3. **`display-protocol.md` designed drawing verbs. ADR-0051 built pixel surfaces.**
   A FRAME client paints into a shared region whose address it was **told**, never
   derived (ADR-0051 §3). The withdrawn verb transport (`open(":WSYS")` /
   `fdwrite` a batch) is still the right long-term shape (`namespace.md` N5) and
   is not what a first app talks to today.
4. **Live-edit of compiled `@bare` is not possible** until DCDart reflection
   exists *and* a compiler or interpreter runs on the box. Persist of **data**
   (layout, colours) can use FAT writes now. Persist of **code** is a different
   project — `applications.md` §4.1.
5. **An AI driver attaches later by inspecting descriptors, not by rewriting the
   kernel.** Escalation 0004 §4 splits introspection from intercession.
   GAP-0166 records that `@extern` carries no descriptors today. The framework's
   honest first "reflective" artefact is a static table of the ABI it already
   has.

---

## 0. Horizon — TODAY / NEXT / BLOCKED ON DCDART / FANTASY

Four buckets. A sentence in this document that does not name its bucket is a
bug in the document.

### 0.1 TODAY — true of the tree this was written against

| fact | value | citation |
|---|---|---|
| two doors into ring 3 | `run <name>` gives `argv` and refuses `sbrk`; `proc run` / `proc spawn` give a heap and historically no `argv` | `applications.md` §1.1; GAP-0149; ADR-0053 for `proc spawn` |
| names | 8.3, twelve characters, root directory only; no `opendir` / `readdir` | `applications.md` §0; GAP-0122 item 2 |
| allocated syscalls | 0–10, 12–20, 23, 24. **11 is `fdwait` and is reserved, not built.** | `syscall-registry.md` |
| files | `open` / `read` / `close` / `seek` / `fdwrite`; one `read` or `fdwrite` is **512 bytes**; write is create+truncate+append | `applications.md` §0; GAP-0127 item 1 |
| surfaces | `wmsurface` (23): `wmOpAttach` / `wmOpCommit` on a 64-byte descriptor naming a **capability handle**; composition is synchronous inside the caller's syscall | ADR-0051 |
| pixels, not verbs | a client owns a shared-region rectangle in `0x00RRGGBB`; the kernel compositor blits damage (ADR-0052) | ADR-0050, ADR-0051; *contra* `display-protocol.md` §1.3 |
| keyboard | 32-event ring; ring 3 pops through `kbdevent` (24), `rdi = 0/1/2` | ADR-0054 |
| mouse | syscall 20 is a level poll; no focus; a click does not reach a client | ADR-0042; GAP-0253; GAP-0308 |
| residency | `proc spawn` returns; the shell is the idle context | ADR-0053 |
| compositor | **in the kernel** (`wm.dart`); D3 made a move expressible, it did not perform it | ADR-0050; GAP-0300 |
| image / window / stack | `elfImageMax = 65,536`; address space `[0x10000000, 0x10200000)` = **2 MiB**; stack **one 4096-byte page** | `exec-format.md` §0 facts 2, 4, 5 |
| libc | **41 symbols, 9 of them C89**; `printf` is `%s %d %x %c %%`; no `errno`; `oslibc.h` has **no** name for 13–20, 23, 24 | `libc-roadmap.md` finding 1; `syscall-registry.md` |
| blocking | five process states, no sixth; nothing waits | GAP-0141; `display-protocol.md` §0 constraint 4 |
| no sockets, no `mmap`, no `poll` | a design that assumes them is a description of Linux | `display-protocol.md` §0 constraint 1; `exec-format.md` §3 |
| `@bare` | no `String`, no function pointers, no `switch`, no `&&` / `\|\|`, no growable collection | `display-protocol.md` §6 language table; DCDart GAP-0035, GAP-0023 |
| reflection | **not implemented.** Escalation 0004 is decided in principle, design not ratified. `@extern` is a name, not a descriptor. | GAP-0166; known-gaps reflection note under GAP-0051 (type descriptors belong in `.rodata`) |

Positively, a program today can: be told up to 8 arguments totalling 128 bytes
(`run` door); `open` four 8.3 files; `read`/`fdwrite` 512 bytes at a time;
`create` a file whose bytes survive reboot (M16, host `fsck_msdos`);
`shmcreate` a region, `wmsurface`-attach it, paint, commit; `kbdevent`-pop a
scancode+edge; `yield`; `exit`. That is enough for FRAME1–FRAME3.

### 0.2 NEXT — kernel or userland work, no new DCDart language feature

* A host-side header that names every allocated syscall and the 64-byte
  `wmsurface` layout, kept in agreement with `syscall-registry.md` the way
  `verify-syscall-registry.sh` already keeps the kernel and `oslibc.h` in
  agreement. **FRAME1. Done** — `core/user/frame/osframe.h`.
* The same header's bytes on the volume under an 8.3 name, so the first SDK
  copy ships on the machine. **FRAME1. Done** — `FRAME.H`, harness
  `core/tests/conformance/frame1/`.
* A tiny surface client kept as a userland program, not only as
  `d2-compositor/prog.c`. **FRAME2. Done** — `core/user/frame/surf.c`,
  `SURF.ELF`, harness `core/tests/conformance/frame2/`.
* That client reading `kbdevent`, and writing layout/colour **data** through
  `open` / `fdwrite`. **FRAME3. Done** — same `surf.c` with `-DFRAME3=1`,
  harness `core/tests/conformance/frame3/`.
* The reverse surface message — a click, a configure, an enter — which
  `display-protocol.md` calls D7 and GAP-0308 names. The eight-word descriptor
  already exists; the kernel compositor has no endpoint to send from
  (ADR-0050 §4). This document calls that direction `wmevent` **as a name for
  the existing message travelling the other way**, not as a new syscall number.
  Do not allocate one here.
* Closing the two-doors split so one program has `argv` and a heap
  (`applications.md` APP5 / GAP-0149).
* `namespace.md` N1 (`:NULL`) and eventually N5 (`:WSYS`), if the transport
  ever becomes the clone-file idiom the display design still recommends.
* `unlink` / `rename` so a save of data does not destroy the previous file
  (`applications.md` §3 tier 2; GAP-0127 items 3 and 8).

### 0.3 BLOCKED ON DCDART

These are a different repo's milestones first. `display-protocol.md` §6 already
marks the language table this way; this document adds the ones the product ask
depends on.

| wanted | blocked by | where |
|---|---|---|
| a program that knows its own fields, so an AI driver can ask "what is this widget" | runtime type descriptors in `.rodata`; escalation 0004 design not ratified; static data existed as a prerequisite and has since landed as ADR-0040/0051 on the DCDart pin, **the descriptors themselves have not** | escalation 0004 §4, §5, §8 items 2–3; GAP-0166 |
| `@extern` that describes what it takes and returns, not only that a name may be undefined | escalation 0004 §6 option 3; DCDart ADR-0038 is a name sidecar | GAP-0166 |
| `String` / client titles / named widgets | DCDart GAP-0035 (`unsupported expression StringLiteral`) | `display-protocol.md` §6 |
| live-edit of **compiled** `@bare` (change a function and keep running) | introspection *and* intercession (escalation 0004 §4); a condition system (escalation 0005) so a fault does not halt; **and** a compiler or interpreter on the guest | §4 below; `applications.md` §4.1 |
| a hosted Dart SDK / `dcc` on the guest | Dart 3.12.2, a JIT or AOT runtime, GC, threads, `mmap`, sockets, directories | `applications.md` §4.1; `libc-roadmap.md` ("not a libc port, it is a Linux personality") |
| exact damage regions, handler tables, compound predicates | no growable collection, no function pointers, no `&&` | `display-protocol.md` §6 |

**Escalation 0004 was read from the host sibling
`dc_sys/DCDart/core/docs/escalations/0004-runtime-reflection.md`.** It is not
present in this scratchpad tree. The in-repo record of its §6 is GAP-0166, and
the in-repo record of its `.rodata` thesis is the reflection paragraph under
GAP-0051 in `known-gaps.md` (type descriptors, field tables, name strings,
condition descriptors and restart tables belong in `.rodata`; a silently
corrupted descriptor is the worst failure mode of the design).

### 0.4 FANTASY — do not plan, do not cost, do not imply

* **GPU, Wi-Fi, SSH.** Not in the kernel. `gpu.md` sizes a VirtIO-GPU 2D
  *design*; nothing here claims a GPU exists. There is no network stack
  running, and no remote shell.
* **A hosted Dart SDK on the guest** as the thing a user "downloads later."
  What can be downloaded later is the **host-side** header and a
  cross-compiled ELF, the same way the first copy shipped.
* **Live-edit of code** ("right-click, change the handler, persist the
  function"). That is DCDart reflection plus in-guest development. Both are
  named elsewhere. Neither is this ladder.
* **An AI driver that rewrites the kernel** to understand the UI. The driver
  attaches as a resident process (or a host-side inspector of tables this
  framework already emitted). See §5.
* **Wayland, GTK, Mesa-in-the-compositor, sockets, `mmap`, `poll`, blocking
  `read`.** `display-protocol.md` §5.2 and GAP-0141.
* **`fork`, `exec`, a POSIX signal implementation, an environment, job
  control.** `applications.md` §5.1.
* **Self-hosting `kernel.elf`.** The kernel is DCDart compiled by `dcc`.
  `applications.md` §4.1: that is a different project.

---

## 1. What the product ask is, restated against the machine

Four sentences of intent, each followed by the honest reduction.

**"An in-built first app / SDK that exposes OS APIs so more apps can be written
in DCDart."** Today DCDart on this OS means `@bare`, compiled on the host by
`dcc`, or freestanding C compiled by `clang -target x86_64-unknown-none-elf`
(`exec-format.md` §1.2; ADR-0014 §2). There is no guest-side language runtime.
The SDK that unblocks a second author is **the ABI written down once**: syscall
numbers, refusal floors, the 64-byte surface descriptor, the `kbdevent` packed
word. Apps in DCDart come later, when `@bare` can express the same header and,
much later, when reflection exists.

**"Users can also download the SDK later; the first copy ships on the
machine."** The volume is FAT16, 8.3, root only (`applications.md` §0;
`namespace.md` §3: paths are not now). "Ships on the machine" means a file
such as `OSXABI.H` or `FRAME.TXT` in the root directory of the image the
harness already builds. "Download later" means a host fetches a newer header
and cross-compiles; it does not mean a package manager, sockets, or an in-guest
`dcc`.

**"All apps (and the OS) are reflective so an AI driver can inspect and drive
the whole UI."** Escalation 0004 §1 is the thesis: programs that know what they
are, so an agent does not reconstruct layout from a debugger. **Nothing in
either repo implements it.** GAP-0166: an `@extern` declaration carries no
descriptors. The framework can, today, emit a **static** description of *its
own* ABI (option 3 of escalation 0004 §6 — describe the boundary). That is not
reflection. It is the thing a future reflective runtime would read first.

**"Persist or discard live edits (right-click edit whatever you see)."** Split
it. **Data** (a colour, an `x/y/w/h`, a title stored as bytes) can be written
with `create` / `fdwrite` / `close` today; the write destroys the previous
contents of that 8.3 name (GAP-0127 item 1) and there is no `rename` to swap
in a temp (item 8). **Code** (the function that painted the pixels) is an ELF
text segment under W^X (`elfErrWx`, `exec-format.md` §3 tier 4). Editing it
live is §4.

---

## 2. Verbs versus the surfaces we actually built

`display-protocol.md` §1.3 withdrew shared-frame *and* copy-on-commit-of-pixels
as the transport, because `fileWriteMax` is 512 bytes = 128 pixels, and
recommended Plan 9 drawing verbs over `open(":WSYS")`. `namespace.md` answered
Q1: the branch belongs in `fileSysOpen`, never `fatLookup`, and the name carries
a `:` sigil.

**That is not what shipped.** ADR-0051 is one syscall, a 64-byte descriptor,
no address in it, pixels in a shared region the caller already holds a
capability to. ADR-0050 put the compositor in the kernel because D3 had not
landed; D3 has now landed (ADR-0053) and the compositor is still in the kernel
(GAP-0300). ADR-0052 made damage a number. ADR-0054 put keys on a queue.

A FRAME client is a client of **ADR-0051**, not of the verb document:

```
  shmcreate(pages)        -> handle          syscall 16
  wmsurface(desc)         -> address         syscall 23, op = wmOpAttach
      desc.word0 = 1
      desc.word1 = handle
      desc.word2..5 = x, y, w, h
      desc.word6 = stride (0 => w*4)
      desc.word7 = byte offset of pixel (0,0)
  paint at the address rax returned
  wmsurface(desc)         -> 0               syscall 23, op = wmOpCommit
      desc.word2..5 = damage rectangle
```

`d2-compositor/prog.c` is the existence proof. It is freestanding, contains no
address literal, and is entered with an empty stack (GAP-0149). **The
framework does not invent a friendlier syscall on top of this.** It writes the
layout down so the next program does not paste it.

The verb transport remains the right answer *if* a second server appears, or
if pixel upload through `fdwrite` is ever attempted. It is `namespace.md` N5
and it is NEXT, not TODAY. FRAME does not wait for it.

`wmevent` is D7 / GAP-0308: the same eight words the other way. A client is
not told where it was placed, when it moved, when the pointer entered, or when
it was clicked. Until that lands, FRAME3 reads **keys** (`kbdevent`) and
**polls** the pointer (syscall 20, GAP-0253: every program sees the same
coordinates). It does not pretend a click arrived.

---

## 3. The first SDK, and the first app

### 3.1 Recommendation

**Ship two artefacts, both small, neither a language runtime.**

1. **Host-side `osframe.h`** — syscall numbers copied from
   `syscall-registry.md`, the `wmsurface` eight-word overlay from ADR-0051 §2,
   the `kbdevent` ops from ADR-0054 §2, the `mouse` packed word from ADR-0042,
   and the refusal floors those ADRs already name. A structural check: the
   numbers agree with the registry script that already exists. `oslibc.h`
   stays the C library; this header is the **rest** of the ABI the library has
   not wrapped. `@bare` DCDart gets the same numbers as `@rodata` words or as
   integer literals in a sibling `osxabi.dart`. There is no hosted Dart SDK
   on the guest, and this document will not propose one.
2. **A tiny surface client on the volume** — one 8.3 name, one ELF ≤ 65,536
   bytes, built on the host, started with `proc spawn` so it can outlive the
   command (ADR-0053). It creates a small surface (256×256 is the size
   `display-protocol.md` §1.2 recommended while the 2 MiB window still binds),
   paints a solid colour, commits, and stays resident. That is the first app.
   Everything else a "framework" usually means — widgets, a scene graph, a
   package manager — is not expressible in `@bare` and not loadable in 64 KiB.

The pair is what "in-built SDK" means on this machine: **headers you compile
against, and one program that proves they work.** A later download is a newer
header plus a newer ELF, produced on a host.

### 3.2 What a second app is written in

| language | TODAY | honest limit |
|---|---|---|
| freestanding C | **yes** — every harness program already is | `oslibc.h` if you want `printf` / `malloc`; `malloc` only through the `proc` door (`applications.md` §1.1) |
| C + `oslibc.h` | **yes**, same doors | 41 symbols; `%02x` is `%!` (`libc-roadmap.md` L4) |
| `@bare` DCDart | **yes on the host** — `dcc` emits `x86_64-unknown-none-elf` | no `String`, no collections, one return value, volatile every `Pointer` (GAP-0034) |
| hosted Dart / `dcc` on the guest | **no** | `applications.md` §4.1 |

Static `.bss` is the memory model of userland that has `argv`
(`applications.md` §1.1). A FRAME client that needs a pixel buffer either
uses the **region `wmsurface` already mapped** (the right answer) or declares
a `.bss` array inside the 2 MiB window. It does not call `malloc` unless it
came through `proc spawn` / `proc run` and can live without arguments.

### 3.3 Bounds the first app must fit

From `exec-format.md` §0 and `applications.md` §0, restated because a framework
that ignores them is fiction:

* image ≤ 65,536 bytes (X1 is the milestone that moves this);
* the whole process lives in 2 MiB, of which a full-screen surface is 1.92 MB
  (`display-protocol.md` §1.2) — **small surfaces only**;
* stack = 4096 bytes (X3);
* four descriptors (`fileMaxFds`); a surface client that also opens a colour
  file uses two of them if it ever takes the `:WSYS` path, and **zero** of
  them if it only talks `wmsurface` / `kbdevent` / `shmcreate`;
* one `fdwrite` is 512 bytes — fine for a colour record, useless for a
  bitmap (`display-protocol.md` §1.3);
* 8.3 names, no directory listing, so the app is told its data file's name
  or uses a name it baked in.

---

## 4. Persist and live-edit — data now, code not

Two different projects that the product sentence collapses.

**Data.** A colour (`u32`), a geometry (`x y w h`), a one-line label stored as
bytes — these are FAT files. `create` / `fdwrite` / `close` persist them;
M16 already proved the host's `msdos` driver believes the volume
(`applications.md` §1.3). Limitations, named rather than discovered:

* `O_WRITE` is create+truncate+append, indivisibly (GAP-0127 item 1). Saving
  over `COLOUR.DAT` destroys the old bytes at the first write. The safe idiom
  is write-temp-and-rename, and there is no `rename` (item 8). FRAME3 may
  write a new name (`COL2.DAT`) or accept the destroy-on-save. It must not
  claim atomic persist.
* There is no `opendir`. The app cannot discover `COLOUR.DAT`; it knows the
  name or it was told via `argv` (`run` door only).
* Right-click is a pointer event delivered to a client. That is GAP-0308.
  Until D7, "edit whatever you see" has no hit-test that the **client**
  receives. The kernel compositor already hit-tests for *its* drag
  (ADR-0050 §2.3, `wmHit`). That policy is not a FRAME API.

**Code.** A compiled `@bare` function is bytes in an `ET_EXEC` `PT_LOAD`
under W^X. There is no interpreter on the guest, no `dcc` on the guest, no
type descriptor, no method table, and no condition system
(escalation 0004 §3 items 1–4; §8 still open). **Live-edit of compiled
`@bare` is not possible until DCDart reflection *and* a compiler or
interpreter on the box.** Persist of code — write a new ELF and `run` it —
is `applications.md` APP10 / `exec-format.md` X1+X3 plus a heap+`argv`
program (APP5). That is in-guest development. It is not this framework.

Discard of a live **data** edit is "do not `fdwrite`." Discard of a live
**code** edit is not a FRAME operation.

---

## 5. How an AI driver attaches later

The product wants a driver that inspects and drives the whole UI. Escalation
0004 §1 says the point of reflection is that the agent does not reconstruct
the program from outside. GAP-0166 says the membrane has no mechanism yet.

**Attach, do not rewrite.** The kernel's job is already specified: surfaces,
a queue of keys, a compositor that owns scanout because ring 3 cannot `out`
(ADR-0050 §2 point 1; `display-protocol.md` §3.1). A driver that patched
`wm.dart` to "understand widgets" would put policy in the kernel that
ADR-0050 already regrets putting there (GAP-0302, GAP-0300). The driver is a
**resident process** (ADR-0053) — or, until reflection exists, a host-side
reader of tables the framework wrote.

**What it inspects, in order, as the layers actually land:**

1. **TODAY / FRAME1.** A static ABI table: syscall numbers, descriptor field
   names and offsets, refusal floors. Bytes. A driver (or a human, or
   `derive.py`) can read them without any language feature. This is
   escalation 0004 §6 option 3 applied to *our* boundary rather than to Mesa:
   the interface is described even though the implementation is the kernel.
   ADR-0029 §7 already specified this shape for DRM — a build-time generator,
   not a DCDart escalation (GAP-0166 item 1). FRAME does the same for
   `wmsurface` / `kbdevent`.
2. **NEXT / D7.** Surface events the other way. The driver sees the same
   eight-word messages a client sees. It does not get a widget tree, because
   there is no widget tree.
3. **BLOCKED ON DCDART.** Type descriptors, field tables, name strings in
   `.rodata` (escalation 0004 §4 introspection; known-gaps reflection note
   under GAP-0051). *Then* a driver can ask "this memory is the colour field
   of the first app" without a debugger. Intercession — replacing a method
   while it runs — is the other half of §4 and is opt-in even in the
   escalation's own recommendation. The driver should not need it to *drive*
   the UI: driving is sending the same attach/commit/event records a human
   client sends.
4. **FANTASY.** A driver that becomes the compositor, or that writes kernel
   code, or that reflects through Mesa. Mesa stays a zombie at the
   implementation (ADR-0029 §7(d); GAP-0166). FRAME will not claim otherwise.

**What it does not do.** It does not require sockets. It does not `mmap` the
framebuffer (ring 3 never touches VRAM, `display-protocol.md` §3.4). It does
not block (`read` of a future device returns 0; `kbdevent` returns 0 when
empty; `yield` is the loop). It does not parse Dart source on the guest.

---

## 6. The FRAME ladder

`applications.md` already took **APP**. Single-letter prefixes are exhausted
(`design/README.md` names the collisions). This ladder is **FRAME**. Identity
with an existing milestone is stated rather than counted twice.

Each early criterion follows the repo's derived-expectation rules
(`display-protocol.md` §6): compute the expectation from a source the kernel
does not control; restate constants in the harness and assert them against
the kernel; guard a vacuous pass; carry a negative control.

**FRAME1–FRAME3 assume no new syscall, no `String`, no reflection, no
blocking, no `mmap`, no sockets, no `poll`.**

---

### FRAME1 — The ABI is written down once, and a copy of it boots

**Done.** Host files plus one freestanding program. Touches no kernel file.
Header: `core/user/frame/osframe.h` (DCDart sibling `osframe.dart`). 8.3
copy: `FRAME.H`. Harness: `core/tests/conformance/frame1/` (PASS).

Deliverable: `osframe.h` (and a DCDart sibling of the same numbers) whose
syscall table is a structural subset of `syscall-registry.md` — every number
it names matches the registry, and it names at least `write`, `open`,
`read`, `close`, `fdwrite`, `shmcreate`, `wmsurface`, `kbdevent`. A
`FRAME.H` 8.3 file on the volume is the same table as bytes. A program
`ABITST.ELF` `open`s that file, `read`s it in 512-byte strides, and
`write`s a host-derived checksum (or a length and a first-line tag). That
is the in-built SDK: **headers on the host, a copy on the machine, a
program that can see the copy.**

*Binary:* `run ABITST.ELF` (name baked — the `run` door) prints a checksum
`derive.py` computed from the file `make-image.py` planted; after the boot
the volume file is unchanged (`fsck_msdos` clean).
*Anti-vacuity:* the planted table is longer than 512 bytes and contains at
least two distinct syscall rows, so a program that hashes one sector of
zeros fails.
*Negative control:* a volume whose `FRAME.H` was truncated by one row
fails the checksum.

This is also the artefact §5 step 1's future driver reads.

---

### FRAME2 — A surface client exists that is not a harness

**Done.** Kept client `core/user/frame/surf.c` compiled against `osframe.h`
(no private `SYS_*`). Harness `core/tests/conformance/frame2/` (PASS).
`proc spawn` starts `SURF.ELF` so the prompt returns (ADR-0053).

The kernel already ran this program as `d2-compositor/prog.c`. FRAME2 is that
program **kept**, compiled against `osframe.h` rather than private `#define`s,
and startable with `proc spawn` so it outlives the command (ADR-0053).

*Binary:* `proc spawn` the client; `wm on` if the mode word is still
required (ADR-0050); the visible framebuffer dump (`xp` at the address the
kernel printed — `display-protocol.md` D4's method) shows a rectangle of the
derived colour and background outside it. The client contains **no**
`0x10200000`-class literal; `build-progs.sh` already greps for that in
`d2-compositor` and the same grep moves here.
*Anti-vacuity:* expected surface area is not zero pixels.
*Negative control:* a client that attaches and never commits leaves the
framebuffer at background (D4's own control).

Uses existing syscalls only: `shmcreate` (16), `wmsurface` (23), `write` /
`exit` as diagnostics. Small surface — 256×256 or the 240×160
`d2-compositor` already uses — because of the 2 MiB window
(`display-protocol.md` §1.2).

---

### FRAME3 — The same client reads keys, and can persist a colour

**Done.** Same kept client `core/user/frame/surf.c` compiled `-DFRAME3=1`
against `osframe.h`. Harness `core/tests/conformance/frame3/` (PASS).
`proc spawn SURF.ELF` on a FAT volume; click-to-focus (D9) so the spawned
client is the consumer. On derived key `'c'` it `fdwrite`s four bytes to
`THEME.DAT`. Host `fsck_msdos` + msdos read-back (M16).

**Blocked on: FRAME2 (done), and on nothing else.** `kbdevent` is built (ADR-0054).

The client pops syscall 24 in a `yield` loop (`display-protocol.md` §2.2's
temporary form; `fdwait` is reserved as 11 and is not available). A derived
scancode changes the fill colour; a commit of the damage rectangle follows
(ADR-0052). Optionally it `create`s `COLOUR.DAT` and `fdwrite`s the `u32` —
**data** persist, append-only, destroy-on-save accepted and documented.

*Binary:* with the client resident, the harness injects N keys at 50 ms
(ADR-0054's method); the framebuffer's surface rectangle holds the colour
`derive.py` computed from the last make-scancode; if persist is in this
milestone, the host reads `COLOUR.DAT` back and it matches that `u32`.
*Anti-vacuity:* two keys that map to two different colours are injected; a
client that ignores the queue cannot pass both.
*Negative control:* a build that never calls `kbdevent` fails the colour
assertion; a persist build that `fdwrite`s `sizeof buf` instead of 4 bytes
fails the host read-back (the `cp` negative control from `applications.md`
APP1, applied to four bytes).

**`wmevent` is not in this milestone.** When GAP-0308 closes, the same loop
gains a second reader of the eight-word descriptor. FRAME3's header reserves
no number for it. If a later ADR names a syscall, it takes a row in
`syscall-registry.md` in that commit, not here.

---

### FRAME4 — One program has arguments and a heap *(identity: APP5)*

**This is `applications.md` APP5 / GAP-0149 and is not restated.** FRAME
clients that want `argv` (which file to open) and `malloc` (a widget list)
wait on it. Counted once, on the APP ladder.

---

### FRAME5 — A click reaches the client *(identity: D7)*

**This is `display-protocol.md` D7 / GAP-0308 and is not restated.**
Right-click-to-edit, even of **data**, is blocked on it. The kernel already
hit-tests for its own drag (ADR-0050). FRAME does not grow a parallel
hit-test.

---

### FRAME6 — The ABI table is field-accurate, and a driver can parse it
without DCDart

**Blocked on: FRAME1.** Still no language reflection. The table grows from
"syscall number + name" to per-descriptor field lists — word index, byte
offset, width, "must be zero" — the same category ADR-0029 §7 specified for
DRM and GAP-0166 item 1 said must **not** become a DCDart escalation. A
host-side parser, and a guest program that `read`s the table and prints one
derived field offset, are the criterion.

This is as reflective as this OS can be before escalation 0004 ships
descriptors. It is the attach point §5 step 1 named.

---

### FRAME7 — Introspection of a FRAME app's own objects

**Blocked on DCDart:** escalation 0004 §4 introspection (type descriptors,
field tables) ratified and implemented; the `.rodata` protection thesis
under GAP-0051 closed or accepted as residual. **Not blocked on a new
oscortex syscall.**

Until then, a FRAME app that "exposes widgets to the AI driver" is a
hand-written table of offsets in `FRAME.TXT`. That is FRAME6, not this.

---

### Capstone, with no binary criterion — live-edit of code, and a hosted SDK

Stated so they are not attempted under this prefix. Live-edit of compiled
`@bare` needs FRAME7, intercession (escalation 0004 §4, opt-in), a condition
system (escalation 0005), and in-guest development (`applications.md` §4,
`exec-format.md` X1/X2/X3). A hosted Dart SDK on the guest is the same
paragraph as "this OS building itself." **This entry exists to say so.**

---

## 7. What I did not decide, and would rather be told

1. **Is the first app allowed to be C forever, with `@bare` as a second
   source of the same ELF?** The product sentence says "written in DCDart."
   `@bare` can paint pixels today. It cannot name a widget. I recommend C
   for FRAME1–FRAME3 (every existing client is C) and a `@bare` twin of
   FRAME2 as soon as someone wants it, not as a gate.
2. **Does `SURF.ELF` start through `proc spawn` (resident, no `argv`) or
   `run` (argv, no `malloc`)?** The surface client does not need a heap if
   it paints in the shm region. It needs residency more than it needs
   arguments. I recommend `proc spawn` and a baked-in data-file name.
   APP5 deletes the question.
3. **Who owns input when the surface client is resident?** ADR-0054: while
   `shellState == 2` the shell drain does not consume, so a `run` program
   gets the keys. A `proc spawn`ed client shares the machine with a live
   prompt. Q3 in `display-protocol.md` §7 is still open; GAP-0253 is still
   open. FRAME3's harness must state which consumer is expected, not assume.
4. **Confirm that `wmevent` is not a syscall number.** I have treated it as
   GAP-0308's reverse descriptor. If the owner wants a dedicated syscall,
   that is a registry row in the ADR that builds D7.

---

## 8. Notes for the coordinator to fold in elsewhere

* **This ladder is FRAME, because APP is taken.** `applications.md` APP1–APP10
  is the Unix-tooling ladder (`cp`, `ls`, a userland shell). This is the
  *surface-and-ABI* ladder. They share APP5 ≡ FRAME4. Count it once.
* **FRAME2 is not a new compositor property.** D4/D5/D6 already proved a
  client can attach and commit. The milestone is "that client is a shipped
  program against a shipped header."
* **`oslibc.h` still says "THERE IS STILL NO INPUT"** in its file comment.
  ADR-0054 made that sentence false for a program that declares
  `SYS_KBDEVENT` itself. The header comment is stale in the same class as
  `stale-comments.md`. Not edited here.
* **Reflection remains in `design/README.md`'s "not yet specified" column
  after this document.** FRAME6 is a static table, not that column. FRAME7
  is blocked on DCDart and is not a specified oscortex implementation.
* **GAP-0166 is not reopened and not closed.** This document takes its
  option-3 recommendation for the FRAME boundary the way ADR-0029 took it
  for DRM.
