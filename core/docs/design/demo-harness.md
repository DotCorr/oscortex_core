# The demo harness — watching the operating system run, continuously, while it is being built

**Status: BUILT AND VERIFIED.** `core/scripts/demo.sh` exists, was run against three different
commits while this was written, and left a QEMU window on the screen each time. This document is the
design behind it and the record of what it actually does. It is not a proposal.

**One paragraph.** `core/scripts/demo.sh` builds a *commit* — not your working tree — in an isolated
`git worktree` under `/private/tmp`, with its own APFS-cloned copy of the DCDart toolchain, boots it
in QEMU with a **real window** when the machine has a window server, drives a scripted tour of the
shell over QMP, captures a PNG per stage plus the whole serial transcript, and then **leaves the
machine running** so a human can type into it. The next run kills the previous one first.

```
core/scripts/demo.sh                 # HEAD, in a window, left running
core/scripts/demo.sh 7ffd8ab         # any commit-ish
core/scripts/demo.sh --headless      # -display none; the PNGs are still taken
core/scripts/demo.sh --status        # is one running, and which commit
core/scripts/demo.sh --kill          # stop it
core/scripts/demo.sh --clean         # stop it and delete every worktree it made
core/scripts/demo.sh --watch 60      # never stop: re-demo whenever the commit moves
```

---

## 0. What it is not

It is **not a conformance harness and it asserts nothing.** It has no golden file, no exit criterion,
and no opinion about whether the kernel is correct. `core/tests/conformance/` is where correctness
lives; this is where *visibility* lives. If the demo and a harness disagree, the harness is right.

The dependency runs one way and by reading only:

| it reads | it never |
|---|---|
| `core/scripts/build-kernel.sh` (invoked, out of the worktree) | edits anything under `core/kernel/`, `core/boot/`, `core/user/`, `core/link/` |
| `core/tests/conformance/m1{6,5,4}-*/build-progs.sh` and `make-image.py` (invoked, out of the worktree) | edits any `run.sh`, `derive.py`, `expected*.txt` |
| `core/tests/conformance/m2-console/pick-port.py` (invoked when present) | writes into the checkout you are working in — **at all** |
| `core/scripts/verify-freestanding.sh` (invoked; its verdict is *reported*, not enforced) | leave a process running that a later run cannot find and kill |

`core/scripts/demo.sh` is the only file it added.

---

## 1. Isolation: why a worktree and an APFS clone

The requirement is that the demo be runnable **at any moment**, including while three other agents
have half-finished edits in `core/kernel/` and a fourth is regenerating a byte-exact golden. Building
the working tree would (a) show a kernel nobody committed, (b) fight for `core/build/`, and (c) be
non-reproducible ten minutes later.

So the recipe is:

```
git worktree add --detach /private/tmp/oscortex-demo/src-<short> <commit>
cp -Rc <repo>/../DCDart  /private/tmp/oscortex-demo/DCDart      # APFS clone, made once
DCDART_HOME=/private/tmp/oscortex-demo/DCDart  bash core/scripts/build-kernel.sh
```

Two details are load-bearing:

* **`cp -Rc`, not `ln -s`.** A symlinked `DCDART_HOME` resolves `.dart_tool/package_config.json` back
  into the shared checkout, which is exactly the isolation being bought. The clone is
  copy-on-write — 278 MiB of DCDart costs milliseconds and near-zero disk on APFS — and is made once
  and reused. `--refresh-toolchain` re-makes it.
* **One worktree per commit**, named `src-<short-sha>`, so re-demoing a commit is a rebuild in a
  directory that is already there and `core/build/` inside it is warm. `--clean` unregisters them
  with `git worktree remove` **before** deleting the directories, so `git worktree list` in the
  checkout other people are working in never names a directory that is gone.

**Consequence to know about:** while a demo worktree exists, `git worktree list` in the main checkout
shows it. That is the price of not copying the repo, and `--clean` is the undo.

### 1.1 The toolchain, and the thing that will bite the next person

`dcc` needs a Dart SDK whose *language version* is high enough for DCDart's vendored `pkg/kernel`
**and** whose `dart compile kernel` emits the Kernel binary format that same `pkg/kernel` reads. On
this machine, today, that is **exactly Dart 3.12.2**, and it is not the `dart` on the default `PATH`:

| SDK | result |
|---|---|
| 3.11.0 (Homebrew flutter) | `The language version 3.12 specified for the package 'kernel' is too high` |
| 3.13.0-184.0.dev (`~/sdks/flutter344`) | `dcc build: Unexpected Kernel Format Version 131 (expected 130)` |
| **3.12.2 (`dc_sys/toolchain/dart-sdk`)** | **builds** |

`demo.sh` therefore sources `dc_sys/env.sh` — the machine's own environment file, one directory above
the repo — **when it exists**, and requires nothing when it does not. `OSCORTEX_ENV_SH` overrides the
path. This is worth writing down because the failure mode is a wall of Dart front-end errors that
look like a DCDart bug and are not one.

---

## 2. The window, detected rather than assumed

`-display cocoa` needs three independent things, and a build machine fails all three. The script
probes each, in order, and says which one decided:

1. **QEMU has the backend** — `qemu-system-x86_64 -display help` lists `cocoa`.
2. **The platform is macOS** — `uname -s`.
3. **There is a window-server session** — `launchctl managername` answers `Aqua`. In a daemon, or over
   ssh, it answers `Background`/`StandardIO`, and that is the difference between a window appearing
   and QEMU exiting with *"Failed to initialize the Cocoa UI"*.

On Linux the same three questions are asked of `gtk`/`sdl` and `$DISPLAY`/`$WAYLAND_DISPLAY`.

**And then the launch itself is the fourth probe.** Detection can be right about the machine and wrong
about the moment. If QEMU dies within two seconds of a windowed launch, the log is echoed, the whole
boot is retried with `-display none`, and the run continues. It is reported as a *fallback*, never as
a failure — verified by running a copy of the script with the backend name deliberately corrupted:

```
demo: display: -display totally-not-a-backend (…)
demo: QEMU could not open a window (see …/qemu.log) — retrying headless
demo:   qemu: -display totally-not-a-backend: Parameter 'type' does not accept value …
demo: QEMU is up (pid 66403, QMP on 127.0.0.1:50215)
  display      -display none  (the windowed launch died immediately)
```

The launch loop retries for a **second, unrelated** reason as well: `pick-port.py` asks the kernel for
a free TCP port and then *closes* it, so something else can take it in the gap before QEMU binds
(`known-gaps.md` GAP-0150). The conformance harnesses retry for exactly that; so does this, up to five
times, and only when QEMU's own log says the address was in use. Without it the demo fails
intermittently for a reason that has nothing to do with the kernel — which was observed once while
this was being written.

**A headless run is a complete run.** `screendump` works with `-display none`, so the PNGs, the serial
transcript and the VGA text dump are the same artefacts either way. The window is a nicety for a
human; it is not where the evidence comes from.

---

## 3. One demo at a time

Two mechanisms, because either alone leaks processes:

* **A pidfile**, `/private/tmp/oscortex-demo/demo.pid`, plus `demo.info` (commit, worktree, display,
  run directory, QMP port) for `--status`. Before signalling, the pid is confirmed to still *be* a
  `qemu-system-x86_64` — a recycled pid belonging to somebody else must not be killed. `TERM`, up to
  four seconds, then `KILL`.
* **A machine-wide sweep** for `qemu-system-x86_64 … -name oscortex-demo`, which catches a QEMU whose
  pidfile was deleted or whose launch was interrupted. Every demo QEMU is launched with that `-name`
  precisely so it can be found without a pidfile. Note that this sweep is *machine-wide*: it ignores
  `OSCORTEX_DEMO_ROOT`, so two demo roots do not give you two simultaneous demos.

**The kill happens immediately before the new launch, not at start-up.** A build that fails should
leave the machine you were already looking at up on the screen rather than clearing it and then
telling you about a compile error.

The new QEMU is launched `nohup … </dev/null &` and `disown`ed, so it outlives the script — which is
the entire point. Verified: after `demo.sh` returned, `ps -p <pid>` still showed the process, with its
window, and the *next* `demo.sh` printed `killed the previous demo (pid …)`.

---

## 4. Driving the session

The protocol is QMP, exactly as `core/tests/conformance/m2-console/qmp-drive.py` uses it: connect,
`qmp_capabilities`, skip asynchronous events interleaved with replies, `send-key` with qcodes one key
at a time with a 50 ms gap (the 8042 has a **one-byte** output buffer), `screendump` for PNGs, and
`human-monitor-command`/`xp` to read the VGA text buffer out of guest physical memory.

**Why the driver is embedded in `demo.sh` rather than being `qmp-drive.py`.** `qmp-drive.py` ends
every session with `{"execute":"quit"}`, because a harness's last act is to stop the machine. A
demo's last act is the opposite. That one difference — plus per-stage screenshots — is the whole
reason for the ~160 embedded lines. `qmp-drive.py` is not modified, not copied into the repo, and not
wrapped; it stays the conformance tree's file.

Two timing details inherited from it, because both are real:

* The kernel's interactive marker (`M1 END`) hits COM1 **before** the keyboard driver has drained the
  8042 and unmasked IRQ1. Keys typed into that window are drained and thrown away, so the driver
  settles for a second first.
* There is no input queue in the kernel (`known-gaps.md` GAP-0055), so a command must finish before
  the next one is typed. The driver waits for the **serial capture to stop growing for 0.6 s**,
  bounded by a per-stage timeout, instead of guessing a fixed delay. That is why `run prog.elf` — a
  180 s budget — actually costs 1.5 s.

The tour is a plain text file (`tour.txt` in the run directory) with four verbs: `send <ms> <line>`,
`shot <file>`, `screen <file>`, `mark <text>`. It is written by `demo.sh` and kept with the run, so
what was demonstrated is recoverable from the artefacts alone.

---

## 5. What the tour shows, and how it degrades

The disk is built by **the milestone that owns it**, out of the worktree, newest first — so demoing
an old commit gets that commit's image builder and that commit's programs:

| candidate | volume | tour |
|---|---|---|
| `m16-filewrite` | 3 ELF programs, free space fragmented by construction | **write**: run the program, `ls` the directory it changed, `cat` a file it wrote |
| `m15-fileio` | 2 ELF programs, files scattered across the FAT | **read**: `cat small.txt`, run a program by name |
| `m14-fat` | 2 named ELF programs | **read**: `cat hello.txt`, run a program by name |
| none | no `-drive` at all | **memory**: `frames`, `frames test`, `vm`, `user`, `user gp` |

At HEAD (M19) the tour is:

```
help · cpu · mem · pci · disk id · fs · ls · frames · run prog.elf · ls · cat empty.txt
· frames · crash div · proc · fb · pci
```

`frames` brackets `run prog.elf` on purpose: the frame allocator's free count printed before and after
is the leak check for everything the ELF loader and the file syscalls touched. `cat empty.txt` is not
decoration either — `EMPTY.TXT` is a **zero-length** file that was on the volume before the boot, the
C program opened it for writing and gave it 40 bytes, and the `cat` is the kernel reading those bytes
back **by name, through a cluster chain it built itself**.

**The tour ends on `fb`, and that is the point of the last two commands.** `fb` finds the display
controller by PCI class, reads BAR0 — `FB BAR FD000000 MODE 0320x0258x20 OK`, an address the kernel
*discovered* rather than one anybody hardcoded — sets an 800×600×32 mode through the Bochs VBE
registers, and blits 8×16 glyphs from a `.rodata` font. Something has to be printed *after* the mode
change or the new console is an empty screen, which is why `pci` follows it; `m5-pci`'s own session
does the same for the same reason. The window you are left looking at is therefore the graphical
console, not VGA text — **the only pixels this operating system currently has.** The VGA text dump is
taken before the mode change so the text artefact and the final PNG describe the same screen.

---

## 6. What the run leaves behind

Everything under `/private/tmp/oscortex-demo/runs/<stamp>-<short>/`, with
`/private/tmp/oscortex-demo/latest` symlinked at the newest:

| file | what it is |
|---|---|
| `demo.png` | the final screen, QEMU's own `screendump` |
| `01-help.png` … `05-after.png` | one per stage of the tour |
| `serial.txt` | COM1, written by QEMU itself — the transcript |
| `screen.txt` | the VGA text buffer read out of guest physical memory |
| `tour.txt`, `drive.py` | exactly what was typed and what typed it |
| `demo.img`, `after.img` | the volume as built, and as the guest left it |
| `build.log`, `progs.log`, `qemu.log` | every subprocess's output |

The printed summary quotes **only lines the kernel itself printed**, pulled out of `serial.txt` by
pattern — so the summary cannot claim something the machine did not say. A pattern that matches
nothing prints nothing.

The volume gets one extra, independent statement:

* **write tours** — the image must have *changed*, and `fsck_msdos`, which knows nothing about this
  kernel, must call the result clean.
* **read tours** — the image must be **byte-for-byte identical** afterwards. At M14/M15 nothing was
  able to write, and the sha256 says so.

---

## 6a. `--watch`: a window that is always current

`--watch [secs]` polls the ref (default 60 s) and re-runs the whole demo every time it moves —
build, boot, tour, and a fresh window, with the previous one killed as usual. It **re-invokes this
script** rather than looping around its body, so one demo is still exactly one process and a commit
that fails to build is one failed child rather than a wedged loop; a failed commit is recorded as
seen so the loop does not spin on it, and the previous window is left up.

This is the mode the harness exists for. M19 landed *during* the session in which this document was
written, and a watching demo picks that up on its own within a minute.

---

## 7. Measured cost

| | |
|---|---|
| cold (new worktree + toolchain clone) | ~30 s |
| warm (worktree exists) | **~18–22 s** end to end at HEAD |
| of which: `build-kernel.sh` | ~3 s |
| of which: programs + FAT16 image | ~2 s |
| of which: boot to shell | ~2 s |
| of which: the 14-command tour | ~15 s |
| toolchain clone on disk | ~0 (APFS clone of 278 MiB) |

---

## 8. Known limits

1. **It demos commits, not your working tree.** That is deliberate — see §1 — but it means
   uncommitted work is invisible to it. Commit to a scratch branch and pass the ref.
2. **The `-name oscortex-demo` sweep is machine-wide.** `OSCORTEX_DEMO_ROOT` isolates the artefacts
   but not the "one at a time" rule.
3. **The tour is hard-coded per disk kind.** Adding a milestone's showpiece means editing the tour
   block in `demo.sh`; there is no per-milestone demo file. That is the right trade at 19 milestones
   and would not be at 50.
4. **Nothing is asserted.** A kernel that boots and prints garbage produces a green demo and a PNG of
   garbage. The summary quotes the serial capture so a human can see that, but only a human will.
5. **`cat` of a large file floods the 80×25 screen.** The tour deliberately `cat`s a 40-byte file for
   that reason; the transcript, not the screen, is where a big file would be legible.
