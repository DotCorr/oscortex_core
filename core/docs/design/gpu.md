# GPU support in oscortex — the honest assessment

**Status: DESIGN, G0–G12 implemented.** Real vendor GPUs remain a NO. VirtIO-GPU 2D is G0–G8. G9 is `GET_CAPSET_INFO`. G10 is the device executing virgl work with alpha (`virtio-gpu-gl-pci` in Docker QEMU). G11 binds the osgfx compose buffer to that 3D scanout (upload, not Graphite). G12 is the explicit app GPU (`osgpu.h`): games call it; UI never does. Skia-on-this-GPU, swapchain, and shaders remain leftover.
G0 — recognise the device and print its capability table — landed in `core/kernel/virtgpu.dart`
(ADR-0059, `tests/conformance/g0-virtgpu/run.sh`). G1 — `pciWrite32` and bus-master — landed
in `pci.dart` + the same file (ADR-0065, `tests/conformance/g1-virtgpu/run.sh`). G2 —
`device_status` → `FEATURES_OK` → `DRIVER_OK` — landed in the same file (ADR-0067,
`tests/conformance/g2-virtgpu/run.sh`). G3 — one control virtqueue and `GET_DISPLAY_INFO` —
landed in the same file (ADR-0074, `tests/conformance/g3-virtgpu/run.sh`). G4 — one resource,
`SET_SCANOUT`, and a derived pixel — landed in the same file (ADR-0079,
`tests/conformance/g4-virtgpu/run.sh`). G5 — the framebuffer console on that
backing — landed in the same file (ADR-0084, `tests/conformance/g5-virtgpu/run.sh`).
G6 — damage as a pixel count, and a scroll that flushes the moved
rectangle — landed in the same file (ADR-0086,
`tests/conformance/g6-virtgpu/run.sh`). G7 — the same G5 walk on
`-device virtio-gpu-pci` with no VGA-class device, `fb` printing
`FB NONE` — landed in the same file (ADR-0091,
`tests/conformance/g7-virtgpu/run.sh`). This document exists because
"GPU support across the major GPUs" is on the owner's list, it is the least tractable item on it,
and the useful thing an engineer can do with an intractable request is say exactly where it stops
being tractable and what is on the near side of that line.

**The one-paragraph answer.** A driver for Intel, AMD or NVIDIA graphics is not a driver in the sense
this kernel has used the word eleven times. Measured against this kernel's 22,088 lines it is **11× to
288× the size**, it is half in the kernel and half in Mesa, and it requires vendor firmware blobs the
vendor cryptographically signs and you cannot produce. Two of them were built by funded vendor teams
over **eleven and twenty-two years** and are still being rewritten; the third was built by volunteers
without documentation over **twenty-one years**, spent a decade unable to raise the GPU off its boot
clocks because of a signature, and is now on its third rewrite. **oscortex will not have one.** What
oscortex *can* have — and what this document argues for — is **VirtIO-GPU**: a fully specified,
vendor-neutral, publicly documented paravirtual GPU whose 2D command space is **fourteen opcodes, of
which a first driver needs six**, which works under QEMU today, and which is reachable from where this
kernel actually is.

### The four claims in this document, for a reader in a hurry

| | claim | where |
|---|---|---|
| **Real GPUs** | Not reachable, and not by a margin that effort closes. The blocker is not size — it is **signed firmware you cannot produce** and **a userspace half (Mesa) larger than the kernel half**. | §1 |
| **VirtIO-GPU 2D** | **Reachable, and by less work than M14's FAT filesystem.** Six commands for a first pixel, one public spec, no firmware, no reverse engineering. | §2.1, §5 |
| **What it needs** | Three things this kernel does not have: **PCI capability-list walking**, **PCI config-space writes**, and **a virtqueue**. All three are small. `pmm.dart`'s one-frame-at-a-time limit is **not** a blocker, and the identity map is a gift. | §3 |
| **The display protocol** | The drawing-verb protocol is **not** a dead end. It is the layer that survives — but only if one decision is taken now, and §4.3 names it. | §4 |

**What to build first, if anything is built:** **G3 — one virtqueue command** (§5). G0 landed (ADR-0059):
the device is found, the five vendor capabilities print, and they resolve against QEMU's own
`info pci`. G1 landed (ADR-0065): `pciWrite32` exists and the command sets bus-master, with
the before value taken from the q35 ECAM window rather than from the kernel. G2 landed (ADR-0067):
the status sequence reaches `DRIVER_OK` (`0x0F`) and accepts only `VIRTIO_F_VERSION_1`.
G3 landed (ADR-0074): queue 0 exists, `GET_DISPLAY_INFO` returns `0x1101`, and scanout 0
matches the `xres`/`yres` the harness launched with. G4 landed (ADR-0079): resource 1
is created, backed, scanned out, and one derived colour is in both the guest
backing store and QEMU's screendump. G5 landed (ADR-0084): the framebuffer
console writes that backing store and issues one `RESOURCE_FLUSH` per
glyph cell of the banner. G6 landed (ADR-0086): a scroll copies the
backing and flushes `fbWidth × (fbHeight - glyphHeight)` pixels, and
the kernel prints that number. G7 landed (ADR-0091): `virtio-gpu-pci`
with no VGA-class device still paints and flushes; `fb` prints
`FB NONE`.

**A note on citations, because this document quotes two other numbered documents.** A bare `§n.n`
means **this document**. A citation to the VIRTIO specification is always written as *"VIRTIO §5.7.6.5"*
or is unambiguous by depth — VIRTIO section numbers in this document are always at least three levels
deep (`§4.1.4.9`, `§5.7.6.6`, `§2.7.1`) except where noted inline. A citation to the display protocol is
always written as *"`display-protocol.md` §1.3"*.

**A note on evidence.** Every claim in §0 and §3 about *this* machine was checked by booting
`core/build/kernel.elf` under QEMU 11.0.0 with the device attached and reading the results back, not
by reasoning about the source. The commands and their output are given inline so the next agent can
re-run them. Claims about the Linux drivers in §1 are cited to their sources and the ones I could not
confirm are marked as such.

---

## 0. Where this machine actually is, measured

`core/kernel/fb.dart` is a **dumb framebuffer console**. It walks PCI bus 0 looking for class 0x03
subclass 0x00, reads BAR0, programs 800x600x32 through the Bochs VBE ("dispi") index/data port pair at
`0x1CE`/`0x1CF`, and blits 8x16 glyphs one `Pointer<u32>` store at a time. There is no acceleration of
any kind: `fbFill` is 480,000 individual volatile 32-bit stores, there is no scroll (GAP-0070 item 1),
no double buffering (item 6), no cursor, and no way back to text mode.

**That is not a criticism, it is the baseline.** GAP-0070 already lists all eight of its limits. What
matters for this document is the *shape*: the kernel owns a linear aperture of video memory and writes
pixels into it with the CPU. Every GPU discussion below is a discussion about replacing that shape with
one where the kernel writes **commands** to a device that touches the pixels itself.

### 0.1 What was measured, and how

Booting the existing kernel against a VirtIO GPU, with no kernel changes at all:

```
qemu-system-x86_64 -kernel core/build/kernel.elf -m 128M -cpu qemu64 \
    -device virtio-vga -device virtio-gpu-pci \
    -serial file:ser.txt -display none -no-reboot -qmp tcp:127.0.0.1:$PORT,server,nowait
```

then `pci` and `fb` at the shell. The kernel's own output:

```
PCI 00:03.0 1AF4:1050 03/00/00 H00 vga display
PCI 00:04.0 1AF4:1050 03/80/00 H00 display
oscortex> fb
FB BAR FE000000 MODE 0320x0258x20 OK
```

**Four facts fall out of those five lines, and three of them are better news than I expected.**

1. **`-device virtio-vga` is class `03/00` — a VGA-compatible display controller — and `fbFindVgaBar`
   finds it, and `fb` works against it unchanged.** `0x320` is 800, `0x258` is 600, `0x20` is 32. The
   Bochs dispi interface, the linear framebuffer in BAR0, and the whole existing console all work on a
   VirtIO GPU on the first try with **zero lines of kernel change**. That is the migration bridge: a
   VirtIO driver can be developed against a device that is *already* driving a working console.
   *(With one caveat that §5/G4 spells out: VIRTIO §5.7.7 makes `SET_SCANOUT` the command that leaves
   VGA compatibility mode, so the two paths are exclusive at run time, not simultaneous. Coexistence
   is at the level of the source tree and the harness, not the frame.)*
2. **`-device virtio-gpu-pci` is class `03/80`** — "display controller, other". It is **not**
   VGA-compatible, it has no dispi interface and no linear framebuffer BAR. `fbFindVgaBar` requires
   subclass `0x00` (`fb.dart:327`) and therefore **cannot find it**. Anyone who reaches for
   `virtio-gpu-pci` first gets `FB NONE` and no explanation.
3. Both devices are `1AF4:1050` — VirtIO vendor `0x1AF4`, device `0x1050` = `0x1040 + 16`, the modern
   VirtIO PCI device ID for device type 16 (GPU).
4. Both landed their BARs in the PCI hole below 4 GiB, which `core/boot/boot.S` already identity-maps.
   §3.4 is about why that matters more than it looks.

---

## 1. THE REALITY — what a driver for Intel, AMD or NVIDIA actually is

**Provenance of every number in this section.** The line counts and commit counts were measured
directly from the **Linux v7.2** release tarball (`wc -l` over every file in each subtree) and from the
GitHub API against tag `v7.2`. Where a published `cloc`-style figure exists it is given alongside as a
cross-check, because `cloc` splits code from comments and blanks and therefore disagrees with `wc -l`
by a few percent. **Every figure I could not confirm is marked ⚠ and is not used to support an
argument.** Nothing in this section is an estimate of mine.

### 1.1 The shape of the problem, before any numbers

**A modern GPU driver is not a device driver.** A device driver, in the sense this kernel has used the
word eleven times — 16550 UART, 8259 PIC, PIT, 8042, ATA PIO, PCI, Bochs VBE — is a program that writes
documented values to documented registers. A modern GPU driver is **four subsystems that happen to ship
together**:

1. **a memory manager** — the GPU has its own address space, page tables and MMU (GTT/GART/PPGTT), and
   the driver is the operating system for it: allocation, eviction, migration between system and device
   memory, and buffer-object lifetime across process boundaries;
2. **a command submission engine** — rings, doorbells, contexts, preemption, fences and scheduling; and
   on modern parts a *hardware* scheduler running its own firmware that you submit to rather than
   program;
3. **a display engine driver** — the modesetting half taken apart in §2.3, which shares almost nothing
   with the other three. In i915 it is **47.9% of the driver** all by itself;
4. **a userspace half — Mesa** — which is where the compiler is. The kernel driver does not implement
   OpenGL or Vulkan. It exposes an ioctl interface; a shader compiler in userspace turns GLSL or SPIR-V
   into that GPU's instruction set. **A kernel driver with no Mesa driver renders nothing.**

**This kernel is 22,088 lines of DCDart across 19 files** (`core/kernel/*.dart`, comments included), or
**24,554** counting the four hand-written boot assembly files as well. Every number below should be read
against that.

### 1.2 Intel — i915 and Xe

| subtree (Linux v7.2) | files | lines |
|---|---:|---:|
| `drivers/gpu/drm/i915` | 910 | **420,185** |
| — of which `i915/display` | 340 | 201,207 *(47.9% of i915)* |
| — of which `i915/gt` | 229 | 94,556 |
| — of which `i915/gt/uc` (GuC/HuC plumbing alone) | 63 | 23,680 |
| `drivers/gpu/drm/xe` | 547 | **140,370** |
| **combined** | **1,457** | **560,555** |

*Cross-check: Phoronix measured i915+xe at 509k lines (352k code, 74k comment, 83k blank) in Linux
6.16 — consistent.*

**History.** `CONFIG_DRM_I915` first appears in **Linux 2.6.9, October 2004**; the driver predates git,
so no commit "adds" it — `i915_drv.c` is already present in the first commit of kernel git history. The
current path was created in 2008 (2.6.27). **36,611 commits** and **at least 767 distinct authors** ⚠
*(a lower bound — the enumeration was truncated)*.

**And then they wrote it again.** `xe` — first commit March 2023, merged in **Linux 6.8, March 2024**,
still labelled *"Experimental driver for Intel Xe series GPUs"* — exists because i915 had become
unmaintainable. **5,643 commits and 218 authors in its first two years.** For a project deciding whether
to write one Intel driver, the relevant fact is that **Intel decided one was not enough and wrote a
second**.

**Documentation: genuinely public, and this is the one thing that makes Intel different.** Intel
publishes Programmer's Reference Manuals under CC-BY-ND, at roughly **5,000 pages per architecture**.
That is why i915 exists as a first-class upstream driver at all. ⚠ *Public PRMs are confirmed through
Gen12.5 (Alchemist/DG2); coverage for Xe2 / Battlemage / Lunar Lake could not be confirmed — Intel's
official index returned HTTP 403.*

**Firmware — and here the honest answer is more nuanced than "it is all mandatory".** Read out of
v7.2's `intel_uc.c`:

* **GuC** (graphics microcontroller): **off** by default pre-Gen12, and on Tiger Lake and Rocket Lake.
  Alder Lake-S gets HuC authentication only. **From Alder Lake-P onward — including DG2, Meteor Lake
  and Xe2 — HuC authentication and GuC submission are on by default and GuC is mandatory**, because
  power management is offloaded to it. Without matching firmware the GPU falls back to software
  rendering. On the `xe` driver there is no `enable_guc` knob at all; `xe_device_uc_enabled()` is
  literally `!force_execlist`, and firmware init failures fail the probe. ⚠ *That last inference is
  from source reading, not from a documentation statement.*
* **DMC** (display microcontroller, gen9/Skylake onward): **not required for basic modesetting.** On
  failure the driver logs *"Failed to load DMC firmware… Disabling runtime power management"* and
  carries on. **You lose display power management, not the display.** This is worth stating precisely,
  because it is the one firmware requirement in this whole section that is genuinely soft.
* **HuC**: media offload.

**The honest reading of Intel.** Best case of the three, and it is still **560,000 lines**, two drivers
because the first collapsed under its own weight, and signed firmware that is mandatory on everything
recent enough to care about.

### 1.3 AMD — amdgpu

| subtree (Linux v7.2) | files | lines | share |
|---|---:|---:|---:|
| **`drivers/gpu/drm/amd`** | **2,839** | **6,353,859** | 100% |
| `amd/include/asic_reg` — **auto-generated register headers** | 488 | **4,977,963** | **78.3%** |
| `amd/include` (all headers) | 564 | 5,116,394 | 80.5% |
| `amd/display` (DAL/DC) | 1,219 | **596,080** | 9.4% |
| — of which `amd/display/dc` | 1,066 | 517,010 | 8.1% |
| `amd/amdgpu` (core driver) | 638 | 387,792 | 6.1% |
| `amd/pm` (power management / SMU) | 284 | 185,767 | 2.9% |
| `amd/amdkfd` (compute) | 68 | 52,993 | 0.8% |
| **non-header code** (`amd` minus `amd/include`) | | **~1,237,465** | 19.5% |

**The largest single file in the tree is `asic_reg/dcn/dcn_3_2_0_sh_mask.h` at 223,492 lines** — one
header, for one display block, of one generation, **ten times the size of this entire kernel.**

*Cross-checks: Phoronix put `amd` at 5,904,055 lines in Linux 6.16, 5,937,130 in 6.19 and 6,048,151 in
7.0 — **roughly 15% of the whole Linux kernel source tree**. AMD's own Marek Olšák noted the amdgpu
include directory is ~32.7% the size of the entire kernel tree and proposed moving it out.*

**The 4.98-million-line header number is not a joke about bloat — it is the measurement that matters.**
It is what "supporting a GPU family" costs *to express*: every ASIC generation has its own register
map, and the maps are large enough that AMD machine-generates them. A from-scratch OS would need the
same information at the same volume and would have to generate it the same way. **You cannot hand-write
your way around five million lines of register definitions.**

**History.** `CONFIG_DRM_AMDGPU` first appears in **Linux 4.2, August 2015**. **37,559 commits** and
**at least 1,364 distinct authors** ⚠ *(lower bound)*. The display code has its own story worth
knowing: DC/DAL landed in **Linux 4.15 (2017)** as roughly **132,000 lines in one go**, and was
**initially rejected** — Dave Airlie: *"Given the choice between maintaining Linus' trust that I won't
merge 100,000 lines of abstracted HAL code and merging 100,000 lines of abstracted HAL code"* — because
AMD shares it with their Windows driver.

**Firmware: mandatory, and the failure is fatal.** `amdgpu` loads per-IP-block microcode from
`/lib/firmware/amdgpu` — PSP, SMU/SMC, RLC, GC/GFX, SDMA, VCN, DMCUB, MEC — through the **PSP**, AMD's
Platform Security Processor, which verifies signatures before anything runs. Without them, the failure
path is `Direct firmware load for amdgpu/<asic>_gpu_info.bin failed` → *"Fatal error during GPU init"*
→ **probe aborts**. Gentoo's wiki states it plainly: *"the AMDGPU driver doesn't work properly without
firmware."* ⚠ *There is no single authoritative kernel-doc page asserting this; the claim rests on
distribution documentation and a large, consistent body of bug reports.*

**Documentation.** AMD publishes ISA reference guides through GPUOpen (RDNA 2, 3, 3.5) including
machine-readable ISA. This is a real and creditable thing, and it does not change the firmware answer.

### 1.4 NVIDIA — nouveau, and the clearest illustration in this document

| subtree (Linux v7.2) | files | lines |
|---|---:|---:|
| `drivers/gpu/drm/nouveau` | 1,306 | **232,946** |
| `drivers/gpu/nova-core` (Rust successor) | 54 | 13,472 |
| `drivers/gpu/drm/nova` (Rust) | 6 | 247 |

**Twenty-one years, and it is being written for the third time.**

* **June 2005** — work begins as clean-room reverse engineering. Publicly announced **February 2006 at
  FOSDEM**. ⚠ *Dave Airlie's own LPC 2022 slides say "started in 2007"; the sources disagree, and
  either way it is ~19–21 years.*
* **February 2010** — mainlined in **Linux 2.6.33**, into **staging**. Four to five years to get that
  far.
* **March 2012** — graduates from staging. ⚠ *That implies Linux 3.4; the source gives the date, not
  the version.*
* **November 2023** — GSP-RM support merged in **Linux 6.7**, a substantial rework.
* **May 2025** — `nova-core`, a Rust rewrite, merged as a stub in **Linux 6.15**.

**Documentation: none.** NVIDIA published no register documentation for the hardware nouveau targets.
The twenty-year timeline is the direct measurement of what that costs.

**The firmware story, which is the whole story.** The primary source is Dave Airlie's LPC 2022 talk
*"nouveau: in the times of firmware"*, whose hardware timeline slide reads:

> 2014 – GM1xx – Maxwell · **2014 – GM2xx – Maxwell 2 – Start of signed firmware** · 2016 – GP1xx –
> Pascal · 2017 – GV1xx – Volta · **2018 – TU1xx – Turing – GSP support** · 2020 – GA1xx – Ampere

and whose "rise of signed firmware" slide reads: *"Started with Maxwell 2 · Firmware had to be signed ·
Complicated firmware boot sequences · Bespoke nouveau firmware · **No reclocking PMU firmware.**"*

**The consequence, in one sentence: on GM20x, GP10x and GV100, nouveau has no reclocking at all and is
pinned to boot clocks.** Not "somewhat slower" — running at the memory and core clock the card chose to
POST at. This was the situation for roughly a decade, and **no quantity of reverse engineering could
change it, because the missing component was a cryptographic signature, not knowledge.** ⚠ *I could not
obtain a confirmed quantitative performance figure for the penalty; the qualitative claim is
well-sourced, a percentage is not.*

**GSP changed the shape of the problem rather than solving it.** From Turing onward NVIDIA ships
**GSP-RM**, firmware running on an on-die **RISC-V** processor that absorbs GPU initialisation and power
management. NVIDIA's May 2022 `open-gpu-kernel-modules` release made it usable — Airlie's summary of
what that release actually is: *"Fork of NVIDIA proprietary driver · Moved 'secrets' to GSP · Remaining
kernel code isn't secret · Allows MIT release of kernel drivers · **Not upstreamable.**"* Nouveau now
gets working reclocking, mandatory on RTX 40 and newer, default-on for Ada.

**And the price of that, which is the part worth internalising.** NVIDIA pushed **62 MB** of GSP blobs
into `linux-firmware.git`; the files are **20–30 MB each, two per device**, with **no stable ABI** — a
version bump means shipping another complete set. Airlie's "upcoming problems" slide lists exactly:
*"Firmware size · initramfs blowouts · No stable fw ABI yet."* **The open driver's job became to be a
supported client of a closed implementation whose interface changes at the vendor's discretion.** That
is not open hardware support.

**The Vulkan half is a separate multi-year effort.** NVK, in Mesa, is now conformant **Vulkan 1.4**
across Kepler through Blackwell, requires Linux 6.6+, and since Mesa 25.1 NVK+Zink is the default
OpenGL implementation for Turing and newer. It is a *different codebase* from everything counted above.

**`nova-core` is not close.** Its own official TODO lists BIOS init, MMU and page tables, the VRAM
allocator, the GSP message queue and bootstrap, and the FIFO, graphics and copy engines as **not yet
done**. 367 commits, 22 authors.

### 1.5 The arithmetic, and the staffing, stated once

| | lines | vs. this kernel |
|---|---:|---:|
| **oscortex — every kernel `.dart` file, 19 of them, comments included** | **22,088** | **1×** |
| oscortex — the same plus `core/boot/*.S` | 24,554 | 1.1× |
| `drivers/gpu/drm/i915/display` — **the modesetting half alone** | 201,207 | **9×** |
| one AMD header file, `asic_reg/dcn/dcn_3_2_0_sh_mask.h` | 223,492 | **10×** |
| `drivers/gpu/drm/nouveau` | 232,946 | **11×** |
| `drivers/gpu/drm/i915` + `xe` | 560,555 | **25×** |
| `drivers/gpu/drm/amd`, non-header code only | ~1,237,465 | **56×** |
| `drivers/gpu/drm/amd`, as it exists in the tree | 6,353,859 | **288×** |

**None of these include Mesa** ⚠ *(not measured)*, where OpenGL, Vulkan and every shader compiler live.

**And the staffing, which answers "how many people over how long" better than any line count.**
Distinct authors and commits over the trailing 24 months, measured at v7.2:

| driver | authors on vendor domains / all authors | vendor share of commits | commits in 24 months |
|---|---:|---:|---:|
| `i915` (`@intel.com`) | 74 / 181 | **88%** | 3,518 |
| `xe` (`@intel.com`) | 109 / 183 | **89%** | 3,541 |
| `amd` (`@amd.com`) | **294 / 504** | **83%** | 6,699 |
| `nouveau` (`@redhat.com`, `@nvidia.com`) | 12 / 80 | 49% | **367** |
| `nova-core` (`@nvidia.com`) | 7 / 22 | 78% | 367 |

**Read the last two rows against the first three.** In the same two years, `xe` — a brand-new driver —
took **3,541 commits** and `nouveau` — a twenty-year-old one — took **367**. Roughly **ten to one**.
AMD alone had **294 distinct `@amd.com` authors** touching the driver in 24 months.

**And the counter-example that proves the point.** Over its lifetime, **Ben Skeggs personally wrote
3,753 of nouveau's 7,166 commits — 52.4%**, with Red Hat accounting for 61.7%. Airlie's own slide on why
nouveau stagnated: *"Developers getting hired away · **Only one fulltime developer** · No reclocking
makes it hard to justify driver efforts."* Skeggs has since left the project.

⚠ *Published paid-headcount figures do not exist for either vendor. A 2015 estimate put Intel's Linux
graphics team at "probably around 30–50", but that is a journalist's estimate, not a company statement,
and it is eleven years old. The contributor counts above are the better proxy.*

**So: how many people over how long.** Intel: a vendor team with hardware access and public
documentation, continuously since **2004**, and they rewrote it in **2024**. AMD: a vendor team with
hardware access, since **2015**, with ~300 distinct company authors active in the last two years alone.
NVIDIA: volunteers without documentation against hardware that actively refuses unsigned code, since
**2005**, effectively **one full-time person** for much of it, now on the **third** attempt.

### 1.6 The three walls — and why size is the least of them

**(1) Signed firmware is not an engineering problem, and this is the decisive one.** Every driver above
needs vendor blobs the hardware verifies cryptographically before it will run them. You cannot write
them, derive them, substitute them or work around them. AMD is the starkest: without PSP-signed
microcode, initialisation **fails and probe aborts**. NVIDIA is the most instructive: a competent team
with two decades of effort **could not raise a Maxwell 2 GPU off its boot clocks**, because the
obstacle was a signature. **This is the sentence to quote if the question comes back: no amount of
effort produces a signature you do not have the key for.**

**(2) Two of the three vendors document nothing you can build from.** Intel publishes real PRMs — which
is exactly why i915 exists and why it is the only one of the three where §2.3 is even arguable. AMD
publishes ISA and register references. NVIDIA published nothing for the hardware nouveau targets, and
nouveau's timeline is the price tag.

**(3) The kernel driver is the smaller half, and this OS cannot host the larger one.** A DRM driver
exposes buffers and command submission; it does not implement a graphics API. The shader compiler, the
state tracker, the format handling and the API itself are all in **Mesa**, in userspace. An OS with no
libc worth the name, no dynamic linker, no threads and no `mmap` — `display-protocol.md` §5.2 itemises
exactly this, and puts a hand-written Wayland client at 80–120 libc symbols and a Cairo one at 250–350
— **cannot host Mesa.** So even a hypothetical complete kernel driver would put **zero** pixels on
screen through any standard API.

**The conclusion, as plainly as I can put it.** oscortex will not have an Intel, AMD or NVIDIA driver.
Not in this milestone, not in this roadmap, and not as a result of trying harder. The goal should be
retired or restated (§6, Q1), and §2 is what should replace it.

---

## 2. What is actually reachable, in order of increasing difficulty

| | path | verdict | why |
|---|---|---|---|
| **(a)** | **VirtIO-GPU 2D** | **Reachable. Build this.** | One public specification, thirteen commands, no firmware, no reverse engineering, no userspace half. §2.1 |
| **(b)** | **VirtIO-GPU 3D (virgl)** | **Not reachable** | The guest side is a Mesa Gallium driver. There is no "virgl protocol" you can implement without Mesa. §2.2 |
| **(c)** | **Modesetting on real Intel hardware** | **Not reachable on any credible timescale**, and it is not a smaller version of an i915 driver | §2.3 |
| **(d)** | **AMD or NVIDIA** | **No.** | §2.4 |

### 2.1 (a) VirtIO-GPU 2D — the realistic first real GPU

**What it is.** A paravirtual GPU defined in the OASIS VIRTIO specification as **device type 16**,
specified in **§5.7 of *Virtual I/O Device (VIRTIO) Version 1.4*, Committee Specification 01, 8 April
2026** (`docs.oasis-open.org/virtio/virtio/v1.4/virtio-v1.4.html`). The guest driver writes commands
into a virtqueue; the host executes them against whatever real display stack it has. There is no
hardware to reverse engineer because there is no hardware — the interface *is* the specification, and
the specification is a normative, versioned, publicly published document with no login, no NDA and no
clickthrough. **§5.7's numbering is identical in v1.2, v1.3 and v1.4**, so a citation does not rot.

**Why it is the right first target, in four points.**

1. **The whole 2D command space is fourteen opcodes (`0x0100`–`0x010D`), and this kernel needs six.**
   `GET_DISPLAY_INFO` (`0x0100`), `RESOURCE_CREATE_2D` (`0x0101`), `SET_SCANOUT` (`0x0103`),
   `RESOURCE_FLUSH` (`0x0104`), `TRANSFER_TO_HOST_2D` (`0x0105`), `RESOURCE_ATTACH_BACKING`
   (`0x0106`). Everything else — `RESOURCE_UNREF`, `RESOURCE_DETACH_BACKING`, `GET_CAPSET_INFO`,
   `GET_CAPSET`, `GET_EDID`, `RESOURCE_ASSIGN_UUID`, the two blob commands, and the two cursor
   commands on the second queue — is optional for a first pixel.
   **Compare that with M14: a FAT16 filesystem is 2,632 lines of `fat.dart` and it is done.** This is
   smaller.
2. **Every structure is a flat, little-endian, fixed-size, hand-layoutable byte block.** No pointers to
   chase, no variable-length encoding except one counted array, no alignment surprises. That is exactly
   the shape `@bare` DCDart can express with `Pointer<T>.fromAddress` and hand-computed offsets, which
   is what this kernel already does everywhere (`fbState`, `pmmMeta`, `fatDirEntry`).
3. **There is a reference implementation you are allowed to read, and it is small.** Linux's
   `drivers/gpu/drm/virtio` is **6,813 lines across 18 files**, and more than half of that is DRM/KMS
   and GEM boilerplate this kernel has no equivalent of. The parts that matter — `virtgpu_vq.c` (1,531
   lines, the virtqueue plumbing and every command encoder) and `virtgpu_plane.c` (614 lines, scanout
   and flush) — are the whole of the useful content. The wire format is a single UAPI header,
   `include/uapi/linux/virtio_gpu.h` (**469 lines**), which is the same file both ends compile against
   and which can be transcribed into DCDart offsets mechanically. **Compare §1.**
4. **It is already in the harness.** §0.1 shows the device found, the mode set and pixels drawn with
   zero kernel changes, by swapping one QEMU argument.

**What it costs, honestly.** VirtIO-GPU 2D gives no acceleration in the sense a graphics programmer
means. `TRANSFER_TO_HOST_2D` moves guest bytes to the host; the compositor still draws every pixel in
software with the CPU (§4.2). What it buys is **a mode the kernel is told rather than guesses, real
double buffering, a hardware cursor, damage-proportional presentation, and the deletion of the kernel's
copy into VRAM.** That is a genuinely better display stack. It is not a GPU in the sense of "things go
fast now".

**And the honest limit on where it runs.** VirtIO-GPU runs under QEMU, KVM, crosvm, Firecracker (with
the right device model), and cloud-hypervisor. **It does not run on a laptop.** If the goal is "boot
this on real metal and see a picture", VirtIO-GPU does not get you there and nothing in §2.3 or §2.4
does either. What gets a picture on real metal is a **UEFI GOP framebuffer handed over by the boot
loader** — which is not a GPU driver, is not in this document's scope, and is a different, much
smaller, genuinely achievable project that this kernel cannot do only because it is a Multiboot1 image
(`fb.dart`'s own header says so).

### 2.2 (b) VirtIO-GPU 3D / virgl — not reachable, and the reason is not size

`VIRTIO_GPU_F_VIRGL` (feature bit 0) turns the control queue into a transport for a 3D command stream.
The tempting reading is "same driver, more commands". It is not.

**The virgl command stream is deliberately not specified.** §5.7.6.9 says of
`VIRTIO_GPU_CMD_SUBMIT_3D`: *"Submit an opaque command stream. The type of the command stream is
determined when creating a context."* OASIS specifies the envelope — contexts, resources, transfers,
capset negotiation — and **nothing about the bytes inside**. The de-facto specification is
`virglrenderer`'s decoder, and virglrenderer's repository contains no protocol document at all: the
normative artefacts are `src/virgl_protocol.h` (808 lines of opcode defines) and
`src/vrend/vrend_decode.c` (2,169 lines), with the actual semantics in `vrend_renderer.c` (13,876
lines) and `vrend_shader.c` (8,598 lines).

**The guest side of virgl is a Mesa Gallium driver**, `src/gallium/drivers/virgl` — **10,582 lines**,
plus **3,376** for its winsys. That number is deeply misleading as an effort estimate, and the reason
is the decisive one: a Gallium *driver* only functions on top of Gallium's screen/context
infrastructure, the GL state tracker, NIR, NIR→TGSI, and Mesa's format and utility libraries.
**Shaders cross the wire as TGSI *text*** — Mesa's `virgl_encode_shader_state` calls `tgsi_dump_str`
and ships ASCII, which virglrenderer parses back with `tgsi_text_translate` and compiles to GLSL. To
emit that you need a shader compiler. **Porting "the virgl driver" means porting Mesa.**

The successors do not help:

* **venus** (capset 4) forwards Vulkan instead of GL. Its protocol is Mesa's **machine-generated**
  `src/virtio/venus-protocol` headers, generated from `vk.xml` — strictly less hand-implementable than
  virgl. It also requires `RESOURCE_BLOB` plus `CONTEXT_INIT` plus a host-visible shared-memory region.
* **DRM native context** forwards the *real* GPU's ioctls to the host driver. The guest side is
  literally the real vendor Mesa driver — radeonsi, anv, freedreno. That is strictly worse: it is §1
  plus a transport.
* **`VIRTIO_GPU_F_RESOURCE_BLOB`** is genuinely useful and genuinely reachable, and it is **not 3D**:
  it lets a resource be host-mappable so the guest can write pixels the host is already scanning out,
  removing `TRANSFER_TO_HOST_2D` from the hot path. It belongs on the 2D ladder as a successor
  milestone, not here.

**And on this machine it is moot: the device does not offer it.** §3.8 measures
`device_feature[0..31] = 0x30000002` — `VIRTIO_GPU_F_VIRGL` is bit 0 and it is clear — and
`num_capsets = 0`. The local QEMU has no `virtio-gpu-gl-pci` device compiled in at all.

**One honest qualification, because "impossible" is a stronger word than the evidence supports.** The
virgl wire format is plain dword commands (`cmd | obj << 8 | len << 16`) and TGSI text is a small,
human-writable assembly language. A determined author could hand-write a few TGSI shaders as string
literals and emit `CREATE_OBJECT`/`SET_FRAMEBUFFER_STATE`/`CLEAR`/`DRAW_VBO` by hand, reverse
engineering against `vrend_decode.c`, and get accelerated blits or a textured quad. That is **not**
OpenGL, has no conformance guarantee, has no compatibility contract (nothing but Mesa is a supported
client), and no such implementation is known to exist. **It is a research project, not a milestone.**

**Verdict: 3D on this OS requires porting Mesa. That is not a milestone, it is a second project larger
than this one.** QEMU's own documentation says the same thing about the 2D backend in one sentence:
*"The guest needs to employ a software renderer for 3D graphics."*

### 2.3 (c) Modesetting on real Intel hardware — why "just modesetting" is a trap

This is the option that sounds reasonable and is not, so it is worth taking apart. The pitch is: skip
the render engine, skip the command submission, skip Mesa — just program the display pipe well enough
to light a framebuffer. Intel publishes register documentation. How hard can it be?

**Start with the measurement, because it settles the question before the argument begins.
`drivers/gpu/drm/i915/display` is 340 files and 201,207 lines — 47.9% of the i915 driver, and nine
times this entire kernel.** That subtree *is* "just modesetting", with the render engine, the memory
manager and the command submitter all in the other half. AMD's equivalent, `amd/display`, is 596,080
lines. **"Just modesetting" is the larger half, not the smaller one.**

**What "just modesetting" actually contains on a modern Intel part:**

* **Power wells and display initialisation.** Before any display register is meaningful you must bring
  up the correct power wells in the correct order with the correct timeouts, per generation. *(In
  fairness, and unlike everything else in this document: the **DMC** display microcontroller's signed
  firmware is **not** required for basic modesetting — i915 logs "Failed to load DMC firmware…
  Disabling runtime power management" and carries on. You lose display power management, not the
  display. This is the one soft firmware requirement in §1, and it should not be overstated.)*
* **Clocks.** DPLL/LCPLL/DPLL4 selection, dividers, and the constraint solver that picks a legal
  combination for a given pixel clock — plus CDCLK, which must be raised *before* a mode that needs it
  and is itself a sequenced programming operation with hardware handshakes.
* **Output detection and training.** DisplayPort link training is a real protocol over AUX: read DPCD,
  pick lane count and link rate, run clock-recovery and channel-equalisation phases, fall back and
  retry on failure. HDMI needs a different path. eDP on a laptop needs panel power sequencing with
  vendor-specific delays read from VBT — **the Video BIOS Table**, an undocumented, per-machine,
  per-generation binary blob that i915 parses because there is no other source for the panel's timing
  and backlight parameters.
* **Watermarks.** The display engine's memory-fetch watermarks must be programmed correctly or the
  display underruns and you get a black or corrupted screen. On Skylake and later this is the SKL+
  watermark algorithm, which is several hundred lines of arithmetic over memory bandwidth and plane
  configuration, and getting it wrong produces a symptom indistinguishable from "my modeset is wrong".
* **Gen-by-gen divergence.** None of the above is one implementation. It is a different implementation
  per display generation, which is most of why i915's display code is the size it is (§1.2).

**And a structural problem this project has that Linux does not.** On real metal, whatever ran before
you already set a mode. i915's hardest, least-documented work is **reading back the hardware's current
state** and taking over from it without a flicker or a hang. A kernel that programs from scratch on
hardware someone else already configured is programming from an unknown starting state.

**The honest exit criterion problem, which is why this gets no milestone ladder.** Every criterion in
this repo is mechanically checked from a serial capture or a memory read-back under QEMU. **Intel
modesetting cannot be tested under QEMU** — QEMU does not emulate an Intel display engine. The test is
"plug in a monitor and look", which is precisely the eyeballing `CLAUDE.md` forbids, on hardware that
varies per machine. **There is no way to write a binary exit criterion for this milestone**, and a
milestone without one does not belong in this project's roadmap.

**Verdict: not reachable, and it is not a scoped-down i915 — it is the hard half of i915 with the easy
half removed.**

### 2.4 (d) AMD or NVIDIA — no

§1 is the argument. In one line each:

* **AMD:** `amdgpu` **aborts probe** without PSP-signed firmware for the GFX, SDMA, VCN, SMU, RLC and
  display blocks — the failure is `"Fatal error during GPU init"`, not a degraded mode — and none of
  those blobs can be produced. Even with them, the register definitions alone are **4,977,963 lines**
  of machine-generated headers, and the display subtree alone is **596,080 lines**.
* **NVIDIA:** from **Maxwell 2 (GM20x, 2014)** onward the GPU refuses unsigned falcon microcode, and
  nouveau consequently had **no reclocking at all** on GM20x/GP10x/GV100 — pinned to boot clocks for
  roughly a decade, by a signature. From **Turing (2018)** the driver's job is largely to talk to
  **GSP-RM**, a 20–30 MB firmware image running on an on-die RISC-V core, over an interface with **no
  stable ABI**. Twenty-one years in, with essentially one full-time developer for much of it, the
  driver is being written for the **third** time (`nova-core`, whose own TODO still lists BIOS init,
  page tables, the VRAM allocator and the GSP bootstrap as not done).

**The single sentence that covers both, and the one to quote if this comes up again:** *the blocker is
not that the code is large — it is that a necessary component is a cryptographically signed binary the
vendor controls, and no amount of engineering effort produces one.*

---

## 3. What VirtIO requires from this OS, item by item, against what this OS has

This section is the reason the answer to §2.1 is "yes" rather than "in principle". Every requirement
below was checked against the kernel's source or against a live boot, not assumed.

### 3.1 The transport: a PCI capability walk, and the numbers from a real device

VirtIO-GPU is a **VirtIO 1.0-only device**, and this is not a preference — it is enforced at both ends.
The specification's transitional-device table (VIRTIO §4.1.2.1) lists transitional PCI device IDs for net,
block, balloon, console, SCSI, entropy and 9P, **and not for the GPU**; and QEMU's
`hw/display/virtio-gpu-pci.c` calls `virtio_pci_force_virtio_1()`, which sets `disable_legacy = ON`
and refuses legacy mode outright. So the simple I/O-port BAR0 transport that makes virtio-blk and
virtio-net easy first drivers **is not available here at all**. The driver must implement the modern
PCI transport, and the modern transport puts everything behind the **PCI capability list at
configuration offset `0x34`** —
which `core/kernel/pci.dart` does not follow. GAP-0067 item 4 says so in as many words: *"No capability
list. Offset `0x34` is not followed... Every modern interrupt path for a PCI device starts there."*

**Here is what is actually there.** Configuration space of `-device virtio-gpu-pci`, read through q35's
ECAM window with the QEMU monitor (`xp/64xw 0xb0020000`) on a live boot, decoded:

```
  offset 0x00  1AF4:1050        vendor / device
  offset 0x04  cmd=0x0103       I/O=1  MEM=1  BUS MASTER=0   status=0x0010 (has caps)
  offset 0x08  class 03/80/00 rev 01
  offset 0x14  BAR1 = 0xfebd5000   32-bit mem, 4 KiB   (MSI-X table)
  offset 0x20  BAR4 = 0xfe00000c   64-bit prefetchable, 16 KiB @ 0xfe000000
  offset 0x34  cap pointer = 0x98

  cap@0x98  id=0x11                MSI-X, table size 3
  cap@0x84  vndr=0x09 cfg_type=5   PCI_CFG
  cap@0x70  vndr=0x09 cfg_type=2   NOTIFY_CFG  bar=4 offset=0x3000 len=0x1000  notify_off_multiplier=4
  cap@0x60  vndr=0x09 cfg_type=4   DEVICE_CFG  bar=4 offset=0x2000 len=0x1000
  cap@0x50  vndr=0x09 cfg_type=3   ISR_CFG     bar=4 offset=0x1000 len=0x1000
  cap@0x40  vndr=0x09 cfg_type=1   COMMON_CFG  bar=4 offset=0x0000 len=0x1000
```

And the *same* decode for `-device virtio-vga`, which is the device this project should actually use:

```
  offset 0x08  class 03/00/00               <- VGA-compatible: fbFindVgaBar finds it
  offset 0x10  BAR0 = 0xfe000008   32-bit prefetchable, 8 MiB   <- the linear framebuffer
  offset 0x18  BAR2 = 0xfe80000c   64-bit prefetchable, 16 KiB  <- the VirtIO structures
  offset 0x20  BAR4 = 0xfebd4000                                <- MSI-X
  offset 0x30  ROM  = 0xfebc0000                                <- the VGA BIOS

  COMMON_CFG  bar=2 offset=0x1000 len=0x800     <- NOT offset 0, NOT length 0x1000
  ISR_CFG     bar=2 offset=0x1800 len=0x800
  DEVICE_CFG  bar=2 offset=0x2000 len=0x1000
  NOTIFY_CFG  bar=2 offset=0x3000 len=0x1000  notify_off_multiplier=4
```

**Three things to take from the two dumps side by side, because each is a bug someone would otherwise
write.**

* **The capability BAR differs between the two devices** — BAR4 on one, BAR2 on the other — and so do
  the offsets and the lengths. `virtio-vga`'s common config is at `+0x1000` and is `0x800` long, not
  at `+0` and `0x1000`, because the VGA compatibility registers occupy the front of that BAR.
  **Read `cap.bar`, `cap.offset` and `cap.length` out of every capability. Never hardcode them.**
* **The VirtIO structure BAR is a 64-BIT BAR** (`0xfe00000c`: bit 0 clear = memory, bits 2:1 = `10` =
  64-bit, bit 3 set = prefetchable). It occupies two configuration registers, and the existing
  `fbFindVgaBar` reads one 32-bit register and masks (`fb.dart:330`). That works today only because
  `virtio-vga`'s BAR0 happens to be a 32-bit BAR. A BAR-reading helper for VirtIO must read the pair.
* **There is an escape hatch worth knowing about even if it is not taken.** `VIRTIO_PCI_CAP_PCI_CFG`
  (`cfg_type = 5`, §4.1.4.9 — the capability at `0x84` in the dump above) is a window in *PCI
  configuration space* through which the driver can read and write any BAR region **without mapping the
  BAR at all**. It is the only capability a driver is permitted to write to. This kernel does not need
  it — its BARs are already identity-mapped (§3.4) — but it is the reason a VirtIO driver can be
  brought up on a kernel with no MMU at all, and it is worth a comment in the source so nobody
  rediscovers it.
* **The upper half is zero on this machine and does not have to be.** `core/boot/boot.S` maps
  `[3 GiB, 4 GiB)` and nothing above it. A BAR placed above 4 GiB is a page fault, silently, and there
  is no code anywhere in this kernel that would say so. QEMU's default allocator keeps a 16 KiB
  prefetchable BAR in the low hole, so this is a latent hazard rather than a present one — but it is
  the same class of hazard as GAP-0071 item 3, and a driver should *check* the upper dword and refuse
  rather than truncate.

### 3.2 PCI configuration-space WRITES — and the firmware does not do this for you

**This is the one requirement that is genuinely missing and genuinely mandatory.** A VirtIO device
reads its virtqueues out of guest RAM by bus-master DMA. Bus mastering is bit 2 of the PCI command
register at offset `0x04`. GAP-0067 item 2 records that this kernel cannot set it:

> **Configuration space is read-only.** No `port_outl` to `0xCFC` anywhere. That rules out, today:
> enabling memory or I/O decoding in the command register, setting the bus-master bit (needed by every
> DMA-capable device)... **On QEMU the firmware has already done all of this, which is precisely why it
> is easy to not notice that the kernel cannot.**

**The last sentence is false for this device, and I checked.** The command register on both VirtIO GPUs
reads `0x0103` after SeaBIOS has finished: I/O space enabled (bit 0), memory space enabled (bit 1),
SERR enabled (bit 8), and **bus master clear (bit 2 = 0)**. SeaBIOS sets the bus-master bit only for
devices it boots from. A VirtIO driver that skips this step gets a device that accepts every register
write, reports every status bit correctly, and then reads all-zeroes or nothing at all from the
descriptor table — the worst possible failure mode, because everything up to the first DMA looks
perfect.

**The good news is that the fix is three lines and needs nothing from DCDart.** `pciRead32` already
does `port_outl(CONFIG_ADDRESS, …)` — the doubleword write half is already there and already used
(`pci.dart:267`). `pciWrite32` is its twin:

```dart
@bare
void pciWrite32(u64 bus, u64 dev, u64 fn, u64 off, u64 value) {
  port_outl(u64(pciConfigAddress), pciAddr(bus, dev, fn, off));
  port_outl(u64(pciConfigData), value);
}
```

And at the current pin (`DCDART_PIN.txt` = `8713298`) it does not even need `portio.S`: DCDart
ADR-0045 added `Port.outl`/`Port.inl` natively, so this is expressible in the language. **GAP-0067
item 2 is one function away from being closed, and it needs to be closed before any DMA-capable device
in this kernel's future works.** It should be closed with an assertion — read the command register
back after writing it and refuse if bit 2 did not stick.

### 3.3 Virtqueues, and the surprise: `pmm.dart`'s one-frame limit is NOT a blocker

A **split virtqueue** is three separate arrays in guest RAM that the device reads by DMA:

| part | layout | align | bytes at size *N* | at *N* = 64 (measured) | at *N* = 256 (max useful) |
|---|---|---|---|---|---|
| **descriptor table** | *N* × 16 B: `le64 addr`, `le32 len`, `le16 flags`, `le16 next` | 16 | 16 *N* | **1024** | **4096** |
| **available ring** (driver → device) | `le16 flags`, `le16 idx`, `le16 ring[N]`, `le16 used_event` | 2 | 6 + 2 *N* | **134** | **518** |
| **used ring** (device → driver) | `le16 flags`, `le16 idx`, `{le32 id, le32 len} ring[N]`, `le16 avail_event` | 4 | 6 + 8 *N* | **518** | **2054** |

The alignment column is VIRTIO §2.7.1's normative requirement. **A 4 KiB frame satisfies all three trivially**,
so `allocFrame()`'s output is a legal base for any of them with nothing to check. Note that the
trailing `used_event`/`avail_event` words exist in the size formula **whether or not**
`VIRTIO_F_EVENT_IDX` (bit 29) is negotiated — the two bytes must be allocated regardless, and a driver
that declines the feature and sizes the arrays without them writes past the end.

`docs/known-gaps.md` GAP-0076 item 1 is the thing that looks fatal here:

> **It allocates ONE frame at a time, and there is no contiguous multi-frame request.** `allocFrame()`
> returns one 4 KiB frame. A DMA landing buffer, a larger-than-page structure and a 2 MiB huge page all
> need N *adjacent* frames... **the first thing that will [need it] is bus-master DMA.**

**It is not fatal, and the reason is a property of the VirtIO 1.0 transport rather than a workaround.**
VIRTIO §2.7 says each part *"is physically-contiguous in guest memory, and has different alignment
requirements"* — **per part, not across parts** — and the modern common-configuration structure has
**three separate 64-bit queue address registers**, `queue_desc` at `0x20`, `queue_driver` at `0x28`
and `queue_device` at `0x30`, one per part. In VirtIO 0.9.5 they were one contiguous block behind a
single `QUEUE_PFN` register; in 1.0 they are three, precisely so a guest without a contiguous
allocator can place them independently.

*(One wording trap, flagged so nobody is talked out of this by the spec itself: §4.1.5.1.3 step 4 says
"allocate and zero the queue memory, making sure the memory is physically contiguous." That sentence
describes the typical single-allocation driver. The normative requirement is the per-part one in
VIRTIO §2.7 and §2.7.1.)*

**QEMU's VirtIO-GPU declares a controlq of 64 and a cursorq of 16**, and §3.8 measures the 64. At size
64 the three arrays are 1024, 134 and 518 bytes; at the largest size worth using, 256, the biggest is
exactly 4096. **Every VirtIO-GPU virtqueue this kernel will ever need fits in three separate single
4 KiB frames from `allocFrame()`, and VirtIO-GPU uses two virtqueues, so the whole transport costs six
frames.** That is 24 KiB out of a 32,768-frame pool.

**The one place contiguity really is needed, and how the protocol already solves it.** A full-screen
scanout resource is 800 × 600 × 4 = 1,920,000 bytes = **469 frames**, and there is no way to allocate
469 adjacent frames with this allocator. `VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING` does not want them
adjacent: its 32-byte header (`ctrl_hdr`, `le32 resource_id`, `le32 nr_entries`) is followed by
`nr_entries` **`virtio_gpu_mem_entry`** records of 16 bytes each — `le64 addr`, `le32 length`,
`le32 padding` — which is a **scatter-gather list**. 469 non-adjacent 4 KiB frames is a legal,
ordinary backing store, one entry per frame.

The entry array itself is 469 × 16 = 7504 bytes, more than one frame, and that is solved by the same
mechanism one level down: a virtqueue request is a **chain** of descriptors linked by
`VIRTQ_DESC_F_NEXT` (flag `1`), each pointing at its own contiguous buffer. Two 4 KiB frames chained
carry the whole list. **The entries are request payload in the same chain as the header, not a
separate command** — that is the single most common way to get this wrong.

**One ordering rule that governs every command, and is easy to violate:** VIRTIO §2.7.4.2 requires **all
device-readable descriptors to precede all device-writable ones** in a chain. Every VirtIO-GPU request
is therefore exactly `[request bytes, F_NEXT]` → `[response buffer, F_WRITE]`, in that order, always.

**So the honest statement is: `pmm.dart` as it stands today can back a full-screen VirtIO-GPU scanout,
and GAP-0076 item 1 does not block this path.** It blocks other things and it should still be closed;
it is not the wall it looks like from here.

### 3.4 The identity map is the best news in this document

Every DMA address a VirtIO device is given is a **physical** address, and every driver on every real
OS has to translate between the virtual address it holds and the physical address it hands the device.
On this kernel that translation is the identity function: `core/boot/boot.S` identity-maps
`[0, 128 MiB)` with 2 MiB pages, `allocFrame()` returns a physical address below 128 MiB, and the
kernel dereferences it directly through `Pointer<T>.fromAddress`. **`va == pa` for every byte a
virtqueue will ever contain, and there is nothing to get wrong.**

The same is true at the other end: the capability BARs measured in §3.1 (`0xfe000000`, `0xfe800000`,
`0xfebd5000`) are all inside `[3 GiB, 4 GiB)`, which `boot.S`'s second page directory identity-maps in
full. **A VirtIO-GPU driver needs no new page-table work of any kind** — not for its rings, not for its
resources, and not for its registers. Compare that with what it takes to write the same driver on a
kernel with a higher-half map and a real IOMMU.

*(One caveat that is worth stating rather than discovering: this only holds while the whole VirtIO
working set stays under 128 MiB and the BARs stay under 4 GiB. Both are true here, neither is
guaranteed, and a driver should assert both.)*

### 3.5 Cacheability — GAP-0071 predicted this device by name

`core/boot/boot.S`'s PCI-hole directory maps all of `[3 GiB, 4 GiB)` **writable, cacheable, with no
MTRR or PAT setup**, and GAP-0071 item 1 says exactly what that means:

> **cacheable**, with no MTRR or PAT setup. For MMIO in general that is wrong — a device register read
> must not be served from a cache line — and for a *linear framebuffer* specifically it is benign and
> even desirable... **the moment it touches a real device register through a BAR rather than a
> framebuffer, this becomes a correctness problem rather than a performance note.**

**A VirtIO-GPU driver is that moment.** The common configuration structure, the ISR register and the
notify register are device registers reached through a BAR, and every one of them has read side
effects or requires ordering. Under QEMU/TCG nothing notices; under KVM the EPT memory type for an
MMIO slot forces uncacheable regardless of the guest PAT, so it very likely still works; on real
hardware with a real VirtIO device (they exist, in hardware NICs and in some SoCs) it is a real bug.

**The narrow fix**, when it is wanted: set PAT entry 1 to UC- or WC, and map the specific BAR pages
with PWT/PCD set rather than remapping the whole gigabyte. That is real page-table work at runtime and
it is a separate milestone from anything below. **The honest position for now is: build it, note it,
and do not claim the driver is hardware-correct.**

### 3.6 Interrupts, or the fact that you do not need one

The device signals completion two ways: legacy INTx (the measured device reports **pin A, routed to
IRQ 10 or IRQ 11 depending on which slot it lands in** — both boots in §3.1 saw one of the two) or
MSI-X (the measured device offers a 3-entry table). Both are out of reach today for the same reason:
`interrupts.dart:269` masks the slave PIC entirely and leaves only IRQ0 unmasked on the master, **IRQ
10 and IRQ 11 are both slave-PIC lines** and therefore need the IRQ2 cascade unmasked, and MSI-X needs
the capability walk of §3.1 plus a local APIC this kernel does not touch. Note also that the pin-to-IRQ
routing is a property of the slot and the chipset's PIRQ routing, not of the device — a driver that
wants INTx must read the interrupt line from configuration offset `0x3C`, not assume a number.

**None of that is on the critical path, because a virtqueue can be polled.** The used ring's `idx` is
a `le16` in guest RAM that the device increments; the driver compares it against its own last-seen
value. A first driver submits one command, spins on `used.idx`, and reads the response. That is
exactly what `ata.dart` already does with the ATA status register, for exactly the same reason, and it
is the same trade GAP-0074 recorded there.

The driver should still set `VIRTQ_AVAIL_F_NO_INTERRUPT` (bit 0 of `avail.flags`) so the device does
not raise a line nothing is listening to. It should **not** rely on that alone: the ISR status byte
(capability `cfg_type = 3`) is read-to-clear and de-asserts INT#x, so a driver that never reads it and
never masks the line would leave a level-triggered interrupt asserted forever the first time the
device did raise one. **An interrupt-driven VirtIO-GPU is a later milestone
and it shares its prerequisite — unmasking the slave PIC and the IRQ2 cascade — with `display-protocol.md`'s
D1 (the mouse, IRQ 12).** Whoever does D1 does most of the work for this.

### 3.7 What `@bare` DCDart makes awkward, and what it makes impossible

Nothing here is a blocker. All of it is a tax, and it is the same tax `fat.dart` and `file.dart` already
pay.

| what a VirtIO driver wants | what the language gives | cost |
|---|---|---|
| a `struct virtq_desc` written by field name | `@packed class … extends Struct` exists but **cannot appear in a signature** (DCDart GAP-0025) | hand-computed byte offsets and a `Pointer<u64>` per field, exactly as `fbState`/`fbSetState` and `pmmMeta` already do. This is the established idiom, not a new one |
| `switch (response_type)` | no `switch`, no `enum`, no function pointers (GAP-0023, GAP-0002) | an `if`-chain, and GAP-0088's warning that a dense one becomes a jump table in a section this repo does not control |
| `memcpy` into a resource's backing store | **every `Pointer<T>` access is volatile** (DCDart GAP-0034) | this is the real ceiling and §4 is where it bites. A byte-at-a-time copy that cannot be vectorised is what makes `fbFill` 480,000 stores |
| a compound guard `if (a && b)` | **no `&&`, no `\|\|`, no general `!`** (GAP-0023) | chains of single-test `if`s, as everywhere else |
| mutable driver state | **it has it now.** ADR-0021/DCDart ADR-0051 landed mutable statics at pin `8713298` | none. A VirtIO driver would be the first subsystem here that never had to negotiate for donated `.bss` |
| doubleword port I/O for config writes | **it has it now.** DCDart ADR-0045 | none |

**The one thing that is genuinely absent and genuinely wanted: a memory barrier.** The VirtIO
specification requires ordering between writing a descriptor and publishing its index in the available
ring, and between reading `used.idx` and reading the entry it points at. On x86-64 with ordinary
write-back memory the hardware's TSO model gives store-store and load-load ordering for free, so a
compiler barrier is what is actually needed — and DCDart's volatile-everything (GAP-0034), which is a
performance liability everywhere else, **is exactly a compiler barrier on every access**. The property
this driver needs is accidentally already true. It should be written down as a dependency rather than
relied on silently, because it stops being true the day DCDart gets non-volatile pointers.

### 3.8 Three measurements from the live device, one of which I got wrong first

All three came from a running `-device virtio-vga` read through the QEMU monitor. The third is an
error I made and then caught, and it matters more than the two that worked, because it invalidates an
obvious way to write the harness in §5.

**(1) The device says there is no 3D here, in two independent places.**

```
  device config @ BAR2+0x2000:  events_read=0  events_clear=0  num_scanouts=1  num_capsets=0
  common config @ BAR2+0x1000:  device_feature[0..31] = 0x30000002
```

`0x30000002` decodes as `VIRTIO_GPU_F_EDID` (bit 1) | `VIRTIO_F_RING_INDIRECT_DESC` (bit 28) |
`VIRTIO_F_RING_EVENT_IDX` (bit 29). **`VIRTIO_GPU_F_VIRGL` is bit 0 and it is clear**, and
`num_capsets` is **0** — there are no 3D capability sets to query. This QEMU (11.0.0, Homebrew) has no
`virtio-gpu-gl-pci` device at all and was built without virglrenderer. §2.2's "not reachable" is a
measurement on this machine, not only an argument.

**`num_scanouts = 1`** is worth having too: the specification allows up to 16 and QEMU's `max_outputs`
defaults to 1. Read it; do not index past it.

**(2) The control virtqueue size is 64.** `queue_size` at common-config offset `0x18`, with
`queue_select = 0`, reads `0x0040`. That makes the three arrays of §3.3 **1024, 134 and 518 bytes** —
all three fit in one 4 KiB frame with room over. They should still get three frames: `queue_size` is a
device property, the driver may lower it but must not assume it, and three frames cost nothing.

**(3) THE ERROR, AND THE HARNESS CONSEQUENCE.** My first reading of the common configuration had
`num_queues` (offset `0x12`) as **0** and `queue_msix_vector` (offset `0x1a`) as **0**, and I nearly
wrote that down as a fact about the device. Both are wrong, and re-reading them at 16-bit width in the
monitor produced the same wrong answers, which is what made it worth chasing.

**The monitor is the thing that is wrong, not the device.** `xp` reads a range through
`address_space_read`, which splits the range according to the target memory region's declared
`impl.max_access_size` — 4 for VirtIO's common-configuration region — and issues **4-byte accesses
regardless of the width typed at the monitor.** QEMU's `virtio_pci_common_read` then switches on the
*exact* offset. So a 4-byte access at `0x10` matches the `config_msix_vector` case and returns that
field zero-extended; offset `0x12` is **never dispatched at all** and reads back as the zero padding of
a neighbour's return value. The same happens at `0x1a` behind `queue_size` at `0x18`, and at `0x15`
(`config_generation`) behind `device_status` at `0x14`.

Everything at a 4-byte-aligned offset came back right — `device_feature` at `0x04`, `config_msix_vector`
at `0x10`, `queue_size` at `0x18` — and everything at offset `+2` inside a dword came back as zero.
That is a complete and consistent explanation, and it is why (1) and (2) above are trustworthy and my
`num_queues` reading was not.

**Two rules fall out, and the second is the one that would have cost a day.**

* **For the driver: §4.1.3.1 states the rule, and it is not the obvious one.** 8-bit fields are
  accessed with byte accesses, 16-bit fields with aligned 16-bit accesses, and **32-bit *and 64-bit*
  fields with aligned 32-BIT accesses.** A `le64` register such as `queue_desc` is written as two
  independent 32-bit halves, low first — §4.1.3.2 requires the device to allow exactly that — **not
  with one 64-bit store.** So the trap runs in both directions: a load too wide silently reads a
  neighbour's padding, and a 64-bit store to `queue_desc` is outside what the specification tells the
  device to accept. This kernel's `Pointer<u16>`/`Pointer<u32>` accesses are single, volatile and
  naturally sized, so obeying the rule costs nothing — it just has to be obeyed deliberately.
* **For the harness:** **`xp` is not a valid way to derive an expectation about a device register
  region.** `m5-pci` uses `xp` to read pixels back out of a linear framebuffer, and that is sound —
  a framebuffer BAR is RAM-like and every access width works. A VirtIO capability BAR is a dispatcher,
  and `xp` cannot address it faithfully. **Every criterion in §5 therefore derives its expectations from
  `info pci`, from the QEMU command line, and from the specification's constants — and never from an
  `xp` dump of a VirtIO BAR.** The `xp` dumps in §5 are all aimed at ordinary guest RAM (backing
  stores and rings), which is exactly where `xp` is trustworthy.

### 3.9 The scorecard

| requirement | status | size of the gap |
|---|---|---|
| find the device on PCI | **have it** — `pciScanBus` walks bus 0 and prints class/subclass; G0 additionally matches `1AF4:1050` | none, except that nothing is *retained* (GAP-0067 item 1) |
| walk the PCI capability list at `0x34` | **have it for this device** — `virtgpu.dart` / G0. `pci.dart` still does not | none for VirtIO-GPU. A general walker is still missing |
| read a 64-bit BAR | **have it for this device** — `virtgpuBarBase`. `fbFindVgaBar` still reads one dword | none for VirtIO-GPU |
| **write PCI configuration space (bus master)** | **have it** — `pciWrite32` in `pci.dart`; G1 sets bit 2 and reads it back (ADR-0065) | none for the write |
| **VirtIO `device_status` to `DRIVER_OK`** | **have it** — G2 (ADR-0067) writes the §3.1.1 sequence on COMMON_CFG and prints the offered features | none for the status walk |
| **one virtqueue + `GET_DISPLAY_INFO`** | **have it** — G3 (ADR-0074) enables queue 0, submits a 24-byte header, and prints scanout 0 | none for the first command. G4 still needs a resource |
| MMIO reads/writes to a BAR at the specification's declared field widths | **have it** — `Pointer<u16>`/`Pointer<u32>`, and the region is identity-mapped | none, but §3.8 rule (3) must be obeyed deliberately |
| physically-contiguous ≤4 KiB DMA memory, 16-byte aligned | **have it** — `allocFrame()` returns 4 KiB-aligned frames, which satisfies VIRTIO §2.7.1's 16/2/4-byte requirements trivially | none. §3.3 |
| physically-contiguous >4 KiB DMA memory | **missing** (GAP-0076 item 1) | **not needed.** §3.3 |
| virtual→physical translation | **have it, trivially** — identity map | none. §3.4 |
| zeroed DMA memory | **missing** — `allocFrame()` returns garbage (GAP-0076 item 5) | the driver must zero its own rings, as `boot.S` and `vmZeroFrame` already do |
| uncacheable MMIO mapping | **missing** (GAP-0071 item 1) | works under emulation; wrong on hardware. §3.5 |
| device interrupts | **missing** | **not needed** — poll. §3.6 |
| mutable driver state | **have it** (ADR-0021) | none |
| memory barriers | **have it accidentally** (volatile everything) | none today; a dependency to record |

---

## 4. What a GPU does to the display protocol

`display-protocol.md` §1.3 chose **server-side drawing verbs** — the Plan 9 `/dev/draw` model — and it
chose them for one arithmetic reason, stated there in three sentences:

> **`fileWriteMax` is 512 bytes. That is 128 pixels. One sixth of one scanline.** Sending pixels
> through this OS's transport is not slow — it is structurally impossible.

It then flagged its own ceiling honestly:

> **A GPU would change the calculus**, and this is the one place where the design has a ceiling.
> Verb-based protocols are what you want when the server draws in software; **a GPU wants buffers and
> command rings.** That is a bridge to cross when a GPU exists.

This section crosses that bridge on paper. **The short answer is that the verb protocol is not a dead
end — it is the layer that survives — and the reason is that the verb protocol and the GPU are on
opposite sides of the compositor, not the same side.**

### 4.1 The two boundaries, which the original framing collapses into one

There is not one interface between "a client" and "the screen". There are two, and only the first is
what `display-protocol.md` specifies:

```
   client  ──[ A: drawing verbs, 512-byte batches, syscall ]──▶  compositor  ──[ B: pixels ]──▶  display
```

* **Boundary A** is a **syscall**. It is bounded by `fileWriteMax = 512`, it crosses a privilege
  level, it must be validated byte by byte against a hostile client, and it happens thousands of
  times a second. **This is what makes pixels impossible and verbs necessary**, and none of that
  changes if a GPU appears — a GPU does not make a 512-byte syscall carry more than 512 bytes.
* **Boundary B** is **the compositor deciding how to make pixels exist**. Today that is `fbPutPixel`
  in a loop. With a GPU it is a command ring. **This boundary is not in the protocol at all** and never
  was: `display-protocol.md` §1.1 already says the client "does not get a buffer, it gets an image
  id", and `display-protocol.md` §5.1 already says window management is compositor policy.

**A GPU is a change to boundary B.** The verb protocol governs boundary A. That is why it survives.

### 4.2 What VirtIO-GPU actually replaces, concretely

Today, presenting one frame is (`display-protocol.md` §3.4):

```
   compositor's composed buffer (user pages)
        │  ONE syscall: present  — kernel copies, byte at a time, volatile
        ▼
   off-screen VRAM frame at 0xFD000000 + offset
        │  one 16-bit port write to 0x1CF (dispi Y_OFFSET)
        ▼
   scanout
```

With VirtIO-GPU 2D it becomes:

```
   compositor's composed buffer (user pages, allocFrame()-backed, ALREADY the resource's backing store)
        │  ONE syscall: present(x, y, w, h)
        ▼
   kernel writes TWO commands into the control virtqueue and rings the notify register:
        VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D  { rect, offset, resource_id }
        VIRTIO_GPU_CMD_RESOURCE_FLUSH       { rect, resource_id }
        ▼
   scanout
```

**Four things change, and the fourth is the whole prize.**

1. **The dispi port write disappears**, and so does everything built on it. Mode setting becomes
   `VIRTIO_GPU_CMD_SET_SCANOUT` against a resource; the mode list becomes
   `VIRTIO_GPU_CMD_GET_DISPLAY_INFO`, which *returns the host window's actual size* instead of the
   compiled-in 800×600 that GAP-0070 item 3 records as "fixed and unnegotiated". A resize on the host
   becomes a `VIRTIO_GPU_EVENT_DISPLAY` notification the kernel can act on. **The kernel stops guessing
   what mode the display is in and starts being told.**
2. **`vbeRegYOffset` page-flipping (§3.2 of `display-protocol.md`) is replaced by something better and
   simpler:** two resources, `SET_SCANOUT` alternating between them. No VRAM arithmetic, no
   "eight frames fit in 16 MiB", no Y-offset-in-lines convention.
3. **The kernel's copy into VRAM disappears.** That copy is the one `display-protocol.md` §3.4 calls
   "the price of not handing ring 3 the display" and sizes as byte-at-a-time in a kernel with no
   `memcpy`. With `RESOURCE_ATTACH_BACKING` the compositor's own pages **are** the resource's backing
   store — the device reads them by DMA. `TRANSFER_TO_HOST_2D` is a command, not a memcpy. **The
   single most expensive operation in the current design is deleted, not optimised.**
4. **Damage becomes free and exact.** `TRANSFER_TO_HOST_2D` and `RESOURCE_FLUSH` both take a rectangle.
   `display-protocol.md` §3.5 argues for a bounding-box union because an exact region needs a data
   structure `@bare` DCDart cannot express — that argument is unchanged, but the *payoff* changes: a
   16×16 damage rectangle costs a 16×16 transfer, in the device, rather than 1024 volatile stores in
   the kernel.

### 4.3 What would have to change in the protocol — and it is one thing

**The wire format does not change.** `present` already means "these pixels are now what I mean", and
`display-protocol.md` §6/D8 already makes the argument for why: *"It changes no byte of the wire
format... where the bytes were sitting beforehand is an implementation detail of both ends."*
A `'v'` (flush) verb becomes two virtqueue commands instead of a copy loop. A `'F'` (fill rect) verb
is still executed by the compositor in software, into its own buffer, exactly as before.

**One decision does have to be taken now, and it is the only actionable item in this section.**

> **Where the compositor's composed buffer lives must be a kernel-allocated, physically-known,
> page-aligned region — not `sbrk` memory — from the day it exists.**

`RESOURCE_ATTACH_BACKING` needs a list of *physical* addresses. `heap.dart`'s `sbrk` gives a process
virtual pages in the 2 MiB window at `0x10000000`, mapped by `vmProgMap(va, pa, …)` from `allocFrame()`
frames — so the physical addresses **do** exist and **are** known to the kernel, one page at a time,
through `vmProgLeaf(va)`. **That means the requirement is already satisfiable**, and the decision is
simply to say so out loud and to add the kernel-side function that walks a user range and emits its
physical frames, rather than to discover later that the compositor's frame buffer was allocated by
something that does not track them.

**If that one thing is true, nothing else about the protocol is a bet.** Everything else — verbs,
batching, server-side allocation, the 512-byte cap, the clone-file transport, events riding the reply
— is unaffected by whether a GPU exists.

### 4.4 Is the verb protocol a dead end? No, and here is the test I applied

The test is: **name a thing a GPU could do that a verb protocol structurally forbids.** There are
three, and all three are outside what oscortex is building.

| a GPU can do | does the verb protocol forbid it? |
|---|---|
| **client-side rendering into a client-owned buffer, then handing the buffer to the compositor** (what Wayland does, and what a GPU-accelerated toolkit wants) | **Yes, structurally** — the client never owns pixels. This is the real cost, and `display-protocol.md` §1.3 already accepted it |
| **client-side 3D** — a client issuing GL/Vulkan commands that reach the GPU | **Yes** — and this needs Mesa, which §1.6 and §2.2 say is not happening on any timescale |
| **hardware overlay planes / a hardware cursor** — the display engine compositing without touching the composed buffer | **No.** These are compositor-side. VirtIO-GPU's `cursorq` and `UPDATE_CURSOR`/`MOVE_CURSOR` are exactly a hardware cursor, and they are reachable *without* any protocol change: the compositor asks for a cursor, the kernel drives the cursor queue |

**So the honest summary is: the verb protocol forecloses GPU-accelerated *clients*, and does not
foreclose a GPU-accelerated *compositor*.** Given that GPU-accelerated clients require a Mesa port
that is not going to happen (§1), the protocol forecloses nothing that was available.

**The one thing I would not do:** try to make the verb protocol GPU-shaped in advance. Reserving four
handle words in the batch header (`display-protocol.md` §2.5) is the correct amount of hedging —
it costs sixteen bytes and it is the slot a buffer handle would go in if D8's zero-copy path is ever
built on top of a VirtIO resource. Anything more than that is designing for a client that cannot exist.

---

## 5. The milestone ladder — VirtIO-GPU only

**Only VirtIO-GPU gets a ladder, because it is the only path in this document with a credible route.**
Intel modesetting gets no milestones because §2.3's first one has no honest exit criterion; AMD and
NVIDIA get none because §2.4 is a refusal.

**Every criterion below is written to this repo's rules for a derived expectation**, restated here
because they are the reason the M7–M19 harnesses are worth anything:

* compute the expectation from a source the kernel does not control — here that is **QEMU's own
  monitor** (`info pci`, `xp` memory dumps, `info qtree`) and **the VIRTIO specification's constants**,
  transcribed into the harness and asserted against the kernel's source, never imported from it;
* **guard against a vacuous pass.** Every criterion below can be passed by a kernel that does nothing,
  unless a negative control is written, and each one names its own;
* structural checks (disassembly, symbol sizes, greps) before boot checks, because they are faster and
  do not need QEMU;
* `core/scripts/verify-freestanding.sh` on every object, as always.

**A ladder-wide setup fact.** Every milestone below runs against **`-device virtio-vga`**, not
`-device virtio-gpu-pci`, and §0.1 is why: `virtio-vga` is class `03/00`, so the existing framebuffer
console keeps working on the same device the VirtIO driver is being written against, and every
pre-existing golden stays meaningful. `virtio-gpu-pci` (class `03/80`) is the *end* of the ladder, at
G7, not the beginning.

---

### G0 — The device is found and its capabilities are read

**Status: implemented (ADR-0059).** `core/kernel/virtgpu.dart` walks vendor `0x1AF4` device
`0x1050`, prints each vendor capability, and resolves `BAR_base + offset`. It programs
nothing: `virtgpuInit` is a no-op, the command is hidden, an absent device prints
`VIRTIO NONE`. Verified by `tests/conformance/g0-virtgpu/run.sh`. G1–G7
landed on the same command. Leftover is two-resource `SET_SCANOUT`
(GAP-0070 item 6).

**Blocked on: nothing.** This is the whole of the §3.1 work and none of the §3.2 or §3.3 work.

Add `pciFindByClassAndVendor`-style discovery for vendor `0x1AF4`, follow the capability list from
configuration offset `0x34`, and for each vendor capability (`0x09`) print `cfg_type`, `bar`, `offset`
and `length`. Read the BAR the capabilities name, handling the 64-bit form.

*Binary:* the harness runs QEMU's monitor `info pci`, parses the BAR base addresses **out of QEMU's own
output**, and requires the kernel's printed capability table to name the same BAR index and to resolve
to a base address inside `[BAR_base, BAR_base + BAR_len)` for all five capabilities, with
`notify_off_multiplier` printed and equal to 4. The harness must additionally assert that all five
`cfg_type` values 1–5 appeared exactly once.
*Anti-vacuity:* the harness fails if fewer than five vendor capabilities were printed.
*Negative control:* the same boot with `-vga std` instead of `-device virtio-vga` must print
`VIRTIO NONE` and must not print a capability table.

---

### G1 — Bus mastering is on, and the kernel can prove it

**Status: implemented (ADR-0065).** `pciWrite32` lives in `core/kernel/pci.dart`.
`virtgpuEnableMaster` ORs bit 2 of the command register (status half zeroed),
prints `VIRTIO CMD BEFORE` / `VIRTIO CMD AFTER`, and prints `VIRTIO CMD STUCK`
if the bit did not stick. Called from the `virtgpu` command, not from
`virtgpuInit`. An absent device still prints `VIRTIO NONE` and writes nothing.
Verified by `tests/conformance/g1-virtgpu/run.sh`. Leftover is G4 (a pixel)
through G7; G2 (ADR-0067) writes `device_status` and G3 (ADR-0074) writes the
control queue. This rung does not issue a 2D command.

**Blocked on: G0.** This is GAP-0067 item 2, closed.

Add `pciWrite32` (§3.2). Set bit 2 of the command register, read it back, and refuse loudly if it did
not stick.

*Binary:* the kernel prints the command register **before and after**. The harness requires the before
value to have bit 2 **clear** and the after value to have it **set** — and it derives the "before"
expectation from QEMU rather than from the kernel, by dumping configuration offset `0x04` through the
q35 ECAM window with `xp/1xw` at `0xb0000000 + (dev << 15) + 4` before the kernel touches it.
*Anti-vacuity:* the harness fails if the two printed values are equal.
*Negative control:* a build with the write removed must fail the "after" assertion. A build that writes
to the wrong offset must fail the read-back refusal, which must print and must be visible on COM1.

---

### G2 — The device negotiates, and reaches `DRIVER_OK`

**Status: implemented (ADR-0067).** `virtgpuNegotiate` walks COMMON_CFG, writes
`device_status = 0` and polls, then `ACKNOWLEDGE` / `DRIVER`, reads both
feature words, accepts only `VIRTIO_F_VERSION_1`, writes `FEATURES_OK`,
re-reads, and writes `DRIVER_OK`. Prints `VIRTIO FEAT`, `VIRTIO QUEUES` and
`VIRTIO STATUS`. `FEATURES_OK` failing to stick prints `VIRTIO FEATOK CLEAR`
and skips `DRIVER_OK`. Called from the `virtgpu` command after G1, not from
`virtgpuInit`. An absent device still prints `VIRTIO NONE` and writes nothing.
Verified by `tests/conformance/g2-virtgpu/run.sh`. Leftover is G4 (a pixel)
through G7; G3 (ADR-0074) writes the control-queue enable field and issues
`GET_DISPLAY_INFO`. This rung does not.

**Blocked on: G1.**

The VirtIO initialization sequence of VIRTIO §3.1.1 against the common configuration structure: reset by
writing `device_status = 0` **and polling until a read returns 0** (§4.1.4.3.2 — the reset is not
instantaneous and this poll is a MUST), then `ACKNOWLEDGE (1)`, `DRIVER (2)`, read the device feature
bits through `device_feature_select`/`device_feature`, write back the accepted subset, `FEATURES_OK
(8)`, **re-read `device_status` and confirm `FEATURES_OK` is still set** (step 6, and the one everyone
skips), then `DRIVER_OK (4)`.

Note that the numeric order of the status bits is not the temporal order: `FEATURES_OK` is 8 and is
set **before** `DRIVER_OK`, which is 4. And VIRTIO §2.1.1 requires the driver never to *clear* a status
bit —
every write is a read-modify-write OR.

The driver must accept `VIRTIO_F_VERSION_1` (feature bit 32, so `device_feature_select = 1`) and
should accept **nothing else** at this milestone — declining bits 28 (`INDIRECT_DESC`), 29
(`EVENT_IDX`) and 34 (`RING_PACKED`) removes indirect descriptors, event suppression and packed rings
from the picture entirely, and the device must cope.

*Binary:* the kernel prints the offered feature bits (both 32-bit halves) and the final `device_status`.
The harness requires the final status to be exactly `0x0F` (`ACKNOWLEDGE|DRIVER|FEATURES_OK|DRIVER_OK`),
requires `FAILED (0x80)` and `DEVICE_NEEDS_RESET (0x40)` to be clear, and requires bit 32 of the
offered features to be **set** — a device that did not offer `VERSION_1` is not the device this driver
is for. It also requires `num_queues` read from the common configuration to be **≥ 2**.
*Anti-vacuity:* the harness fails if the printed offered-feature words are both zero (which is what an
undecoded BAR reads back as, and would otherwise look like a successful negotiation of nothing).
*Negative control:* a build that skips the `FEATURES_OK` read-back must still pass this — so the
control is a build that writes `DRIVER_OK` **before** `FEATURES_OK`, which the device must reject by
leaving `FEATURES_OK` clear, and the harness must see the refusal printed.

---

### G3 — A virtqueue exists and the device answers one command

**Status: implemented (ADR-0074).** `virtgpuOneCmd` selects queue 0, reads
`queue_size`, allocates three zeroed frames, writes the three queue
address registers as 32-bit halves (low first), enables the queue last,
submits a 24-byte `GET_DISPLAY_INFO` (`0x0100`), and polls `used.idx`.
Prints `QSIZE`, `NSCAN`, `USED`, `RESP` and scanout 0. A poll that never
moves prints `VIRTIO QTIMEOUT`. `virtgpun` is the same walk without the
notify store (QEMU/TCG still DMAs with BME clear; the doorbell is the
write that actually moves `used.idx`). Called from the `virtgpu`
command after G2, not from `virtgpuInit`. Verified by
`tests/conformance/g3-virtgpu/run.sh`.
G5 (ADR-0084) moved the console onto that backing, G6 (ADR-0086)
made damage a number and scrolled it, and G7 (ADR-0091) ran that
walk on `virtio-gpu-pci` with no VGA. Leftover is two-resource
`SET_SCANOUT` (GAP-0070 item 6).

**Blocked on: G2.** This is the milestone that proves DMA works, and it is the one that matters.

Per VIRTIO §4.1.5.1.3: write `queue_select = 0`; read `queue_size` (**0 means the queue does not exist** —
QEMU reports **64** for the controlq, measured in §3.8); allocate three frames with `allocFrame()` and
**zero them** (GAP-0076 item 5); write `queue_desc`, `queue_driver`, `queue_device` **as pairs of
32-bit halves, low first** (§3.8); then `queue_enable = 1`, which MUST be last (§4.1.4.3.2).

Then build a two-descriptor chain — a read-only descriptor holding a **24-byte** `virtio_gpu_ctrl_hdr`
(`le32 type`, `le32 flags`, `le64 fence_id`, `le32 ctx_id`, `u8 ring_idx`, `u8 padding[3]`) with
`type = VIRTIO_GPU_CMD_GET_DISPLAY_INFO` (`0x0100`), chained by `VIRTQ_DESC_F_NEXT` (`1`) to a
`VIRTQ_DESC_F_WRITE` (`2`) descriptor for the **408-byte** `virtio_gpu_resp_display_info` — publish the
head index in the available ring, bump `avail.idx`, compute the notify address as
`BAR[notify.bar] + notify.offset + queue_notify_off * notify_off_multiplier`, write the **16-bit queue
index** there, and **poll `used.idx`**.

**The header is 24 bytes, not 32**, and it is worth stating in the largest possible letters because
every command's payload offset derives from it: a 32-byte assumption corrupts every command sent and
produces `ERR_INVALID_PARAMETER` at best and silence at worst.

*Binary:* the kernel prints the response header's `type` and scanout 0's rectangle and `enabled` flag
from the returned `virtio_gpu_resp_display_info` (24-byte header followed by 16 × 24-byte
`virtio_gpu_display_one`, hence 408 bytes). The harness requires `type ==
VIRTIO_GPU_RESP_OK_DISPLAY_INFO` (`0x1101`), requires scanout 0's `enabled` to be non-zero, and
requires its width and height to equal the values QEMU was **launched with** — so the harness passes an
explicit `-device virtio-vga,xres=W,yres=H` with derived numbers that are neither QEMU's defaults
(1280×800) nor the kernel's compiled-in mode (800×600) nor the specification's fallback (1024×768), and
asserts the kernel reported exactly those. **No hardcoded constant anywhere in the stack can pass
that.** The kernel must also print `num_scanouts` from the device configuration and the harness must
require it to equal QEMU's `max_outputs`, defaulted to 1.
*Anti-vacuity:* the harness fails if the reported width or height is zero, and fails if `used.idx`
never advanced (the kernel must print it).
*Negative control (this is the important one):* **the same walk with the notify store omitted
must fail** — `used.idx` never advances, and the kernel must print a poll-timeout rather than
hanging. That is `virtgpun`. QEMU/TCG still performs virtqueue DMA with bus-master clear, so
omitting G1's write is not a usable control on this machine (G1 already proved the bit sticks
via the q35 ECAM window). The doorbell is the write that actually moves the used ring.

---

### G4 — A resource is created, backed, scanned out, and one pixel is provably on screen

**Status: implemented (ADR-0079).** `virtgpu <hex>` (after G3 on the same
command) creates resource 1 at the reported width×height, attaches a
scatter-gather of `allocFrame()` pages, `SET_SCANOUT`, writes the typed
colour into the first backing word, transfers a 1×1 rect, and flushes.
Each reply prints `VIRTIO PIX` so G3's `RESP` count stays one on the
bare command. `virtgpua` omits attach and requires an error PIX from
`SET_SCANOUT`. `virtgpuInit` stays a no-op. Verified by
`tests/conformance/g4-virtgpu/run.sh`. G5 (ADR-0084) moved the
console, G6 (ADR-0086) scrolled it, and G7 (ADR-0091) dropped VGA.
Leftover is two-resource `SET_SCANOUT` (GAP-0070 item 6).

**Blocked on: G3.** (closed.)

`RESOURCE_CREATE_2D` (`resource_id = 1` — guest-chosen and **non-zero**, since 0 is reserved;
`format = VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM = 2`, which is the `0x00RRGGBB` little-endian layout
`fb.dart:230` already uses; the reported width and height), `RESOURCE_ATTACH_BACKING` with a
scatter-gather list of `allocFrame()` frames covering `w*h*4` bytes (§3.3 — ~469 entries at 800×600,
and the entry array itself must be a **descriptor chain**), `SET_SCANOUT` binding resource 1 to
scanout 0 with `r = {0, 0, w, h}`, then fill the backing store with a known colour,
`TRANSFER_TO_HOST_2D` the whole rectangle with `offset = 0`, and `RESOURCE_FLUSH`.

**THE THING THAT WILL SURPRISE WHOEVER BUILDS THIS.** §5.7.7 (VGA Compatibility): on a VGA-compatible
device, **`SET_SCANOUT` is the command that leaves VGA compatibility mode**, and only a device reset
returns to it. So the moment G4 succeeds on `-device virtio-vga`, **the BAR0 linear framebuffer that
`fb.dart` has been drawing into stops being what the host displays.** The two paths are not
simultaneous; they are exclusive and the switch is explicit. That is fine — G5 is the milestone that
moves the console across — but a G4 that leaves the old console pointed at BAR0 will produce a screen
that stops updating with no error anywhere, and it must not be diagnosed as a driver bug.

**On fences.** `VIRTIO_GPU_FLAG_FENCE` (bit 0 of `hdr.flags`) makes the device respond only after the
command is actually processed. §5.7.6.5 permits the device to respond early otherwise. QEMU only
processes asynchronously in 3D mode, so a 2D driver can omit fences — **except** before pointing
`UPDATE_CURSOR` at a freshly filled cursor resource, where §5.7.6.6 makes them mandatory. Omit them
here; note the exception where the cursor lands.

*Binary:* every one of the five commands must return `VIRTIO_GPU_RESP_OK_NODATA` (`0x1100`) and the
kernel must print each response code. Then — and this is the unfakeable half, and it is exactly
`m5-pci`'s mechanism — the harness dumps the **guest backing store** with `xp/<n>xw {addr}` at the
first backing frame's address, which the kernel printed, and requires the derived colour. Screen
content is verified by the second half of the criterion: run the same boot a second time with a
**different** derived colour passed to the kernel through the shell command's argument, and require the
dump to change accordingly.
*Anti-vacuity:* the harness fails if the expected colour is the background colour, and fails if fewer
than the derived number of backing frames were printed.
*Negative control:* a build that omits `RESOURCE_ATTACH_BACKING` must produce
`VIRTIO_GPU_RESP_ERR_UNSPEC` or `ERR_INVALID_RESOURCE_ID` from `SET_SCANOUT`, printed, rather than
silently continuing. A build that omits `SET_SCANOUT` must have every command succeed and must still
fail a `GET_DISPLAY_INFO` re-read that requires scanout 0 to name resource 1.

**A note on the PNG.** `display-protocol.md` §6 is right and it applies here: *"The PNG is not
evidence."* Do not write a criterion that compares a screenshot. The `xp` read-back of the backing
store, plus the response codes, plus a second boot with a different derived colour, is the substitute.

---

### G5 — The framebuffer console runs on VirtIO instead of dispi

**Status: implemented (ADR-0084).** `virtgpuc` (after G3 on the same
command) creates resource 1, attaches a contiguous scatter-gather of
`allocFrame()` pages, `SET_SCANOUT`, points `fbStateBase` at the first
backing frame, and paints the existing banner. `fbDrawGlyph` is
unchanged; `fbPutc` calls `virtgpuCell`, which issues
`TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` for the damaged 8×16 cell when
the live base is ordinary RAM. `virtgpue` omits that flush. `virtgpuInit`
stays a no-op. Bare `virtgpu` / `virtgpu <hex>` stay the G3 / G4 walks.
`fb` still takes GOP then Bochs (ADR-0064). Verified by
`tests/conformance/g5-virtgpu/run.sh`. G6 (ADR-0086) closed damage /
scroll. G7 (ADR-0091) closed `virtio-gpu-pci` with no VGA. Leftover
is two-resource `SET_SCANOUT` (GAP-0070 item 6).

**Blocked on: G4.** (closed.) This is the milestone that makes the driver *load-bearing* rather than a demo.

`fbPutc`/`fbDrawGlyph` keep writing pixels into a linear buffer; what changes is that the buffer is the
VirtIO resource's backing store in ordinary RAM rather than the BAR, and that a `flush` step issues
`TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` for the damaged glyph cell. **`fb.dart`'s drawing code is
untouched; only `fbState(fbStateBase)` and a new flush call change.**

*Binary:* the M5 glyph read-back check runs **unchanged in form** — the harness reads the pixels of the
banner string back out of guest memory and compares against glyphs derived from `fbFont8x16` in the
built ELF — but at the backing-store address rather than at the BAR. Additionally, the kernel must print
a count of `RESOURCE_FLUSH` commands issued, and writing a 52-byte banner must produce the derived count
(one per glyph cell, or one per line, whichever the implementation chooses — the harness asserts the
number the design commits to, not a range).
*Anti-vacuity:* the harness fails if zero foreground pixels were expected, exactly as `check-font.py`
already does.
*Negative control:* a build with the flush removed must pass the pixel read-back (the backing store is
still correct) and must fail the flush-count assertion — which is what proves the count is measuring
the device round trip rather than the drawing.

---

### G6 — Damage is a number, and scrolling exists

**Status: implemented (ADR-0086).** `virtgpus` (after the G5 walk on the
same command) paints the banner a second time and calls `fbScroll`.
The guest copies `fbWidth × (fbHeight - glyphHeight)` pixels up a
glyph row, fills the last row, and issues `TRANSFER_TO_HOST_2D` +
`RESOURCE_FLUSH` of that rectangle. The leftover word is the last
rect's pixel count, printed as `VIRTIO DAMAGE`. One cell is 128;
a scroll is `800 × 584 = 467200` (`00072000`), not 480,000.
`virtgpux` is the same walk with every flush omitted. `fbScroll`
no-ops on a BAR / GOP aperture so the Bochs path still stops
(GAP-0070 item 1). `virtgpuInit` stays a no-op. Verified by
`tests/conformance/g6-virtgpu/run.sh`. G7 (ADR-0091) closed
`virtio-gpu-pci` with no VGA. Leftover is two-resource double
buffering (GAP-0070 item 6).

**Blocked on: G5.** (closed.) This closes **GAP-0070 item 1** on the
VirtIO console path. Item 6 (double buffering / two resources) is
not this slice.

Two resources, `SET_SCANOUT` alternating between them, would be real
double buffering with no VRAM arithmetic and no Y-offset convention
(§4.2 item 2). That is leftover after G7. What landed is the damage
number and a scroll that is a `TRANSFER_TO_HOST_2D` of the moved
region — the 1.9 MiB `memcpy` GAP-0070 item 1 says DCDart cannot do
is now a rectangle in a command, though the *guest-side* move of the
backing store is still a byte-at-a-time copy until DCDart has
`memcpy`, so what this actually buys is a smaller transfer, not a
free scroll.

*Binary:* the kernel prints pixels-transferred-per-flush, exactly as `fatMetaReads`/`fatMetaHits` made
caching a number at M14. Writing one character must produce the derived 8×16 = 128-pixel count, **not**
480,000. Scrolling by one line must produce the derived count for `fbWidth × (fbHeight - glyphHeight)`.
*Anti-vacuity:* the harness fails if the printed count is zero.
*Negative control:* a build that always transfers the full rectangle must produce the big number, so
the assertion is sensitive to damage tracking actually happening. `virtgpux` (paint + scroll, no
flush) must leave `FLUSH` and `DAMAGE` at 0.

---

### G7 — `virtio-gpu-pci` with no VGA compatibility at all

**Status: implemented (ADR-0091).** The G5 `virtgpuc` walk on
`-vga none -device virtio-gpu-pci` (class `03/80`). Discovery is
already vendor `0x1AF4` / device `0x1050` (G0); the mode still
comes from `GET_DISPLAY_INFO`. `fb` prints `FB NONE` (ADR-0064
`fbStrNoDev`) — this machine has no VGA-class BAR, so `FB NOVBE`
would be a lie. `virtgpuInit` stays a no-op. Verified by
`tests/conformance/g7-virtgpu/run.sh`. G8 (ADR-0093) closed
two-resource `SET_SCANOUT` (GAP-0070 item 6) on this path.

**Blocked on: G5.** (closed.) This is the milestone that proves the driver is a driver and not a decoration on
the dispi path.

`-device virtio-gpu-pci` is class `03/80`, has no linear framebuffer BAR, no dispi interface and no VGA
BIOS. `fbFindVgaBar` cannot find it (§0.1) and must not be asked to. The device discovery is
"vendor `0x1AF4`, VirtIO device ID `0x1050`", and the mode comes from `GET_DISPLAY_INFO` because
there is no other source for it.

*Binary:* the same G5 glyph read-back, on a boot whose QEMU machine has **no VGA-class device at all**
(`-vga none` suppresses the default stdvga; the harness asserts this by requiring QEMU's `info pci`
output to contain **zero** devices of class "VGA controller"). The kernel must additionally print
`FB NONE` if asked to run the old `fb` command, proving the dispi path is genuinely absent rather
than quietly substituting. `FB NOVBE` is the other existing spelling and means a VGA BAR answered
without dispi — not this machine.
*Anti-vacuity:* the harness fails if `info pci` shows any VGA-class device, and fails if `fb`
prints `FB BAR` or `FB NOVBE`.
*Negative control:* `-vga std` (no virtio-gpu) must print `VIRTIO NONE` and produce no pixels.
A discovery walk filtered to subclass `0x00` would also print `VIRTIO NONE` on this device.

---

### G8 — Two resources, and SET_SCANOUT flips between them

**Status: implemented (ADR-0093).** `virtgpuf` creates resource 1
and resource 2, attaches a contiguous backing run to each,
`SET_SCANOUT` of resource 1, paints the banner into resource 1,
paints the same banner into resource 2 at the next glyph row, then
`SET_SCANOUT` of resource 2. Prints `VIRTIO RES`, two `VIRTIO BACK`
addresses, `VIRTIO FRAMES`, `VIRTIO FLUSH`, and
`VIRTIO FLIP 00000001 00000002`. `virtgpuy` is the same walk
without the second `SET_SCANOUT`: both backings are painted and
the flip line is absent. `virtgpuInit` stays a no-op. G5–G7
commands are unchanged. Verified by
`tests/conformance/g8-virtgpu/run.sh`. Leftover on this path is
the cursor queue / interrupt-driven completion (not on the
ladder). Bochs still has no double buffering.

**Blocked on: G5.** (closed.) This closes **GAP-0070 item 6** on
the VirtIO console path. Item 6 on the Bochs BAR is unchanged:
glyphs still land in the scanned-out aperture, and this rung
does not scroll Bochs.

Two resources and an alternating `SET_SCANOUT` is the page-flip
`gpu.md` §4.2 item 2 named — no VRAM arithmetic, no Y-offset
convention. The second paint is at glyph row 1 so a guest memcpy
of resource 1 cannot satisfy the read-back.

*Binary:* the kernel prints two resource ids and two backing
bases. After two paints the scanout target must change
(`VIRTIO FLIP 00000001 00000002`). The harness dumps the
newly scanned-out resource at the second paint's row and
requires the banner derived from `fbFont8x16` in the built ELF
(m5 form, not a PNG).
*Anti-vacuity:* the harness fails if the two BACK addresses are
equal, if FLIP names the same id twice, or if the dump is of
row 0 of resource 2 (the memcpy of resource 1).
*Negative control:* `virtgpuy` paints both resources and must
not print the flip line. Pixel read-back of resource 2 still
passes — the line measures the second `SET_SCANOUT`, not the blit.

---

### G9 — GET_CAPSET_INFO, the first 3D-path command

**Status: implemented (ADR-0097).** `virtgpui` reuses the G3
control queue, reads `num_capsets` from DEVICE_CFG +12, and
submits `GET_CAPSET_INFO` (type `0x0108`) for capset index 0.
Prints `VIRTIO CAPSETS` and `VIRTIO CAPINFO`. `virtgpuj` prints
the config word and omits the submit: `CAPINFO` must not print.
Feature negotiation stays `VIRTIO_F_VERSION_1` only (G2).
`virtgpuInit` stays a no-op. G0–G8 commands are unchanged.
Verified by `tests/conformance/g9-virtgpu/run.sh`.

This Homebrew QEMU offers `num_capsets=0` and has no
`virtio-gpu-gl-pci`. The device answers with an error type
(`0x12xx`). That is the honest result: the OS sent a 3D-path
command through the GPU virtqueue. It is not Skia, not Graphite,
not Vulkan, not a shader, and not sit-in chrome.

**Blocked on: G3.** (closed.) Leftover is virgl / Venus / a
Graphite Vulkan backend that paints session chrome onto the
same scanout. That needs a QEMU built against virglrenderer
(or Venus) and is not this machine.

*Binary:* after `GET_DISPLAY_INFO`, the kernel prints
`VIRTIO CAPSETS` from the MMIO word and `VIRTIO CAPINFO` from
the virtqueue reply. The reply type is neither 0 nor
`GET_DISPLAY_INFO`.
*Anti-vacuity:* `virtgpuj` still prints `CAPSETS` and must not
print `CAPINFO`. A hardcoded `num_capsets = 0` without the
DEVICE_CFG load fails the structural check.
*Negative control:* `-vga std` prints `VIRTIO NONE` and no
capset lines.

---

### Two uses. Do not mix them.

**Owner, 2026-08-30.** The GPU is used two ways.

1. **Implicit** — UI / osgfx / wm decide GPU vs CPU Skia. Apps do
   not pick. That is the compositor path (G10–G11 paint fallback).
   A FRAME client never calls `osgpu.h`.
2. **Explicit** — `osgpu.h` (`osgpu_create` / `osgpu_submit` /
   `osgpu_readback`) is a C header, like osframe, for apps that
   need a GPU (games). Hidden `osgpug` hits G10 virgl today. A
   later syscall may wrap the C stub; 11 stays `fdwait`. DCDart
   does not become C++. C++ only behind the fence if the impl is
   Vulkan/virgl. UI never requires the app to call osgpu. Games call osgpu.

Leftover: swapchain, shaders.

### Paint fallback — 3D GPU → CPU raster → 2D mailbox

**Owner, 2026-08-30.** Same idea as GOP → Bochs → NONE
(ADR-0064). One probe, never a blank desktop because there
is no GPU.

| order | probe | winner line | what it is |
|---|---|---|---|
| 1 | VirtIO-GPU 3D: `VIRTIO_GPU_F_VIRGL` (or later Venus) offered, context created, the device executes a command stream | `VIRTIO PAINT 3D` / `VIRTIO 3D OK` | transparency, opacity, animation. G10 |
| 2 | else a CPU raster of the **same** osgfx/Skia scene | (sibling; not this slice — do not print `PAINT CPU` until that raster is real) | same chrome, worse cost. Not per-pixel `fbPutPixel` |
| 3 | else the existing G4–G8 2D mailbox | `VIRTIO PAINT 2D` | CPU writes backing, `TRANSFER_TO_HOST_2D` + flush |
| none | no VirtIO GPU at all | `VIRTIO PAINT NONE` | Bochs / GOP / `FB NONE` already exist |

Homebrew QEMU 11.0.0 on this Mac has no `virtio-gpu-gl-pci`.
G10's positive boot uses a QEMU built against virglrenderer
(`virtio-gpu-gl-pci` + Xvfb `-display gtk,gl=on`). The 2D
machines and G0–G9 contracts are unchanged.

---

### G10 — The device executes GPU work, including alpha

**Status: implemented (ADR-0098).** New file
`core/kernel/virtgpu3d.dart`. Hidden `virtgpug` negotiates
`VIRTIO_GPU_F_VIRGL` (G2 still accepts `VERSION_1` only),
`CTX_CREATE`, two `RESOURCE_CREATE_3D`, `SUBMIT_3D` (virgl
`CLEAR` navy, `CLEAR` 50% red, `BLIT` with `alpha_blend`),
`TRANSFER_FROM_HOST_3D` of one pixel inside the blit, then
`SET_SCANOUT`. Prints `VIRTIO 3D OK`, `VIRTIO PAINT 3D`, and
`VIRTIO 3D PIX` from the backing the **device** wrote.
`virtgpuz` stops after the probe: no submit, no `3D OK`.
`virtgpuInit` / `virtgpu3dInit` stay no-ops. G0–G9 commands
are unchanged. Verified by `tests/conformance/g10-virgl/run.sh`
(`virgl0/run.sh` is a pointer).

This is not Mesa. It is a hand-built virgl stream: one
navy clear, one translucent (50% red) clear, one blit.
Host `glBlitFramebuffer` often copies, so the transferred
pixel may be the GPU clear `A=0x80` rather than src-over.
Either dword is device-written alpha, not a CPU store into
BACK + flush labelled 3D.

**Blocked on: G9.** (closed as the capset probe.) Leftover
was session chrome on this scanout — that is G11 (upload
of the osgfx compose buffer). Graphite / Vulkan **paint**
of that same chrome is still the leftover.

*3D QEMU on this arm64 Mac:* Homebrew 11.0.0 has no
`virtio-gpu-gl-pci` (cocoa bottle, no virglrenderer).
`scripts/build-qemu-gl.sh` builds `oscortex-qemu-gl:local`
from `debian:sid-slim` + `qemu-system-modules-opengl` +
`libvirglrenderer1` + Xvfb. Proven: QEMU 11.1.0
(Debian `1:11.1.0+ds-2`), `LIBGL_ALWAYS_SOFTWARE=1`,
`GALLIUM_DRIVER=llvmpipe`, `-display gtk,gl=on`.

*Binary:* on that `virtio-gpu-gl-pci`, `virtgpug` prints
`VIRTIO 3D OK`. The printed BACK dword is a GPU-written
translucent: 50% red `A=0x80`, or src-over of that red
over navy `0x184060` if the host blends — not navy, not
full opaque red, not the G5 desktop constant `0x00101018`.
*Anti-vacuity:* `virtgpuc` (G5 2D flush) must not print
`VIRTIO 3D OK`. `virtgpuz` on the same 3D device must not
print it either. Those result dwords must not appear as a
CPU store in `virtgpu3d.dart`.
*Negative control:* `-vga std` and Homebrew
`virtio-gpu-pci` (no VIRGL bit) print `VIRTIO 3D NONE`
and no `3D OK`.

---

### G11 — osgfx session chrome reaches VIRGL scanout

**Status: implemented (ADR-0107).** Hidden `virtgpuk` appends
to `virtgpu3d.dart`. After `wm gfx` has painted rounded
chrome into the compose buffer, it negotiates VIRGL,
`RESOURCE_CREATE_3D` of the GET_DISPLAY_INFO rectangle,
`TRANSFER_TO_HOST_3D` of that buffer, `TRANSFER_FROM_HOST_3D`
of the AABB corner and title interior, then `SET_SCANOUT`.
Prints `VIRTIO 3D OK`, `VIRTIO PAINT 3D`, `VIRTIO OSGFX 3D`.
G10 `virtgpug` / `virtgpuz` / CLEAR stay. `virtgpu3dInit`
stays a no-op. Verified by `tests/conformance/g11-osgfx-gl/run.sh`.

This is not Graphite and not a Mac `libskia.a`. The paint
is Skia CPU raster (ADR-0110). The GPU path is upload +
bind. Homebrew QEMU still has no `virtio-gpu-gl-pci`; the
positive boot is the same Docker image as G10.

*Binary:* on `virtio-gpu-gl-pci`, `virtgpuk` establishes the
3D scanout, `wm gfx` plus two session windows paint, then
`virtgpuk` again prints `VIRTIO OSGFX 3D`.
AABB (window-0 origin) is desktop `0x184060`; title interior
is title. Those dwords are `TRANSFER_FROM_HOST_3D` after a
zero of the sample slot.
*Anti-vacuity:* `virtgpuc` (G5) must not print `OSGFX 3D`.
*Negative control:* `-vga std` and Homebrew `virtio-gpu-pci`
print `VIRTIO 3D NONE` and no `3D OK`. `wm gfx` on Bochs
still prints `WM GFX ON`.

**Blocked on: G10.** (closed.) Leftover is Graphite / Vulkan
paint behind `osgfx.h` onto this same scanout.

---

### G12 — Explicit app GPU (`osgpu.h`)

**Status: implemented (ADR-0114).** `core/user/gpu/osgpu.h` is
the games ABI: `osgpu_create`, `osgpu_submit` (CLEAR or
triangle), `osgpu_readback`. Hidden `osgpug` calls the existing
G10 virgl walk (`virtgpu3dGoApp`) and prints `OSGPU OK` /
`OSGPU PIX` (device alpha, not a CPU blit constant) or
`OSGPU NONE`. The C stub returns `OSGPU_NONE` until a later
syscall wraps it. No number is taken. 11 stays `fdwait`.
Verified by `tests/conformance/gpu-app0/run.sh`.

UI / osgfx / wm do not include this header. `wm gfx` on a
machine with no 3D device still prints `WM GFX ON`.

*Binary:* on `virtio-gpu-gl-pci`, `osgpug` prints `OSGPU OK`
and `OSGPU PIX` whose dword is the G10 GPU clear (A=0x80) or
src-over — not navy, not the G5 desktop constant.
*Negative:* `-vga std` and `virtio-gpu-pci` print `OSGPU NONE`
and no `OSGPU OK`. `wm gfx` still works.
*Anti-vacuity:* `virtgpuc` (G5) must not print `OSGPU OK`.
wm / osgfx_sw / osxui never `#include "osgpu.h"`.

Leftover: swapchain, shaders. Not a Mesa port.

---

### Not on the ladder, and why

| | why it has no milestone |
|---|---|
| **interrupt-driven completion** | §3.6 — polling is correct here, and the prerequisite (slave PIC + IRQ2 cascade) is shared with `display-protocol.md`'s D1. Sequence it after D1, not here |
| **MSI-X** | needs the local APIC, which this kernel does not touch at all |
| **`VIRTIO_GPU_F_EDID`** | a nicety. `GET_DISPLAY_INFO` already gives the mode |
| **`VIRTIO_GPU_F_RESOURCE_BLOB`** | the zero-copy path (host-mappable resources). It is the natural successor to `display-protocol.md`'s D8 and it should be built there, on a working D4, not here |
| **the cursor queue** | needs a mouse first — `display-protocol.md` D1. It is then genuinely small: two commands (`UPDATE_CURSOR` `0x0300`, `MOVE_CURSOR` `0x0301`) on virtqueue 1, which QEMU sizes at 16. Two constraints to carry forward: the cursor resource **must be exactly 64×64**, and the transfer that fills it **must be fenced** (§5.7.6.6) |
| **Mesa / vendor GPU** | §1, §2.2. G10 is a hand-built virgl CLEAR+BLIT, not a Mesa port and not amdgpu |
| **virtio-mmio transport** | `-device virtio-gpu-device` needs a `virtio-mmio-bus`, which the x86 `pc`/`q35` machines do not instantiate. It is an ARM `virt` convenience and does not apply here |

---

## 6. What I did not decide, and would rather be told

**Q1 — Is "GPU support across the major GPUs" retired as a goal, or restated?**
This document argues it cannot be met and should not be attempted. The useful restatement I would
propose is: **"the display stack must not assume a dumb framebuffer"** — which VirtIO-GPU satisfies,
which is achievable, and which is what the goal was probably reaching for. If the goal is genuinely
"this OS runs on my laptop's Intel iGPU", the honest answer is in §2.3 and it is a multi-year project
with a low probability of ever lighting a pixel.

**Q2 — Is `virtio-vga` accepted as the reference display device for the project?**
The payoff is that the existing console keeps working on the device the future driver targets (§0.1),
with no kernel change at all. **The cost is not free and I checked rather than assumed.**
`m5-pci/run.sh:988` greps the literal string `^FB BAR FD000000 MODE 0320x0258x20 OK$`, and line 999
asserts QEMU's `info pci` puts BAR0 at `0xfd000000`. Under `-device virtio-vga` the BAR moves — it was
`0xfe000000` in every boot in §0.1 — so **both assertions move, and so does the `--addr-from-serial`
capture and the `info pci` device-for-device comparison, because the device list changes.** That is
real work in an existing harness. **I would still take it, and I would take it before G0 rather than
after, so those assertions move once instead of twice.**

**Q3 — Should G1 (`pciWrite32`, bus master) be its own milestone independent of graphics?**
It closes GAP-0067 item 2, it is five lines, and **every future DMA device needs it** — a virtio-net,
a virtio-blk, an AHCI driver, a bus-mastering IDE driver. It is on the graphics ladder here only
because graphics is what surfaced it. If someone is doing device work for another reason, they should
take it.

**Q4 — Does the compositor's composed buffer become kernel-allocated now?**
§4.3 is the one decision in this document that has to be taken before `display-protocol.md`'s D4 is
built rather than after. The requirement is weak (the physical frames behind a `sbrk` range are already
known to `vmProgLeaf`) and the cost of getting it wrong is a rewrite of the present path.

**Q5 — Is the ceiling acceptable?** With VirtIO-GPU 2D and nothing else, this OS gets: a display whose
mode it is told rather than guesses, double buffering, a hardware cursor, damage-proportional
presentation, and no software 3D of any kind, ever. **No OpenGL, no Vulkan, no shaders, no video
decode, no compute.** That is the whole envelope and it does not grow. If that is not acceptable the
answer is not a different GPU plan, it is a different project.

---

## 7. Notes for the coordinator to fold in elsewhere

G0 folded the GAP-0067 item 2 correction, the item 3/4 narrowing, and the GAP-0070 item 2
`virtio-vga` line into `known-gaps.md`. `ROADMAP.md` was not touched. The remaining entries:

**A correction to an existing gap, which I verified rather than inferred.** GAP-0067 item 2 says of
configuration-space writes: *"On QEMU the firmware has already done all of this, which is precisely why
it is easy to not notice that the kernel cannot."* **That is false for VirtIO devices.** SeaBIOS leaves
the bus-master bit clear on both `virtio-vga` and `virtio-gpu-pci` — measured `cmd=0x0103`, bit 2 clear,
§3.2. The gap entry should say that the firmware enables memory and I/O decoding and **does not** enable
bus mastering except on devices it boots from, because the current wording would let someone conclude
that a DMA driver needs no config writes on QEMU, and it does.

**A gap that does not exist yet and should.** *The 3–4 GiB identity map is cacheable, and the first
device-register BAR this kernel touches makes that a correctness problem rather than a performance
note.* GAP-0071 item 1 already predicts this in as many words; what is missing is that nothing records
which future subsystem trips it. §3.5. It is a *hardware* correctness problem only — under TCG and
almost certainly under KVM it is invisible — so it should be filed as "known-wrong, invisible here",
not as a blocker.

**A gap that should be narrowed rather than closed.** GAP-0076 item 1 (no contiguous multi-frame
allocation) names bus-master DMA as "the first thing that will need it". §3.3 shows that VirtIO
specifically does **not** need it — three separate queue address registers and a scatter-gather backing
list are exactly the design that removes the requirement. The entry is still correct about AHCI, about
a PRDT, and about huge pages; it should stop naming DMA in general as the trigger, because the next
person to read it will believe VirtIO is blocked and it is not.

**Two facts about the framebuffer that GAP-0070 should gain.** Item 2 says the dispi interface "is
implemented by QEMU's std VGA, by Bochs, and by very little else". **`virtio-vga` implements it too**,
and that is worth a line, because it is the reason the migration in §0.1 is free. Item 3 says the mode
is "fixed and unnegotiated"; `VIRTIO_GPU_CMD_GET_DISPLAY_INFO` is the negotiation, and it exists on the
device already present in the harness the moment `-vga std` becomes `-device virtio-vga`.

**A `display-protocol.md` cross-reference.** §1.3 of that document flags "a GPU would change the
calculus" as its one open ceiling. §4 here is the answer and the answer is "no, it does not" — the verb
protocol survives, with **one** prerequisite (§4.3). That should be reflected back into
`display-protocol.md` §1.3 so the ceiling stops reading as unresolved.

**A shared prerequisite worth sequencing deliberately.** An interrupt-driven VirtIO-GPU and
`display-protocol.md`'s D1 (the mouse) need the same thing: **the slave PIC unmasked and the IRQ2
cascade enabled**, which has been `0xFF` at every point in this kernel's life. Whoever does D1 does
90% of the work for VirtIO interrupts. Neither is on anyone's critical path, and they should not be
costed twice.

**A tooling note.** `-device virtio-vga` takes `xres=` and `yres=` properties (defaults **1280×800**,
not 800×600), which is what makes G3's exit criterion derivable rather than hardcoded: launch with a
non-default geometry and require the kernel to report exactly it. No harness change is needed for this
beyond the device argument.
