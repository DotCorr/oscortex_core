# The Linux DRM/KMS ABI in oscortex — what the decision actually costs

**Status: DESIGN. Nothing here is implemented.** The decision this document designs *within* was taken
by the project owner and is recorded as **ADR-0029**: GPU support comes from implementing the **Linux
DRM/KMS kernel ABI** so that **Mesa's existing userspace drivers run unmodified**, with **oscortex's
own display protocol above it** rather than Wayland. This document does not relitigate either half. It
maps what they cost, in what order the work can be done, and where the schedule attached to the
decision has to move.

**Provenance.** Both decisions were relayed to me by the coordinator and **not witnessed by me**, the
same standing as the display-protocol decision `display-protocol.md` records. This document records
the difference.

**This document supersedes nothing in `gpu.md` and contradicts one of its conclusions.** `gpu.md` §2.2
concluded that virgl and venus were "not reachable" because their guest halves are Mesa. That
conclusion was *conditional on hand-writing what Mesa does*, and it was correct under that condition.
The decision in ADR-0029 removes the condition. §1.3 below is the reversal, stated precisely, with the
part of `gpu.md` that survives intact marked as surviving — which is most of it, including its entire
G-ladder, which becomes the transport layer underneath this one (§5.0).

---

### The findings, for a reader in a hurry

| | finding | where |
|---|---|---|
| **The rationale has a hole, and it is worth naming once** | "Mesa covers Intel, AMD, Nvidia, Adreno and Mali, so broad support means running what exists" is true about the **userspace** half of a GPU driver and false about the **kernel** half. Below `DRM_COMMAND_BASE` the ABI is **per-driver**: virtio-gpu 11 ioctls, xe 12, nouveau 13, amdgpu 16, **i915 62**. Implementing "the DRM ABI" for amdgpu *is* writing amdgpu. Mesa saves the compiler, not the driver. | §1.1, §2.8 |
| **The decision still pays, and here is the mechanism** | **virtio-gpu is a universal shim.** With one kernel driver — the one `gpu.md` already argued for — Mesa's **venus** (Vulkan), **virgl** (GL) and **DRM native context** (the real vendor driver, forwarded) all become reachable, because Mesa supplies the guest halves that could not be hand-written. This is real, vendor-accelerated 3D and compute, and it needs no vendor firmware and no vendor kernel driver. | §1.3 |
| **…in a virtual machine, and only there** | Nothing in ADR-0029 changes bare metal. An Intel/AMD/Nvidia GPU on real hardware still needs its kernel driver and its signed firmware. `gpu.md` §1 is unaltered and remains the answer. | §1.4 |
| **Compute is a much smaller ABI than display, measured** | Of the 75 rows in Linux's core DRM ioctl table, **17 are `DRM_RENDER_ALLOW`** — usable on a render node with no master and no KMS at all. The render-path core files total **8,120 lines**; the KMS-path core files total **34,699**. **The compute path skips 4.3× the code the display path needs, and it can proceed with no compositor at all.** | §2.2, §7 |
| **The substrate is the project, not the GPU** | Before Mesa links: `ioctl`, a device namespace, `mmap`, fd passing, threads, TLS, futexes, dynamic linking, a hosted libc, a libm, a C++ runtime. This kernel has **10 syscalls and a 32-symbol libc**. This is where the multi-year answer lives, and almost none of it is graphics work. | §3, §8 |
| **Mesa must not be the first C library this OS links** | It would be the largest C/C++ codebase in the project's reach, linked by a toolchain that has never linked anything. **`libdrm` is the right first one** — it is small, it is pure ioctl wrappers, it is on the critical path anyway, and it fails loudly and early if the ABI is wrong. | §8.3 |
| **The membrane has an unusually good answer here** | Escalation 0004 §6 recommends "describe the boundary". The DRM ioctl surface is a **fixed, finite, versioned set of flat POD structs in public headers** — the most mechanically describable FFI boundary this project will ever have. And **our own protocol is the containment**: Mesa lives in its own address space, behind our protocol, and everything crossing our protocol is described. **The owner's two decisions are complementary, not in tension.** | §4 |
| **The dev machine cannot test the compute path at all** | Measured: this Mac's QEMU 11.0.0 offers `virtio-gpu-pci`, `virtio-gpu-device` and `virtio-vga` and **no `virtio-gpu-gl-pci`, no `vhost-user-gpu`**; `-display help` lists `none/curses/cocoa/dbus` and **no EGL-capable backend**. Every 3D and compute rung needs **a Linux host**. That is a logistics prerequisite, not a code one, and nothing in the ladder can substitute for it. | §6.3, GAP-0163 |

**What to build first:** **S0 — `ioctl` exists** (§5.1). It is a syscall, a `_IOC` decode and a bounded
copy in each direction, it needs no GPU, and it is the single item that unblocks every other rung in
this document. **What to build first that produces a number: V0** (§5.4), which links Mesa's venus
driver on the host and counts its undefined symbols, turning every ⚠ in §3 into a measurement without
touching the kernel.

**A note on evidence.** Every number attributed to Linux in this document was measured with `wc -l`
and `grep` against a **Linux 6.12.0** source tree at `/Users/ghostportal/kpi-ref/linux-6.12` on this
machine, and the commands are given inline so the next agent can re-run them. Every number attributed
to *this* kernel was measured against the working tree at `e1381f8`. **Everything I could not measure
is marked ⚠ and is not used to support an argument.** In particular I have no Mesa checkout on this
machine and **every claim about Mesa's size or symbol surface is unmeasured**; §3.4 says exactly which
command would close that and why it should be run before V1 is scoped.

**Citation convention.** A bare `§n.n` is this document. Linux uAPI is cited by header and symbol
(`include/uapi/drm/drm.h`, `DRM_IOCTL_MODE_ATOMIC`). Sibling design documents are cited by filename
(`gpu.md` §5, `libc-roadmap.md` §5.8).

---

## 0. Where this machine is, measured

`gpu.md` §0 established the graphics baseline and it has not moved: `core/kernel/fb.dart` is a dumb
framebuffer console, 800×600×32, found by PCI class `03/00`, programmed through the Bochs VBE
index/data ports at `0x1CE`/`0x1CF`, with every pixel placed by a `Pointer<u32>` store. There is no
command submission, no memory manager and no mode negotiation.

What this document needs on top of that is the **process and syscall** baseline, because that is what
Mesa lands on. Measured at `e1381f8`:

| | what exists | source |
|---|---|---|
| syscalls | **ten**: `exit`, `write`, `who`, `yield`, `sbrk`, `open`, `read`, `close`, `seek`, `fdwrite` | `core/user/libc/oslibc.h:66`–`80` |
| libc | **32 exported functions**, of which 9 are C89 names | `core/user/libc/oslibc.h`; `libc-roadmap.md` §1.1 |
| `ioctl` | **does not exist**, in any form | — |
| `mmap` | **does not exist**. `sbrk` is the only way a program gets a page | ADR-0016 |
| device nodes | **do not exist**. Every `open` goes to FAT16, root directory, 8.3 names | ADR-0018, `file.dart` |
| fd passing | **does not exist**, and there is no transport that could carry one | `display-protocol.md` §0 |
| processes | **four**, each with **four** descriptors and a **2 MiB** address space | `proc.dart`, `vm.dart:1976` |
| threads | **none**, and none are possible: `procSpaceFree` and `freeFrame` are not reference-counted | `blocking-and-threads.md` §4.3 |
| blocking | **none**. Five process states, no sixth | `blocking-and-threads.md` §1.1, GAP-0141 |
| dynamic linking | **refused by name** — `elf.dart:1280` rejects `PT_INTERP` and `ET_DYN` | GAP-0091 |
| floating point in userland | works (SSE2 on, `fxsave` per switch) — but **no `strtod`, no `printf("%f")`, no libm** | `libc-roadmap.md` §3 |
| C++ | **nothing**. No runtime, no `__cxa_*`, no unwinder, no `operator new` | — |

**Read the `ioctl` row and the libc row together, because they are the whole shape of this document.**
The DRM ABI is an **ioctl** ABI reached through a **character device** and consumed by a **libc-hosted,
dynamically-linked, multi-threaded C and C++ program**. This OS has none of those five things.

---

## 1. What the decision buys, and the one thing it does not

### 1.1 A modern GPU driver has two halves, and Mesa is one of them

`gpu.md` §1.1 took this apart already and it is worth restating in the form the new decision needs:

* the **kernel half** is a memory manager for the GPU's own address space, a command-submission engine,
  a display engine driver, power/clock management, and the uAPI that exposes all of it;
* the **userspace half** — Mesa — is the shader compiler, the state trackers, the API implementations
  (OpenGL, Vulkan), the format and modifier handling, and the descriptor/pipeline machinery.

**Mesa covering Intel, AMD, Nvidia, Adreno and Mali means Mesa has the userspace halves.** The kernel
halves are `i915`+`xe` (**560,555 lines**), `amdgpu` (**~1,237,465 non-header lines**, plus 4,977,963
lines of machine-generated register headers), `nouveau` (**232,946**), `msm`, `panfrost`/`panthor` —
all measured in `gpu.md` §1.5 against Linux v7.2, all still yours to write, and all still gated on
vendor firmware you cannot sign.

**So the sentence to keep is this one: implementing "the DRM ABI" for a given GPU is not an alternative
to writing that GPU's kernel driver — it is the interface that driver exposes.** The ABI is the shape
of the work, not a substitute for it.

This is not an argument against the decision. It is an argument against one expectation attached to it,
and §1.4 states the corrected expectation.

### 1.2 What Mesa genuinely does supply, and it is a lot

The half Mesa supplies is the half this project could least plausibly write:

| | what it is | why this project could not write it |
|---|---|---|
| **NIR** | Mesa's SSA shader IR, plus ~100 optimisation and lowering passes | a compiler middle-end |
| **SPIR-V front end** | Vulkan's shader input format → NIR | a parser for a 1,000-page spec |
| **ACO** (AMD), **brw/elk** (Intel), **nak** (Nvidia), **ir3** (Adreno) | per-vendor instruction selection, scheduling and register allocation | a code generator per ISA, per generation |
| **the Vulkan runtime** (`src/vulkan/runtime`) | the ~80% of a Vulkan driver that is not hardware-specific | a conformance-tested implementation of a large API |
| **format and modifier handling** | the 180 `DRM_FORMAT_*` codes and the tiling-modifier namespace | measured: `grep -c '^#define DRM_FORMAT_' include/uapi/drm/drm_fourcc.h` → **180** |

That is the trade the decision makes, and on its own terms it is a good one. The correction in §1.1 is
about which half is left over, not about whether the half you get is worth having.

### 1.3 The mechanism that makes the decision pay — virtio-gpu is a universal shim

**This is the reversal of `gpu.md` §2.2, and it is the most important paragraph in this document.**

`gpu.md` §2.2 concluded that virgl was "not reachable, and the reason is not size": the guest side of
virgl is a Mesa Gallium driver, shaders cross the wire as TGSI text, and *"porting 'the virgl driver'
means porting Mesa."* It said the same of venus, more strongly: venus's protocol is
machine-generated from `vk.xml` and is *"strictly less hand-implementable than virgl."* It said the
same of DRM native context: the guest side is *"literally the real vendor Mesa driver — radeonsi, anv,
freedreno,"* which is *"strictly worse: §1 plus a transport."*

**Every one of those verdicts is correct, and every one of them was an argument against hand-writing
Mesa's job. ADR-0029 says we do not hand-write it. So all three verdicts invert.** Under the decision:

| path | guest kernel driver needed | guest userspace | what runs on the host |
|---|---|---|---|
| **virgl** (capset 1/2) | virtio-gpu, `EXECBUFFER` + `GET_CAPS` | Mesa's `virgl` Gallium driver — **unmodified** | `virglrenderer` → host GL |
| **venus** (capset 4) | virtio-gpu + `CONTEXT_INIT` + `RESOURCE_CREATE_BLOB` + a host-visible region | Mesa's `venus` Vulkan driver — **unmodified** | `virglrenderer` (venus) → **host Vulkan** |
| **DRM native context** | virtio-gpu + `CONTEXT_INIT` with a nativectx capset | the **real vendor Mesa driver** — radeonsi, RADV, anv, freedreno — **unmodified** | the host's real vendor kernel driver |

**Read the third row twice.** DRM native context means the guest runs AMD's or Intel's real Mesa driver
and the guest kernel forwards the vendor ioctls to the host, which owns the hardware. **The guest never
needs the vendor kernel driver and never needs the firmware.** "Almost all GPUs" is genuinely reachable
in that shape — through a hypervisor, with one kernel driver, exactly as the owner hoped, just not on
bare metal.

**And the second row is the one that matters for an AI machine.** Venus forwards Vulkan calls to the
host's Vulkan implementation. SPIR-V crosses the wire as SPIR-V. ⚠ *I believe the venus guest driver
contains no shader compiler at all — it is a protocol encoder over the Mesa Vulkan runtime — which
would make it the only Vulkan driver in Mesa that does not need NIR-to-ISA code generation in the
guest. I could not confirm this without a Mesa checkout; V0 (§5.4) is the rung that confirms or refutes
it, and the whole compute ladder's cost estimate depends on the answer.*

### 1.4 The scoreboard — what runs where, honestly

| | in a VM (QEMU/KVM, Linux host) | on bare metal |
|---|---|---|
| **display, dumb framebuffer** | yes, today (`fb.dart`) | yes, today, on Bochs-VBE-compatible hardware only |
| **display, KMS through the Linux ABI** | yes — virtio-gpu, R3 (§5.3) | no |
| **3D (OpenGL)** | yes — virgl, once the substrate exists | no |
| **Vulkan compute** | **yes — venus, and this is the target** | no |
| **vendor-accelerated anything** | yes — DRM native context | no |
| **an Intel/AMD/Nvidia GPU driven directly** | n/a | **no, and ADR-0029 does not change this** |

**The honest restatement of "almost all GPUs, early":** *almost all GPUs, through a hypervisor,
eventually.* The "through a hypervisor" is not a hedge — it is what makes the rest true at all, and it
is a genuinely capable target. The "eventually" is §8.

---

## 2. The ABI surface, measured against Linux 6.12

Everything in this section was measured on this machine:

```
L=/Users/ghostportal/kpi-ref/linux-6.12
grep -c '^#define DRM_IOCTL_' $L/include/uapi/drm/drm.h            # 109
wc -l $L/include/uapi/drm/*.h                                       # 24,265 total
```

### 2.1 The device, the node, and the ioctl encoding

A DRM device is a character device, major **226**, presented as two nodes:

* **`/dev/dri/card0`** — the *primary* node. Carries KMS. Has a **master** concept: exactly one client
  at a time may modeset (`DRM_IOCTL_SET_MASTER` / `DRM_IOCTL_DROP_MASTER`). This is the compositor's
  node.
* **`/dev/dri/renderD128`** — the *render* node. **No master, no KMS, no authentication.** Any process
  may open it. This is the node a compute client uses, and §2.2 is why it matters so much.

Every request is an `_IOWR('d', nr, type)`: the request number encodes **direction** (2 bits),
**payload size** (14 bits), the **type letter** `'d'` (8 bits) and the **command number** (8 bits).
A kernel serving this ABI must decode all four from the request word — it must not carry a switch on
the whole 32-bit value, because `libdrm` computes the number from `sizeof(struct)` at compile time and
a mismatch in one struct's size changes the request number silently.

Number-space layout, from `include/uapi/drm/drm.h`:

| range | meaning |
|---|---|
| `0x00`–`0x3F` | core DRM |
| `0x40`–`0x9F` | **`DRM_COMMAND_BASE`..`DRM_COMMAND_END` — per-driver.** §2.8 |
| `0xA0`–`0xBC` | KMS (`DRM_IOCTL_MODE_*`) |
| `0xBF`–`0xCD` | `syncobj` |

### 2.2 The core ioctls, and the number that separates compute from display

`drivers/gpu/drm/drm_ioctl.c` holds the core dispatch table. Measured:

```
python3 -c "import re;s=open('$L/drivers/gpu/drm/drm_ioctl.c').read();\
r=re.findall(r'DRM_IOCTL_DEF\(DRM_IOCTL_([A-Z0-9_]+),\s*([a-z0-9_]+),\s*([^)]*)\)',s);\
print(len(r), len([x for x in r if 'RENDER_ALLOW' in x[2]]))"
# 75 17
```

**75 table entries; 17 flagged `DRM_RENDER_ALLOW`.** Those seventeen, in full, are the entire core
surface a render-node client can reach:

```
VERSION  GET_CAP  GEM_CLOSE  PRIME_HANDLE_TO_FD  PRIME_FD_TO_HANDLE
SYNCOBJ_CREATE  SYNCOBJ_DESTROY  SYNCOBJ_HANDLE_TO_FD  SYNCOBJ_FD_TO_HANDLE
SYNCOBJ_TRANSFER  SYNCOBJ_WAIT  SYNCOBJ_TIMELINE_WAIT  SYNCOBJ_EVENTFD
SYNCOBJ_RESET  SYNCOBJ_SIGNAL  SYNCOBJ_TIMELINE_SIGNAL  SYNCOBJ_QUERY
```

**Five of those seventeen are not syncobj.** A first render-node implementation that declines
`DRM_CAP_SYNCOBJ` and `DRM_CAP_SYNCOBJ_TIMELINE` has **five core ioctls to implement** — `VERSION`,
`GET_CAP`, `GEM_CLOSE`, and the two PRIME calls — plus its driver's own set. That is the smallest
honest statement of the compute path's core-ABI cost, and it is remarkably small.

The remaining 58 table entries are KMS (38), master/auth, and a long tail of pre-KMS legacy
(`DRM_IOCTL_ADD_MAP`, `AGP_*`, `SG_*`, `ADD_CTX`, the SAREA calls) that **modern userspace never
issues** and that a from-scratch implementation should refuse with `EINVAL` rather than implement.
⚠ *"Never issues" is an inference from the ioctls' `DRM_ROOT_ONLY`/legacy flags and from their absence
in modern Mesa; I did not verify it by tracing a live Mesa.*

`DRM_IOCTL_GET_CAP` answers a 15-value capability enum (`DRM_CAP_DUMB_BUFFER`, `DRM_CAP_PRIME`,
`DRM_CAP_TIMESTAMP_MONOTONIC`, `DRM_CAP_ADDFB2_MODIFIERS`, `DRM_CAP_SYNCOBJ`,
`DRM_CAP_SYNCOBJ_TIMELINE`, `DRM_CAP_CURSOR_WIDTH`/`HEIGHT`, …) and
`DRM_IOCTL_SET_CLIENT_CAP` accepts six (`DRM_CLIENT_CAP_UNIVERSAL_PLANES`, `DRM_CLIENT_CAP_ATOMIC`,
`DRM_CLIENT_CAP_WRITEBACK_CONNECTORS`, `DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT`, …). **These two are the
whole negotiation surface**, and a device that answers them honestly gets to decline most of the rest.

### 2.3 GEM — the buffer object model

GEM is the buffer abstraction every DRM driver shares. Its rules, and every one of them is something
this kernel would have to grow:

1. A buffer object is created by a **driver-specific** ioctl (there is no generic `DRM_IOCTL_GEM_CREATE`
   — `virtio_gpu`'s is `DRM_IOCTL_VIRTGPU_RESOURCE_CREATE`, xe's is `DRM_IOCTL_XE_GEM_CREATE`).
2. It is named to userspace by a **per-open-file handle** — a small integer, valid only in that file
   description. `drm_gem.c` (**1,535 lines**) is the handle table, the reference counting and the
   lifetime rules.
3. `DRM_IOCTL_GEM_CLOSE` drops one handle reference. The object dies when the last reference — handle,
   dma-buf fd, or in-flight command-buffer reference — goes.
4. It is mapped into the process by **`mmap` on the DRM fd at a driver-assigned fake offset**, obtained
   from a driver ioctl (`DRM_IOCTL_VIRTGPU_MAP`, `DRM_IOCTL_XE_GEM_MMAP_OFFSET`). Linux calls this the
   `drm_vma_offset_manager`: the offset is not a file offset, it is a token in a per-device address
   space.

**Point 4 is the requirement this OS is furthest from.** It needs `mmap` (which does not exist), of a
file descriptor (never done), at an offset chosen by the driver (a new concept), with the mapping
surviving into a fault handler that can populate pages on demand. GAP-0159 records it.

`drm_gem_shmem_helper.c` (**782 lines**) is Linux's shared implementation for drivers whose buffers are
ordinary system pages — which is exactly virtio-gpu's case, and exactly this kernel's case. It is the
right thing to read before writing R1.

### 2.4 Dumb buffers — the three ioctls that give a framebuffer with no driver knowledge

`DRM_IOCTL_MODE_CREATE_DUMB`, `MAP_DUMB`, `DESTROY_DUMB`. `drivers/gpu/drm/drm_dumb_buffers.c` is
**151 lines** — the smallest meaningful thing in the whole subsystem. They exist so that a client with
no driver-specific knowledge can get a linear, CPU-mappable, scanout-capable buffer.

**This is the correct first buffer type for R2/R3**, and it is a genuine shortcut: a dumb buffer plus
`ADDFB2` plus `SETCRTC` is a complete, ABI-correct display path with **no render engine involved at
all**. It is also what `libdrm`'s own `modetest` uses, which makes it testable by a program we do not
write.

### 2.5 KMS — 38 ioctls and an object/property model

```
grep -E '^#define DRM_IOCTL_MODE' $L/include/uapi/drm/drm.h | wc -l     # 38
```

The model: the device exposes **objects** (CRTC, connector, encoder, plane, framebuffer, property
blob), each with a 32-bit id and a set of **properties**. Legacy KMS sets state with typed ioctls
(`SETCRTC`, `SETPLANE`, `PAGE_FLIP`, `CURSOR2`). Atomic KMS sets all of it in one
`DRM_IOCTL_MODE_ATOMIC` carrying arrays of (object id, property id, value) — which is what every modern
compositor uses, and which `DRM_CLIENT_CAP_ATOMIC` gates.

Measured cost of the KMS half of the core, by file:

| file | lines |
|---|---:|
| `drm_atomic_helper.c` | 3,794 |
| `drm_connector.c` | 3,452 |
| `drm_modes.c` | 2,776 |
| `drm_vblank.c` | 2,163 |
| `drm_atomic.c` | 1,861 |
| `drm_plane.c` | 1,795 |
| `drm_atomic_uapi.c` | 1,538 |
| `drm_probe_helper.c` | 1,329 |
| `drm_framebuffer.c` | 1,208 |
| `drm_crtc_helper.c` | 1,065 |
| `drm_property.c` | 999 |
| `drm_crtc.c` | 941 |
| `drm_edid.c` | 7,504 |
| *(+ mode_config, encoder, blend, color_mgmt, plane_helper, gem_atomic_helper, fourcc, mode_object, dumb_buffers)* | |
| **total** | **34,699** |

against the render path:

| file | lines |
|---|---:|
| `drm_syncobj.c` | 1,719 |
| `drm_gem.c` | 1,535 |
| `drm_drv.c` | 1,115 |
| `drm_prime.c` | 1,086 |
| `drm_file.c` | 996 |
| `drm_ioctl.c` | 887 |
| `drm_gem_shmem_helper.c` | 782 |
| **total** | **8,120** |

**8,120 against 34,699.** Those are Linux's numbers, not an estimate of what oscortex would write — a
from-scratch implementation serving one driver would be far smaller than either. But the **ratio** is
the finding, and it is the load-bearing fact behind §7: *the display half of the DRM ABI is roughly
four times the render half, and the compute path needs none of it.*

### 2.6 PRIME and dma-buf — buffer sharing, and the transport it needs

`DRM_IOCTL_PRIME_HANDLE_TO_FD` turns a GEM handle into a **file descriptor**. That fd is a `dma-buf`:
it can be `mmap`ed, it can be `poll`ed (readable when the implicit fence signals), it accepts
`DMA_BUF_IOCTL_SYNC` (`include/uapi/linux/dma-buf.h`, **182 lines** — the whole uAPI), and it can be
imported by a *different* DRM device with `DRM_IOCTL_PRIME_FD_TO_HANDLE`. `drivers/dma-buf/` is
**8,618 lines**.

**The blocker is not the ioctls. It is that an fd has to get from one process to another, and on this
OS nothing can.** On Linux that is `SCM_RIGHTS` over a Unix socket; `display-protocol.md` §5.2 calls it
*"the single hardest thing to retrofit"* and lists it first. This OS has no sockets, no fd passing and
no mechanism that could carry one.

**But our own protocol is where this gets fixed, and the slot is already reserved.**
`display-protocol.md` §2.5 and §5.3(1) reserved **four handle words in the verb-batch header, defined
as must-be-zero**, precisely so that a future out-of-band handle transport needs no wire-format change.
**Those four words are the fd-passing mechanism, and this document is the consumer that justifies
building it.** C1 (§5.6) is the rung that fills them.

### 2.7 Fences and events — how completion is reported

Three mechanisms, and a serious implementation needs all three eventually:

1. **`drm_syncobj`** — 12 ioctls, `drm_syncobj.c` is 1,719 lines. Binary and **timeline** semaphores.
   This is what Vulkan's `VkSemaphore` and `VkFence` map onto. `DRM_CAP_SYNCOBJ` /
   `DRM_CAP_SYNCOBJ_TIMELINE` gate them, so a first implementation may honestly answer *no* — ⚠ *but I
   do not know whether any Mesa Vulkan driver still functions with syncobj declined; RADV and ANV have
   required it for years. V1's link and V2's `vkCreateInstance` are where this is found out, and it is
   the single most likely place the compute ladder stalls.*
2. **`sync_file`** — an fd whose readiness *is* the fence (`include/uapi/linux/sync_file.h`, 113
   lines). Interoperates with `poll` and with dma-buf's implicit fences.
3. **Events read off the DRM fd.** `read(2)` on a DRM fd returns a stream of fixed-size records:
   `DRM_EVENT_VBLANK`, `DRM_EVENT_FLIP_COMPLETE`, `DRM_EVENT_CRTC_SEQUENCE`. **This is how a compositor
   learns a page flip completed**, and it is the mechanism `display-protocol.md` §3.2 refused to claim
   tearing was eliminated without.

All three want a blocking `poll`. `blocking-and-threads.md`'s `fdwait` (syscall 11) is exactly the
right primitive and is designed already — this document adds a fourth readiness kind to its §3.5 table:
*a DRM fd is ready when an event record is queued.*

### 2.8 The per-driver uAPI — the row that falsifies "one ABI, all GPUs"

Measured, per `include/uapi/drm/`:

| driver | uAPI header lines | ioctls | notes |
|---|---:|---:|---|
| **`virtgpu`** | **270** | **11** | `MAP`, `EXECBUFFER`, `GETPARAM`, `RESOURCE_CREATE`, `RESOURCE_INFO`, `TRANSFER_FROM_HOST`, `TRANSFER_TO_HOST`, `WAIT`, `GET_CAPS`, `RESOURCE_CREATE_BLOB`, `CONTEXT_INIT`. **All eleven are `DRM_RENDER_ALLOW`** |
| `panfrost` | 282 | 9 | Mali, pre-CSF |
| `msm` | 405 | 12 | Adreno |
| `nouveau` | 520 | 13 | incl. the `VM_INIT`/`VM_BIND`/`EXEC` trio added for NVK |
| `panthor` | 966 | 15 | Mali CSF |
| `amdgpu` | 1,299 | 16 | plus **53 `AMDGPU_INFO_*` sub-queries** behind one `INFO` ioctl |
| `xe` | 1,701 | 12 | the modern Intel design: `DEVICE_QUERY`, `VM_BIND`, `EXEC_QUEUE_*`, `EXEC` |
| `i915` | **3,916** | **62** | plus **59 `I915_PARAM_*`** and an open-ended extension-chain scheme |

**The ioctl count understates the difference and the header line count understates it further.** `xe`
has twelve ioctls and 1,701 lines of header because the work moved *into* the structures:
`drm_xe_vm_bind` is a page-table programming interface, `drm_xe_exec_queue_create` is a hardware
context, and `drm_xe_device_query` returns the ASIC's full topology. Serving those honestly means
having the thing they describe.

**This is the table to point at when the question "how much of almost-all-GPUs does this get us" comes
back.** Answer: the 17 core render ioctls and the 38 KMS ioctls are shared and are written once. The
row that makes a specific GPU work is that GPU's own, and behind it is that GPU's kernel driver.

### 2.9 The scorecard — every requirement against what this OS has

| requirement | status here | size of the gap |
|---|---|---|
| a character device that can be `open`ed by a reserved name | **missing** | small — `display-protocol.md` §2.1's `:` sigil and the `fileSysOpen` placement rule apply unchanged. **Do not put the branch in `fatLookup`** — that document caught a ring-3-reachable volume corruption there |
| `ioctl(fd, request, argp)` as a syscall | **missing, and it is the keystone** | moderate: a syscall, an `_IOC` decode, and a bounded copy in each direction reusing M16's two mutation-tested pointer validators. GAP-0158 |
| per-open-file handle tables (GEM) | **missing** | moderate. `fileStore`'s four-descriptor row is the shape; GEM handles need their own, larger table |
| reference-counted buffer objects | **missing, and unsound to fake** | `freeFrame` is a plain bit-clear with no refcount; `procSpaceFree` frees every present leaf unconditionally. **Two designs already want this fixed** (`display-protocol.md` D8, `blocking-and-threads.md` §4.3). It is a hard prerequisite here too |
| `mmap` of an fd at a driver offset | **missing** | large. GAP-0159 |
| fd passing between processes | **missing** | large. GAP-0160; the four reserved handle words are the slot |
| fences / `poll` / event records on `read` | **missing** | `fdwait` is designed (`blocking-and-threads.md` §3) and unbuilt. GAP-0164 |
| a virtqueue and PCI bus mastering | **missing** | `gpu.md` G0–G3. Small, and independently justified |
| write-combining / uncacheable mappings | **missing** | GAP-0071 item 1, narrowed by GAP-0165. Invisible under TCG, wrong on hardware |
| MSI/MSI-X | **missing** | needs the local APIC, untouched. Pollable for 2D (`gpu.md` §3.6); wanted for a compute queue |
| IOMMU | **missing** | **not needed in a VM.** The identity map is the whole translation layer (`gpu.md` §3.4) |
| threads, TLS, futexes | **missing** | §3.2. Large, and gated on the refcount fix |
| dynamic linking | **refused by name** (`elf.dart:1280`) | §3.2. Large |
| a hosted libc + libm | **32 symbols** | `libc-roadmap.md` L1–L9. Large |
| a C++ runtime | **nothing** | §3.2. Large, and not scoped anywhere in the project |

---

## 3. What Mesa needs from the OS before it links

### 3.1 "Unmodified" has two readings and they cost differently

**Reading A — run prebuilt Linux binaries.** Take a distribution's `libvulkan_virtio.so`, its
`libdrm.so.2`, the Vulkan loader, and load them. This requires a **Linux personality**: `ld.so` with
glibc symbol versioning, glibc's TLS model, `futex`, `clone`, `arch_prctl`, `mmap` with Linux
semantics, `openat`/`getdents64`/`statx`, a `/sys/class/drm` hierarchy for device enumeration, and
`/usr/share/vulkan/icd.d/*.json` for ICD discovery. `libc-roadmap.md` §5's conclusion applies verbatim:
this *"is not a libc port, it is a Linux personality"*, and its recommendation is never to attempt it.
**Reading A is not on any ladder in this document.**

**Reading B — build Mesa from source against an oscortex toolchain.** Unmodified *source*, our libc,
our linker. Mesa is already ported to FreeBSD, OpenBSD, Haiku, Android and Windows, so the codebase is
not Linux-only by construction; and the DRM ioctls it issues stay identical because the *ABI* is what
we implement. **Reading B is the only credible one, it is what this document means throughout, and it
should be said explicitly in the ADR so nobody later reads "unmodified" as reading A.**

Reading B has one honest cost reading A does not: Mesa's build is **meson + python3**, and neither
exists here. The port therefore also needs either a cross-build on the host (recommended: the host
builds a `.a` for `x86_64-unknown-none-elf` against our libc headers) or a hand-written build for the
subset in use. **Cross-building on the host is the right answer and it is what V1 does** — it keeps
meson and python where they already work.

### 3.2 The substrate, item by item

What Mesa's userspace needs, independent of which driver:

| | what | present here | where it is designed |
|---|---|---|---|
| **`ioctl`** | the entire DRM ABI is this one call | no | S0, §5.1 |
| **`mmap`/`munmap`/`mprotect`** | every buffer object is reached through `mmap`; `MAP_ANONYMOUS` backs the allocator; `MAP_FIXED` and `PROT_NONE` reservations are used by Mesa's own suballocators | no | S2 |
| **threads** | Mesa's shader-compile thread pool (`util/u_queue`), the disk cache thread, and per-driver submit threads. `pthread_create` must genuinely work — `blocking-and-threads.md` B6's honest stub returns `EAGAIN`, and that is correct there and **not sufficient here** | no | S4; gated on refcounted frames/page tables |
| **TLS** | `__thread` throughout; needs `%fs` base, initial-exec and global-dynamic models, `__tls_get_addr` | no | S4 |
| **futexes** | Mesa's `util/futex.h` issues `SYS_futex` directly | no | S4; `procSlotWaitKind` already reserves an `ADDR` value for exactly this |
| **`poll`/`ppoll`** | fence waits, event loops | no | `fdwait`, `blocking-and-threads.md` §3 |
| **a device namespace** | `/dev/dri/card0`, `/dev/dri/renderD128` | no | S1 |
| **a sysfs-shaped enumeration** | ⚠ libdrm's `drmGetDevices2` reads `/sys/class/drm/*/device/{vendor,device,revision,config}` on Linux. It has a separate non-Linux path, so a source port may be able to supply the PCI identity through a small OS shim instead — **this is the single most likely place a "we implement the ABI" plan discovers it also implements a filesystem** | no | S1, and ⚠ needs confirming against libdrm's source before S1 is scoped |
| **dynamic linking + `dlopen`** | the Vulkan loader `dlopen`s ICDs; the GL stack `dlopen`s DRI drivers | refused by name | S5. **Avoidable**: Mesa can be static-linked and the ICD entry point called directly. Recommended for V1–V3; unavoidable eventually |
| **a hosted libc** | stdio, full `printf`, `string.h`, `stdlib.h`, `errno`, `time`, `locale` (Mesa's shader-cache and `strtof` paths are locale-sensitive) | 32 symbols | `libc-roadmap.md` L1–L9 |
| **libm** | the shader compiler constant-folds with `expf`/`logf`/`powf`/`fmodf`/`ldexp`/`frexp` | none | `libc-roadmap.md` L6 |
| **a C++ runtime** | Mesa's Vulkan runtime and several drivers are C++17; ACO is C++20. Needs `operator new`/`delete`, `__cxa_atexit`, static init, and either exceptions with an unwinder or a `-fno-exceptions` build proven to link | **nothing, and not scoped anywhere in this project** | new. §8.2 |
| **`getrandom` / `/dev/urandom`** | device and pipeline-cache UUIDs | no | small |
| **a monotonic clock** | `clock_gettime(CLOCK_MONOTONIC)` in timeout paths | no | `libc-roadmap.md` L8; `time-and-power.md` |
| **`sysconf(_SC_NPROCESSORS_ONLN)`** | `util/u_cpu_detect.c` sizes the thread pool from it | no | trivial: return 1 |
| **environment variables** | `MESA_SHADER_CACHE_DISABLE`, `VK_ICD_FILENAMES`, driver overrides. Needed to *turn off* the things we cannot support | none (GAP-0146) | small; M19 built the hard half |

**The row to read twice is the C++ runtime.** It is the only item in this table that no document in this
project has ever scoped, it is not a libc problem, and `libc-roadmap.md`'s picolibc recommendation does
not touch it. GAP-0162 records it.

### 3.3 LLVM — the question that decides whether the compute path is tractable

| Mesa driver | needs LLVM in the guest? |
|---|---|
| **venus** (Vulkan over virtio) | **no** — ⚠ believed to be a protocol encoder with no code generator |
| **virgl** (GL over virtio) | no — ships TGSI text |
| **RADV** (AMD Vulkan) | no — ACO replaced LLVM |
| **ANV** (Intel Vulkan), **NVK** (Nvidia Vulkan) | no |
| **radeonsi** (AMD OpenGL) | **yes** |
| **lavapipe** / **llvmpipe** (software Vulkan / GL) | **yes** — it JITs |

**This kills the obvious shortcut.** The tempting first Vulkan target is **lavapipe**: a conformant
software Vulkan implementation needing no GPU and no DRM at all. It would let the whole Vulkan stack be
proved with zero driver work. **It needs LLVM** — millions of lines of C++, a JIT that requires
`mmap(PROT_EXEC)` and therefore a deliberate hole in the W^X policy ADR-0012 established. That is not a
rung; it is a second project.

**So venus is not merely the best compute target, it is close to the only one**, and its "no compiler in
the guest" property — the thing I could not confirm — is what makes it so. V0 exists to confirm it.

### 3.4 The measurement I could not make, and the command that makes it

I have **no Mesa checkout on this machine** and every statement about Mesa's size and symbol surface in
this document is unmeasured. The commands that close it, and which **should be run before V1 is
scoped**, are:

```bash
# on a Linux box with a distro Mesa installed:
nm -D -u /usr/lib/x86_64-linux-gnu/libvulkan_virtio.so | awk '{print $2}' | sort -u
nm -D -u /usr/lib/x86_64-linux-gnu/libvulkan_radeon.so | awk '{print $2}' | sort -u
nm -D -u /usr/lib/x86_64-linux-gnu/libdrm.so.2         | awk '{print $2}' | sort -u
```

Three numbers come out: the venus ICD's undefined-symbol count, the same for a real hardware driver as
a cross-check, and libdrm's. **Every cost estimate in §5's V-track is a guess until those three numbers
exist**, and a document in this project should say so rather than pick a number. The equivalent
measurement for the C++ side is whether the venus ICD has undefined `_Z*` symbols at all.

---

## 4. The membrane problem, and how this plan handles it

DCDart escalation 0004 §6 is the constraint this section answers:

> **C libraries are zombies by construction, and linking them does not fix that.** An FFI call into
> ffmpeg hands control to a region with no descriptors, no typed frames, and no self-knowledge. Every
> FFI boundary is a hole in the reflective world, and the holes are exactly where the large, useful,
> already-written software lives.

It offers three options — FFI it in, simulate it, or **describe the boundary** — and recommends the
third as the default, with the second for anything genuinely foreign.

**Mesa is the largest zombie this project will ever consider.** It is also, and this is the useful
surprise, the one with **the best-shaped boundary in the whole plan.**

### 4.1 The DRM boundary is unusually describable, and that is not luck

Compare the two boundaries this project has contemplated:

| | ffmpeg | the DRM ABI |
|---|---|---|
| shape of the boundary | **hundreds of C function signatures**, many taking pointers to structs with pointers to structs, with ownership conventions that are documented in prose | **one call**: `ioctl(fd, request, argp)` |
| how many things cross | every `av_*` symbol the program uses | **one flat POD struct per request number**, and the request number encodes the struct's exact size |
| where the definition lives | headers that change per release, with no machine-readable contract | `include/uapi/drm/*.h` — **24,265 lines of public, versioned, stability-guaranteed uAPI**, and the Linux uAPI stability rule means these structs cannot change incompatibly |
| ownership | unclear per function; ADR-0038 refuses ARC types in `@extern` signatures for exactly this reason | **there is none.** `ioctl` copies in and copies out. Nothing crosses that the kernel does not own on both sides |

**Every property that makes ffmpeg's boundary hard to describe is absent here.** The DRM ABI is a
finite set of named, sized, flat structures with no pointers-to-be-owned crossing it (the few embedded
pointers — `drm_mode_atomic`'s arrays, `drm_amdgpu_cs`'s chunk list — are explicitly copy-in). It is
the single most mechanically describable FFI surface in this project's future.

### 4.2 The proposal — descriptors generated from the uAPI headers

**Every ioctl this kernel serves carries a descriptor, and the descriptor is generated, not written.**

* A build step reads `include/uapi/drm/*.h` and emits, for each request number the kernel serves: the
  name, the direction, the payload size, and the field list (name, offset, width, signedness).
* The kernel's ioctl dispatcher consults that table to validate the request *before* dispatching:
  direction, size, and — where the descriptor knows — reserved fields that must be zero.
* The same table backs a **`drm trace` shell command** that prints, for every ioctl that crossed,
  what crossed, by field name. **That is the reflective property, and it is the thing escalation
  0004's owner-framing actually asks for**: the system knows exactly what it handed over and what it
  got back, and can say so, even though it cannot see inside Mesa.

The generator is the mechanism ADR-0038 §3 deliberately did not build (`@linkName`, `@section`, a
richer manifest) and it should not be built as a DCDart language feature — **it is a build-time table
generator in this repo**, the same category as `derive.py` and `check-font.py`, and it is subject to
CLAUDE.md rule 3 in the negative: this is not a DCDart gap.

**One honest limit.** A descriptor over the ioctl surface describes *what crosses the boundary*. It
does not describe Mesa's internal state, its threads, its heap or its shader IR. Those remain opaque.
**Describing the boundary is what escalation 0004 §6 recommends, and it is not the same as abolishing
the zombie.** This document is not claiming it is.

### 4.3 The containment — and this is where the owner's second decision pays

The stronger answer is architectural, and it falls out of keeping our own protocol:

```
   client  ──[ our verb protocol ]──▶  compositor  ──[ our verb protocol ]──▶  Mesa-hosting process
                                                                                    │
                                                                            [ DRM ioctls, described ]
                                                                                    ▼
                                                                                 kernel
```

**Mesa never runs inside the compositor and never runs inside the kernel. It runs in its own address
space, reached through our own protocol, and the only thing it touches directly is the described ioctl
boundary.** The zombie is quarantined by a page table, and *everything crossing our protocol is a
message this system defines and can describe totally*.

Three consequences worth stating:

1. **The two owner decisions are complementary, not in tension.** Adopting Wayland would have put Mesa
   *inside every client*, because Wayland's whole model is client-side rendering into client-owned
   buffers — the zombie would be everywhere. Keeping our protocol keeps it in one place.
2. **The conventional objection is real and should be answered rather than dismissed.** Mesa, DRM and
   dma-buf being "a package deal" is a claim about *Wayland's* buffer model — clients render, clients
   hand over dma-bufs, the compositor scans out. Our protocol's client hands over *verbs*. The place
   where a dma-buf genuinely must cross is compositor↔Mesa-process, which is **one boundary, inside the
   system's own trust domain**, not one per client. `display-protocol.md`'s four reserved handle words
   are exactly wide enough.
3. **The cost is a process hop per frame.** For a compositor at 60 Hz that is 60 round trips a second
   through our own protocol, which is nothing. For a *compute* client dispatching thousands of small
   kernels it would be ruinous — and §7 is why the compute path does **not** go through the compositor
   and links Mesa in-process instead. **Different containment for different traffic, decided on
   measured traffic shape, is the right answer and should be stated as a rule rather than discovered.**

### 4.4 Recommendation, stated as a decision to ratify

* **Display path:** Mesa in a separate address space, behind our protocol. Descriptor-described DRM
  boundary. Option 3 (describe) plus process isolation.
* **Compute path:** Mesa linked in-process with the compute client, because the traffic shape forbids a
  hop. Descriptor-described DRM boundary, no isolation. Option 3 alone, and the zombie is genuinely
  inside the client's address space — **which is acceptable precisely because the client is the thing
  that asked for it**, and is not acceptable for the compositor, which everything depends on.
* **Never:** Mesa in the kernel. This is not a real proposal, it is written down so it never becomes
  one.

---

## 5. The ladder

Four tracks. **S** (substrate) and **R** (the DRM ABI) are sequential; **V** (Vulkan compute) forks off
R and needs no compositor; **C** (compositor bridge) rejoins at the end. Every rung is written to this
repo's rules for a derived expectation, restated because they are why M7–M19's harnesses are worth
anything:

* compute the expectation from a source the kernel does not control — here that is **Linux's own uAPI
  headers**, **QEMU's monitor**, and **`libdrm`'s own tools once they run** — transcribed into the
  harness and asserted against the kernel, never imported from it;
* **guard against a vacuous pass.** Every criterion below names its own anti-vacuity check;
* every rung has a **negative control** — a build that must fail;
* structural checks before boot checks;
* `core/scripts/verify-freestanding.sh` on every object.

### 5.0 The dependency graph, and what it inherits

```
  gpu.md  G0 ─ G1 ─ G2 ─ G3 ─ G4          (PCI caps, bus master, virtqueue, a resource on screen)
                            │
  S0 ─ S1 ─ S2 ─ S3         │             (ioctl, device node, mmap, address space)
   │         │              │
   └────┬────┴──────────────┘
        ▼
       R0 ─ R1 ─ R2 ─ R3 ─ R4 ─ R5 ─ R6 ─ R7
                      │      │     │
                      │      └─────┴──── V0 ─ V1 ─ V2 ─ V3 ─ V4   (needs S4: threads)
                      │
                      └───────────────── C0 ─ C1 ─ C2             (needs display D3–D5)
```

**`gpu.md`'s G-ladder is not superseded and must be built first.** G0–G3 build the PCI capability walk,
the bus-master enable and the virtqueue; G4 puts a resource on the screen. **Those are the transport;
this document's R-ladder is the ABI over the transport.** Nothing here replaces them and every claim
`gpu.md` §3 makes about what the transport costs still holds.

**S4 (threads) and S5 (dynamic linking) are large enough that they are named here and specified
elsewhere.** S4 is `blocking-and-threads.md` §4.3 plus a futex plus TLS, and it is hard-gated on
reference-counted frames and page tables. S5 is `exec-format.md` and GAP-0091. Both are prerequisites,
neither is this document's to design.

---

### S0 — `ioctl` exists, and a struct crosses it intact

**Blocked on: nothing.** This is the keystone and it has nothing to do with graphics.

A new syscall `ioctl(fd, request, argp)`. Decode `_IOC_DIR`, `_IOC_SIZE`, `_IOC_TYPE` and `_IOC_NR`
from `request`. Copy `_IOC_SIZE` bytes in for `_IOC_WRITE`, copy them out for `_IOC_READ`, both for
`_IOWR`, through M16's existing mutation-tested pointer validators. A request whose size exceeds a
fixed bound is **refused**, not truncated. Take the next number from the syscall registry
(`design/README.md` fix #2 — **create the registry in this unit if it still does not exist**; syscall
11 is already claimed twice).

*Binary:* a C test program issues an `_IOWR('d', 0x00, struct drm_version)`-shaped call against a test
device; the kernel prints the decoded direction, size, type and number; the harness requires all four
to equal values **computed by the harness from the `_IOC` macros transcribed from
`include/uapi/asm-generic/ioctl.h`**, not read from the kernel. A second call with `_IOC_SIZE` one byte
larger must be refused and the refusal printed.
*Anti-vacuity:* the harness fails if the printed size is zero, and fails if the in-direction and
out-direction byte counts are equal for a call that is `_IOC_WRITE` only.
*Negative control:* a build that ignores `_IOC_DIR` and always copies both ways must fail the
write-only case; a build that trusts `argp` without validation must fail `m9-ring3`'s kernel-pointer
payload, re-run against `ioctl`.

---

### S1 — a device namespace, and `open(":DRI0")` returns a descriptor that is not a file

**Blocked on: S0.**

A reserved-name branch in **`fileSysOpen` (`file.dart:1360`)**, after the pointer-validated bounce-buffer
copy and before `fatParseAt`. **Not in `fatLookup`** — `display-protocol.md` §2.1 caught a
ring-3-reachable volume corruption there and the reason is unchanged. Names carry the `:` sigil, which
`fatNameByteBad` already forbids in disk names, so the namespaces are disjoint by construction.

Two names: `:DRI0` (primary) and `:DRIR0` (render). ⚠ *Whether Mesa can be told those names instead of
`/dev/dri/card0` depends on libdrm's device-open path and on `VK_ICD_FILENAMES`-style overrides; it is
the second thing V0 must check.*

*Binary:* `open(":DRI0")` returns a descriptor; `read` on it returns a refusal distinct from every FAT
refusal; `ioctl` on it reaches the DRM dispatcher and prints so; `open(":DRI9")` is refused; and
`open("A.TXT")` still opens the file — the harness re-runs `m15-fileio` and `m16-filewrite` unchanged.
*Anti-vacuity:* the harness fails if the device descriptor number is the same value a FAT open would
have returned for the first open.
*Negative control:* the branch placed in `fatLookup` instead must fail — the harness runs
`open(":DRI0", O_WRITE)` and requires the volume hash afterwards to be **unchanged**, which is the
mutation that would have shipped the corruption.

---

### S2 — `mmap` of a descriptor at a driver-chosen offset

**Blocked on: S1, and on the address-space work (S3) if the mapping is large.**

`mmap(addr, len, prot, flags, fd, offset)`, restricted from the start: `MAP_SHARED` on a device
descriptor only, `MAP_ANONYMOUS` for the allocator, no `MAP_FIXED` in the first cut, and the offset
interpreted by the *device*, not as a file offset. The driver returns a token from its own ioctl and
`mmap` resolves it.

**This is the rung that forces reference-counted frames**, because a mapped buffer object outlives the
handle that created it and a second process may map the same object. `freeFrame`'s plain bit-clear and
`procSpaceFree`'s unconditional leaf walk are both wrong the moment this exists.

*Binary:* the kernel creates a test buffer object of a derived size; a ring-3 program maps it, writes a
derived byte pattern, and `munmap`s; the harness dumps the **guest physical frames** the kernel printed
with `xp/<n>xw` and requires the pattern — `m5-pci`'s mechanism, at the backing store rather than a BAR.
Then a second process maps the same object and reads the pattern back.
*Anti-vacuity:* the harness fails if the derived pattern is the frame's zero value, and fails if fewer
than the derived number of frames were printed.
*Negative control:* a build in which the first process exits before the second maps must leave
`pmmMetaErrors` at zero and the allocator free count at baseline — **this is `display-protocol.md`
D8's control and it is the one that proves the refcount, not the mapping.**

---

### S3 — the ring-3 address space is bigger than a buffer

**Blocked on: nothing. Independently wanted by three documents.**

The 2 MiB window at `[0x10000000, 0x10200000)` cannot hold a 1,920,000-byte framebuffer plus a program
plus a heap plus a stack, and it certainly cannot hold Mesa. `display-protocol.md` §1.2's
recommendation applies unchanged: **split `vmProgEnd` into a load bound and a new `vmUserEnd`** rather
than widening it, because 47 golden window-address occurrences depend on the current value. `vm.dart`'s
PDPT entries 1 and 2 are unwritten, so `[1 GiB, 3 GiB)` is unclaimed.

*Binary:* a program `sbrk`s past 2 MiB and touches the last page; the harness requires the mapping to
exist by reading the leaf PTE the kernel prints and requires the touched page's content back out of
guest memory; the five byte-exact goldens are re-derived and the harness asserts **which** moved and by
how many bytes, as every previous window change did.
*Anti-vacuity:* the harness fails if the highest touched address is below the old `vmProgEnd`.
*Negative control:* a build with the load bound also widened must fail `m10-elf`'s load-address
assertion, which is what proves the split is a split.

---

### R0 — `DRM_IOCTL_VERSION` answers, and a real uAPI struct crosses intact

**Blocked on: S1.** This is the rung that makes the ABI real and it needs no GPU.

Serve `DRM_IOCTL_VERSION` (`_IOWR('d', 0x00, struct drm_version)`) on `:DRIR0`. The struct's
two-pass convention is the point of this rung: **the first call has `name_len`/`date_len`/`desc_len`
zero and the kernel fills in the lengths; the second call supplies buffers and the kernel fills them.**
A driver that gets this wrong looks correct to a naive test and fails against real libdrm.

Also serve `DRM_IOCTL_GET_CAP` for `DRM_CAP_PRIME` and `DRM_CAP_DUMB_BUFFER`, and
`DRM_IOCTL_SET_CLIENT_CAP` refusing everything it does not implement.

*Binary:* a C test program performs both `VERSION` passes and prints the returned lengths and strings.
The harness computes `sizeof(struct drm_version)` and the request number **by transcribing
`include/uapi/drm/drm.h` into the harness** and requires the kernel's printed request number to match.
It requires pass 1's lengths to be non-zero with the buffers untouched, and pass 2's strings to be
exactly the driver name the kernel was built with. `GET_CAP` for an unknown capability must be refused,
not answered zero.
*Anti-vacuity:* the harness fails if pass 1 wrote any byte into the supplied buffers.
*Negative control:* a build that fills the strings on pass 1 must fail; a build that hardcodes the
request number rather than decoding `_IOC` must fail when the harness issues the same call with a
deliberately wrong size.

---

### R1 — GEM handles: created, closed, and counted

**Blocked on: R0, and on `gpu.md` G3 (a working virtqueue).**

`DRM_IOCTL_VIRTGPU_RESOURCE_CREATE` creates a resource and returns a **handle** plus a `res_handle`.
A per-open-file handle table maps handle → object. `DRM_IOCTL_GEM_CLOSE` drops one reference.
`DRM_IOCTL_VIRTGPU_RESOURCE_INFO` reports back. Closing the file drops every handle it holds.

*Binary:* the kernel prints, per operation, the handle, the object's reference count and the allocator's
free-frame count. The harness requires: creating N resources of a derived size consumes exactly the
derived number of frames; closing all N returns the free count to **exactly** its starting value;
closing the *descriptor* without closing the handles does the same.
*Anti-vacuity:* the harness fails if the derived resource count is zero or if the free-frame delta is
zero.
*Negative control:* a build in which `GEM_CLOSE` frees unconditionally rather than decrementing must
fail a sequence that creates one object, exports two handles to it, and closes one — the free count
must not move on the first close.

---

### R2 — a GEM object is mapped and the CPU's writes are visible to the device

**Blocked on: R1, S2.**

`DRM_IOCTL_VIRTGPU_MAP` returns an offset; `mmap` on the DRM fd at that offset maps the object's pages;
the program writes; `DRM_IOCTL_VIRTGPU_TRANSFER_TO_HOST` moves the rectangle.

*Binary:* the same derived-colour read-back as `gpu.md` G4, but through the ABI rather than through
kernel-internal calls: the harness dumps the guest backing store at the address the kernel printed and
requires the derived colour, then reruns with a second derived colour passed as a program argument.
Every ioctl's return value is printed and must be success.
*Anti-vacuity:* the harness fails if the expected colour equals the background, and fails if the
mapped length is zero.
*Negative control:* a build in which `MAP` returns a fixed offset rather than a per-object one must
fail a test that maps two objects and writes a different pattern to each.

---

### R3 — KMS: a dumb buffer is scanned out through the Linux ABI

**Blocked on: R2, and `gpu.md` G4.** This is the rung where the display path becomes ABI-shaped.

`DRM_IOCTL_MODE_GETRESOURCES` → `GETCONNECTOR` → `GETENCODER` → `GETCRTC`;
`DRM_IOCTL_MODE_CREATE_DUMB` + `MAP_DUMB`; `DRM_IOCTL_MODE_ADDFB2` with
`DRM_FORMAT_XRGB8888`; `DRM_IOCTL_MODE_SETCRTC`. Legacy KMS only — **no atomic** (that is R7), and
`DRM_CLIENT_CAP_ATOMIC` is refused.

The two-pass counted-array convention appears again and is the same trap as R0's:
`GETRESOURCES` and `GETCONNECTOR` are called first with zero counts to learn the sizes.

*Binary:* the harness launches QEMU with `-device virtio-vga,xres=W,yres=H` where W and H are derived
values that are **neither QEMU's defaults (1280×800), nor the kernel's compiled-in mode (800×600), nor
the DRM fallback (1024×768)**, and requires the connector's reported mode to be exactly W×H — the same
unfakeable mechanism `gpu.md` G3 uses. Then the derived-colour read-back from the dumb buffer's guest
pages.
*Anti-vacuity:* the harness fails if `count_connectors` is zero, and fails if pass 1 wrote into the
supplied arrays.
*Negative control:* `SETCRTC` with a framebuffer id that was never added must be refused with the
`EINVAL`-equivalent and printed; and the boot with `ADDFB2` omitted must fail while every other ioctl
still succeeds.

---

### R4 — `EXECBUFFER`, and a command stream the kernel does not understand reaches the host

**Blocked on: R2.** **This is the rung the whole decision is for.**

`DRM_IOCTL_VIRTGPU_EXECBUFFER` takes an opaque command buffer and a list of buffer handles and pushes
it into the virtqueue as `VIRTIO_GPU_CMD_SUBMIT_3D`. **The kernel does not parse it.** That is the
entire point: the guest kernel becomes a transport, and Mesa becomes the thing that knows what the
bytes mean. `DRM_IOCTL_VIRTGPU_GETPARAM` reports `VIRTGPU_PARAM_3D_FEATURES`,
`VIRTGPU_PARAM_CONTEXT_INIT`, `VIRTGPU_PARAM_RESOURCE_BLOB`, `VIRTGPU_PARAM_HOST_VISIBLE`;
`DRM_IOCTL_VIRTGPU_GET_CAPS` returns the capset; `DRM_IOCTL_VIRTGPU_CONTEXT_INIT` selects it;
`DRM_IOCTL_VIRTGPU_WAIT` blocks on a resource.

**This rung cannot be completed on the dev machine.** §6.3 and GAP-0163: the local QEMU has no
virgl/venus device compiled in and no EGL display backend, so `GET_CAPS` will report zero capsets
exactly as `gpu.md` §3.8 measured. **R4 needs a Linux host**, and saying so is part of the rung.

*Binary:* on a host QEMU built with virglrenderer, `-device virtio-gpu-gl-pci`: the kernel prints the
capset ids `GET_CAPS` returned and the harness requires the set to be **non-empty and to equal what the
host's `virglrenderer` reports**, derived from the QEMU command line and the host's own capability
dump, never from the kernel. Then one hand-built `EXECBUFFER` — a virgl `CLEAR` against a resource — and
the harness requires the cleared colour to appear in a `TRANSFER_FROM_HOST`ed read-back.
*Anti-vacuity:* the harness fails if the capset list is empty, and fails if the cleared colour equals
the buffer's prior contents.
*Negative control:* the same boot on this Mac's QEMU (no virgl) must report **zero** capsets and must
print a refusal rather than proceeding — which makes the platform requirement itself a tested claim.

---

### R5 — PRIME: a buffer becomes an fd, and the fd crosses a process boundary

**Blocked on: R2, and on a handle transport (§2.6).**

`DRM_IOCTL_PRIME_HANDLE_TO_FD` and `PRIME_FD_TO_HANDLE`. The fd is passed to another process through
the four reserved handle words in the verb-batch header (`display-protocol.md` §2.5), which this rung
is the first consumer of.

*Binary:* process A creates a resource, writes a derived pattern, exports it, and passes the handle;
process B imports it and reads the pattern back and prints it; the harness requires the pattern, and
requires the free-frame count to be **unchanged** after A exits while B still holds the import.
*Anti-vacuity:* the harness fails if A and B report the same handle number (which would mean the
transport passed a number, not a reference).
*Negative control:* a build in which the export does not take a reference must fail — A's exit must
free the frames and B's read-back must not match.

---

### R6 — fences and events: `read()` on the DRM fd returns records, and `fdwait` blocks on it

**Blocked on: R3, and on `blocking-and-threads.md` B1–B3 (`fdwait`).**

`DRM_IOCTL_MODE_PAGE_FLIP` with `DRM_MODE_PAGE_FLIP_EVENT`; the completion arrives as a
`struct drm_event_vblank` with `type = DRM_EVENT_FLIP_COMPLETE` read off the fd. A DRM fd becomes a
fourth readiness kind in `fdwait`'s §3.5 table.

*Binary:* the program flips, `fdwait`s on the DRM descriptor, reads the record, and prints its `type`,
`sequence` and `user_data`. The harness requires `type == DRM_EVENT_FLIP_COMPLETE` (transcribed from
`drm.h`), requires `user_data` to equal a derived cookie the program supplied, and requires the process
to have been genuinely BLOCKED — `procHeadIdle` must have grown and `procSlotPreempts` must be **zero**
across the wait, which is `blocking-and-threads.md` B1's anti-spin guard applied here.
*Anti-vacuity:* the harness fails if the record length read is zero.
*Negative control:* a build that returns the event without ever going BLOCKED must fail the
`procHeadIdle` assertion.

---

### R7 — atomic modesetting

**Blocked on: R3, R6.** The last display rung, and the one every modern compositor needs.

`DRM_CLIENT_CAP_ATOMIC` accepted; `DRM_IOCTL_MODE_ATOMIC` with object/property/value arrays;
`DRM_IOCTL_MODE_CREATEPROPBLOB` for the mode blob; `DRM_MODE_ATOMIC_TEST_ONLY` must genuinely validate
without committing; `DRM_IOCTL_MODE_OBJ_GETPROPERTIES` enumerates.

*Binary:* a `TEST_ONLY` commit of a legal configuration must succeed **and change nothing** — the
harness reads the scanout state back before and after and requires it identical; the same commit
without `TEST_ONLY` must change it; and an illegal configuration (a plane larger than the CRTC) must be
refused by `TEST_ONLY` **and** by the real commit, with the same error.
*Anti-vacuity:* the harness fails if the before-state and the legal-commit after-state are equal.
*Negative control:* a build in which `TEST_ONLY` commits must fail the first assertion — which is the
whole reason `TEST_ONLY` exists and the thing an implementation is most likely to stub.

---

### V0 — Mesa is measured, and the compute plan stops being a guess

**Blocked on: nothing. No kernel work. Costs a day.**

On a Linux host: check out Mesa, build the **venus** Vulkan driver, and produce four numbers.

1. `nm -D -u` on the built venus ICD → the undefined-symbol set, split into libc, libm, C++ runtime and
   pthread.
2. Whether the ICD has any undefined `_Z*` symbols at all → **does the compute path need a C++
   runtime?**
3. Whether venus links any NIR/compiler object → **confirm or refute §1.3's ⚠**, which is the
   assumption the whole V-track rests on.
4. The same three for `libdrm` alone, as the §8.3 first-C-library candidate.

*Binary:* the four numbers are written into this document as a table, replacing the ⚠ in §3.4, and the
symbol set is committed as `core/docs/design/data/venus-undefined.txt` so later rungs derive against a
file rather than a memory. The harness for V1 reads that file.
*Anti-vacuity:* the recorded symbol list must be non-empty and must contain at least `memcpy` and
`malloc`, which any C object needs — an empty list means `nm` failed, which is exactly the vacuous-pass
shape GAP-0155 caught in the freestanding checker.
*Negative control:* the same command against a deliberately stripped object must produce a different
(smaller) list, proving the measurement is reading the object and not a cache.

---

### V1 — the venus ICD links against oscortex's libc, and does not run

**Blocked on: V0, and on `libc-roadmap.md`'s ladder reaching whatever V0 measured.**

Cross-build venus on the host for `x86_64-unknown-none-elf` against oscortex's libc headers, link it
statically into a test program with the ICD entry point called directly (**no `dlopen`** — S5 is not a
prerequisite for this rung and should not be made one). Link only. Do not run.

*Binary:* the link produces an executable with **zero undefined symbols outside the declared set**, and
`core/scripts/verify-freestanding.sh` passes on it against a manifest generated from V0's recorded
list. The harness additionally requires the executable's `.text` size and compares it against the ring-3
window bound from S3 — **and refuses if it does not fit**, because discovering that at load time is
`exec-format.md`'s recorded failure mode.
*Anti-vacuity:* the harness fails if the declared manifest is empty, and fails if the linked size is
smaller than V0's recorded object size.
*Negative control:* the same link with one libc symbol removed must fail with that symbol named — which
is what proves the manifest is being checked rather than trusted.

---

### V2 — `vkCreateInstance` succeeds and `vkEnumeratePhysicalDevices` returns the GPU

**Blocked on: V1, R4, S4 (threads).** **This is the rung most likely to reveal an unbudgeted
requirement**, and it should be scoped with that expectation.

*Binary:* the program prints `VkPhysicalDeviceProperties.deviceName`, `apiVersion`,
`vendorID`/`deviceID` and the queue-family count. The harness requires `deviceName` to equal what the
**host's** `vulkaninfo` reports for the device venus is forwarding to — derived from the host, not from
the guest — and requires at least one queue family with `VK_QUEUE_COMPUTE_BIT`.
*Anti-vacuity:* the harness fails if the device count is zero or the name is empty.
*Negative control:* the same boot with the DRM render node absent must return a device count of zero
and must not crash — a Vulkan loader that finds no ICD is a defined, testable state.

---

### V3 — a compute shader dispatches and the answer is right

**Blocked on: V2.** **This is the first moment "the AI machine" is a measured claim.**

A SPIR-V compute shader that reads an input buffer, does arithmetic with a derived constant, and writes
an output buffer. `vkCreateComputePipeline`, `vkCmdDispatch`, a fence, a mapped readback.

*Binary:* the harness generates the input buffer and the expected output **on the host, in Python**,
from a derived seed; the program prints a checksum of the output buffer; the harness requires the exact
checksum. Run twice with different seeds.
*Anti-vacuity:* the harness fails if the expected output equals the input, and fails if the expected
checksum is zero.
*Negative control:* a build in which the fence is not waited on before the readback must fail at least
one of the two seeds — and if it never fails, **that is itself a finding to record**, because it means
the host is completing synchronously and the fence is not being tested at all.

---

### V4 — compute is a number

**Blocked on: V3.**

A matrix multiply of a derived size, timed on the guest's monotonic clock, and the same multiply timed
on the host.

*Binary:* the guest's achieved rate is printed and the harness requires it to be within a derived factor
of the host's own — the factor is stated by the design, not a range, and if the honest factor is 5× that
is what gets written down. `fatMetaReads`/`fatMetaHits` set the precedent: **a performance claim in
this repo is a number in a golden, or it is not a claim.**
*Anti-vacuity:* the harness fails if the elapsed time is zero ticks, which is what a clock that does not
advance looks like.
*Negative control:* the same program with the dispatch removed must produce a wall time below the
derived floor, proving the measurement times the GPU and not the setup.

---

### C0 — the compositor's composed buffer is a GEM object

**Blocked on: R2, and display `D4`.** This executes `gpu.md` §4.3's one actionable decision.

The compositor's composed buffer stops being `sbrk` memory and becomes a kernel-allocated, page-aligned
region whose physical frames the kernel tracks — which, as `gpu.md` §4.3 established, is *already*
satisfiable through `vmProgLeaf`, so this rung is mostly about saying it out loud in code.

*Binary:* display D4's pixel read-back passes unchanged in form, at the GEM object's frames rather than
at a `sbrk` range; and the kernel prints the object's frame list, which the harness requires to have the
derived length.
*Negative control:* a build that leaves the buffer in `sbrk` memory must fail the frame-list assertion
while still passing the pixel read-back — which is what proves the assertion measures the allocation and
not the drawing.

---

### C1 — a buffer handle crosses our protocol

**Blocked on: C0, R5.** The four reserved handle words stop being reserved.

*Binary:* display D8's zero-copy criterion, with the copied-bytes counter dropping to zero for the
client→compositor step, and the handle words carrying a real reference.
*Negative control:* D8's own control — the client exits first, the compositor keeps drawing,
`pmmMetaErrors` stays zero and the free count stays at baseline.

---

### C2 — a Mesa-rendered client is composited

**Blocked on: C1, R4, and the Mesa-hosting process of §4.3.**

*Binary:* the composited frame contains a rectangle whose contents were produced by a GL or Vulkan
draw on the host, verified by the same derived-colour read-back, with the colour supplied as a program
argument and the boot repeated with a second colour.
*Negative control:* the same boot with the Mesa process not started must produce the background colour
in that rectangle and must print a refusal, not a blank.

---

### Not on the ladder, and why

| | why it has no rung |
|---|---|
| **an amdgpu / i915 / xe / nouveau kernel driver** | §1.1 and `gpu.md` §1. The ABI is defined; the driver behind it is not reachable and firmware is not obtainable. **DRM native context (§1.3) is how those GPUs get used, and it needs none of this** |
| **lavapipe / llvmpipe** | §3.3 — requires LLVM in the guest. A second project |
| **`DRM_IOCTL_MODE_CREATE_LEASE` and friends** | multi-seat. Nothing wants it |
| **`drm_edid`** | 7,504 lines to parse a monitor's capabilities. `GET_DISPLAY_INFO` already tells us the mode on virtio-gpu (`gpu.md` §4.2). Wanted only on real hardware, which is not reachable |
| **the legacy pre-KMS core ioctls** (`ADD_MAP`, `AGP_*`, `SG_*`, `ADD_CTX`, SAREA) | modern userspace does not issue them. Refuse with `EINVAL` |
| **`DRM_IOCTL_GEM_FLINK` / `GEM_OPEN`** | the pre-PRIME global-name sharing mechanism. `DRM_AUTH`-gated, superseded, and a security footgun. Refuse |
| **running prebuilt Linux Mesa binaries** | §3.1 reading A. A Linux personality, which `libc-roadmap.md` §5 recommends never attempting |

---

## 6. On virtio-gpu as the first rung — the position

**I agree, without reservation, and more strongly than `gpu.md` did.** Three reasons, of which the
third is new and is the strongest.

### 6.1 It is the smallest ABI, measured

**11 ioctls, 270 header lines, and all eleven are `DRM_RENDER_ALLOW`** (§2.8) — the smallest per-driver
uAPI of any modern DRM driver in the tree, by a wide margin against amdgpu's 16-plus-53-subqueries and
i915's 62. The Linux driver behind it is **5,700 lines across 16 files**, of which
`virtgpu_ioctl.c` is 735 and `virtgpu_vq.c` is 1,304. Against amdgpu's ~1.2 million non-header lines,
this is not a smaller version of the same problem — it is a different problem.

### 6.2 It runs under QEMU, so every rung has an exit criterion

`gpu.md` §2.3 rejected Intel modesetting on precisely this ground and the argument is unchanged: *"there
is no way to write a binary exit criterion for this milestone."* Every rung R0–R3 above has one, because
QEMU's monitor and QEMU's command line are a source of truth the kernel does not control.

### 6.3 It is the only driver whose ABI, once served, gives access to *other vendors' hardware*

This is the reason it is not merely the first rung but the **load-bearing** one. Serving virtio-gpu's
eleven ioctls plus `CONTEXT_INIT` and `RESOURCE_CREATE_BLOB` gives, in one implementation:

* **venus** → the host's Vulkan, whatever GPU that is (§1.3);
* **virgl** → the host's OpenGL;
* **DRM native context** → the host's *real vendor driver*, with the guest running radeonsi/RADV/ANV.

**One driver, every vendor, through the hypervisor.** No other DRM driver in the tree has that property,
and it is the closest thing to the owner's stated goal that is actually reachable.

**The cost, stated plainly, and it is not small.** *Everything in this section is true in a virtual
machine and false on bare metal.* And **the dev machine cannot exercise any of it**: measured on this
Mac, `qemu-system-x86_64 -device help | grep virtio-gpu` lists only `virtio-gpu-device`,
`virtio-gpu-pci` and `virtio-vga` — **no `virtio-gpu-gl-pci`, no `vhost-user-gpu`** — and
`-display help` offers `none`, `curses`, `cocoa` and `dbus`, none of them EGL-capable. **Every rung from
R4 onward requires a Linux host with a QEMU built against virglrenderer.** That host does not need a
discrete GPU — a Linux host's own llvmpipe would do — but it does need to be Linux. GAP-0163.

### 6.4 What I would argue against, if someone proposed it

**A `vgem`-style software-only DRM device as rung zero.** It is tempting: `drivers/gpu/drm/vgem` is 62
uAPI lines, it needs no hardware, and it would exercise GEM and PRIME with no virtqueue at all. I would
**not** take it, for the same reason `gpu.md` refused a G-ladder for Intel: **there would be nothing on
the other side to disagree with us.** A vgem-shaped test can only assert that our implementation matches
our own expectations. virtio-gpu's exit criteria are worth having precisely because QEMU is a second,
independent implementation that will reject a wrong struct. *(If R0 needs a device before G3's virtqueue
exists, serving `DRM_IOCTL_VERSION` from a stub device is fine — that is R0 as written, and it is a
scaffold, not a rung.)*

---

## 7. Compute is not display, and the difference is larger than expected

### 7.1 What the compute path needs that the display path does not

| | compute | display |
|---|---|---|
| **node** | render node (`renderD128`) — **no master, no authentication** | primary node, master, KMS |
| **core ioctls** | **17** `DRM_RENDER_ALLOW`, of which **5** if syncobj is declined | those plus **38** `MODE_*` |
| **core code, Linux's own** | **8,120 lines** | **34,699 lines** |
| **needs a connector, encoder, CRTC, mode, EDID, vblank** | **no** | yes, all of it |
| **needs a compositor** | **no** | yes |
| **needs the display protocol** | **no** | yes |
| **needs threads** | **yes, genuinely** — Mesa's submit and cache threads | yes |
| **needs a big address space** | **yes, and more of it** — model weights, not framebuffers | yes |
| **needs `mmap`** | yes | yes |
| **needs fences** | **yes, and this is the sharp difference** — a dispatch you cannot wait on is useless, whereas a display path can poll a used ring | polls acceptably at first |
| **needs fd passing** | **no** — a compute client owns its buffers | yes, for zero-copy clients |

**The headline: the compute path skips the entire KMS surface and the entire compositor, and adds
exactly one hard requirement the display path can defer — real fences.**

### 7.2 Can it proceed independently of the compositor? Yes, and it should

**Yes.** The V-track's dependencies are S0–S4, R0–R2, R4 — and **not** R3, R5, R6, R7, and **not** any
D-rung or C-rung. A compute-only oscortex that can run a Vulkan matmul while its display is still the
800×600 dumb framebuffer console from M5 is a coherent, reachable, and genuinely useful system.

**And it should proceed independently, for a reason beyond scheduling.** The display path is entangled
with three other unbuilt designs — the display protocol, the input queue, blocking — each with its own
open questions. The compute path is entangled with the substrate only. **Given that the owner's stated
priority is the compute path, the ladder should be walked as S0→S1→S2→S3→R0→R1→R2→S4→R4→V-track, and
the KMS rungs R3/R6/R7 should be taken when the compositor is ready for them, not before.**

### 7.3 On Vulkan compute as the portable target — agreed, with one correction

Vulkan compute is the right cross-vendor target and the brief's reasoning is correct: CUDA is
Nvidia-proprietary and would be the hardest possible start; ROCm is AMD-only and additionally requires
`amdkfd`, a *second* uAPI beside `amdgpu` (measured: `drivers/gpu/drm/amd/amdkfd` is 52,993 lines per
`gpu.md` §1.3).

**The correction is about what portability means here.** Vulkan is portable *across GPUs*; it is not
portable *across the absence of a driver*. Under this plan, every Vulkan device oscortex sees is the
host's, forwarded by venus. **So what the compute path buys is not "our Vulkan runs on any GPU" — it is
"our Vulkan runs on whatever GPU the host has."** That is still the right target and still the right
API, but the portability is the hypervisor's, not ours, and the ADR should say so.

---

## 8. Risks, and what I think is infeasible as scoped

### 8.1 The largest risk is that the substrate is the project and the GPU is the garnish

Add up what §3.2 requires and compare it against what this kernel is: **10 syscalls, 32 libc symbols,
4 processes, 4 descriptors each, 2 MiB address spaces, no threads, no `mmap`, no `ioctl`, no dynamic
linking, no C++.** Threads alone are gated on reference-counting the frame allocator and the page
tables — a change `blocking-and-threads.md` §4.3 calls out as unsound to skip and which touches
`freeFrame`, `procSpaceFree` and every harness that asserts the free count.

**Every one of those items is a milestone-sized piece of work, and none of them is graphics.** The
project has shipped twenty milestones. This is not twenty more, but it is not two either.

**My honest estimate, and I would rather be wrong loudly than vague:** at the measured cadence of
`design/README.md` (3–4 milestones per day with ~3 agents when integration keeps up, and integration
has been the throttle), **S0–S3 plus R0–R3 is a few weeks of work.** S4 (threads + TLS + futex, with
the refcount prerequisite) plus S5 (dynamic linking) plus `libc-roadmap.md` L1–L9 plus a C++ runtime is
**not weeks.** Calling it *"months at best, and a year is a defensible number"* is the most honest
thing I can say, and the reason the range is that wide is §8.4.

### 8.2 The C++ runtime is unscoped and nobody has noticed

`libc-roadmap.md` is 1,518 lines about the C library and does not mention C++ once. Mesa's Vulkan
runtime and several of its drivers are C++17; ACO is C++20. A C++ runtime needs `operator new`/`delete`,
`__cxa_atexit` and static-init ordering, RTTI unless every object is built `-fno-rtti`, and either
exception support (which means an unwinder, `.eh_frame`, and a personality routine) or a proof that the
whole build links `-fno-exceptions`. ⚠ *Whether Mesa's venus path can be built entirely
`-fno-exceptions -fno-rtti` is exactly what V0 measures, and it is the difference between "a few hundred
lines of glue" and "port libc++abi".*

**This is the single largest unbudgeted item in the plan.** GAP-0162.

### 8.3 Mesa must not be the first C library this OS links

The brief's own observation is the sharpest risk in it: *reuse in this project is currently near zero,
and the OS has never linked a real C library.* Mesa would be, by a very large margin, the largest
codebase this toolchain has ever been pointed at, linked by a libc that has never been linked against
anything, on an ELF loader that refuses `ET_DYN`.

**The recommendation is concrete: `libdrm` is the right first C library, and it is on the critical path
anyway.** It is small ⚠ *(not measured — V0 measures it)*, it is almost entirely `ioctl` wrappers and
struct marshalling, it needs no threads beyond atomics, no C++ and no libm, and — decisively — **it is
the thing that tells you whether your DRM ABI is right.** `libdrm`'s own `modetest` and `drmdevice`
tools are a conformance suite for R0–R3 written by somebody else, which is exactly the kind of
independent expectation this repo's exit criteria are built on. **Port libdrm at R0; it is a rung's
worth of work and it de-risks everything after it.**

### 8.4 What I think is infeasible as scoped, stated plainly

| | verdict |
|---|---|
| **S0–S3, R0–R3** (`ioctl`, device node, `mmap`, bigger address space; DRM version/GEM/dumb buffers/KMS on virtio-gpu) | **Feasible, and comparable to M14 in difficulty.** This is a real milestone ladder and agents can walk it |
| **libdrm ported and `modetest` running** | **Feasible**, and should be pulled earlier than instinct suggests |
| **R4 (`EXECBUFFER`) and the V-track** | **Feasible in principle, blocked in practice on two things that are not code**: a Linux host with a virgl-capable QEMU (GAP-0163), and the substrate of §8.1. I would not commit a date |
| **S4 — threads, TLS, futexes, with refcounted frames and page tables underneath** | **Feasible, and it is the hinge.** Everything above R2 waits on it. It is also the change most likely to break existing goldens en masse |
| **A C++ runtime** | **Unknown, because unmeasured.** Could be glue; could be porting libc++abi. V0 decides |
| **Mesa source-ported and running (reading B)** | **Feasible on a multi-year horizon, and not before.** Not because any single piece is impossible, but because the pieces are the entire substrate and each has been deferred by every previous milestone for good reasons |
| **Running prebuilt Linux Mesa binaries (reading A)** | **Infeasible as scoped, and should be ruled out by name in the ADR.** It is a Linux personality — `ld.so`, glibc symbol versioning, glibc TLS, `futex`, `clone`, sysfs, procfs — and `libc-roadmap.md` §5 already recommends never attempting it |
| **"Almost all GPUs, early"** | **Not achievable as stated, and this is the sentence the unit exists to deliver.** "Early" and "almost all GPUs" are not simultaneously reachable. What *is* reachable, and is worth having: **almost all GPUs, through a hypervisor, after the substrate.** The GPU work is not the long pole; the POSIX substrate is |
| **A bare-metal Intel/AMD/Nvidia driver** | **Not reachable. `gpu.md` §1 is unchanged and ADR-0029 does not touch it.** Signed firmware is not an engineering problem |

**The one-sentence version, because an accurate map is the whole value of this unit:** *the DRM ABI
decision is architecturally right and buys more than it looks like it does — but the thing standing
between oscortex and Mesa is not the GPU ABI, it is `ioctl`, `mmap`, threads, TLS, dynamic linking, a
hosted libc and a C++ runtime, and that is a multi-year substrate programme that happens to have a
graphics driver at the end of it.*

---

## 9. What this forces elsewhere in the project

Nothing in this list is new work invented here; each is an existing gap or design that this decision
**promotes from optional to blocking**, and that is the useful thing to record.

| forced | who else wants it | status |
|---|---|---|
| **reference-counted frames and page tables** | `display-protocol.md` D8, `blocking-and-threads.md` §4.3 | **now a hard prerequisite for S2 and S4.** Three consumers; it should be one unit |
| **real threads, TLS (`IA32_FS_BASE` via `wrmsr`), futexes** | `blocking-and-threads.md` §4.3 said "not yet" and was right *then* | **now mandatory.** B6's honest `pthread_create → EAGAIN` stub is correct for ffmpeg and **insufficient** for Mesa |
| **blocking / `fdwait`** | `blocking-and-threads.md` B1–B3, `display-protocol.md` D3 | **now mandatory** — DRM events and fence waits are both blocking reads |
| **dynamic linking, `PT_INTERP`, `ET_DYN`, `dlopen`** | `exec-format.md`, GAP-0091 | deferrable through V3 by static-linking; **mandatory** for a real Vulkan loader |
| **a much larger libc, a libm, `stdio`, `errno`, `locale`** | `libc-roadmap.md` L1–L9 | **now on the critical path**, where it was previously an ffmpeg-driven nice-to-have |
| **a C++ runtime** | **nobody. It is unscoped** | **new, and GAP-0162 opens it** |
| **an address space larger than 2 MiB** | `display-protocol.md` §1.2, `libc-roadmap.md` §0, `blocking-and-threads.md` §4.3 | **now mandatory** and by a much larger factor — model weights, not framebuffers |
| **more than four descriptors and more than four processes** | `libc-roadmap.md` §5.7 (three standard streams alone) | **now mandatory**: a Vulkan client holds a render node, a syncobj eventfd, and its own files |
| **PCI capability walk, config-space writes, bus mastering** | `gpu.md` G0–G1, GAP-0067 item 2 | unchanged, still small, still first |
| **MSI/MSI-X and the local APIC** | `gpu.md` §3.6 said polling suffices for 2D | **for a compute queue it does not.** A dispatch you poll for burns the core you are trying to free. Promoted from "not needed" to "wanted at V3" |
| **write-combining / PAT** | GAP-0071 item 1 | **promoted from performance note to correctness bug** the moment a GPU buffer is CPU-mapped. GAP-0165 |
| **IOMMU** | nobody | **still not needed in a VM.** The identity map is the translation layer. On real hardware it would be mandatory, and real hardware is not reachable |
| **fd passing between processes** | `display-protocol.md` §5.2 called it the hardest retrofit and reserved four handle words for it | **now the transport for PRIME/dma-buf.** GAP-0160 |
| **a device namespace** | `namespace.md`, `display-protocol.md` §2.1 | **now mandatory.** Two device names, `:DRI0` and `:DRIR0` |
| **a syscall-number registry** | `design/README.md` fix #2 | **build it in S0.** `ioctl` is at least the third claimant on a number, and syscall 11 is already double-claimed |
| **a monotonic clock** | `time-and-power.md`, `libc-roadmap.md` L8 | **now mandatory** — every Vulkan timeout is `CLOCK_MONOTONIC` |
| **a Linux host in the loop** | nobody | **new, and it is logistics, not code.** GAP-0163 |

---

## 10. What I did not decide, and would rather be told

**Q1 — Is "unmodified Mesa" reading A or reading B?** §3.1. I have designed for **B** (source port,
our libc, cross-built on the host) throughout, and I believe A is infeasible on any horizon this
project should plan against. **This should be stated in ADR-0029 explicitly**, because "unmodified"
reads naturally as A and the two differ by an entire Linux personality.

**Q2 — Does the compute path get priority over the display path?** §7.2 argues it should, and that the
ladder should run S0→S3→R0→R2→S4→R4→V-track with the KMS rungs taken later. That is a scheduling
decision with a real cost: it means the display stays an 800×600 software-blitted console for longer
than it otherwise would.

**Q3 — Where does Mesa live for the display path: in the compositor, or in its own process?** §4.3
recommends its own process, on membrane grounds, at the cost of a hop per frame. The alternative —
Mesa linked into the compositor — is faster and puts a 10-megabyte zombie inside the one process
everything depends on. I would take the hop, and I would want that confirmed rather than assumed.

**Q4 — Is `libdrm` accepted as the first C library this OS links, ahead of Mesa?** §8.3. It is on the
critical path anyway and it brings `modetest` with it as an independently-authored conformance suite.
The cost is that it is a real port with a real build, and it happens before anything visible works.

**Q5 — Is the Linux-host requirement accepted?** §6.3 and GAP-0163. Every rung from R4 on needs a
Linux box with a QEMU built against virglrenderer. There is no software substitute — lavapipe would be
one, and §3.3 shows it needs LLVM. **If the answer is no, the V-track stops at V1 and the honest
statement is that the compute path cannot be proved on the available hardware.**

**Q6 — Does the descriptor generator (§4.2) get built, and does it get built early?** It is the
concrete answer to escalation 0004 §6 and it is cheap while there is one driver's uAPI to describe. It
gets expensive to retrofit once several ioctls are served by hand.

**Q7 — Is `gpu.md` retired, amended, or left standing?** My recommendation: **left standing, with a
status line added at its head** pointing at ADR-0029 and at §1.3 here. Its §1 (real GPUs, firmware, the
staffing arithmetic) is the best-evidenced thing in the design corpus and remains completely true. Only
its §2.2 verdict changes, and only conditionally.

---

## 11. Notes for the coordinator to fold in elsewhere

I have not touched `ROADMAP.md`. These are the entries and edits that belong elsewhere.

**Gaps opened by this unit:** GAP-0158 (no `ioctl`, no device namespace), GAP-0159 (no `mmap`),
GAP-0160 (no fd passing, so PRIME has no transport), GAP-0161 (the DRM ABI is per-driver below
`DRM_COMMAND_BASE`, measured), GAP-0162 (Mesa would be the first C library linked, and there is no C++
runtime), GAP-0163 (the dev machine cannot exercise any 3D or compute path), GAP-0164 (no fences, no
vblank events, no `read`-record transport), GAP-0165 (write-combining is now a correctness bug, not a
performance note — narrows GAP-0071 item 1), GAP-0166 (the reflective membrane has no mechanism: an
`@extern` declaration carries no descriptors).

**An amendment `gpu.md` should receive.** Its §2.2 verdict on virgl/venus/native-context is correct as
written *and* conditional on hand-writing Mesa's job. A one-paragraph status note at its head, pointing
at ADR-0029 and §1.3 here, stops the next reader concluding that 3D is closed. **Do not delete or
rewrite §1** — the firmware and staffing arithmetic is unchanged and is the best-cited material in the
corpus.

**An amendment `display-protocol.md` should receive.** §2.5's four reserved handle words now have a
named consumer (§2.6, R5, C1). Its §1.3 "a GPU would change the calculus" ceiling was already answered
by `gpu.md` §4; this document does not reopen it, because §4.3's containment keeps Mesa *outside* the
protocol entirely.

**An amendment `blocking-and-threads.md` should receive.** §4.2 concludes "no threads", correctly, on
the evidence available then: ffmpeg and libwayland link mutexes without needing concurrency. **Mesa is
a counter-example** — its compile thread pool is not a linking artefact — so §4.2's conclusion should
gain a sentence naming the workload that changes it, rather than being read as settled. §3.5's
readiness table gains a fourth kind: a DRM fd is ready when an event record is queued.

**An amendment `libc-roadmap.md` should receive.** Its tier table (A…E) has no tier for Mesa. Mesa sits
above tier E — it needs everything tier E needs *plus* a C++ runtime, which no tier includes. Adding a
row costs nothing and stops the tier table being read as exhaustive.

**A DCDart-side note, not a DCDart-side change.** §4.2's descriptor generator is a build-time table
generator **in this repo**. It is not a DCDart language feature and CLAUDE.md rule 3 applies in the
negative: nobody should open a DCDart escalation for it. The DCDart-side question that *is* real is
escalation 0004 §6's, and it remains open and unimplemented; GAP-0166 records that from this side.

**A sequencing note.** S0 (`ioctl`) and the syscall registry are the same unit, and both are wanted by
work that has nothing to do with graphics. If someone is doing syscall work for another reason, they
should take it — the same argument `gpu.md` Q3 made for `pciWrite32`.
