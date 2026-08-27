# The design corpus — an index, an ordered queue, and an honest count

**Status: INDEX. Nothing here is a decision.** Thirteen specialist documents were written in parallel,
each by an agent that read the tree for itself. This file is the only thing that read all of them. Its
job is to turn a pile of designs into a work queue, name the places where two specialists disagree,
and say what is *not* covered.

**Provenance.** The owner chose a native display protocol over Wayland compatibility, relayed by the
coordinator and not witnessed directly — recorded that way in `display-protocol.md`. Everything else
in this corpus is a proposal.

---

## The count

**145 milestones are specified across 18 ladders.** That is the answer to "how many tasks are left",
for the parts that have been designed. It is not the whole answer:

| specified | not yet specified |
|---|---|
| blocking · memory · namespace · storage · exec format · libc · text · display · SMP · GPU · NIC · net stack · time & power · ARM64 · **applications** · **security** · **USB & audio** | package format · ffmpeg itself · reflection · a window manager's *policy* (as opposed to the protocol) |

**Twenty-one documents now.** The count moved from 97 to 136 during a single afternoon of writing, so
treat it as a floor rather than a total. It is also
not a *schedule*: several ladders share milestones (`blocking` B1 **is** `display` D3), and several
are blocked on the same four small fixes below.

**Rate, measured rather than guessed:** M16, M17, M18 and M19 landed within about a day of each
other, with roughly three agents working. That is ~3–4 milestones/day *when integration keeps up*.
At that rate the 97 specified milestones are on the order of a month of wall clock — **and the
throttle is not agent count, it is the integration queue.** `hot-files.md` is the document about
that, and it should be read before anyone plans a fleet.

---

## The documents

| file | what it decides | the one thing to know |
|---|---|---|
| `display-protocol.md` | surfaces, transport, damage, input routing | server-side **drawing verbs**, not pixels — `fdwrite`'s 512-byte cap is 128 pixels, so pixel transfer is structurally impossible |
| `blocking-and-threads.md` | a blocked process state, `fdwait` | the blocked state is **one constant**; threads are not wanted and the motivating software does not need them |
| `memory.md` | the ring-3 window, shared frames, kmalloc, PAT/MTRR | do **not** widen `vmProgEnd` — split it into a load bound and a user bound, and 47 goldens stay put |
| `namespace.md` | device names, VFS shape | the device branch goes in `fileSysOpen`, **never** `fatLookup`. The sigil was `:`; for DRM it has to be `/`, because `libdrm` hardcodes `/dev/dri/card0` — GAP-0174 |
| `storage.md` | AHCI/DMA, filesystem beyond FAT16 | a 512-byte file costs **five** sector writes and five flushes; the cost is scheduling, not throughput |
| `exec-format.md` | `.osx`, dynamic linking | ffmpeg is gated on **size**, not linking — `libavutil.__text` alone is 5.4× the loader's max |
| `libc-roadmap.md` | what real applications need | 41 symbols exist, **only nine are C89**; 130 of C89's 139 are absent |
| `text.md` | fonts, glyph runs, Unicode | **this machine cannot type a capital `A`** |
| `net-e1000.md` | the NIC driver | the option ROM sends DHCP **before any guest OS runs** — the vacuity trap that would have cost a day |
| `net-stack.md` | ARP/IP/ICMP/UDP/TCP | a userland stack over a raw-packet device; TCP without timers is the hard part |
| `smp.md` | APIC, multiple CPUs | **SMP is not worth it yet — there is no workload for a second core.** But APIC pays for itself on ONE core, and two of ADR-0002's three reasons for rejecting it have been false since M5 |
| `arm64-port.md` | a second architecture | **not blocked on DCDart at all** — it emits aarch64 today. `-M virt` takes a plain ELF, exits 0 via PSCI, and the generic timer *is* the sub-tick clock. RAM starts at `0x40000000` |
| `time-and-power.md` | RTC, monotonic time, shutdown | shutdown is **one `outb`**; and GAP-0058 has been misread for milestones — a real clock costs two golden lines |
| `demo-harness.md` | showing the machine to a human | `core/scripts/demo.sh` — builds any commit in an isolated worktree, boots it in a window, kills the previous |
| `gpu.md` | what is actually reachable | VirtIO-GPU 2D only. Measured against this kernel's 22,088 lines: nouveau is 11×, i915+xe 25×, **amdgpu 288×** — and Intel modesetting is rejected not for size but because **no binary exit criterion can be written for it** |
| `drm-abi.md` | the Linux DRM/KMS ABI, so Mesa runs unmodified (ADR-0029) | virtio-gpu is a **universal shim** — one kernel driver reaches the host's Vulkan through venus. But the substrate is the project: `ioctl`, `mmap`, threads, TLS, dynamic linking, a hosted libc |
| `libdrm-port.md` | the first C library this OS was pointed at (ADR-0031) | unmodified libdrm **compiles**, 43 symbols short — and four of the ten that resolve are the **wrong function**. Serving BSD's `_IOC` instead of Linux's would have moved 29 of 121 request numbers silently |
| `hot-files.md` | what blocks parallel work | `kmain.dart`'s `part` list is **append-only and load-bearing**; two agents both appending last silently break a third file |
| `stale-comments.md` | 41 false comments | `ata.dart` states a superseded pin hash **twice** |

---

## Fix these before anyone writes code

Five items, all small. Four block or corrupt work that would otherwise proceed in parallel; the
first is a live defect reachable from ring 3 today.

0. **`open(name, O_WRITE)` truncates a read-only file.** `fileMakeEmpty` checks for a directory and
   never looks at `fatAttrReadOnly`. **~6 lines.** See the section below for how an audit found what a
   nineteen-item gap entry about the same code did not.
1. **Consolidate the eight whole-byte PIC-mask writes.** `keyboard.dart:173,190`, `kmain.dart:272`,
   `shell.dart:1085,1090`, `proc.dart:2006,2434`, `vga.dart:426`. Each re-masks everything it does
   not name, so **any newly unmasked IRQ works until the next shell command and then stops, silently.**
   This blocks the mouse, the NIC and every future interrupt-driven device. `m18-preempt` asserts the
   site counts, so it moves one assertion.
2. **Create a syscall-number registry.** Numbers 0–10 live in four files. **Two agents both writing
   `= 11` merge clean and mis-dispatch silently** — it nearly happened here between `fdwait` and a
   withdrawn display call.
3. **Repair the 41 stale comments.** Several instruct a reader to edit `core/boot/kdata.S` for symbols
   that left it at M17, which would reintroduce the seam M17 spent a milestone deleting.
4. **Fix `vm.dart:1958`.** It says `[128 MiB, 1 GiB)` has "62 unused page-directory entries". It has
   **447**; 62 is the size of the preceding *used* range. The wrong number was propagated into at
   least two documents before anyone checked the arithmetic.

---

## A live defect in the shipped write path

**`open(name, O_WRITE)` truncates a read-only file.** `fileMakeEmpty` checks for a directory
(`fatErrIsDir`) and never looks at `fatAttrReadOnly`, so any ring-3 program can destroy a file the
volume marks read-only. It is **about six lines** to fix and it is reachable today.

Worth noting how it was found: M16 shipped with a nineteen-item gap entry enumerating what its write
path deliberately does *not* do — and this was not one of them, because the author (me) was
enumerating *design* limits and this is an *omission*. It took an independent audit with a different
question to see it. That is the argument for the audit, not against the gap entry.

## The finding that most limits what this OS can run today

**No program on this machine can have both `argv` and `malloc`.** The two doors into ring 3 have
disjoint capabilities and nobody had written that down:

* **`run <name> args...`** gives a program its arguments and four descriptors — but it never calls
  `procCreate`, and `user.dart:1585` refuses `sbrk` unless `procLive() > 0`. **So `malloc` returns
  `NULL` for every program that can be told what to work on.**
* **`proc run <lba> <lba>`** gives a real process with a heap — and passes it nothing. A `start.c`
  program launched that way page-faults at `_start + 2`.

**M19 landed while this index was being written, and it did NOT close this — it sharpened it.**
Verified against `d4e768c`: `elf.dart` still contains **zero** calls to `procCreate` and enters ring 3
directly through `enter_user`, while `user.dart:1586` still reads
`if (procLive() < u64(1)) { userRefuse(...) }`. So as of today a program **can** be told what to do
and **still cannot allocate a byte.** M19 delivered the half that makes the missing half visible.

Every "write a useful program" milestone in `applications.md` is gated on closing that, and it is not
on any ladder. **It belongs in Tier 1**: a program that can be told which file to work on and can also
allocate memory is the precondition for `cp`, `wc`, an editor, and a userland shell.

A related measurement worth having: **`elfImageMax` bounds *disk* bytes, not mapped bytes**, so `.bss`
is a free multi-hundred-KiB static buffer that nothing currently uses. Flagged as derived rather than
measured; `applications.md`'s APP1 proves or falsifies it.

## `fileWriteMax` is 512, and three subsystems hit it independently

None of these documents could make this argument alone; together they make it decisively.

* **Display:** 512 bytes is **128 pixels**, one sixth of a scanline. This is what forced the entire
  protocol away from pixel transfer and onto server-side drawing verbs.
* **Audio:** 512 bytes is **345 `fdwrite` calls per second** for CD-quality stereo.
* **Storage:** a 512-byte write costs five sector writes and five cache flushes.

**Raising the cap is a shared unblock**, and it is the clearest example in the corpus of something
that looks like a local tuning constant from inside any one subsystem and like a structural limit from
outside all of them.

## Two hazards in the frame allocator nobody had written down

* **`allocFrame` does not zero the frame it returns.** Harmless for a page a program is about to fill;
  **not** harmless for a UHCI frame list, which is a page the controller reads as pointers *at 1000
  Hz* — uninitialised bytes are plausible transfer-descriptor addresses. Any future DMA structure
  inherits this.
* **A frame mapped into two address spaces is freed by whichever process dies first** — `freeFrame` is
  a bit-clear and `procSpaceFree` frees every present leaf unconditionally. Recorded in
  `display-protocol.md` §1.3; it is a property of `pmm.dart`, not of any display design.

## Two traps in the verification method itself

Several ladders propose deriving expectations from a QMP memory dump. Two specialists hit failure
modes in that technique that would have produced *silently wrong tests*, and both are worth knowing
before anyone writes a criterion.

* **`xp` reads MMIO in 4-byte units regardless of the width you type.** The GPU specialist caught
  itself misreading a VirtIO `num_queues` field this way. **No criterion may derive an expectation
  from an `xp` dump of a device BAR** — the number you get is not the number the device has. Dumping
  guest *RAM* is unaffected, which is what m5-pci, m7-frames and m10-elf already do.
* **The inverse trap: QEMU's default x86 machines have NO USB controller and NO audio device at
  all.** Measured — `-M pc` and `-M q35` each expose exactly six PCI functions and none is class
  `0x0C03` or `0x04xx`. So a naive criterion *fails* with no driver, and "fixing" it by adding
  `-device` proves nothing at all. Every rung in those ladders therefore carries **two** negative
  controls: device-absent and driver-disabled.
* **`-serial file:` is output-only, and every harness uses it.** That blocks the cheap ARM64 plan
  (drive the shell from serial input) and any future input testing until the driver grows a
  `chardev`-based path.
* **A default `-device e1000` sends seven packets, including a full DHCP exchange, with no guest OS
  running at all.** The option ROM does it during POST. Any "the capture is non-empty" criterion
  therefore passes against a kernel that does nothing. `romfile=` (empty) removes it and yields zero
  packets — and the NIC specialist verified that booting the *current* `kernel.elf` produces zero,
  so that negative control is already true today.

* **The ACPI tables move out of the mapped region when the machine has more RAM.** Measured: the RSDT
  is at `0x07FE2328` with `-m 128M` — inside `boot.S`'s 128 MiB identity map — and at `0x0FFE2328`
  with `-m 256M`, which is **outside it**. `m7-frames` boots 256 MiB. Any ACPI work (shutdown, APIC,
  SMP, MADT) inherits this, and it is the kind of thing that works on every harness but one.

Both belong in whatever the anti-vacuity guidance ends up being; they are the same failure the
existing harnesses guard against when `check-pixels.py` refuses to pass on a blank screen.

## A fleet-coordination hazard, learned the hard way

**A blanket `pkill qemu-system-x86_64` kills every other agent's work.** One happened during this
session and took down the live demo window; no `run.sh` in the tree does it, so it came from an
agent's own cleanup. With many agents running conformance harnesses simultaneously — each of which
boots QEMU — a blanket pkill is indistinguishable from sabotage from the victim's side, and no
pidfile or `-name` scheme defends against it.

**Cleanup must be scoped to what you started**: kill by recorded pid, or by a `-name` you set and then
match, never by process name alone. Worth stating in whatever contributor guidance the fleet ends up
with, because it is invisible until it bites someone else.

## One environment trap that costs hours

**`dcc` needs exactly Dart 3.12.2 — and this trap has now caught two specialists.** The ARM64 agent
concluded from it that *"`dcc` does not run on this host at all"* and that the break *"gates the
existing x86 suite"*. **That conclusion is wrong**, and I can disprove it from this session: the
kernel built cleanly many times today and all 20 harnesses passed, including a full run against the
pinned toolchain in an isolated sandbox. The agent simply had the wrong `dart` on PATH. **Anyone who
sees 49 "language version too high" errors is looking at this, not at a real break.** The `dart` on the default PATH here is 3.11.0 and fails with
*"language version 3.12 … is too high"*; a Flutter SDK at 3.13.0-dev fails differently with
*"Unexpected Kernel Format Version 131 (expected 130)"*. The working SDK is in
`dc_sys/toolchain/dart-sdk`, put on PATH by `dc_sys/env.sh`. **Source that file before anything.**
The demo specialist lost most of its debugging time to this before finding it.

~~Two related isolation facts, both verified: a git worktree only builds if **DCDart is a real sibling
directory** — `kmain.dart` imports the prelude by a relative path, and a *symlink does not work*
because Dart resolves library identity through real paths (the same root cause as GAP-0110). An APFS
clone (`cp -Rc`) does work and is near-free.~~ **OBSOLETE (2026-08-27, ADR-0043).** A git worktree now
builds with `DCDART_HOME` pointing anywhere — a sibling, an unrelated real path, or a symlink — and no
sibling DCDart need exist at all. Proved from a worktree that has none. The stated cause was also
wrong: Dart resolves *nothing*; `dcc` compares library URIs as lexically normalised strings and
symlinks survive unresolved on both sides, which is why routing the import and the compiler through
one `core/build/dcdart` prefix works. See GAP-0003 and the correction under GAP-0110.

## The ordered queue

**Tier 1 — the structural gates.** Everything else waits on these.

* **Sub-tick time and a free-running PIT — and this is now FIRST, not optional.** The time specialist
  found a dependency neither ladder had: **`blocking-and-threads.md` B1 cannot land until the timer
  runs while the machine is idle**, which is this milestone's decision. It is also cheap and it
  corrects a belief this repo has held for several milestones: **GAP-0058 has been read as "a real
  clock is expensive"; it is not.** `M1 TICKS` does not move at all (it counts triggers, printed with
  IRQ0 already unmasked) — only two lines in `m3-shell` and `m4-fault` break, and the fix is deleting
  a field. One further detail neither document had: `pitInit` programs **mode 3** (`0x36`), which
  decrements by two and makes a half-period ambiguous; **mode 2 (`0x34`) makes interpolation exact and
  moves no golden.**
* **A blocked process state + a resident process.** `blocking-and-threads.md` B1 and
  `display-protocol.md` D3 are **the same milestone**, reached from opposite ends: parking inside a
  syscall is unsound because the frame sits below RSP0, so the sound way to park is to leave through
  the door a resident process needs anyway. Build once.
* **`pciWrite32`.** Configuration space is read-only today. **Both** the NIC and the storage DMA path
  are blocked on it. Smallest item with the widest unblock.
* **A second ring-3 region** (`memory.md` MEM-1, `exec-format.md` X2). Splitting `vmProgEnd` rather
  than widening it.

* **SMEP and SMAP — the best value-per-line item in the corpus, and it moves no golden.** ~12 lines of
  assembly, zero new externs, zero DCDart changes, and it catches an entire bug class (the kernel
  dereferencing a ring-3 pointer it forgot to validate). Measured on QEMU 11.0.0: plain `qemu64` has
  **neither** feature, so a probe finds nothing, CR4 stays `0x620`, and the eight goldens carrying a
  full CR4 dump do not move; `qemu64,+smep,+smap` enables both **and leaves `CPU LEAF 0000000D EXT
  8000000A` unchanged**, so the feature boot is a new assertion rather than a moved one. It is cheap
  here for a specific reason: the kernel dereferences a ring-3 *virtual* address in exactly **four**
  places — the ELF loader, `args.dart` and `vmZeroFrame` all already write through the physical alias
  — so SMAP needs a conversion rather than `stac`/`clac` everywhere.
* **ACPI + APIC — a late addition to this tier, and the corpus argues for it rather than me.** The SMP
  specialist concludes that *multiple CPUs* are not worth building (there is no workload for a second
  core: nothing blocks, no `fork`, no `exec`, four slots, and processes only exist while a shell
  command runs). **But the controller pays for itself on one core, three ways.** It gives a clean
  shutdown. **The precise version of that claim, measured by the time specialist, is sharper than the
  one I first wrote:** it is not that twenty harnesses end via `timeout` — seventeen end with a
  host-side QMP `quit` and only three rely on the timeout. **The real gap is that the guest never
  terminates itself and never reports a status**, which has been true since M0. It gives a
  microsecond clock. And it gives **MSI/MSI-X, without which every driver after ATA is stuck
  polling** — which is exactly why the NIC ladder polls for its first seven milestones and takes
  interrupts only at the eighth. Estimated cost: ~512 bytes of `@bss`, **zero new externs, zero new
  assembly**.

**Tier 2 — devices, genuinely parallel once Tier 1 and the PIC fix land.** Mouse · NIC · AHCI · RTC ·
text T1. Different files, different harnesses, no shared state beyond the fixes above.

**Tier 3 — the OS becoming usable.** Display D4–D7 · the net stack above the driver · libc tiers ·
the namespace beyond one device.

---

## Where two specialists disagree

Recorded rather than silently resolved.

| disagreement | resolution |
|---|---|
| Is PCI bus mastering already enabled? | **Three specialists measured three things and all three are right.** The network-stack agent read `cmd=0x0107` on the **e1000** — bus master *set*. The GPU agent read `cmd=0x0103` on **both VirtIO devices** — bus master *clear*. The NIC agent predicted it would need setting. The rule they resolve to: **BME is set only where an option ROM ran.** iPXE drives the e1000 during POST (it completes a whole DHCP exchange before any guest OS starts); nothing drives a VirtIO device, so its bit stays clear. Consequences: **`GAP-0067` item 2's blanket claim that "firmware has already set up config space" is wrong as a general statement**; `pciWrite32` is mandatory (~5 lines, `Port.outl` already exists); every driver must set BME defensively; and the NIC ladder's N2 negative control is valid **only because it mandates `romfile=`** — drop that flag for convenience and the test passes without a driver. |
| Device-name sigil: `:` or `/`? | **`:`.** Both are already illegal in 8.3, but `/` is what a future path grammar wants. |
| Does ring 3 see frames it did not earn? | **Unresolved, and it is a real contradiction.** `net-e1000.md`'s step 11 sets `UPE` (unicast promiscuous), which directly contradicts `net-stack.md` §7.2's central claim that ring 3 *"never sees a frame it did not earn"*. One of the two designs has to give, and the security audit is right that it should be decided before either is built rather than after. |
| Does the "no allocator" constraint still hold? | **No — it expired at M7.** Two briefs repeated it; `pmm.dart` has given out frames since M7. |

**Naming collisions, now three and counting:** `N1` names a milestone in `namespace.md`,
`net-e1000.md` **and** `net-stack.md`; `T1` names one in both `text.md` and `time-and-power.md`; and
`arm64-port.md` claimed `A…` while `applications.md` was drafting the same prefix — that one was
caught mid-session and renamed to `APP`. **Adopt multi-letter prefixes for every ladder** before
anyone builds a work queue from these. It is the same class of collision as the syscall numbers, and
independent agents keep walking into it because nobody owns the namespace.

---

## Corrections these documents make to the existing repo

* **`GAP-0122` item 2 is factually wrong.** `open("SUB/X.TXT")` returns `fileRetNotFound`, not
  `fileRetBadName` — `/` is `0x2F` and `fatParseAt` accepts it, so the name folds silently to
  `SUB/X   TXT`. The claim became true only for the *write* path at M16.
* **`GAP-0141` names five process states and says four.** `ADR-0022` §12 is the correct original.
* **`GAP-0066`'s status is stale** — word/dword port I/O is on the pin; `portio.S` is now removable
  work rather than blocked work, and its deletion touches nine harnesses.
* **`GAP-0071` understates itself:** the kernel has never read an MTRR, so the framebuffer's effective
  memory type is unknown to it.
* **`CLAUDE.md` RULE 4 IS FACTUALLY WRONG, AND IT IS PROBABLY WHY ARM64 SAT OFF EVERY LADDER.** It
  says *"DCDart's backend has only ever verified `x86_64-unknown-none-elf`"*. **DCDart has emitted
  aarch64 since ADR-0033** — `core/backend/lib/targets.dart` registers eight targets including
  `aarch64-unknown-none-elf`. So an ARM64 port is **not** gated on a DCDart milestone; it is an
  oscortex project from day one. That sentence is in the file every agent reads first, so the
  correction matters more than most. (`CLAUDE.md` is the project's own rules file, so this is flagged
  rather than edited.) The honest qualifier: `bare-aarch64` has **zero conformance tests** upstream —
  it went in as an enum case — which is a day of DCDart's own work, not a milestone.
* **`ADR-0002` and `GAP-0007` reject the APIC for three reasons, and TWO have been false since M5.**
  The LAPIC at `0xFEE00000` and the I/O APIC at `0xFEC00000` are both inside the `[3 GiB, 4 GiB)` PCI
  hole that `vm.dart:596` already identity-maps for BARs — **there is nothing to map**. And xAPIC
  needs no MSR at all: the base comes from the MADT and the enable bit is a plain MMIO store, so the
  whole controller is `Pointer<u32>` in ordinary `@bare` DCDart. Only the ACPI parsing is real work,
  and every byte it reads is already mapped. The rejection should be re-decided on current facts.
* **`GAP-0127` item 4 (no timestamps) has a closer than it looks, and closing it touches M16's own
  harness.** The time specialist's T3 reads the RTC, which gives FAT its date and time fields — but
  **`m16-filewrite/derive.py` compares the written image byte-exactly**, so it must gain FAT
  date/time prediction *in the same change*. That is only possible because `-rtc base=` pins the
  clock, which the specialist verified. A milestone that adds timestamps without touching that
  harness turns a byte-exact comparison into a flaky one.
* **A hazard nothing records:** `fatLookup`'s four callers disagree about what its return codes mean,
  and `fileMakeEmpty` acts on two of them by truncating and rewriting a directory entry. Any future
  change that returns those codes for something that is not a plain file is a ring-3-reachable volume
  corruption.

---

## What this corpus does not cover

USB · audio · a security model beyond W^X and ring separation · package format · applications ·
reflection. **ARM64 is no longer on this list** — see the correction to `CLAUDE.md` rule 4 above; it
was excluded on a premise that has been false since DCDart's ADR-0033. **And nothing here
is implemented.** Thirteen designs and a boot that lists a filesystem is not an operating system with
a window on it; it is the map that says which order to build one in.
