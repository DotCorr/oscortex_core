# The application system — packages on FAT 8.3, launched by run/spawn, native UI only

**Status: DESIGN, closed by ADR-0112.** An app is an ELF + osframe.
Chrome is wm. The paint engine is osgfx (Skia when that agent lands).
Never Flutter. `applications.md` is the Unix-tooling ladder (`cp`,
`ls`, a userland shell). `app-framework.md` is the ABI ladder (FRAME).
This file is the *package and launch* contract those two assume.

**It cites rather than re-derives.** 8.3 root, two doors, 65,536-byte
image: `applications.md` §0 and `exec-format.md` §0. `.osx` as a
wrapper around ELF, not a replacement: `exec-format.md` §1–§2. The
SDK: `app-framework.md`, `osframe.h`. Language: `dcdart.md` — **an
app is DCDart or freestanding C against osframe, never Flutter.**
The C-library membrane for DRM: ADR-0029 §7, GAP-0166, `libdrm-port.md`.
Surfaces: ADR-0051. Spawn as the process-creation shape:
`applications.md` §2.4 (APP7). **No syscall is invented here. No web
view is claimed. A random C package will not link.**

**No new ladder prefix.** Launch identities are APP5 / APP7. The ABI
is FRAME. UI is OSXUI. Counting a fourth prefix for "a directory
entry is a package" would be a collision of the class
`design/README.md` already warned about.

---

### The five things this document lands on, for a reader in a hurry

1. **A package is one or more 8.3 files in the FAT16 root, not a
   container format and not a store.** The runnable member is an
   `ET_EXEC` ELF ≤ 65,536 bytes (or, later, that ELF wrapped in `.osx`
   — `exec-format.md` §2, X4, deferred). Sidecars (`FRAME.H`,
   `COLOUR.DAT`, `SEL.DAT`) are more 8.3 names. There is no
   `opendir`, so the package cannot be discovered; it is launched by
   name or the name is baked (`applications.md` §0).
2. **Launch is `run <name>` or `proc spawn` / the `spawn` syscall
   APP7 will be.** There is no `fork`, no `exec` in place, no
   installer, no shebang, no MIME. The two doors still split argv
   from heap (`applications.md` §1.1) until APP5.
3. **UI is native only.** An app paints through `wmsurface` (and
   reads `kbdevent` / `wmevent` / `mouse`) or it prints to COM1 /
   the text console. There is no HTML engine, no JS runtime, no
   browser process, no "load this URL." A web view is fantasy of the
   same class as a guest Dart SDK (`app-framework.md` §0.4).
4. **A C package is freestanding or it does not belong here.**
   `clang -target x86_64-unknown-none-elf`, `osframe.h` and optionally
   `oslibc.h` (41 symbols, 9 of them C89). No hosted libc, no POSIX
   (`mmap`, `poll`, `pthread`, `dlopen`, `errno` as a global the
   kernel sets). **A random C package from another OS will not link.**
   That is the design, not a temporary gap.
5. **libdrm-style ports are the named exception, and they carry a
   membrane.** ADR-0029: Mesa/libdrm are unmodified *source* behind
   oscortex's own display protocol, with a **build-time** descriptor
   table of the ioctl boundary (GAP-0166 option 3 — describe the
   boundary; do not open a DCDart escalation). That exception is not
   a licence to vendor GTK, ffmpeg, or a hosted libc and hope.

---

## 0. What is true today

| fact | value | citation |
|---|---|---|
| names | 8.3, twelve characters, root only, no path | `applications.md` §0; GAP-0122 item 2 |
| image | `elfImageMax = 65,536` | `exec-format.md` §0 fact 2 |
| address space | 2 MiB, `[0x10000000, 0x10200000)` | `exec-format.md` §0 fact 4 |
| stack | one 4096-byte page | `exec-format.md` §0 fact 5 |
| launch | `run <name\|lba> [args]` or `proc run` / `proc spawn` | `applications.md` §1.1; ADR-0053 |
| argv + heap | **disjoint doors** until APP5 | GAP-0149; `applications.md` §1.1 |
| process-from-process | **name-only, syscall 26.** APP7's `argv` pointer is still later | GAP-0096 item 7 (narrowed, ADR-0078); GAP-0141 |
| listing | no `opendir`; shell `ls` is ring 0 | GAP-0122 item 2 |
| UI | `wmsurface` / `kbdevent` / `wmevent` / `mouse` | `osframe.h`; ADR-0051/54/55/42 |
| C library | 41 symbols; no hosted libc | `libc-roadmap.md`; `oslibc.h` |
| Flutter / Dart VM | **not present** | `dcdart.md` |

Positively, a package today is: plant `FOO.ELF` (and maybe `FOO.DAT`)
on the image `make-image.py` already builds; type `run FOO.ELF` or
`proc spawn` it. That is the whole installer.

---

## 1. A package is files, not a format

`exec-format.md` already asked whether `.osx` should replace ELF and
answered **no**: keep ELF as the payload; a 64-byte header plus
manifest is optional metadata *about* the image (X4, deferred). This
document does not reopen that.

**TODAY.** The package *is* the directory entries:

```
FRAME.H      SDK table (FRAME1) — not executable
SURF.ELF     a surface client (FRAME2 / OSXUI2)
TAP.ELF      closed-contract plant (ADR-0112 / de-apps): attach, paint, click, `go`
COLOUR.DAT   optional data the client baked or was told
STUDIO.ELF   OSXStudio listing + launch + HAVE + SEL.DAT persist (STUDIO1 / STUDIO2 / STUDIO2b / de-studio; not a builder)
```

All legal 8.3. All in the root. No subdirectory, so there is no
`APPS/FOO/` tree (`namespace.md` / storage still own paths). No
archive: `fatChainMax` is 256 KiB and one `fdwrite` is 512 bytes;
unpacking a tarball is APP work that does not exist.

**NEXT.** When X4 is wanted, `FOO.OSX` is the ELF plus a manifest
(syscall set, version) at a 512-byte boundary
(`exec-format.md` §2). The loader sniffs magic. Until then `run`
already loads a plain `ET_EXEC`. Do not block FRAME or OSXUI on `.osx`.

**Not a package manager.** "Download later" is a host fetching a
newer header and a newer ELF (`app-framework.md` §1). There are no
sockets in the guest that this document may assume
(`display-protocol.md` §0 constraint 1).

**Not discoverable.** Without APP3 (`:ROOT` or `readdir`) an app
cannot list its siblings. The shell's `ls` is not a FRAME API. A
launcher that "shows installed apps" is either a baked table
(STUDIO1's shape) or it waits on APP3.

---

## 2. Launch

Two spellings today, one intended later.

| how | what the program gets | citation |
|---|---|---|
| `run NAME.ELF a b` | `argv`, four fds, **no `sbrk`** | `applications.md` §1.1 |
| `proc spawn` / `proc run` | a slot, a heap, residency; historically no `argv` | ADR-0053; GAP-0149 |
| `spawn(name, argv)` (APP7) | a slot *and* arguments, from a process | `applications.md` §2.4 |

**Recommendation, unchanged from those files:** a surface app that
must outlive the command uses `proc spawn` and a baked data-file
name. A tool that must be told which file to copy uses `run` and
`.bss`. APP5 is the closer. This document does not add a third door.

**Never:** `fork`, replace-in-place `exec`, POSIX `posix_spawn` as a
compatibility symbol, double-click as a kernel object. A future
taskbar tile (OSXUI4) that starts an app is the shell or a FRAME
launcher calling the same `spawn`, not a new syscall.

**Four process slots.** A "desktop full of apps" is two resident
clients plus the shell plus one spare on a good day (GAP-0096 item
1). The application system does not pretend otherwise.

---

## 3. Native UI only

An app that wants a picture uses the FRAME ABI:

```
  shmcreate → wmsurface attach → paint 0x00RRGGBB → wmsurface commit
  kbdevent / wmevent / mouse in a yield loop
```

That is `app-framework.md` §2 and `osx-ui.md`. Widgets are client
rectangles (OSXUI2) or compositor chrome (taskbar, OSXUI1 popover).
Title bars do not exist (`osx-ui.md` §2).

**There is no web view.** No HTML parser, no CSS, no JS, no GPU
compositor for layers, no network stack the app can treat as
"browse." Shipping a URL to the guest is not an app model. If a
later document wants a browser, it is a new project on the far side
of the net stack, a libc that is a Linux personality
(`libc-roadmap.md`), and a GPU this kernel does not have (`gpu.md`).
It is not a FRAME widget.

**There is no Flutter view.** `dcdart.md` §3. An app's source may
look like Dart. It is DCDart `@bare` or it is C. A `pubspec.yaml`
does not load.

---

## 4. C packages: freestanding, or a membrane, or they do not link

### 4.1 The rule

**Only freestanding C is an application on this OS.** The compile
line every harness already uses — `clang -target x86_64-unknown-none-elf`
— is the contract. Platform C/C++ (osgfx, later Skia / Chromium
WebView) is oscortex core, not a FRAME app (`c-modules.md`). The program `#include`s `osframe.h` and, if it
wants `printf` / `malloc`, `oslibc.h`. It does not `#include
<stdio.h>` from a hosted SDK. It does not expect POSIX.

`oslibc.h` is 41 symbols, 9 of them C89 (`libc-roadmap.md`).
`printf` is `%s %d %x %c %%`. There is no `errno` the kernel sets
(GAP-0122 item 6). There is no `mmap`, `poll`, `pthread`, `dlopen`,
`socket`, `getenv`. `verify-freestanding.sh` is the check. An app
that fails it is not an app here.

**A random C package will not link.** That sentence is load-bearing.
libpng, SDL, GTK, a POSIX `coreutils`, a prebuilt `curl` — they
resolve hundreds of hosted symbols this libc does not have, and four
of the names that *do* resolve are the wrong function
(`libdrm-port.md` §3: `open`/`read`/`close`/`printf` bind by name
and are not the same functions). A clean link against the wrong
`open` is the failure mode. The application system does not grow a
hosted personality to make those packages "just work."
`libc-roadmap.md` already called that a Linux personality and
recommended not attempting it.

### 4.2 The exception: a port with a membrane (ADR-0029)

libdrm is the C library this OS was pointed at (ADR-0031). It
**compiles** unmodified for the freestanding target and is **43
symbols short**; four of the ten that resolve are wrong
(`libdrm-port.md`). ADR-0029 keeps oscortex's own display protocol
above a Linux DRM *ABI*, Mesa as unmodified *source*, not unmodified
binaries (reading A in that ADR is rejected).

GAP-0166 / escalation 0004 §6: C libraries are zombies by
construction; the recommended option is **describe the boundary**.
ADR-0029 §7 specifies that description as a **build-time table
generator in this repo**, not a DCDart language feature. The
dispatcher validates against the table. Mesa's internals stay
opaque (§7(d)).

**That is the membrane.** A future C port of the same class
(another flat ioctl ABI, public uAPI, nothing crossing the kernel
does not own) may take the same shape. It is an exception that
must be named in an ADR. It is not the default for "a C package."

ffmpeg is the worked example of a port that is **not** this
exception: gated on size, not linking (`exec-format.md` §4;
`design/README.md` still lists it as unspecified). Do not fold it
into FRAME.

### 4.3 DCDart packages

A DCDart app is `@bare`, compiled on the host by `dcc`, sibling
numbers in `osframe.dart` because DCDart has no `#include`
(`dcdart.md` §4). Same ELF caps. Same syscalls. Same refusal to be
Flutter. A DCDart app that imports `dart:io` or a pub package is
a Dart app and will not run (`dcdart.md` §1).

---

## 5. How the pieces compose

```
  host:  C or @bare  →  ELF ≤ 64 KiB
           │
           ├─ #include osframe.h   /  osframe.dart literals
           └─ optional oslibc.h    (freestanding only)
           │
  volume:  FOO.ELF  +  optional 8.3 sidecars   (the package)
           │
  launch:  run FOO.ELF …     or   proc spawn / APP7 spawn
           │
  UI:      wmsurface / kbdevent / wmevent / mouse     (or serial)
           │
  chrome:  wm (compositor policy). paint engine: osgfx (Skia when that agent lands)
```

OSXStudio (`osxstudio.md`) is one such package that *lists* the
FRAME table. It is not the installer and not the compiler.

An AI driver attaches by reading the static table and the same
syscalls (`app-framework.md` §5). It does not get a package
metadata API until X4, and it does not get reflection until
GAP-0166 closes on the DCDart side.

---

## 6. What this file does not do

It does not add APP11. It does not allocate a syscall. It does not
schedule `.osx` ahead of X1/X3 (`exec-format.md` §5). It does not
authorise a hosted libc, a web view, or a Flutter embedder. It
does not close GAP-0166. Spawn 26 / hidden `go` have landed
(ADR-0078 / ADR-0099); APP7's leftover is the argv pointer.

---

## 7. Notes for the coordinator

* **`package format` in `design/README.md`'s "not yet specified"
  column is this file**, reduced to: 8.3 files in the root, ELF
  payload, optional `.osx` later. It is not an App Store format.
* **Count:** no new ladder. APP / FRAME / OSXUI / STUDIO stay the
  prefixes. This document is a contract they share.
* **Point at `dcdart.md` in any public sentence about "apps."**
  DCDart or C against osframe. Never Flutter.
