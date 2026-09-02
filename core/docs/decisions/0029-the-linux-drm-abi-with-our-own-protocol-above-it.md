# ADR-0029 — GPU support is the **Linux DRM/KMS kernel ABI**, so that Mesa runs unmodified. **The compositor keeps oscortex's own protocol.**

**Status:** **decided by the project owner** (2026-08-26), **relayed to this session by the coordinator
and not witnessed by it** — recorded as the owner's decision, on that date, relayed. **Nothing is
implemented.** No kernel source was touched by the unit that wrote this.
**Date:** 2026-08-26
**Part of:** a design unit, not a milestone. No `ROADMAP.md` entry.
**Design:** `core/docs/design/drm-abi.md` — the gap analysis, the measurements and the ladder.
**Supersedes in part:** `core/docs/design/gpu.md` §2.2 (see §6 below). **Everything else in `gpu.md`
stands, including all of §1.**
**Records:** GAP-0158 … GAP-0166. **Narrows:** GAP-0071 item 1 (via GAP-0165).

---

## 1. The decision, in full

1. **oscortex implements the Linux DRM/KMS kernel ABI** — the `/dev/dri` character devices, the
   `ioctl` surface of `include/uapi/drm/*.h`, GEM buffer objects, PRIME/dma-buf, `drm_syncobj` fences,
   and the KMS object/property model — **as its GPU interface**, rather than inventing one.
2. **Mesa is the userspace half**, run **unmodified**. §3 fixes what "unmodified" means, because the
   word has two readings that differ by an entire Linux personality.
3. **The compositor keeps oscortex's own display protocol** (`display-protocol.md`). Wayland is not
   adopted. The target shape is **our protocol at the top, the Linux DRM ABI underneath**.
4. **The Linux compatibility layer is promoted from "later" to structurally early**, because DRM is a
   Linux ABI and this decision makes it load-bearing.
5. **The first driver behind the ABI is `virtio-gpu`**, and `gpu.md`'s G-ladder is the transport under
   it, not a competitor to it.

---

## 2. Context

The owner's framing: **oscortex is meant to be "the AI machine"** — heavy GPU use is the point of the
system, not decoration — and GPU support must cover **almost all GPUs, early**. The rationale offered
for the ABI route was that nobody can hand-write drivers for almost all GPUs, and Mesa already covers
Intel, AMD, Nvidia (NVK), Adreno and Mali, so broad support means being able to *run what exists*.

Three facts about this project frame the decision:

* **`gpu.md` had already concluded "mostly a NO"** — measured, with citations — for Intel, AMD and
  NVIDIA drivers, on the grounds that a modern GPU driver is 11× to 288× this kernel's size, is half in
  the kernel and half in Mesa, and needs vendor firmware the vendor cryptographically signs.
  Its recommendation was VirtIO-GPU 2D and nothing else, with an explicit ceiling: *"No OpenGL, no
  Vulkan, no shaders, no video decode, no compute."*
* **Reuse in this project is currently zero.** Kernel, libc and drivers are all hand-written DCDart.
  DCDart has extern FFI (DCDart ADR-0038) and **the OS has never linked a real C library.**
* **The display protocol decision was already taken** and already priced: an own protocol, on the
  grounds that Wayland is Linux's paradigm and adopting it contradicts a native syscall ABI
  (`display-protocol.md` §0). It was taken knowing that *"nothing from the existing graphical software
  ecosystem will run on this OS."*

The tension the decision resolves is between `gpu.md`'s ceiling and the owner's goal. The tension it
creates is between "use the existing C ecosystem" and DCDart escalation 0004 §6's "no zombies", and
§7 is this ADR's answer to that.

---

## 3. What "unmodified Mesa" means here, and it must be said

There are two readings, and the ADR takes one:

| | reading | verdict |
|---|---|---|
| **A** | Run **prebuilt Linux binaries** — a distribution's `libvulkan_virtio.so`, its `libdrm.so.2`, the Vulkan loader | **REJECTED.** It requires `ld.so` with glibc symbol versioning, glibc's TLS model, `futex`, `clone`, `arch_prctl`, Linux `mmap` semantics, `openat`/`getdents64`/`statx`, a `/sys/class/drm` hierarchy, and ICD-discovery JSON on a real filesystem. That is a **Linux personality**, which `libc-roadmap.md` §5 recommends never attempting, and this ADR does not overrule that |
| **B** | Build Mesa **from unmodified source** against an oscortex toolchain and libc, cross-built on the host | **CHOSEN.** The DRM ioctls Mesa issues are identical either way, because the *ABI* is the thing we implement. Mesa is already ported to FreeBSD, OpenBSD, Haiku, Android and Windows, so the codebase is not Linux-only by construction |

**"Unmodified" therefore means unmodified *source*, not unmodified *binary*.** Anyone reading this ADR
later and planning against reading A is planning against something this decision did not authorise.

---

## 4. Options, and why each of the rejected ones was rejected

### 4.1 Write our own GPU drivers — REJECTED, and this was already settled

`gpu.md` §1 is the argument and it was measured, not asserted: `i915`+`xe` are **560,555 lines**,
`amdgpu` is **~1.2 million** non-header lines behind **4,977,963** lines of machine-generated register
headers, `nouveau` is **232,946** lines after twenty-one years and is on its third rewrite. Two of the
three vendors document nothing you can build from. **And the decisive one is not size: every one of
them needs vendor blobs the hardware verifies cryptographically before it will run them, and no amount
of engineering effort produces a signature you do not have the key for.**

This option is not reopened by this ADR and remains closed.

### 4.2 Adopt Wayland along with Mesa/DRM/dma-buf — REJECTED

Mesa, DRM and dma-buf are conventionally a package deal with Wayland, and the owner reaffirmed the own-
protocol choice knowing that. The reasons the package is *not* mandatory here:

* **The package-deal claim is a claim about Wayland's buffer model**, not about DRM. Wayland's model is
  client-side rendering into client-owned buffers handed over as dma-bufs. **Our protocol's client
  hands over drawing verbs and never owns pixels** (`display-protocol.md` §1.3), so the dma-buf hop
  that Wayland needs *per client* we need **once**, between the compositor and the Mesa-hosting
  process.
* **Adopting Wayland would put Mesa inside every client.** §7's containment argument then fails
  everywhere at once.
* `display-protocol.md` §5.2's original blocker is unchanged and is not a graphics problem: **nothing
  on this OS can block**, and `wl_display_dispatch` is `poll` plus read. A Wayland client is impossible
  before `fdwait` exists regardless of what the GPU stack looks like.
* The retrofit cost was already itemised and the hardest item — `SCM_RIGHTS` fd passing — **is needed
  by this ADR anyway**, for PRIME. So rejecting Wayland does not avoid that cost; it avoids the rest.

**Cost of the rejection, stated rather than implied:** no Wayland client, toolkit or compositor will
ever run on oscortex without a bridge, and `display-protocol.md` §5.4's ruling stands — *"if a bridge
is ever built, it bridges clients, not compositors."*

### 4.3 Invent our own GPU ABI — REJECTED

The only argument for it is that it could be smaller and DCDart-shaped. Against it: **it would have no
userspace.** Mesa would have to be modified — which is exactly what the decision exists to avoid — and
every future driver would be ours alone. The Linux uAPI additionally brings a stability guarantee, a
public specification in the form of 24,265 lines of `include/uapi/drm/*.h`, and reference
implementations we are allowed to read.

### 4.4 Do nothing beyond VirtIO-GPU 2D — REJECTED as insufficient

This was `gpu.md`'s recommendation and it is a good display stack, but its own §6/Q5 states the ceiling:
**no OpenGL, no Vulkan, no shaders, no video decode, no compute.** For a machine whose stated purpose is
compute, that ceiling is the whole objection, and `gpu.md` said so: *"If that is not acceptable the
answer is not a different GPU plan, it is a different project."* This ADR is the different plan.

---

## 5. The consequence that changes what is reachable — virtio-gpu is a universal shim

**This is why the decision pays, and it is not obvious.** Serving virtio-gpu's eleven ioctls — plus
`CONTEXT_INIT` and `RESOURCE_CREATE_BLOB` — gives, with **one** kernel driver and **no** vendor firmware:

| Mesa driver, run unmodified | what it reaches |
|---|---|
| **venus** (`src/virtio/vulkan`) | **the host's Vulkan**, whatever GPU that is — this is the compute path |
| **virgl** (`src/gallium/drivers/virgl`) | the host's OpenGL |
| **DRM native context** | the host's **real vendor driver**, with the guest running radeonsi / RADV / ANV / freedreno |

No other driver in the DRM tree has that property. "Almost all GPUs" is genuinely reachable in that
shape — **through a hypervisor**, which is the qualification that makes the rest of the sentence true.

**And the qualification is load-bearing.** *Nothing in this ADR changes bare metal.* An Intel, AMD or
Nvidia GPU on real hardware still needs its kernel driver and its signed firmware, and `gpu.md` §1
remains the complete and correct answer to that. **The honest restatement of the goal is: almost all
GPUs, through a hypervisor, after the substrate.**

---

## 6. What this does to `gpu.md`

**`gpu.md` §2.2 concluded virgl and venus were "not reachable, and the reason is not size."** That
conclusion was correct *and conditional on hand-writing what Mesa does*. This ADR removes the
condition, so the verdict inverts — see `drm-abi.md` §1.3.

**Everything else in `gpu.md` stands**, and two parts of it stand emphatically:

* **§1 in its entirety** — the driver sizes, the histories, the staffing arithmetic, the three walls
  and the firmware analysis. It is the best-evidenced material in the design corpus and this ADR does
  not soften a word of it.
* **The whole G-ladder (G0–G7).** G0–G3 build the PCI capability walk, the bus-master enable and the
  virtqueue. **Those are the transport; the DRM ABI is the interface over the transport.** The G-ladder
  is a prerequisite of this ADR's ladder, not a competitor to it, and no work on it is wasted.

`gpu.md` should gain a status line at its head pointing here. It should **not** be rewritten.

---

## 7. The membrane — how this ADR handles DCDart escalation 0004 §6

Escalation 0004 §6 states the tension plainly: *"C libraries are zombies by construction… Every FFI
boundary is a hole in the reflective world, and the holes are exactly where the large, useful,
already-written software lives."* It offers three options and recommends **"describe the boundary"** —
the FFI declaration carries full descriptors, so the *interface* is reflective even though the
*implementation* is opaque. **Mesa is the largest zombie this project will ever consider, and this ADR
adopts option 3 with an architectural amplifier.**

**(a) Describe the boundary, and here it is unusually easy.** The DRM ABI is **one call** —
`ioctl(fd, request, argp)` — carrying **one flat POD struct per request number**, with the struct's
exact size encoded in the request number itself, defined in **public, versioned, stability-guaranteed**
headers. Compare ffmpeg, whose boundary is hundreds of hand-written signatures with prose-documented
ownership; DCDart ADR-0038 refuses ARC types in `@extern` signatures for exactly that reason.
**Nothing crosses the DRM boundary that the kernel does not own on both sides.** The mechanism is a
build-time generator that reads the uAPI headers and emits a descriptor per request — name, direction,
size, field list — which the dispatcher validates against and which backs a `drm trace` command that
can say, by field name, exactly what crossed. `drm-abi.md` §4.2 specifies it. **It is a table generator
in this repo, not a DCDart language feature; CLAUDE.md rule 3 applies in the negative.**

**(b) The containment, and this is where keeping our own protocol pays.** For the **display** path,
**Mesa runs in its own address space, reached through oscortex's own protocol.** It is never linked
into the compositor and never into the kernel. The zombie is quarantined by a page table, and
everything crossing our protocol is a message this system defines and can describe totally. **The
owner's two decisions are therefore complementary, not in tension:** adopting Wayland would have put
Mesa inside every client.

**(c) The exception, decided on traffic shape rather than principle.** For the **compute** path, Mesa
is **linked in-process with the compute client**, because a process hop per dispatch is ruinous where a
hop per frame is free. The zombie is inside that client's address space — acceptable precisely because
that client is the thing that asked for it, and not acceptable for the compositor, which everything
depends on.

**(d) The limit, stated so it is not overclaimed.** Describing the boundary describes *what crosses
it*. Mesa's internal state, threads, heap and shader IR remain opaque. **This is what escalation 0004
§6 recommends; it is not the same as abolishing the zombie, and this ADR does not claim it is.**

---

## 8. Consequences

### 8.1 What becomes mandatory that was optional

Each of these already existed as a gap or a design. The decision promotes them to blocking:

* **`ioctl` as a syscall**, and a device namespace — GAP-0158. Neither exists.
* **`mmap`** of a descriptor at a driver-chosen offset — GAP-0159. Does not exist; `sbrk` is the only
  way a program gets a page.
* **Reference-counted frames and page tables.** `freeFrame` is a plain bit-clear; `procSpaceFree` frees
  every present leaf unconditionally. `display-protocol.md` D8 and `blocking-and-threads.md` §4.3 both
  already wanted this; it is now a hard prerequisite for `mmap` and for threads.
* **Real threads, TLS and futexes.** `blocking-and-threads.md` §4.2 concluded "no threads", correctly,
  on the evidence then available — ffmpeg and libwayland link mutexes without needing concurrency.
  **Mesa is the counter-example**: its shader-compile thread pool is not a linking artefact. B6's
  honest `pthread_create → EAGAIN` stub stays correct for ffmpeg and is **insufficient** here.
* **Blocking / `fdwait`** — DRM events and fence waits are both blocking reads.
* **Dynamic linking** — deferrable by static-linking through the early compute rungs, mandatory for a
  real Vulkan loader. GAP-0091 and `elf.dart:1280` stand.
* **A hosted libc, a libm, and — newly — a C++ runtime.** `libc-roadmap.md` is 1,518 lines and does not
  mention C++ once; Mesa's Vulkan runtime is C++17 and ACO is C++20. GAP-0162.
* **An address space larger than 2 MiB**, more than four descriptors, more than four processes.
* **Write-combining / PAT** — GAP-0071 item 1 was a performance note; a CPU-mapped GPU buffer makes it a
  correctness bug. GAP-0165.
* **MSI/MSI-X and the local APIC** — `gpu.md` §3.6 was right that a 2D display path can poll. A compute
  queue cannot: polling burns the core the dispatch was meant to free.
* **A Linux host in the loop.** GAP-0163, and it is logistics rather than code.

### 8.2 What does *not* become mandatory

* **An IOMMU.** In a VM the identity map is the whole translation layer (`gpu.md` §3.4). It would be
  mandatory on real hardware, which is not reachable.
* **`drm_edid`** — 7,504 lines to parse a monitor. `GET_DISPLAY_INFO` already reports the mode on
  virtio-gpu.
* **The legacy pre-KMS core ioctls** (`ADD_MAP`, `AGP_*`, `SG_*`, `ADD_CTX`, the SAREA calls) and
  `GEM_FLINK`/`GEM_OPEN`. Refuse with the `EINVAL` equivalent.

### 8.3 The honest schedule consequence

**The GPU work is not the long pole; the POSIX substrate is.** `ioctl`, a device namespace, `mmap`, a
larger address space and the first four DRM rungs on virtio-gpu are a real, walkable ladder of roughly
M14's difficulty. **Threads + TLS + futexes + dynamic linking + a hosted libc + a libm + a C++ runtime
is bigger than everything this kernel has built so far**, and it is what stands between oscortex and
Mesa. `drm-abi.md` §8 gives the per-item verdicts; the summary is that **"almost all GPUs, early" is
not achievable as stated**, and the reachable restatement is **"almost all GPUs, through a hypervisor,
after the substrate."**

### 8.4 Reversibility

**High, and deliberately so.** Nothing is implemented. The parts of the ladder that are cheap and
independently justified — `ioctl`, a syscall registry, a device namespace, `mmap`, refcounted frames —
are wanted by three other designs and survive a reversal intact. The parts that are expensive
(threads, dynamic linking, a C++ runtime, a Mesa port) come late enough that the decision can be
revisited after the first measurement — **`drm-abi.md`'s V0 rung exists to produce that measurement
before anything expensive is committed to.**

---

## 9. What this ADR does not decide

Seven questions are recorded in `drm-abi.md` §10 and are the coordinator's to route. The two that
change this ADR's meaning if answered differently:

* **Q1 — reading A or reading B of "unmodified"?** §3 takes B. If the owner means A, this ADR is
  understating the cost by an entire Linux personality and should be rewritten, not amended.
* **Q5 — is the Linux-host requirement accepted?** If not, the compute ladder stops at "the venus ICD
  links" and the honest statement becomes that the compute path cannot be proved on the available
  hardware.
