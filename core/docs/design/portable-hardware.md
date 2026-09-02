# Portable hardware — what "run like Linux/Windows" actually means here

**Status: DESIGN. PORT1 and PORT2 are implemented under QEMU+OVMF (ADR-0060
probe, ADR-0061 map+paint, `tests/conformance/p2-gop/run.sh`). The scanout
fallback chain is ADR-0064 (`fb` tries GOP, then Bochs, then `FB NONE`;
`tests/conformance/p3-fallback/run.sh`). PORT4 is a Limine hybrid ISO under
QEMU SeaBIOS (`tests/conformance/p4-bios/run.sh`, ADR-0072) — not metal.
Metal is not.** This file answers the owner
ask *"we need to run like Linux/Windows across hardware, all GPUs, all CPUs, all arches."* It
cites the corpus. It does not write kernel code. When a piece is built it gets its own numbered
ADR; this document is the thing those ADRs will point back at.

**It cites rather than re-derives.** Real GPUs, signed firmware, and VirtIO-GPU as the only
reachable GPU are `gpu.md`'s (G0 landed as ADR-0059). The missing bootloader is GAP-0001's.
The current scanout is `fb.dart` / ADR-0009 / GAP-0070 — Bochs VBE. The compositor owns that
framebuffer (ADR-0050). aarch64 is A1 virt proof of life (`arm64-port.md`, ADR-0057). The NIC
is an e1000 under QEMU (`net-e1000.md`, `net-stack.md`). USB HID on metal is
`peripherals.md`'s. **No GPU, Wi-Fi, NVMe, or Apple-silicon driver is claimed.**

**Provenance of the product ask.** The owner wants the machine to sit on ordinary laptops —
Ryzen, a random Windows box — and to look like Linux/Windows in the breadth of hardware it
covers. That is the intent. The rest of this document is what of that intent is true of this
tree, what the portable *strategy* is, and what is fantasy dressed as motivation.

---

### The eight things this document lands on, for a reader in a hurry

1. **Linux/Windows do not "target all GPUs" in one weekend.** They ship thousands of drivers
   plus vendor firmware. We will not write i915, amdgpu or nouveau. That is not a motivation
   problem (`gpu.md` §1).
2. **What those OSes use *before* the vendor GPU driver is the trick we can use: UEFI GOP /
   efifb.** Firmware already programmed a linear framebuffer. Early Linux is a CPU blit into
   that. That is how a Ryzen laptop shows pixels without `amdgpu`. `gpu.md` §2.1 already named
   this as the real-metal pixel path; `fb.dart`'s header and GAP-0054 / GAP-0070 already say
   this kernel cannot take it because it is a Multiboot1 image.
3. **"Drop in kexts" is not a plan.** Loading Linux `.ko` files or macOS kexts into an
   `@bare` DCDart kernel is a different ABI, a different runtime, and usually GPL/blob legal
   land. Hackintosh folklore (OpenCore + macOS kexts on a Windows laptop) is not a porting
   strategy. Rejected.
4. **Three scanout backends, one compositor, one probe order.** Bochs VBE (exists). VirtIO-GPU 2D (G0 probe
   done, G1–G7 done). **UEFI GOP handoff** — the bare-metal pixel path. `fb` tries GOP (tag + map),
   then Bochs, then prints `FB NONE` and leaves VGA text + COM1. Vendor 3D/compute is
   out of scope forever unless Mesa+firmware becomes a separate project (`gpu.md` §1.6, §2.2).
5. **x86_64 UEFI is the laptop target.** aarch64 virt is A1 only. Apple Silicon is a third
   machine. "All arches" is three ladders, not one binary.
6. **What actually blocks sitting at a laptop**, in order: a bootloader (GAP-0001), GOP FB,
   USB HID, then storage, then net. PS/2 and e1000 and ATA PIO are QEMU-shaped.
7. **Ladder prefix `PORT`** — not A, G, or N. First rungs PORT1–PORT3 below. A build that
   only works on UEFI and breaks the Multiboot goldens is a fail.
8. **This is DESIGN.** Not an ADR.

---

## 0. What is true of this machine today

Every row is already written down somewhere else. This section is the inventory, not a new
measurement.

| fact | value | citation |
|---|---|---|
| boot path | Three loaders, one `kernel.elf`: QEMU `-kernel` (every golden); OVMF+Limine (`p2-gop`, ADR-0060); **SeaBIOS+Limine hybrid ISO** (`p4-bios`, ADR-0072). BIOS MBR / UEFI on real hardware is unbuilt | GAP-0001; ADR-0001; ADR-0060; ADR-0072 |
| container | QEMU's Multiboot loader rejects a 64-bit ELF; the kernel is `elf32-i386` with 64-bit `.text` | ADR-0001 |
| proof of life | COM1, 16550, serial goldens. VGA text is a development path, not a portable one | ADR-0001; `OSCORTEX_SPEC.md` §3; GAP-0054 |
| scanout | `fb.dart` walks PCI class `03/00`, reads BAR0, programs **800×600×32 through Bochs VBE** at `0x1CE`/`0x1CF`, CPU-blits 8×16 glyphs | `fb.dart` header; ADR-0009; GAP-0070 |
| where that works | QEMU std VGA, Bochs, and `virtio-vga` (dispi compatibility). **"and by very little else"** | GAP-0070 item 2; `gpu.md` §0.1 |
| compositor | in the kernel (`wm.dart`); owns the framebuffer; presentation is already a kernel operation because ring 3 cannot `out` | ADR-0050 |
| real GPUs | **NO.** amdgpu is **288×** this kernel; i915+xe 25×; nouveau 11×. Signed firmware you cannot produce. Mesa is the larger half and this OS cannot host it | `gpu.md` §1 |
| reachable GPU | VirtIO-GPU 2D only. **G0–G7 landed** (device recognised through `virtio-gpu-pci` with no VGA, ADR-0091). It **does not run on a laptop** | `gpu.md` §2.1; ADR-0059; ADR-0091 |
| GOP | a UEFI machine hands the loader a linear RGB framebuffer (addr, width, height, pitch, bpp). Asking a GOP-configured adapter for Bochs VBE gets **`FB NOVBE`** | `fb.dart` header; GAP-0054; GAP-0070 item 2; ADR-0009 §2 |
| keyboard | i8042 PS/2. **Assumed to exist.** On UEFI with no legacy emulation there may be no 8042; the real path is USB HID | GAP-0055 item 5; `keyboard.dart` |
| USB on the default QEMU machine | **none.** `-M pc` / `-M q35` expose no class `0x0C03`. xHCI is "the only option on a physical board" and is ranked **No — not for years** for the QEMU product | `peripherals.md` §0, §0.1, rank 6 |
| storage | ATA PIO on the PIIX3 IDE that every disk harness already attaches. **AHCI probe landed** (A0, ADR-0069: class `01/06/01`, BAR5, CAP). **NVM0+NVM1 landed** (class 01/08/02, BAR0, CAP/VS, ADR-0071/0074). Neither reads a sector | `storage.md`; ADR-0071; ADR-0074; ADR-0069 |
| NIC | Intel 82540EM (`8086:100E`) under QEMU. N0 (MAC) landed. Option ROM DHCP is a vacuity trap (`romfile=`). **Not a laptop NIC** | `net-e1000.md`; ADR-0058 |
| aarch64 | **A1 only**: `OSCORTEX A64 OK\n` + PSCI `SYSTEM_OFF` on `-M virt`. A2–A9 unstarted. **No UEFI, no real hardware** | `arm64-port.md`; ADR-0057 |
| Apple silicon | named as a **different port** from `-M virt` — different UART, different interrupt controller, **no device tree** | `arm64-port.md` "What this document does not cover" |

**The one-sentence version of today:** this kernel is a Multiboot1 `elf32-i386` image that
QEMU loads with `-kernel`, that OVMF+Limine loads without `-kernel` (PORT1/2), and that
SeaBIOS+Limine loads from the same hybrid ISO (PORT4, QEMU only), paints by programming
Bochs VBE or taking a GOP tag, types on an 8042, reads ATA PIO, and (if asked) names an
e1000 and a VirtIO-GPU. None of those four devices is what a Ryzen laptop presents.

---

## 1. "All GPUs" is not a motivation problem

`gpu.md` §1 is the argument. Restated here only so the owner ask and the refusal sit in the
same file.

A modern GPU driver is four subsystems that happen to ship together: a memory manager for the
GPU's own MMU, a command-submission engine, a display-engine / modesetting half, and **Mesa
in userspace**, where the shader compiler lives. Measured against this kernel's 22,088 lines
(`gpu.md` §1.5):

| | lines | vs. this kernel |
|---|---:|---:|
| nouveau | 232,946 | **11×** |
| i915 + xe | 560,555 | **25×** |
| amdgpu, as it exists in Linux v7.2 | 6,353,859 | **288×** |

None of those include Mesa. Two of the three vendors spent **eleven and twenty-two years**
with funded teams and are still rewriting; the third spent **twenty-one years** without
documentation and is on its third rewrite (`gpu.md` §1).

**Size is the least of the three walls** (`gpu.md` §1.6):

1. **Signed firmware.** AMD's PSP verifies blobs before anything runs; without them probe
   **aborts** (`"Fatal error during GPU init"`). NVIDIA, from Maxwell 2, refuses unsigned
   falcon microcode — nouveau spent a decade **pinned to boot clocks** because the missing
   piece was a cryptographic signature, not knowledge. *No amount of effort produces a
   signature you do not have the key for.*
2. **Documentation.** Intel publishes PRMs. NVIDIA published nothing for the hardware
   nouveau targets. The twenty-year timeline is the price tag.
3. **This OS cannot host Mesa.** No libc worth the name, no dynamic linker, no threads, no
   `mmap` (`display-protocol.md` §5.2; `gpu.md` §1.6). A hypothetical complete kernel driver
   would put **zero** pixels on screen through any standard API.

**"Just modesetting"** is the trap that sounds reasonable. i915's display subtree alone is
201,207 lines — **47.9% of i915, nine times this kernel** — and Intel modesetting **cannot
be tested under QEMU**, so no binary exit criterion can be written (`gpu.md` §2.3). AMD's
display subtree is 596,080 lines. That work is retired, not deferred.

**We will not write i915, amdgpu or nouveau.** Restating the goal as "try harder" does not
change the firmware or the Mesa half. `gpu.md` Q1 already asked whether "GPU support across
the major GPUs" is retired. This document answers: **retired as a GPU goal, restated as a
scanout goal** (§4).

---

## 2. The firmware-framebuffer trick — what Linux does before `amdgpu`

Linux on a Ryzen laptop does not need `amdgpu` to show a console. Firmware (UEFI) has already
programmed a linear framebuffer through the **Graphics Output Protocol**. The bootloader
hands the kernel that buffer's address, width, height, pitch and pixel format. Early Linux
(`efifb` / `simplefb`) is a CPU blit into that memory. The vendor driver comes later, if it
comes at all, and is what brings 3D, power management and a modeset that can survive a
hotplug.

**That path is already named in this tree**, and it is named as the thing this kernel does
not have:

* `fb.dart`'s header: *"A UEFI machine hands the loader a framebuffer through the boot
  protocol; this kernel is a Multiboot1 image and gets nothing of the kind, so it finds the
  framebuffer the only other way there is — by enumerating PCI and reading BAR0 … then
  programming a mode through a device-specific register interface. That works on the
  QEMU/Bochs std VGA device and on nothing else."*
* ADR-0009 §2: *"It does not work on a machine that boots UEFI and hands the loader a
  framebuffer it has already configured — there, the right answer is still to take the one
  you are given, and asking a GOP-configured adapter for a Bochs VBE mode will get nothing.
  Multiboot2 (or a UEFI stub) is therefore still the portable answer and is still unbuilt."*
* GAP-0054 / GAP-0070 item 2: a modern machine *"boots UEFI, has no VGA text mode on the
  primary boot path, and hands the loader a linear RGB framebuffer."* The dispi ports are
  implemented by QEMU std VGA, Bochs, and `virtio-vga`. On real hardware the equivalents
  are real-mode VBE (unreachable from long mode), **a UEFI GOP handle (which needs a UEFI
  boot)**, or a device-specific modesetting driver.
* `gpu.md` §2.1: *"What gets a picture on real metal is a UEFI GOP framebuffer handed over
  by the boot loader — which is not a GPU driver, is not in this document's scope, and is a
  different, much smaller, genuinely achievable project that this kernel cannot do only
  because it is a Multiboot1 image."*

**This document takes that project.** GOP handoff is the portable scanout. It is not a GPU
driver. It does not light the Ryzen iGPU's command processor. It is how the machine shows
pixels on hardware we will never write a vendor driver for.

The compositor does not care which backend produced the linear aperture. ADR-0050 already
put presentation on the kernel side of a single ownership word (`wmActive`). Boundary B in
`gpu.md` §4.1 — *"the compositor deciding how to make pixels exist"* — is the seam: today
that is `fbPutPixel` into a Bochs BAR; with GOP it is the same stores into an address the
bootloader named. The verb protocol and the surface protocol sit above that seam.

---

## 3. Reject "drop in kexts" / `.ko` files

The folklore version of portability is: macOS runs on a Windows laptop if you collect the
right **kexts** and an OpenCore USB. That is Hackintosh. It is a macOS kernel loading
macOS drivers, on firmware that was bullied into looking like a Mac. It is not evidence
that *this* kernel can load a foreign driver.

Three independent refusals, any one of which is enough:

1. **ABI.** A Linux `.ko` is a relocatable ELF that calls `EXPORT_SYMBOL` functions in a
   Linux kernel (`pci_register_driver`, `drm_dev_alloc`, the DRM/KMS ioctl table,
   `request_firmware`, workqueues, `mmap`). A macOS kext is a Mach-O that calls I/O Kit.
   This kernel is `@bare` DCDart, one compilation unit (`kmain.dart` `part` list,
   GAP-0004 item 4), no `ioctl`, no `mmap`, no threads, no firmware loader. There is
   nowhere for a `.ko` to resolve a single symbol.
2. **Runtime.** Foreign drivers assume a hosted C environment, a dynamic linker, and a
   scheduler that can block. This machine has five process states and no sixth
   (GAP-0141). `drm-abi.md` already priced "Mesa runs unmodified" as *the substrate is
   the project*. Loading the vendor kernel half without that substrate is the same
   project with a different filename.
3. **Law.** amdgpu, i915 and nouveau are GPL-2.0. Their matching firmware blobs are
   redistributable only under the vendor's licence, and the hardware will not run
   unsigned substitutes (`gpu.md` §1). Shipping a folder of `.ko` + firmware next to
   `kernel.elf` does not make them ours to link, and does not make the signatures ours
   to pass.

`storage.md` §3 uses macOS's `msdos` kext as an **external judge of a FAT volume** — a
host-side reader, not a guest driver. That is the only honest use of a kext in this
corpus: feed it bytes from outside. It is not a load path.

**Plan rejected.** If a future project hosts Linux or Mesa, that is a second OS, not a
milestone on this one.

---

## 4. Three scanout backends, one compositor

One compositor (ADR-0050). Three ways to obtain a linear framebuffer it can blit into.
Vendor 3D/compute is not a fourth backend.

| backend | where it runs | status | what it is |
|---|---|---|---|
| **Bochs VBE (dispi)** | QEMU daily driver (`-vga std`, and `virtio-vga` in VGA-compat mode) | **exists** — `fb.dart`, ADR-0009, GAP-0070 | kernel programs 800×600×32 through ports `0x1CE`/`0x1CF`, discovers BAR0 |
| **VirtIO-GPU 2D** | VMs (QEMU, KVM, crosvm, …) | **G0–G8 done** (ADR-0059, ADR-0065, ADR-0067, ADR-0074, ADR-0079, ADR-0084, ADR-0086, ADR-0091, ADR-0093). Does not run on a laptop (`gpu.md` §2.1) | six opcodes to a first pixel; host scans out; `SET_SCANOUT` leaves VGA compat (VIRTIO §5.7.7); `virtio-gpu-pci` has no VGA and `fb` prints `FB NONE`; two resources flip via `SET_SCANOUT` |
| **UEFI GOP handoff** | real x86_64 UEFI machines (Ryzen laptop, random Windows laptop) | **QEMU+OVMF built** (ADR-0060 probe, ADR-0061 map+paint). Prints W/H/pitch/addr, identity-maps the aperture, pmemsave reads a derived pixel. Metal unbuilt | bootloader hands width / height / pitch / addr; kernel paints; **no device mode-set** |

**The compositor stays one.** ADR-0050's reason for putting it in the kernel — presentation
is a privileged operation, the aperture is not shareable ring-3 memory, the 2 MiB user
window cannot hold a frame — does not change when the aperture's *origin* changes from
"BAR0 we programmed" to "address the loader wrote into a tag." `fb.dart`'s glyph blit is
the renderer GAP-0054 already said would work anywhere; only the mode-set path is
Bochs-specific (GAP-0054's M5 update). GOP deletes the mode-set. VirtIO-GPU replaces it
with `SET_SCANOUT` (`gpu.md` §4.2). Same stores into a rectangle.

**Fallback order (ADR-0064), one `fb`, never hang.** The three backends above are not
three kernels and not three boot commands. `shellFb` / `gopTry` walk this list and
print which one won:

| order | probe | winner line | where it runs | compositor |
|---|---|---|---|---|
| 1 | GOP tag (Multiboot1 flags bit 12) **and** a successful identity map | `FB GOP <w>x<h> <pitch> <addr>` | UEFI laptops / OVMF+Limine | yes |
| 2 | else Bochs/VBE BAR (PCI class `03/00` + dispi `0x1CE`) | `FB BAR … MODE 0320x0258x20 OK` | QEMU `-kernel -vga std`, `virtio-vga` compat | yes |
| 3 | else no linear aperture | `FB NONE` | `-vga none`, `virtio-gpu-pci` (class `03/80`) | no |
| always | VGA text 80×25 at `0xB8000` + serial COM1 | (already exist; not a fourth `FB` line) | every boot that reaches `kmain` | no |

A GOP tag that cannot be mapped is not GOP: `gopTry` returns 0, prints nothing, leaves
`fbState` at zero, and the walk continues at step 2. A store into an unmapped aperture
is a `#PF`; falling through is the whole point of this row. COM1 is last-ditch glass
when there is no scanout at all.

**What this envelope never grows into** (`gpu.md` §6 Q5, restated): no OpenGL, no Vulkan, no
shaders, no video decode, no compute, no `amdgpu` on the Ryzen iGPU. VirtIO-GPU 3D is a
Mesa port (`gpu.md` §2.2). A GOP framebuffer is a dumb aperture. If that is not acceptable
the answer is not a different PORT plan, it is a different project.

---

## 5. CPU / arch — three ladders, not one binary

ADR-0001 decided **x86_64 only**, Multiboot1, hand-written long mode, COM1. That decision
is still the laptop path. What has changed since is that DCDart emits aarch64
(`arm64-port.md`; the `CLAUDE.md` rule-4 sentence is false since DCDart ADR-0033) and A1
has landed on `-M virt`.

| ladder | machine | what exists | what "portable" would still mean |
|---|---|---|---|
| **x86_64 UEFI** | QEMU+OVMF first; then a Ryzen / Windows laptop | Multiboot1 `-kernel` goldens; Bochs FB; PS/2; ATA PIO; e1000 N0; VirtIO-GPU G0 | **this document.** GOP + a real bootloader. The laptop target |
| **aarch64 virt** | `qemu-system-aarch64 -M virt` | **A1 only** — sixteen serial bytes and `hvc` `SYSTEM_OFF`. Parallel `kmain_virt.dart`, not the x86 `kmain.dart` | A2–A9 (`arm64-port.md`). Still a virt machine. No GOP |
| **Apple Silicon** | a real Mac | **nothing** | a third port: iBoot, not UEFI; DCP, not GOP; no device tree (`arm64-port.md`). Not A1-plus-a-flag |

**There is no way to write `if (arch == arm64)` inside a kernel file** (`arm64-port.md`
STEP 2): no `#ifdef`, one `part` list per library root. Arch selection is which files are
in the root. A1 already took "two library roots" (`kmain.dart` vs `kmain_virt.dart`). A
UEFI x86_64 kernel that also boots Multiboot1 is two *boot paths*, not two arches — same
`kmain.dart`, same `elf32` image if the loader can still see a Multiboot1 header
(PORT3).

Apple Silicon is listed so "all arches" cannot be misread as "finish A9 and copy the
binary." iBoot is not Multiboot and not UEFI. DCP is not a GOP linear FB the way OVMF
hands one over. The device tree A2 would parse is not there. **That ladder is not
opened here.**

---

## 6. The rest of a laptop, in the order that actually blocks sitting at one

Pixels on a GOP aperture are not a session. The blockers below are already named in the
corpus; this is the sitting-at-it sequence, not a new inventory.

### 6.1 Bootloader — GAP-0001, still OPEN

> *"No real bootloader. Still true. QEMU's built-in Multiboot loader (`-kernel`) is the
> only tested boot path. BIOS MBR / UEFI boot on real hardware is unbuilt and unverified."*

ADR-0001 scoped BIOS MBR / UEFI out of M0 on purpose. Every golden from `m0-boot` onward
assumes `-kernel`. **That path must keep working** (§7, PORT3). Closing GAP-0001 is a
second path, not a replacement.

Two candidate loaders, either of which can hand GOP to a kernel:

* **Limine** — a small modern loader that speaks Multiboot1/2 and UEFI, so the existing
  Multiboot1 header can remain the `-kernel` contract while a Limine/UEFI boot supplies
  a framebuffer request.
* **Multiboot2 + OVMF** — the path GAP-0054 / ADR-0009 already named. Multiboot2 has the
  framebuffer tag Multiboot1 lacks. OVMF is the QEMU UEFI firmware the harness can pin.

This document does not pick. PORT1's exit criterion is "a bootloader we control loaded
our kernel under OVMF and printed serial," not a brand. A third loader that satisfies
the same criterion is the same milestone.

**BIOS MBR is not the laptop path.** GAP-0001 names it; modern laptops boot UEFI. A
legacy-BIOS fallback is a named successor, not a first rung. **PORT4
(ADR-0072) is that successor under QEMU SeaBIOS**, not metal: the same
Limine hybrid ISO `p2-gop` already packs, booted with `-cdrom` and no
OVMF. Serial `OSCORTEX M0 OK`. GOP is not required (Bochs / `FB NONE`).

### 6.2 GOP framebuffer — the first pixel on metal

§2 and §4. Width, height, pitch, physical address, pixel format, from the loader, not
from dispi. The renderer in `fb.dart` already blits into a `Pointer<u32>` aperture;
GOP is a different way to learn the aperture. The kernel must **not** then write
`0x1CE`/`0x1CF` on that path — that is how you get `FB NOVBE` on a machine that was
already showing firmware splash (GAP-0070 item 2).

Identity-map work is real: today's BAR lives in the 3–4 GiB hole `boot.S` already maps
(ADR-0009). A GOP address may sit anywhere the firmware put it. ADR-0061 maps the
OVMF aperture (`0x80000000`) with 2 MiB leaves in `gop.dart` when the tag exists.
GAP-0071 (cacheable PCI hole, no MTRR/PAT) applies to a GOP aperture the same way
it applies to a BAR; `gpu.md` §3.5 already called that "known-wrong, invisible under TCG."

### 6.3 USB HID — do not rely on PS/2

GAP-0055 item 5: *"On hardware that came up through UEFI with no legacy emulation there
may be no PS/2 controller at all; the real input path there is USB HID, which needs a
USB stack."* Some firmware still emulates an 8042. **Do not rely on it.** A laptop that
does not emulate one is the common case, not the edge.

`peripherals.md` is honest about the QEMU product: default machines have **no USB**,
UHCI is the cheap emulator path, and **xHCI is the only option on a physical board**,
ranked "No — not for years" *for sitting at QEMU*. Sitting at a laptop inverts that
ranking. The laptop HID ladder is `usb-hid.md` (USB0 landed: find xHCI on PCI).
PORT does not absorb it. PORT names it as the next blocker after pixels.

Until USB HID exists, a GOP laptop is a picture plus COM1. That is still a proof. It is
not sitting at it.

**USB0–USB3 and ADR-0138 (`hid-sess/`) landed under QEMU:** class-matched
xHCI, HID→set-1 into `kbdq`, one wire report, and a focused `kbdevent`
plus HID boot-mouse through COM1 seams (no `usb-kbd` on 8042 goldens).
A resident IRQ poll at the idle prompt is still leftover (`usb-hid.md`
§6). Metal vendor:device is not the match.

### 6.4 Storage — ATA PIO is QEMU; AHCI then NVMe

Every disk harness uses `-drive file=…,if=ide` on the PIIX3 (`storage.md` fact 15).
That controller is not in a modern laptop. `storage.md` designs **bus-master IDE first**
(zero harness-line change) and **AHCI after** (twelve QEMU command lines change). AHCI
is the first storage that a SATA laptop could use.

**NVM0–NVM6 and A2 landed (ADR-0071, ADR-0074, ADR-0087, ADR-0088, ADR-0089,
ADR-0090, ADR-0092, ADR-0137):** the kernel finds class `01/08/02` and class
`01/06/01`. FAT and a named ELF go through `fatDiskRead` on either
(`nvm-root/`). Machines with neither still use ATA PIO. A laptop
vendor:device is not the match. `smp.md` names NVMe as a device that
delivers interrupts by MSI — which this kernel does not have. Polled
NVMe/AHCI is enough for FAT under QEMU. It is not a PORT rung.

### 6.5 Net — e1000 is a VM; laptop Wi-Fi is a different project

`net-e1000.md` is an Intel 82540EM under QEMU, already on the default machine, BAR
already mapped, option ROM already talking if you forget `romfile=`. That is a **VM
wired NIC**. A Ryzen laptop's NIC is typically a vendor Ethernet or, more often, a
PCIe/USB **802.11** part that needs signed firmware the same way `gpu.md` §1 described
for GPUs.

**VirtIO-net is a second wired class (ADR-0145, `net-virtio/`):** modern
`1af4:1041` (non-transitional), MAC via DEVICE_CFG, `nic virtio`. Not TX/RX.
Not Wi-Fi. Relabeling e1000/virtio as "wifi" is refused.

There is no Wi-Fi device in QEMU 11 on this Mac (ADR-0139 OPEN). There is no
USB-net design. The honest order after GOP + HID + a disk is: a **wired** path
we can name (e1000 N0–N3, virtio-net class door, or a USB-Ethernet dongle on
the eventual xHCI stack), and only then 802.11 when a real class/device exists.
OTA signed plant on NIC is PASS (`ota0/`, ADR-0140): RX plant + keyed
XOR signature against planted `OTAKEY`, apply to `SLOT.TXT`, bad sig leaves
the slot unchanged, no NIC refuses. OTA host TCP fetch is PASS
(`ota-host/`, ADR-0151): `ota get <port>` pulls the same blob from a
real host listener at `10.0.2.2`, bad sig / no listener leave the slot
unchanged. Leftover: HTTPS / TLS record layer (not plat-tls / FSGS).
`net-stack.md` N0–N3 ("the machine can ping") remains the first network
capability — against slirp, on QEMU, with `romfile=`. It does not put
this OS on hotel Wi-Fi.

---

## 7. The PORT ladder

**Prefix `PORT`.** `README.md` already records that `N` collided three ways and `A`
nearly collided with applications; multi-letter prefixes are the rule. A, G and N
are taken (`arm64-port.md`, `gpu.md`, `net-e1000.md` / `net-stack.md` / `namespace.md`).

**Three rungs were specified first; PORT4 is the BIOS successor.** Everything in
§6 after GOP is a blocker this document sequences, not a PORT milestone (USB
stays `USB*`. Storage stays `S*`. NIC stays `N*`. ARM64 stays `A*`.
VirtIO-GPU stays `G*`). PORT4 is the named legacy-BIOS fallback (§6.1),
proven under QEMU SeaBIOS only.

Every criterion is written to this repo's rules: derived from something the kernel
does not control, a negative control that must fail, no eyeballed screenshot
(`gpu.md` §5: *"The PNG is not evidence"*).

**Ladder-wide invariant:** the existing Multiboot1 `-kernel` path (ADR-0001, GAP-0001's
workaround, every `m0`/`m1`/… `run.sh`) **must keep working on the same kernel image.**
A build that only works on UEFI and breaks those goldens is a fail — stated once here
and tested at PORT3.

---

### PORT1 — QEMU OVMF + a bootloader loads our kernel

**Blocked on: nothing but a loader choice** (§6.1). Does not require GOP. Does not
touch `fb.dart`.

A UEFI firmware (OVMF) plus a bootloader (Limine, or Multiboot2, or a UEFI stub) loads
`kernel.elf` under `qemu-system-x86_64` **without** QEMU's `-kernel` Multiboot loader.
Proof of life is serial, the same shape as M0: a derived banner on COM1, byte-exact,
and `verify-freestanding.sh` clean.

*Binary:* the harness launches QEMU with `-bios` / pflash OVMF and a bootable ESP (or
Limine ISO) that names our kernel; it does **not** pass `-kernel`. The first bytes on
the serial file are a derived string the harness wrote into the image (or the existing
M0 banner, if the same `kmain` path runs). QEMU's own `info` / file tree must show the
firmware volume the harness built, so a `-kernel` boot cannot satisfy this by accident.
*Anti-vacuity:* fail if the serial file is empty — OVMF itself prints; emptiness means
the guest never ran, not that we were quiet. Fail if the capture equals a do-nothing
firmware splash with no kernel banner.
*Negative control:* the **same** `kernel.elf` booted the old way —
`qemu-system-x86_64 -kernel core/build/kernel.elf` — must still pass `m0-boot` and
`m1-interrupts` byte-for-byte. A linker script or header change that makes the
Multiboot1 `-kernel` path die is a PORT1 fail, even if OVMF booted beautifully.

---

### PORT2 — the bootloader hands GOP; the kernel paints without Bochs

**Blocked on: PORT1.**

The loader reports a GOP framebuffer: **width, height, pitch, physical address** (and
enough format to know it is 32-bit XRGB/ARGB, which is what `fb.dart:230` already
stores as `0x00RRGGBB`). The kernel identity-maps that aperture if it is not already
mapped, and the existing glyph blit paints **without** any write to `0x1CE`/`0x1CF`
and without `fbFindVgaBar`.

*Binary:* the harness asks OVMF for a non-default GOP mode (or Limine for an explicit
framebuffer request) whose width×height is **neither** 800×600 (the kernel's compiled-in
dispi mode, GAP-0070 item 3) **nor** 1280×800 (QEMU virtio-vga's default, `gpu.md` §7).
The kernel prints the four numbers. The harness requires them equal to the mode *the
firmware / loader was told*, which the harness itself chose. Then — `m5-pci`'s
mechanism — `xp` of guest RAM at the printed address must contain the derived banner
glyphs from `fbFont8x16`. *No dispi port write may appear in the PORT2 path's
disassembly* (structural, `m6-disk`-style).
*Anti-vacuity:* fail if the printed address is 0, if width or height is 0, if the
expected glyph has zero foreground pixels (`check-font.py`'s rule).
*Negative control:* a build that still programs dispi and ignores the GOP tag must
fail the "no `0x1CE` on this path" structural check, and must fail the geometry
assertion (it will report 800×600). A boot with **no** GOP (OVMF GOP torn out, or a
loader config that requests no framebuffer) must print an honest refusal and must
**not** paint at `0xB8000` pretending it did.

**PORT2 is not "it boots my Ryzen laptop."** It is "under OVMF, the kernel can paint
into a framebuffer it did not program." Metal is a later verification of the same
contract, and it is eyeball-on-hardware unless we grow a way to read that laptop's
FB back. This repo does not award milestones for a photograph.

---

### PORT3 — the same image still works with `-kernel` + Bochs
**The three-way check is `p3-fallback` (ADR-0064):** UEFI GOP, `-kernel` Bochs,
and `-vga none` → `FB NONE` with no `#PF`. PORT3's two-path split is still
`p2-gop`'s negative control.

**Blocked on: PORT2.**

One kernel. Two boot paths. The OVMF+GOP image from PORT2, passed to the historical
harness as `-kernel`, still finds Bochs VBE, still prints
`FB BAR … MODE 0320x0258x20 OK`, and still satisfies `m0-boot` and `m1-interrupts`.

*Binary:* `m0-boot/run.sh` and `m1-interrupts/run.sh` run **unchanged in form** against
the PORT2 artefact (the same `kernel.elf` bytes, not a second build flavour). `fb`
on that `-kernel` boot still matches `m5-pci`'s BAR/mode assertions, or a documented
superset that still contains `0320x0258x20`. The OVMF boot from PORT2 still prints
the GOP geometry, not 800×600, on a **second** launch of the same file.
*Anti-vacuity:* fail if the two boots produce the same geometry line — that would
mean one path is a stub.
*Negative control, and it is the load-bearing one:* **a build that only works on
UEFI and breaks the m0/m1 Multiboot goldens is a fail.** The harness must run those
goldens and they must PASS. Deleting `.section .multiboot`, switching the container
to ELF64 so QEMU's Multiboot loader says `"Cannot load x86-64 image, give a 32bit
one."` (ADR-0001's measured refusal), or making `kmain` wait for a GOP tag that
`-kernel` never provides, are all PORT3 fails.

---

### PORT4 — QEMU SeaBIOS + the same hybrid ISO loads our kernel

**Blocked on: PORT1** (the ISO). Does not require GOP. Does not touch `fb.dart`.
**QEMU SeaBIOS, not metal.**

The Limine hybrid ISO PORT1 already packs (`build-uefi-image.sh`, now with
`limine bios-install`) boots under QEMU's built-in SeaBIOS: no OVMF, no
`-bios`, no `-kernel`. Proof of life is the same first-line M0 banner.

*Binary:* `tests/conformance/p4-bios/run.sh` launches
`qemu-system-x86_64 -cdrom hybrid.iso` and requires the first serial
bytes to be `OSCORTEX M0 OK\n` and `M1 END` after. `fb` must print an
ADR-0064 winner (`FB GOP` / `FB BAR` / `FB NONE`). GOP is not a BIOS
*requirement* — VBE-as-tag is extra, not the criterion.
The recorded argv must not contain `-kernel`, `-bios`, or pflash.
*Anti-vacuity:* fail if the serial file is empty. Fail if a `-kernel`
boot could have produced the capture (argv check).
*Negative control:* the same `kernel.elf` under `-kernel` still prints
the M0 banner and the Bochs MODE line. p2-gop (OVMF) is a separate
harness and must still PASS — a BIOS-only ISO that drops `BOOTX64.EFI`
is a PORT4 fail.

---

### Not on this ladder, and why

| | why it has no PORT milestone |
|---|---|
| **G1–G7 VirtIO-GPU** | landed (`gpu.md` §5, ADR-0091). VM scanout, not metal |
| **A2–A9** | already specified in `arm64-port.md`. Different arch, still virt |
| **USB HID / xHCI** | `peripherals.md`. Sequenced *after* PORT2 if the goal is a laptop keyboard; not a PORT rung |
| **AHCI / NVMe** | `storage.md` owns AHCI. NVMe is unspecified |
| **e1000 N1–N7 / net stack** | `net-e1000.md` / `net-stack.md`. VM NIC |
| **Wi-Fi / 802.11** | ADR-0139 OPEN — QEMU 11 has no WLAN device; do not relabel e1000/virtio |
| **Intel / AMD / NVIDIA modesetting** | `gpu.md` §2.3–§2.4. Retired |
| **Apple Silicon** | third machine; not opened |
| **BIOS MBR on metal** | GAP-0001 names it; not the laptop path. **QEMU SeaBIOS is PORT4** (ADR-0072, `p4-bios`) — proven there, not on a real MBR stick |
| **a photograph of a Ryzen lid** | not a binary criterion |

---

## 8. The one-sentence answers the owner will ask

**PORT1.** QEMU OVMF plus a bootloader loads our kernel; serial proves it; the existing
Multiboot `-kernel` path must keep working.

**PORT2.** The bootloader hands GOP width, height, pitch and address; the kernel paints
without Bochs.

**PORT3.** The same image still works with `-kernel` plus Bochs — one kernel, two boot
paths. A build that only works on UEFI and breaks the m0/m1 Multiboot goldens is a fail.

**PORT4.** The same Limine hybrid ISO boots under QEMU SeaBIOS (`-cdrom`,
no OVMF, no `-kernel`). Serial `OSCORTEX M0 OK`. GOP is not required.
Not metal.

**Will it boot my Ryzen laptop after PORT2?** No — PORT2 proves GOP paint under OVMF, not
a metal boot, and that laptop still has no USB HID, no AHCI/NVMe, and no vendor GPU
driver.

---

## 9. What I did not decide, and would rather be told

**Q1 — Limine, or Multiboot2 plus a UEFI stub?** PORT1 accepts either. Limine keeps the
Multiboot1 header and adds a framebuffer request; Multiboot2 is the tag GAP-0054 already
priced as a `multiboot.dart` rewrite. I would rather be told than guess; the negative
control is the same.

**Q2 — Is a metal boot (a real Ryzen, a real Windows laptop) ever a milestone?** This
repo's rule is a binary criterion a harness can fail. A laptop has no QMP and no `xp`.
The honest metal artefact is a **manual** verification after PORT3, recorded as a note,
not a golden. If that is unacceptable, say so before anyone books a weekend with a USB
stick.

**Q3 — Confirm vendor GPU remains retired.** §1 is `gpu.md`'s conclusion copied out so
it sits next to the laptop ask. If the owner wanted amdgpu on that Ryzen, the answer is
still no.

**Q4 — May PORT share `fb.dart`'s blit and only add a discovery path?** That is this
document's recommendation (GAP-0054: the renderer would work anywhere; the mode-set is
what is Bochs-specific). A second blit would be a second golden and a second font bug.

---

## 10. Notes for the coordinator to fold in elsewhere

**I have not touched `known-gaps.md` or `ROADMAP.md`.** These are the entries that
belong in them.

* **GAP-0001's remaining open item is this ladder's PORT1.** The entry already says
  UEFI boot is unbuilt. PORT1 is the first criterion that could close it *under QEMU
  OVMF*; metal remains unverified even then.
* **GAP-0054 / GAP-0070 item 2 named GOP and then left it.** `gpu.md` §2.1 deferred it
  as out of scope. This file is the scope. The gap entries should point here so the
  next agent does not reopen "should we write a modesetting driver for the iGPU."
* **GAP-0055 item 5 (no 8042 on UEFI) becomes load-bearing the moment PORT2 works.**
  Until USB HID exists, GOP-on-metal is output-only. That is worth a line on the USB
  ranking in `peripherals.md`: xHCI stays "not for years" for QEMU and becomes the
  laptop keyboard.
* **Naming:** `PORT` does not collide. Do not shorten it to `P` (`proc` talk) or
  reopen `A`.
