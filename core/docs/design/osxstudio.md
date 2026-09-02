# OSXStudio — a FRAME app that lists what an app can call, not an IDE

**Status: DESIGN. Not an ADR, not numbered.** OSXStudio is not writable
as a project and is not a builder. STUDIO1 listing is done (`studio1/`).
STUDIO2 launch is done (`studio2/`, ADR-0078): a catalog name starts
as a resident process. STUDIO2b persist is done (`studio2b/`, ADR-0119):
`SEL.DAT` remembers the last launched row across a second Studio start.
The DE proof is `de-studio/`: Studio exhibits planted names that `open`
on the volume, a derived key spawn(26)s one, and hidden `go NAME`
(ADR-0099) is the idle-line Spotlight. It is not an IDE, not live-edit,
not a Dart SDK, not a compiler.
This file is product intent stated against the machine. When a
piece is built it gets its own numbered ADR; this document is the thing
those ADRs will point back at.

**It cites rather than re-derives.** The in-built SDK is
`app-framework.md` (FRAME1 done: `osframe.h`, 8.3 `FRAME.H`). Language
identity is `dcdart.md`: **OSXStudio is a FRAME app compiled on the
host, in freestanding C or `@bare` DCDart, against osframe. It is not
Dart, not Flutter, not a guest `dcc`.** Packages, launch, and the C
membrane are `app-system.md`. Surfaces are ADR-0051. The two doors into
ring 3, the 8.3 root, and the absence of `opendir` are
`applications.md`'s. Editor safety is GAP-0127. Reflection is GAP-0166.
The 65,536-byte image is `exec-format.md`. Spawn-by-name from ring 3
is syscall 26 (ADR-0078), taken from the registry, not invented in
this file. **An IDE is not claimed.**

**Ladder prefix `STUDIO`.** `APP` is Unix tools. `FRAME` is the ABI.
`OSXUI` is the widget kit. This is the *in-built builder surface*.
Games are a later client of the same kit, not a second product.

---

### The five things this document lands on, for a reader in a hurry

1. **OSXStudio is a FRAME app, not an IDE port.** It will be an ELF ≤
   65,536 bytes on the FAT root, started with `run` or `proc spawn`,
   painting through `wmsurface`. It is not VS Code, not Xcode, not
   Flutter DevTools, not a hosted Dart analysis server. There is no
   editor buffer that can save safely, no directory listing, and no
   compiler on the guest (`applications.md` §3 tier 2, §4.1).
2. **TODAY it is not writable** — four independent gates, all already
   named: no `rename` / editor-safe save (GAP-0127 items 1, 3, 8); no
   `opendir` (GAP-0122 item 2); `elfImageMax = 65,536`; no reflection
   (GAP-0166). A program that pretended to be a studio would be a
   surface that cannot list the volume, cannot save a project without
   destroying the previous file, and cannot inspect its own widgets.
3. **NEXT was listing; that rung is STUDIO1 (done).** Launch is
   STUDIO2 (done, ADR-0078): from `STUDIO.ELF`, a derived key or a
   hit-strip click starts the selected catalog name as a resident
   process via syscall 26 (`spawn`). Harness `studio2/` sees APP1's
   HEAP line and studio still listed. The idle-line sibling is
   hidden `go NAME` (ADR-0099, `de-studio/`): same named residency,
   no start-menu widget, not in `help`. It does not discover other
   files (`opendir` is still absent). It does not compile. It is not
   a builder. STUDIO2b (done, ADR-0119) persists the selected row as
   `SEL.DAT` so a second start exhibits that derived name. A FRAME.H
   syscall-row paint remains optional later paint of the same client.
4. **BLOCKED: live-edit of compiled `@bare`, and a Dart SDK on the
   guest.** Those are `app-framework.md` §0.3–§0.4 and
   `applications.md` §4.1. OSXStudio will not grow a "change the
   handler and keep running" gesture until DCDart ships descriptors
   *and* a compiler or interpreter runs on the box. It will not host
   `dcc`.
5. **Games later means a second FRAME client, not a game engine.**
   Same syscalls, same 2 MiB window, same small surfaces. No GPU
   claimed (`gpu.md`). No asset pipeline beyond FAT files the host
   planted.

---

## 0. Horizon — TODAY / NEXT / BLOCKED ON DCDART / FANTASY

### 0.1 TODAY — OSXStudio cannot be written as a studio

| gate | why it blocks a studio | citation |
|---|---|---|
| no editor-safe save | `O_WRITE` is create+truncate+append; there is no `rename` to swap a temp over the old file. The first byte of a save destroys the previous contents | GAP-0127 items 1, 3, 8; `applications.md` §3 tier 2 |
| no `opendir` | ring 3 cannot enumerate the volume. A project picker cannot list `*.C` / `FRAME.H` / siblings. The shell's `ls` is ring 0 | GAP-0122 item 2; `applications.md` APP3 |
| 65,536-byte image | an editor, a tokeniser, and a widget kit do not fit. chibicc is already past this; a "studio" that is also a compiler is `exec-format.md` X1 plus APP10 | `elfImageMax`; `exec-format.md` §0 fact 2 |
| no reflection | `@extern` is a name, not a descriptor. "Right-click, what is this widget" has no type table | GAP-0166; `app-framework.md` FRAME7 |

What *can* exist today is the thing FRAME1 already shipped: a file of
syscall names on the volume, and a program that checksums it. That is
an SDK copy. It is not a studio.

The two doors still split (`applications.md` §1.1): `run STUDIO.ELF`
can pass `FRAME.H` as `argv` and cannot `malloc`; `proc spawn` can
allocate and cannot be told the filename unless it is baked in.
STUDIO1 bakes `FRAME.H` and uses `proc spawn` so it can stay resident
(ADR-0053). APP5 deletes the question.

### 0.2 NEXT — listing then launch, no new language feature

* **STUDIO1 listing — done (2026-08-30).** A resident surface client
  (`STUDIO.ELF`, `proc spawn`) that `open`s `APPS.TXT`, `read`s it in
  `OSFRAME_READ_MAX` (512) strides, writes each name to COM1, and
  paints a simple colour strip when the compositor is on. Harness:
  `core/tests/conformance/studio1/`. Not an editor, not a builder.
* **STUDIO2 launch — done (2026-08-30, ADR-0078).** The same client
  selects a catalog row (derived digit key or hit-strip click) and
  `spawn`s that 8.3 name as a resident process (syscall 26). Harness:
  `core/tests/conformance/studio2/`. Still not live-edit, not a Dart
  SDK, not a builder.
* **DE exhibit + idle-line Spotlight — done (2026-08-30, ADR-0099).**
  After listing, Studio `open`s each catalog name and writes
  `STUDIO2 HAVE` for those that exist on the volume. Hidden `go NAME`
  from the idle prompt starts the same planted ELF without WM chrome.
  Harness: `core/tests/conformance/de-studio/`. This is a launcher
  and an exhibit. **It is not a builder.**
* **STUDIO2b persist — done (2026-08-30, ADR-0119).** The same client
  `fdwrite`s a selected-row index to `SEL.DAT` (4 bytes, destroy-on-save
  accepted, `app-framework.md` §4). A second Studio start reads it and
  exhibits the derived catalog name. Harness: `core/tests/conformance/studio2b/`.
  Not a project format. Not atomic (`unlink` / `rename` still absent).
  **Still not a builder.**

### 0.3 BLOCKED ON DCDART

| wanted | blocked by | where |
|---|---|---|
| live-edit of compiled `@bare` (change a function, keep running) | escalation 0004 introspection *and* intercession; escalation 0005 conditions; a compiler or interpreter on the guest | `app-framework.md` §4; `applications.md` §4.1 |
| Dart SDK / `dcc` / analysis server on the guest | Dart 3.12.2, JIT or AOT, GC, threads, `mmap`, sockets, directories | `applications.md` §4.1; `dcdart.md` §5 |
| "what is this widget" from an AI driver walking live objects | type descriptors in `.rodata` | GAP-0166; FRAME7 |
| `String` source buffers in `@bare` | GAP-0035 | `display-protocol.md` §6 |

**A static listing of syscall names is not reflection.** It is
escalation 0004 §6 option 3 applied to the FRAME boundary — the same
move ADR-0029 took for DRM and `app-framework.md` FRAME6 named. STUDIO1
*displays* that table. It does not close GAP-0166.

### 0.4 FANTASY — do not plan

* **An IDE.** Syntax highlighting, a project tree, debug probes, git,
  LSP, "Run" that shells out to `dcc`. Those assume APP9, paths,
  `spawn`, a stack bigger than one page, and an image bigger than
  64 KiB — and still would be a cross-compile story, not self-hosting
  (`applications.md` §4.1).
* **Flutter / Dart pad / hot reload.** `dcdart.md` §3. Hot reload is
  live-edit of a VM the guest does not have.
* **Downloading a guest SDK later** as a Dart tarball. What can be
  downloaded later is a newer `FRAME.H` and a newer ELF, produced on
  a host (`app-framework.md` §1).
* **In-guest games as Unity/Godot ports.** A game is a FRAME client
  with a tighter yield loop. No engine, no GPU claimed.

---

## 1. What the product ask reduces to

The owner wants an in-built app for building apps (and later games).
Four honest reductions:

**"Building apps" today means writing C or `@bare` on a host, linking
against `osframe.h` / `osframe.dart`, planting the ELF on a FAT
image, and `run` / `proc spawn`.** OSXStudio does not replace that
loop. It shows a person sitting at the machine *what the loop is
allowed to call*.

**"In-built" means an 8.3 file on the same volume as `FRAME.H`.** Not
a package manager, not a store, not a web download inside the guest
(`app-system.md`).

**"For building apps" is not "is a compiler."** APP10 is an assembler
on the machine and is already a capstone. A C compiler is that
document's un-numbered capstone. OSXStudio sits *beside* those
ladders. It does not absorb them.

**"Games later"** is a second ELF with the same ABI and a different
paint loop. It waits on the same surfaces and the same 2 MiB window.
It is not a milestone on this prefix until STUDIO1 exists and someone
names a game criterion that is not "pixels moved."

---

## 2. The STUDIO ladder

**STUDIO1 assumes no new syscall, no `opendir`, no `rename`, no
reflection, no guest Dart SDK.**

---

### STUDIO1 — A surface lists catalog names it was told (listing rung done)

**Blocked on: FRAME1 (done) and on a surface client (FRAME2 / OSXUI2).**
If those clients have not landed, this program **is** that client and
is counted once.

**Listing rung: done (2026-08-30).** Deliverable: `STUDIO.ELF`
(`core/user/frame/studio.c`), `proc spawn`, `open`s planted
`APPS.TXT`, `read`s in `OSFRAME_READ_MAX` (512) strides, writes each
catalog name to COM1, and paints a small colour strip when `wm on`
has attached. Host `derive.py` knows the planted bytes. Optionally
attaches through `wmsurface` — still not `opendir`. This rung does
**not** claim a FRAME.H syscall-row table, live-edit, a Dart SDK, or
OSXStudio as a builder.

*Binary:* after spawn (and `wm on` when a strip is wanted), COM1
carries `STUDIO1 NAME APP1.ELF` and the derived name count. The
volume file is unchanged (`fsck_msdos` clean). Harness
`tests/conformance/studio1/`.
*Anti-vacuity:* planted `APPS.TXT` lists at least two 8.3 names
(`APP1.ELF`, `APP2.ELF`). A studio that prints a baked `APP1.ELF`
literal fails the truncate control. `studio.c` / `STUDIO.ELF` must
not contain that token.
*Negative control:* a volume whose `APPS.TXT` was truncated to one
row (`APP2.ELF` only) must not print `APP1.ELF`. A build that never
`open`s the file fails the same way.

Uses `open` / `read` / `close` / `write` / `yield` / `exit`, and
`shmcreate` / `wmsurface` when the strip attaches. Selection with
`kbdevent` / `wmevent` is not required for the listing criterion.

---

### STUDIO2 — A catalog name is launched as a resident process (done)

**Blocked on: STUDIO1 (done) and on a spawn-from-userland path.**
Deliverable: `STUDIO.ELF` reads `APPS.TXT`, then a derived digit key
(row 0 is `'1'`) or a click on that row's hit strip calls syscall 26
`spawn(namePtr, nameLen)` on the planted 8.3 name. The child is
`procCreate` + `elfLoadFile` and stays READY. Studio stays resident
(ADR-0053). ADR-0078. Harness `tests/conformance/studio2/`.

*Binary:* after `proc spawn studio.elf` and the derived key, COM1
carries `STUDIO2 LAUNCH APP1.ELF`, APP1's HEAP/hello line, and
`STUDIO1 LIST` / `STUDIO2 READY` (studio still listed) or the prompt
already returned. Names that `open` on the volume also produce
`STUDIO2 HAVE`. `fsck_msdos` clean.
*Negative control:* the same volume, no key → APP1 does not start
(no HEAP line, no `STUDIO2 LAUNCH`).
*Anti-vacuity:* `studio.c` / `STUDIO.ELF` must not contain `APP1.ELF`
as a token; the launched name comes from the planted catalog.

This is **not** live-edit, **not** a guest Dart SDK, **not**
`opendir`, **not** persist of `SEL.DAT`. The syscall is name-only;
APP7's `argv` pointer is still later.

The seam: ring 3 calls 26; the kernel bounces the name through
`fileBufBase`, `fatLookup`, `procCreate(named)`, restores the
caller's CR3. Not a `SPAWN.REQ` idle hook.

### STUDIO2b — The listing can persist a selection as data (done)

**Blocked on: STUDIO2 (done), and on nothing else if destroy-on-save is
accepted.** Done (2026-08-30, ADR-0119). Writes `SEL.DAT` (4 bytes, a
row index) with `create` / `fdwrite` / `close`. A later Studio start
`open`s that file and exhibits `STUDIO2 SEL` plus the derived catalog
name. No `rename`. Documented as unsafe save (`app-framework.md` §4).
Harness `tests/conformance/studio2b/`.

*Binary:* after a derived key or click selects row K, the host reads
`SEL.DAT` and it is the `u32` `derive.py` computed. A second Studio
start on the same volume exhibits that planted name as selected.
`fsck_msdos` clean.
*Anti-vacuity:* the catalog plants a second 8.3 name. That name must
not appear selected. A first start with no `SEL.DAT` must not exhibit
`SEL` (a client that always prints catalog[0] fails).
*Negative control:* a build that `fdwrite`s `sizeof buf` instead of 4
fails the host read-back (APP1's `cp` control). No key → no `SEL.DAT`.

**`unlink` / `rename` are not in this milestone.** When APP4 lands,
the safe idiom is write-temp-and-rename and this program may grow it.
Until then this persist rung must not claim atomic persist. It is
still not a builder. The leftover is emit (GAP-0166 / GAP-0321).

---

### STUDIO3 — Live-edit of `@bare`, and a guest Dart SDK

**Blocked on DCDart, and on in-guest development.** Not a STUDIO
implementation. Named so nobody files "hot reload in OSXStudio" under
this prefix.

This is `app-framework.md`'s capstone and `applications.md` §4.1.
**This entry exists to say so.**

---

## 3. How OSXStudio relates to the other ladders

| ladder | what it owns | what OSXStudio does with it |
|---|---|---|
| FRAME | header, `FRAME.H`, first surface client | STUDIO1 **is** a FRAME client that displays the header |
| OSXUI | popover, hit rectangles, client menu | STUDIO may use OSXUI2 for row hit-test; it does not invent widgets |
| APP | `cp`, `ls`, editor-safe save, `spawn` | STUDIO does not wait on `ls` for STUDIO1; it waits on APP4 before a safe project save; it does not become APP9 |
| `dcdart.md` | not Dart, not Flutter | the studio source is `@bare` or C; the guest never runs `dart` |

An AI driver attaches the way `app-framework.md` §5 already said:
read the static table (TODAY / FRAME1 / STUDIO1), then `wmevent`s
(NEXT), then descriptors (BLOCKED). It does not rewrite `wm.dart` to
"understand the studio."

---

## 4. What I did not decide

1. **Is the first studio allowed to be C forever?** Same question as
   `app-framework.md` §7. I recommend C for STUDIO1 (every surface
   client is C) and a `@bare` twin when someone wants it, not as a
   gate. The public line remains `dcdart.md`.
2. **Does STUDIO.ELF start through `proc spawn` or `run FRAME.H`?**
   Residency matters more than `argv` if the name is baked. APP5
   deletes the question.
3. **Games: a second 8.3 name (`GAME.ELF`) or a mode of the studio?**
   A second ELF. A studio that is also a game loop is two programs
   fighting 64 KiB.

---

## 5. Notes for the coordinator

* **Prefix `STUDIO`.** Do not call this FRAME8 — FRAME7 is already
  DCDart introspection.
* **STUDIO1 may be FRAME2 / OSXUI2.** Count once.
* **GAP-0166 stays open.** A list of syscall names is not descriptors.
* **Do not schedule a guest Dart SDK under this file.**
