# The oscortex network stack — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered, nothing implemented.** This document exists so that the
agent who builds the first piece does not have to re-decide anything. When a piece is built it gets
its own numbered ADR; this file is the thing those ADRs will point back at. It is the sibling of
`display-protocol.md` and it borrows that document's shape deliberately, because the two designs turn
out to need **the same three missing things** and it should be obvious when they are the same thing
(§3.5, §4.4, §2.4).

**Nothing here is relayed from the owner.** `display-protocol.md` opens by recording that its one
already-made decision — own protocol over Wayland — came from the owner via the coordinator. **I have
no such decision for networking.** Everything below is a proposal, every recommendation is mine, and
§10 is the list of things I would rather be told than guess.

**What IS decided, and it was decided by measurement rather than by me:** ten facts about this
machine in §0.2, each with the command that produced it. Four of them changed what I was going to
write. One of them — that the firmware has already set the e1000's bus-master bit — is the difference
between "this needs a PCI config-space write path that does not exist" and "this needs a config-space
*read*, which does."

### The five things decided here, for a reader in a hurry

| | decision | where |
|---|---|---|
| **Where the stack lives** | **In the kernel, all of it, up to and including TCP** — not because a kernel stack is nicer but because *the buffers cannot live anywhere else*. Three things must happen while the client is off the CPU, and on this machine "off the CPU" is the normal case. | §1.2 |
| **What replaces a socket** | **One descriptor is one session; a connection is a 16-bit channel id inside it.** `open("/net")` and then records. It costs **one** of a process's four descriptors for an unbounded number of connections — and the session fd *is* the poll set, which is how an OS with no `poll` gets one. | §2.2 |
| **Receiving** | **Non-blocking `read` + `yield` is right for delivery and insufficient for the protocol.** The fix is not a wait primitive, it is that **the kernel buffers and the kernel acks**. TCP's receive window then does double duty as this OS's missing backpressure. | §3.1, §3.3 |
| **Time** | **One `netTick()` call inside the existing `procTick`. That is the entire timer machinery.** A fixed 1-second RTO with exponential backoff — which is RFC 6298's own floor — deletes the RTT estimator, and 100 Hz is exactly enough to measure it. | §4.3, §4.5 |
| **Buffers** | **`allocFrame()`, not `@bss`.** Frames are 4 KiB, identity-mapped, and their physical address *is* their virtual address — which is precisely a DMA buffer. Nineteen frames, and **zero new bytes of donated `.bss`** beyond one 512-byte state block. | §5.1 |

**What to build first: N0 — the kernel prints the NIC's MAC address (§9).** It moves no packet, it
touches two files, and its exit criterion compares the kernel's answer against the `mac=` string the
harness itself typed on the QEMU command line. That is a whole milestone whose expectation comes from
outside the kernel, which is this repo's rule, and it can be built today with nothing else changing.

### And the four findings that surprised me most

* **The bus-master bit is already set.** `pci.dart` cannot write configuration space at all — there
  is exactly one `port_outl` call site in the kernel and it writes `0xCF8`, never `0xCFC`
  (GAP-0067 item 2). I expected that to be the blocker for any DMA-capable NIC. It is not:
  SeaBIOS has already written `0x107` to the e1000's command register, so **I/O decode, memory decode
  and bus mastering are all on before the kernel's first instruction** (§0.2 fact 4). The kernel needs
  a config-space *read* to check that, and a config-space read is what it has.
* **The e1000's registers are already mapped.** BAR0 lands at `0xFEBC0000`, which is inside
  `[3 GiB, 4 GiB)` — the PCI hole `vm.dart:1196-1203` blankets with 2 MiB identity RW+NX pages at
  boot. **A NIC driver needs no new mapping and no change to `vm.dart` at all** (§0.2 fact 3).
* **The pcap is contaminated unless you say `romfile=`.** The e1000's iPXE option ROM does a full
  DHCP exchange plus a gratuitous ARP — **seven frames** — before the kernel runs. A harness that
  asserts "the guest sent frames" passes against a kernel that sends none. With `romfile=` the pcap
  has **zero** packets (§0.2 fact 8). This is the anti-vacuity guard for the entire N-series and it
  is a one-token change.
* **The NIC's interrupt is on the slave PIC.** `cfg[0x3C] = 0x010B` — IRQ 11, pin A. The slave 8259
  is written `0xFF` at every one of the four sites that touch it, and there is no slave EOI function
  in this kernel. **So the first NIC does not use its interrupt at all** (§6.3) — and when one
  eventually does, it needs exactly the cascade-unmask-and-double-EOI work that
  `display-protocol.md` §4.4 costs for the mouse. That is a shared milestone, not two.

---

## 0. What this has to be true of

Five constraints shape every choice below. Four are properties of this machine; the fifth is a
property of the network, and it is the one that makes this document different from the display one.

1. **NOTHING ON THIS MACHINE CAN BLOCK.** `proc.dart:272-276` has five process states —
   `procStateFree` 0, `procStateReady` 1, `procStateRunning` 2, `procStateExited` 3,
   `procStateKilled` 4 — and there is no sixth. GAP-0141: *"Nothing ever waits."* No sleep, no
   wakeup, no signal, no wait queue. This is upstream of §1, §3 and §4.
2. **There are no sockets, no `mmap`, no fd passing and no `poll`**, and a process has **four
   descriptors** (`fileMaxFds = 4`, `file.dart:281`). Anything that assumes otherwise is not a design
   for this OS.
3. **The kernel is one compilation unit** — every kernel source file is `part of 'kmain.dart'`
   because `dcc` lowers exactly one library per object file (GAP-0004 item 4) — and every harness
   asserts a byte-exact serial capture. A design that needs six subsystems changed at once cannot be
   landed here.
4. **`@bare` DCDart is a small language.** No `switch`, no `enum`, no `&&`, no `||`, no general `!`,
   no function pointers, no growable collections, no struct in a signature, and **every
   `Pointer<T>` access is volatile** (DCDart GAP-0023, GAP-0025 and GAP-0034; GAP-0002 here). §8 is
   where that stops being a style note and becomes a line count.
5. **THE PEER DOES NOT WAIT FOR US.** This is the new one. A display client that stops polling sees a
   stale window; a TCP peer that stops hearing acknowledgements retransmits, backs off, and
   eventually resets the connection. Every other subsystem in this kernel is driven entirely by
   something the machine itself did — a keystroke, a syscall, a command. **The network is the first
   thing that happens to this machine on somebody else's schedule**, and most of what is unusual
   below follows from that one sentence.

---

## 0.1 Naming, so the rest of the document is unambiguous

| term | meaning here |
|---|---|
| **frame** | an Ethernet frame — a MAC header and up to 1500 bytes of payload |
| **packet** | an IPv4 datagram, inside a frame |
| **segment** | a TCP segment, inside a packet |
| **record** | a fixed-header, variable-body unit of the *session protocol* — what a program reads and writes on its descriptor. Not a wire object; see §2.3 |
| **session** | one open descriptor onto `/net`. One process may have several; each is independent |
| **channel** | a 16-bit id inside one session. One channel is one endpoint: a UDP port, or a TCP connection |
| **endpoint** | the kernel-side object a channel names — a 4-tuple, its buffers and its state |

**Deliberately NOT called "socket".** A socket has a family, a type, a protocol, an address structure
that is a union, `setsockopt`, `select` and an fd of its own. A channel has an id and two buffers.
Calling it a socket would promise the rest.

---

## 0.2 What is already on this machine — measured, not assumed

Every line below was produced by running something, and the command is given so the next agent can
re-run it rather than believe me. Several of these changed the design.

| # | fact | how it was measured |
|---|---|---|
| 1 | **There is already an e1000 on the default machine, at 00:03.0, `8086:100E`, class `02/00/00`.** `pci.dart:195` already has a `02/00 → "ethernet"` record, so the kernel already *prints* it. `m5-pci` already asserts it, and its third boot already attaches a second one with `-device e1000` (`m5-pci/run.sh:1097`). | `README.md:57`; `qemu-system-x86_64 … -monitor stdio` → `info pci` |
| 2 | **It is already wired to a SLIRP backend with no command-line flags at all.** `hub0port1: #net155: index=0,type=user,net=10.0.2.0`, `hub0port0: e1000.0: … macaddr=52:54:00:12:34:56`. **All twenty existing harnesses already boot with a live NIC and a live network behind it: none of the twenty `run.sh` files passes `-nic none` or `-net none`.** | `info network` |
| 3 | **BAR0 = `0xFEBC0000`, 128 KiB MMIO. BAR1 = I/O at `0xC000`, 64 bytes.** `0xFEBC0000` is inside `[vmPciBase = 0xC0000000, vmPciEnd = 0x100000000)`, which `vm.dart:1196-1203` identity-maps as 512 2 MiB RW+NX pages at boot. **The register file is already addressable.** | `info pci` after firmware has run |
| 4 | **`cfg[0x04] = 0x00000107`.** Command bits 0, 1 and 2: **I/O decode, memory decode and BUS MASTER are already enabled by the firmware.** | `o/w 0xcf8 0x80001804` then `i/w 0xcfc` at the QEMU monitor |
| 5 | **`cfg[0x34] = 0x00000000` — there is no capability list.** No MSI, no MSI-X, no PCIe extended capabilities on this device on this machine. GAP-0067 item 4 ("offset `0x34` is not followed") therefore **costs this design nothing**. | same |
| 6 | **`cfg[0x3C] = 0x0000010B` — Interrupt Line 11, Interrupt Pin A.** IRQ 11 is on the **slave** PIC. `0xA1` is written `0xFF` at all four mask sites (`interrupts.dart:271`, `:279`; `keyboard.dart:174`, `:191`) and `picEoiMaster` (`interrupts.dart:288-290`) is the only EOI in the kernel. | same |
| 7 | **`cfg[0x08] = 0x02000003`** — class 0x02, subclass 0x00, prog-IF 0x00, revision 3. Matches what `pci.dart` prints. | same |
| 8 | **The option ROM sends seven frames before the kernel runs** — DHCP DISCOVER/OFFER/REQUEST/ACK and a gratuitous ARP. **With `romfile=` the pcap contains zero packets.** | two boots with `-object filter-dump`, then count |
| 9 | **SLIRP's gateway is 10.0.2.2 and its MAC is `52:55:0a:00:02:02`** — literally `52:55` followed by the four address bytes, so it is derivable and must never be typed into a harness. The guest lease is 10.0.2.15/24, DNS is 10.0.2.3. | read out of the DHCP OFFER in the pcap above |
| 10 | **`filter-dump` writes a classic little-endian pcap**, magic `0xa1b2c3d4`, linktype 1 (Ethernet), snaplen 65536, 16-byte per-packet headers. **Forty lines of `struct.unpack` parse it with no host dependency at all** — no scapy, no tshark, nothing to install. | parsed one by hand |

**Two of these deserve to be stated as consequences rather than facts.**

* Because of 3 and 4, **the first NIC driver changes `vm.dart` not at all and `pci.dart` by one
  function.** I expected the opposite and had written half a section about mapping a BAR before I
  measured it.
* Because of 8, **every exit criterion in §9 that reads a pcap must pass `romfile=`**, and the
  harness must assert that a do-nothing boot produces a **zero-packet** pcap. Without it, "the guest
  transmitted" is satisfied by firmware the kernel did not write, which is precisely the vacuous pass
  `check-pixels.py` exists to prevent.

---

## 1. Kernel or userland — and why that is not quite the question

### 1.1 The three shapes, stated fairly

**(A) Everything in the kernel.** Device, Ethernet, ARP, IPv4, ICMP, UDP, TCP. A program gets an
endpoint through a descriptor. This is Linux, BSD, ToaruOS, SerenityOS.

**(B) A userland stack process, serving other processes over IPC.** The kernel exposes a raw-packet
device; one resident process owns it and speaks a protocol to its clients. This is what a microkernel
does, and it is what "avoid growing the kernel" usually means.

**(C) A userland stack *library*, linked into each program, over a raw-packet descriptor.** No server,
no IPC. Each program has its own stack. This is lwIP in RAW mode, and it is genuinely the fastest
path from here to "a program on this machine opened a TCP connection".

The framing in the brief — *a userland stack avoids growing the kernel; a kernel stack is simpler to
give a socket API* — is the right trade in general. **On this machine it is not the trade that
decides**, and I want to say why before I say which.

### 1.2 THE ARGUMENT THAT SETTLES IT: three things must happen while the client is not running

Constraint §0.5 says the peer does not wait for us. Make that concrete. Here are the three things a
network endpoint has to do at a moment when the program that owns it is not on the CPU:

1. **Answer an ARP request.** A peer that cannot resolve our MAC cannot send us anything at all. The
   request arrives when it arrives.
2. **Answer an ICMP echo request.** "Can you ping it" is the first question anyone asks of a new
   stack, and the answer must not be "only while a particular program is scheduled".
3. **Acknowledge a TCP segment, and retransmit an unacknowledged one.** This is the load-bearing one.
   A missing ACK is not a delay; it is a retransmission, then a backoff, then — after enough of them —
   a reset. **The connection breaks.**

Now ask how often "not on the CPU" is. `procQuantumTicks = 8` (`proc.dart:338`) at 100 Hz is an 80 ms
slice; with two processes live, a given program is off the CPU roughly half the time and for 80 ms at
a stretch. Sitting at the shell prompt with no process started, it is off the CPU **entirely**, and
`picUnmaskKeyboardOnly` has masked IRQ0 as well. And on an OS with no fifth state, a program that is
between `read` calls is not "blocked in the kernel where the kernel can act for it" — it is *running*,
somewhere else, doing something else.

**So the receive buffer, the retransmit buffer and the demultiplexing table must be in the kernel.**
Not for elegance — because there is nowhere else that runs.

And that is most of a TCP stack's *state*. Shape (B) and shape (C) both then reduce to: the buffers
are in the kernel, the demux is in the kernel, and only the state machine is in ring 3 — reachable
only through a 512-byte syscall (`fileReadMax = fileWriteMax = 512`, `file.dart:300`, `:310`), unable
to touch its own buffers, and unable to run when the buffers need it. **That is the worst place to
draw the line**, and it is the line both userland shapes are forced to.

### 1.3 Three more arguments, each independent, each sufficient on its own

I would recommend (A) on §1.2 alone. These are here because a decision this expensive to reverse
should not rest on one argument.

**A raw-packet descriptor in ring 3 is a hole straight through M8, M9 and M11.** With one, any
program can forge any source MAC and any source IP, can transmit on behalf of any other program, and
can *read every frame the machine receives* — including every other program's traffic. There is no
uid, no capability, no privilege bit and no `root` on this OS to gate it with, and inventing one is a
larger decision than this document's. `elfOwns` and `fileOwnsWrite` were built, and mutation-tested
with fourteen mutants at M16, to keep ring 3 from touching what is not its own. A raw device hands it
the wire.

**Four descriptors.** Shape (B)'s stack process has `fileMaxFds = 4` descriptors, one of which is the
raw device. **Three clients, ever.** Raising the bound is cheap in isolation — `fileRowWords = 32` is
four eight-word descriptors, so eight descriptors is 2560 bytes of table instead of 1280 — but every
harness that counts the table's size has to move, and "how many files may a program have open" should
not be decided as a side effect of a network stack. (This is the same shape as
`display-protocol.md` §1.2's page-window question, and it deserves the same answer: its own
milestone.)

**There is no IPC, and the missing kind is exactly the kind (B) needs.** A client's
`open("/net")` served by a *process* means the client's syscall must not return until the server has
answered. That is a blocking round trip inside a syscall, which GAP-0097/GAP-0141 say does not exist
and cannot be added without a fifth process state. `display-protocol.md` §2.1 gets away with the same
idiom only because the kernel is the *broker*: the bytes land in kernel storage and the compositor
drains them later, asynchronously, and no client ever waits for a process. **That works for pixels
because a late pixel is a late pixel. It does not work for an ACK.**

### 1.4 What it costs, stated plainly, because it is not small

**The kernel grows by 2,500–4,500 lines of `@bare` DCDart, in a single compilation unit that is
23,404 lines today.** §8 breaks that down and says which part of it is TCP. That is the price, it is
the real one, and the userland options were not rejected because the price is imaginary.

Three specific taxes inside that number, all from §0.4:

* **Header parsing is hand-indexed byte arithmetic.** A `@packed class extends Struct` cannot appear
  in a signature (DCDart GAP-0025), so there is no `IpHeader` type to pass around; every field access is
  `Pointer<u8>.fromAddress(base + 9).value` with the 9 in a named constant, exactly as `fat.dart`
  reads a directory entry.
* **Every protocol demultiplex is an `if`-chain.** No `switch`, no jump table this repo controls
  (GAP-0088), no array of handlers. Ethertype, IP protocol, ICMP type, TCP state — four chains.
* **Checksums are volatile loads.** DCDart GAP-0034 means a TCP checksum over a 1460-byte segment is 730
  individual, unvectorisable, unhoistable 16-bit loads. That is the performance ceiling of this
  stack and it should be recorded, not discovered.

### 1.5 What stays in userland, and it is more than it sounds

The rule that draws the line is one sentence, and it is worth putting in the eventual ADR verbatim:

> **The kernel implements what must run when nobody is scheduled. Everything else is a program.**

By that rule, these are **programs, not kernel code**, and none of them needs a syscall this document
does not already propose:

* **DHCP.** Four UDP packets and some option parsing, over an ordinary UDP channel. `netstat`-style
  configuration is then a `write` on the session (§2.3's `CONF` verb). This is a genuinely good first
  network *program* and it is why §9 puts static configuration first: a static address makes DHCP
  optional, and optional is what lets it be a program.
* **DNS.** A UDP query to 10.0.2.3 and a reply parser. Pure userland, no kernel support at all.
* **Every application protocol.** HTTP, TFTP, whatever.
* **The client library** — record framing, the >512-byte reassembly of §2.3, and the poll helper of
  §3.5. This is the exact analogue of `display-protocol.md` §2.3's batching library, it belongs in
  `core/user/libc/`, and **without it the 512-byte transport is as unusable for records as it was for
  pixels.**

### 1.6 The recommendation, and the one thing I would reconsider

**Recommendation: shape (A). The whole stack in the kernel, TCP included.**

**The one thing that would change my mind**, stated so nobody has to guess at it later: if the owner
decides that **TCP is not wanted on this machine at all**, then §1.2's argument weakens to just ARP
and ICMP — both of which are a few hundred lines — and shape (C) over a *restricted* raw device
(UDP-payload-only, no forged sources) becomes defensible for the rest. **Almost everything expensive
in this document is TCP.** §9 is laddered so that the decision can be taken as late as N5, with
everything before it built and paid for either way.

---

## 2. The handle — what replaces a socket

### 2.1 Yes, the clone-file idiom reuses, and it reuses better here than it does for display

`display-protocol.md` §2.1 proposes:

```
   fd = open("WSYS")              the fd IS the session
   fdwrite(fd, batch, <=512)      a batch of binary verbs
   read(fd, buf, <=512)           fixed-width event records; 0 when there are none
   close(fd)                      the session ends, the server frees the client's windows
```

**Everything in that paragraph is true of a network session, one word at a time**, and one thing is
*more* true. `close(fd)` frees the client's windows for display; for networking it frees the client's
**connections**, which means a program that faults with three TCP connections open leaks none of them
— and that path already exists: `fileReleaseOwner` (`file.dart:667`) is called from `elfTeardown` and
`procCleanup`, **on the fault path as well as the normal one**. The hardest resource-lifetime problem
in a network stack is already solved by machinery M15 built for files.

So: **zero new syscalls.** `open`, `read`, `close`, `fdwrite` with the refusal floor
(`fileRetFloor = 0xFFFFFFFFFFFFFF00`, `file.dart:429`), the four-descriptor bound, and both pointer
validators that M16 mutation-tested. One caveat, stated once: `fileOwnsWrite` requires the user *and*
writable bits page by page before a byte is copied out (`file.dart:79-84`), and a receive path that
writes network bytes into a caller's buffer is exactly the case that validator exists for. It is
reused unchanged.

### 2.2 But four descriptors is not four connections — a connection is a CHANNEL, not an fd

This is the one place the display idiom does not transfer, and it is the central design question of
§2.

A display client needs **one** session. A network program needs **one endpoint per conversation**, and
a program that reads a configuration file (1 fd) and serves two connections is at three of four before
it does anything interesting. One-fd-per-connection makes `fileMaxFds = 4` a hard bound on
concurrency, and that is not an acceptable API.

**Proposal: one descriptor is one session; connections inside it are 16-bit channel ids.** This is
exactly `display-protocol.md` §1.3's move — *the client never owns pixels, it owns an image id* —
applied one layer over: **the client never owns a socket, it owns a channel id.**

```
   fd  = open("/net")                         one descriptor, one session
   fdwrite(fd, OPEN  {ch=1, proto=UDP, lport=5000})
   fdwrite(fd, OPEN  {ch=2, proto=TCP, raddr=10.0.2.2, rport=7})
   fdwrite(fd, SEND  {ch=1, ...bytes...})
   read(fd, rec)   -> {ch=2, EVT_CONNECTED}
   read(fd, rec)   -> {ch=1, DATA, ...bytes...}
   fdwrite(fd, CLOSE {ch=2})
   close(fd)                                  every channel in the session goes with it
```

**Four properties fall out, and the second is the one that matters most.**

1. **One descriptor, unbounded channels.** The bound moves from `fileMaxFds` (4, and shared with
   files) to a kernel-side endpoint table sized in §5.2. That is a bound this design gets to choose.
2. **THE SESSION FD IS THE POLL SET.** `read(fd)` returns the next record from *any* channel, in
   arrival order. That is what `select` is for, and this design gets it as a side effect of
   multiplexing rather than as a twelfth syscall and a scheduler change. **An OS with no `poll`
   should not build N single-channel handles and then invent a way to watch them all; it should build
   one handle that is already the union.** I think this is the strongest single argument in §2.
3. **Ordering across channels is preserved**, which a fd-per-connection design cannot promise.
4. **Channel ids are client-allocated**, from a client-owned range, with an explicit "you may reuse
   this id" event from the kernel when an endpoint is finally gone. That is Wayland's `delete_id`, it
   is `display-protocol.md` §5.3's "half-decision that constrains nothing", and matching it costs one
   record type.

**The cost, stated plainly.** Head-of-line: a record on channel 1 delays channel 2. It is bounded by
one record — 512 bytes — because that is all a `read` can carry, so the delay is one syscall, not one
message. And a channel cannot be handed to another process; but nothing on this machine can be handed
to another process, so nothing is lost that exists.

### 2.3 The record format, and the one place 512 bytes bites

A record is a **fixed 16-byte header and a body**. Hand-indexed, because DCDart GAP-0025 means the
kernel and its C userland cannot share a type and both ends must write the offsets out
(`display-protocol.md` §8 says the same thing about its verb batches).

```
   +0   u16  channel
   +2   u8   opcode / event
   +3   u8   flags        bit 0 = MORE: this record is not the end of the message
   +4   u16  body length  (<= 496)
   +6   u16  reserved     MUST BE ZERO
   +8   u64  tick         the kernel's tick_count() at the moment this record was formed
   +16  ...  body
```

**Two fields are load-bearing and neither is obvious.**

**The MORE bit.** `fileReadMax` is 512, so the largest body is 496 bytes and **a 1500-byte datagram
cannot be delivered in one `read`.** For TCP that is a non-issue — a stream has no message boundaries
and a short read is already the normal case (`file.dart:1415-1419`: *"a short read is not an error and
the program is required to notice"*). For UDP it is a real semantic problem: a datagram delivered in
pieces with no way to tell where it ends is a datagram the program can misparse. So: a message is a
run of records on one channel, all but the last with MORE set. The client library reassembles. **A
program that ignores MORE gets the first 496 bytes and can tell that it did**, which is the loud
failure this repo prefers to the quiet one.

**The tick.** §4 needs a monotonic clock in userland — for round-trip times, for timeouts, for
"should I give up". Putting it in every record header costs 8 bytes and **removes the need for a
`now()` syscall on the receive path entirely**. A program that also needs the time when nothing has
arrived still needs one, and §10's Q3 asks whether that should be syscall 10.

**Reserved MUST BE ZERO.** `display-protocol.md` §2.5 reserves four words for out-of-band handles on
the argument that a wire format with nowhere to put them gets a version 2. The same argument holds
and the same answer is cheaper here: two bytes, defined as zero, refused if not.

### 2.4 The device name — and a correction I owe the display protocol

`display-protocol.md` §2.4 flipped its own recommendation to *"`fatLookup` gains one branch that
recognises a single reserved name before it touches the volume"*, and proposed `WSYS`. I agree with
the mechanism and **I think the spelling is wrong, in a way that is cheap to fix now and expensive
later.**

`WSYS` and `NET` are both **valid 8.3 names**. A volume with a file called `NET` on it — and this OS
now writes files (M16) — shadows or is shadowed by the device, silently, depending on which branch
runs first. That is a bug that appears once, in the field, on somebody's data.

**Proposal: a device name begins with `/`, which is illegal in an 8.3 name and therefore cannot
collide with any file that can exist on this volume.** `open("/net")`. `open("/wsys")`. The branch is
one test on one byte:

```
   if (Pointer<u8>.fromAddress(buf).value == u8(0x2F)) { ... device ... }
```

and it goes in `fileSysOpen` **after** the name has been copied into `fileBufBase()` and **before**
`fatParseAt` is called (`file.dart:1355-1360`) — so the bytes are already the kernel's when the test
runs, which is the ordering M16's pointer argument depends on. `fatParseAt` never sees it and
`fileNameMax = 12` still bounds it.

This is strictly narrower than a `/dev` tree, a mount table or a VFS, it is one branch rather than
one branch plus a shadowing rule, and it reads like what it is. **It should be built once, as its own
milestone, serving both this document and the display one** — which is the same conclusion §3.5 and
§4.4 reach about two other shared prerequisites, and three coincidences is a pattern.

### 2.5 What a program actually looks like

```c
    unsigned long fd = open("/net");
    net_open_udp(fd, /*ch=*/1, /*lport=*/5000);
    net_sendto(fd, 1, gw, 7, "hello", 5);

    char rec[512];
    for (;;) {
        if (read(fd, rec, sizeof rec) == 0) { yield(); continue; }
        ...
    }
```

Six lines, four of them syscalls that already exist. That is the point of §2.1.

---

## 3. How anything receives, given there is no `poll`, no `select` and no blocked state

### 3.1 Non-blocking `read` + `yield` is the right answer for delivery — and it is not sufficient

`display-protocol.md` §2.2's loop is correct and I am not proposing to replace it:

```
   while (read(fd, rec, sizeof rec) == 0) yield();     /* syscall 3, already exists */
```

It needs no fifth state, no wait queue and no wakeup, and since M18 it cannot hang the machine.

**But it answers a different question than the one TCP asks.** That loop governs *when the program
learns about bytes*. It says nothing about *when the bytes are accepted*, *when they are
acknowledged*, or *when a lost segment is sent again* — and those three are on the peer's schedule,
not ours (§0.5). The display protocol never had to distinguish them because a compositor that is not
scheduled simply does not draw; nothing outside the machine notices.

**So the sentence to hold onto is: the answer to "how do you receive without blocking" is not a
better wait. It is that the kernel receives, and the program collects.** Reception and delivery are
two different events, separated by a buffer, and only the second one is the program's business.

### 3.2 The three things the kernel must therefore do on its own

These are §1.2's three, now with a place to happen:

1. **ARP replies** — from the RX path, immediately, no program involved.
2. **ICMP echo replies** — same. `ping` works with nothing running. This is also, not by accident,
   the easiest thing in this document to test (§9, N3).
3. **TCP acknowledgement and retransmission** — from the RX path and from `netTick` (§4.3).

All three run in the kernel's RX processing, which §6.3 puts on the timer path rather than on an
interrupt. **Latency is therefore one PIT tick, 10 ms.** Against a 1-second RTO (§4.5) that is
1% of the budget, and against SLIRP's sub-millisecond RTT it is the dominant term — meaning **this
stack's measured RTT will be about 10 ms and that is the clock, not the network.** Say so in the ADR
rather than letting somebody investigate it.

### 3.3 TCP's receive window IS the backpressure this OS does not have

This is the part of §3 I did not expect and it is the nicest thing in the document.

Between two `read` calls, an arbitrary number of packets can arrive. A queue with a fixed size and no
backpressure drops them, and `display-protocol.md` §4.2 item 2 is right that the drop must be
**counted and readable** — but for a keyboard a dropped keystroke is a missing character, and for TCP
a dropped segment is a retransmission, a backoff, and a slower connection.

**TCP already has the mechanism for exactly this, and it is the receive window.** So:

> **The window advertised on a channel is the free space in that channel's receive ring.**

A program that stops calling `read` fills its ring; the window shrinks; the window reaches zero; **the
peer stops sending, and nothing is dropped.** When the program reads, the window opens and a window
update goes out. The flow-control mechanism TCP was given for slow *receivers* turns out to be exactly
the flow-control mechanism an OS with no blocking needs for slow *readers*, and the fit is exact
rather than approximate.

Two consequences follow and both should be written down:

* **The zero-window persist timer becomes mandatory, not optional.** A zero window that is reopened
  by a window update the peer never receives is a permanently stalled connection — the classic TCP
  deadlock. §4.1 lists it among the timers that cannot be cut.
* **The receive ring size is a visible API constant**, because it is the maximum window and therefore
  the bandwidth-delay bound. §5.2 sizes it at 4 KiB per channel.

### 3.4 UDP has no window, so UDP drops — and counts

A datagram that arrives for a channel whose ring is full is **dropped, counted in
`netMetaUdpDrops`, and not signalled to the program in any other way.** That is what UDP means, it is
what every other stack does, and the counter is the difference between "the network lost it" and "you
were too slow", which is a distinction a program can act on. Same instinct as `fatMetaHits` and
`procHeadKernTicks`, same rule as `file.dart`'s: **no counter that nothing reads** — GAP-0120 records
that an unread counter is a mutation survivor by construction, so every counter in §5.4's list is
printed.

### 3.5 The primitive that is actually missing — and the display protocol wants the same one

The polling loop of §3.1 costs a trip through the scheduler per poll. With one program that is
nothing. With a program that wants to redraw at 60 Hz *and* service a connection, it is a spin.

The fix is the one `display-protocol.md` §5.3(2) already names:

```
    wait(handles[], n, timeoutNanos) -> readyMask
```

**Two independent designs, arrived at from opposite ends of the machine, want the identical
primitive.** That is the best evidence available that it is the right primitive, and it is worth
recording as such — a wait that is single-handle, or has no timeout, or is special-cased for one
subsystem, would fail both. It is a new syscall **and a fifth process state**, it is GAP-0097 in the
shape GAP-0097 has to be answered in, and **it is not needed for N0–N7.** §2.2's session-as-poll-set
is why: one handle is already the union of everything this stack can tell you.

---

## 4. Time — TCP without timers

### 4.1 What a timer is actually for, itemised, so the list can be cut honestly

| timer | what breaks without it | can it be cut? |
|---|---|---|
| **retransmission (RTO)** | a lost segment is never resent; the connection hangs forever | **No.** This is the one that makes TCP TCP |
| **zero-window persist** | a lost window update deadlocks the connection permanently (§3.3) | **No**, and §3.3 is why it matters more here than elsewhere |
| **connection-establish timeout** | a SYN to a dead host leaves an endpoint allocated forever | **No** — but it is the RTO with a bounded retry count, not a second mechanism |
| **TIME_WAIT (2×MSL)** | a stale segment from an old connection can be accepted by a new one on the same 4-tuple | **Yes, conditionally.** §4.6 |
| **delayed ACK** | nothing breaks; you send more ACKs than necessary | **Yes.** ACK immediately. Simpler and strictly more conservative |
| **keepalive** | a connection to a vanished peer is never noticed | **Yes.** It is optional in RFC 1122 and the application can do it |
| **RTT estimation (Karn/Jacobson)** | the RTO is not adaptive | **Yes**, and §4.5 argues it must be cut here |
| **congestion control timers** | throughput is bad on a lossy path | **Yes** — see §8's stop-and-wait |

**Three timers survive, and two of them are the same mechanism.** So the minimum is: *a deadline per
endpoint, and something that checks it.*

### 4.2 The PIT is enough, and here is the arithmetic

`pitInit` (`interrupts.dart:310-314`) writes `0x43 ← 0x36`, then divisor `0x2E9C` = 11932 to `0x40`.
1,193,182 / 11,932 = **100.0 Hz exactly**, one tick per 10 ms. `tick_count()` is an `@extern` reading
a 64-bit counter in `isr.S`'s `.bss` (`isr.S:326-329`), zeroed by `idt_load` (`isr.S:344`), and it
**must** be an extern call rather than a `Pointer<u64>` load, because DC-IR's `Load` has no volatile
semantics and LLVM would hoist a spin (`interrupts.dart:120-127`). A 64-bit counter at 100 Hz wraps
in 5.8 billion years; there is no wrap case to write.

**Is 10 ms enough for TCP? For the RTO, yes, and with room to spare — because RFC 6298 §2.4 puts a
floor of one second under the RTO in the first place.** One second is 100 ticks. A 10 ms clock
measures a 100-tick interval to 1% and that is not the limiting error in anything.

**Is 10 ms enough to *estimate* RTT? No, and that is the finding.** Against SLIRP the round trip is
tens of microseconds. Every RTT this machine can measure is 0 or 1 ticks, and §3.3's own 10 ms
polling latency dominates whatever is left. A smoothed RTT estimator fed by a clock coarser than the
thing it is measuring does not produce a bad estimate — it produces **noise with a mean of the polling
interval**, and then the RTO computed from it is wrong in a way that looks principled. §4.5 is what to
do instead.

**Should the PIT go to 1000 Hz?** Divisor 1193 instead of 11932; the change is two bytes. **No**, for
two reasons: it multiplies IRQ0 by ten for a stack whose RTO floor is 100 ticks either way, and it
moves `m3-shell`'s byte-exact `ticks` golden and every `procHeadKernTicks` number in `m18-preempt`.
Cost with no buyer.

### 4.3 `netTick()` inside `procTick()` — and that is the whole of the timer machinery

```
   isrDispatch, vector 0x20            interrupts.dart:479-517
     tick_counter += 1
     picEoiMaster()
     procTick(frame)                   <-- netTick() goes here, or at its head
```

**One call, in a handler that already exists, at a rate that is already correct.** No new interrupt,
no new vector, no new PIC work, no new storage for a timer wheel. `netTick` walks the endpoint table —
**four entries, sized in §5.2** — and for each one compares a deadline word against `tick_count()`.
Four comparisons per tick, 400 per second. That is not a cost worth optimising and it should not be
optimised.

There is no timer wheel, no sorted list, no callback registration, and no data structure at all. A
deadline is **one `u64` per endpoint**, and "the timer fired" is `now >= deadline`. `@bare` DCDart
cannot express the alternative anyway (no growable collection, no function pointers), and here that
constraint costs nothing, which is worth noticing after §1.4 listed three places it costs plenty.

**`netTick` also drives the receive path** (§6.3): it polls the NIC's RX descriptor ring. One function
called from one place does both, which means **there is exactly one place in this kernel where network
work happens outside a syscall**, and that is a property worth asserting structurally in the harness
the way `m14-fat` and `m16-filewrite` assert that the only `port_outw` aimed at `0x1F0` is inside
`ataWriteFrom`.

### 4.4 The honest hole: IRQ0 is masked at rest, so at the shell prompt there is no time at all

`picUnmaskTimerAndKeyboard` (`keyboard.dart:190-191`, `0x21 ← 0xFC`) is called from exactly two
places — `shellTicks` and the preemptive-scheduler session start — and `procSessionTimerOff`
(`proc.dart:2005-2007`) re-masks at every session exit. GAP-0058 explains why: with the PIT masked at
rest, `tick_count()` holds still and the `ticks` command's output is byte-exact assertable.

**So with no process running, `netTick` does not run, and therefore: no ARP replies, no ICMP replies,
no ACKs, no retransmissions.** The machine is off the network whenever it is idle. That is not a
subtle degradation; it is the whole stack stopping.

**The fix is one line and it is somebody else's golden.** IRQ0 must be permanently unmasked. This is
**exactly item 4 of `display-protocol.md` §6's D3** — *"IRQ0 must stay unmasked … which moves
`m3-shell`'s byte-exact `ticks` golden (GAP-0058). That is a real cost in somebody else's harness and
it should be budgeted, not discovered."* — and it is the third thing (after the device name, §2.4, and
the wait primitive, §3.5) that both documents need and neither owns.

**Consequence for the ladder:** N0–N3 can be built without it, because a harness drives the machine
and something is always running while it does. **N6 (TCP) cannot**, because a TCP connection that
survives an idle prompt is the entire point. §9 marks it.

### 4.5 What a fixed RTO deletes, and why it is not a shortcut

**Proposal: RTO = 1 second, doubling on each retransmission, capped at 60 seconds, giving up after 5
attempts.** No RTT samples, no smoothed estimator, no variance term, no Karn's algorithm.

**This is RFC 6298's own initial value and its own floor**, not a simplification of it: §2.1 says the
RTO SHOULD begin at 1 second, and §2.4 says it MUST NOT be rounded below 1 second. A stack that never
updates the estimator sits permanently at the value the RFC says to start from and never go under.
**It is not a cut corner; it is the corner.**

What that deletes: the SRTT and RTTVAR words, the sampling rule, the exclusion of retransmitted
segments from sampling (Karn), the backoff-interacts-with-sampling rule, and the timestamps option.
Call it 150 lines and four subtle bugs.

What it costs, stated plainly: **on a fast path, recovery from a lost segment takes one second instead
of one RTT.** Against SLIRP, where the RTT is microseconds, that is roughly a 10,000× penalty on the
loss path — and it does not matter, because the loss rate on a SLIRP link is zero except when a
harness deliberately makes it non-zero (N7). On a real network it would matter. **Record it as the
first thing to fix if this stack ever leaves QEMU**, alongside stop-and-wait (§8).

### 4.6 TIME_WAIT, and the one word that substitutes for it

TIME_WAIT is 2×MSL — conventionally four minutes, 24,000 ticks. Keeping an endpoint allocated for four
minutes after it closes, out of four endpoints (§5.2), means **a program that opens and closes four
connections cannot open a fifth for four minutes.** On this machine that is unacceptable.

**What TIME_WAIT actually protects against is one thing: a delayed segment from an old incarnation
being accepted by a new connection on the same 4-tuple.** On a machine where the local port is ours to
choose, there is a cheaper defence:

> **A monotonically increasing ephemeral port counter, one `u64`, never reused within a boot.**

Ports 49152–65535 gives 16,384 outbound connections before it wraps, which on this machine is more
than any session will make, and if it wraps it wraps after long enough that no segment survives.
Combined with a randomised-per-connection ISN (which TCP needs regardless), the 4-tuple never repeats
and there is nothing for a stale segment to land on.

**What is genuinely given up**, and it should be in the ADR rather than discovered: a **passive**
close on a **listening** port — where the remote chooses the 4-tuple, not us — has no such defence.
So: **no TIME_WAIT for outbound connections (defended by the port counter); a real 2×MSL TIME_WAIT
only for a listening endpoint, and that is a reason to put listening sockets (N8) after everything
else** rather than a reason to skip the milestone.

---

## 5. Where the packets live, with no allocator

### 5.1 Not `@bss` — frames. And the reason is one sentence.

My first draft sized a `@bss` block the way every other subsystem here does (`fileStore` 2560 bytes,
`pmmStore` 4672, `procStore` 4224 — **14,264 bytes for the whole kernel today**). It came to about
66,000 bytes, which is **4.6× the kernel's entire existing static footprint**, and I was going to
argue for it.

**Then: `allocFrame()` returns a physical address, and the map is identity below 128 MiB. So a frame's
physical address IS its virtual address. That is a DMA buffer.**

* `allocFrame()` → a 4096-byte physically-addressed frame, or 0 (`pmm.dart:1090-1109`). 32,768 frames
  exist (`pmmMaxFrames`, `pmm.dart:611`).
* The identity map is stated at `vm.dart:62` and built for `[4 MiB, 128 MiB)` at `vm.dart:1188-1194`.
* Every address is below 128 MiB, so **every DMA address is 32-bit and `RDBAH`/`TDBAH` are zero.** No
  bounce buffer, no address-width question, no IOMMU.
* `ata.dart:849-853` already says the destination of a sector read is *"in practice a frame from
  `allocFrame()`"*. **This is not a new pattern; it is the existing one.**

**The rings must be contiguous. The buffers must not.** An e1000 descriptor ring is one contiguous
region whose base goes in a register — and at 16 bytes per descriptor a 16-entry RX ring is 256 bytes
and an 8-entry TX ring is 128, so **both rings fit in one frame together**, 16-byte alignment
satisfied for free by a 4096-aligned frame. Each *buffer* address is written into its own descriptor
and they can be anywhere. So the "no contiguous multi-frame allocator" gap (`pmm.dart` has none, and
`vm.dart:1289-1311` only *checks* adjacency it got by luck) **never comes up.**

**Frames are never freed.** Nineteen frames of 32,768 is 0.06% of the machine, held for the life of
the boot, and `pmmMetaAllocs` counts them.

### 5.2 The sizing table

Two columns, because the difference is 16 KiB and somebody should get to choose.

| region | small | comfortable | why that size |
|---|---|---|---|
| RX + TX descriptor rings | **1 frame** | **1 frame** | 16 RX × 16 B = 256, 8 TX × 16 B = 128. `RDLEN`/`TDLEN` must be multiples of 128, and both are |
| RX packet buffers | 8 × 2048 = **4 frames** | 16 × 2048 = **8 frames** | `RCTL.BSIZE = 2048` holds any non-jumbo frame in one buffer. This is burst tolerance, not storage: RX processing copies out immediately (§5.3) |
| TX packet buffers | 4 × 2048 = **2 frames** | 4 × 2048 = **2 frames** | Only one transmit is ever in flight (§6.3), so four is already generous |
| per-channel receive rings | 4 × 4096 = **4 frames** | 4 × 4096 = **4 frames** | **This is the TCP receive window** (§3.3). 4 KiB is the advertised window |
| per-channel retransmit buffer | 4 × 2048 = **2 frames** | 4 × 2048 = **2 frames** | **One MSS per channel**, because stop-and-wait has one segment outstanding (§8). This is the single biggest thing stop-and-wait buys |
| endpoint state, ARP cache, config, counters | **`@bss`, 512 bytes** | same | The `fileStore` pattern: one block, one accessor, spare words declared as spares |
| **total** | **13 frames + 512 B** | **17 frames + 512 B** | **53 KiB / 70 KiB of ordinary RAM, and 512 bytes of `.bss`** |

**Four channels**, matching `procMax = 4` and `fileMaxFds = 4` — a number this machine is already
shaped around. A fifth `OPEN` is refused with a value at or above `fileRetFloor` and nothing is
allocated and nothing leaks, exactly as a fifth `open` is `fileRetNoSlot` (`file.dart:442`).

**The one number to argue about is the receive ring: 4 KiB is the window, and the window is the
bandwidth-delay product.** At SLIRP's RTT that is enormous. At 10 ms polling latency (§3.2) it caps
throughput at 400 KB/s, which is far above anything this machine will do with a byte-at-a-time
volatile checksum loop (§1.4). It is not the bottleneck and should not be grown until measurement says
it is.

### 5.3 Zero what is read before it is written, and nothing else

`allocFrame` returns **dirty** frames (`vm.dart:834-839`), `.bss` is not cleared by anything in this
kernel (`kdata.S`'s own note, restated at `file.dart:610-613`), and `fileInit` zeroes every word it
owns before the first byte of output for exactly that reason.

So `netInit` must zero:

* **the descriptor rings** — the device reads the status bytes back, and a dirty `DD` bit makes the
  driver believe a packet arrived that did not. `vmZeroFrame` (`vm.dart:841-847`) already exists;
* **the endpoint state block and every counter** — because a report line printed from an unzeroed
  word lands in the middle of somebody's byte-exact golden. `fileInit` is the precedent and its
  comment is the warning.

And it must **not** zero:

* **the 2 KiB packet buffers.** The device writes them and the descriptor carries the length, so no
  byte is ever read that was not written. That is 48 KiB of byte-at-a-time volatile stores not done,
  and the rule that makes it safe — *zero what is read before it is written* — is worth stating as a
  rule because the next person to add a buffer will need it.

**`netInit` must print nothing**, for `m1-interrupts`' reason: that harness asserts the entire
544-byte serial capture and its last byte is the newline after `M1 END`.

### 5.4 No fragment reassembly — and no counter that nothing reads

**Inbound IPv4 fragments are dropped and counted (`netMetaIpFrags`). Outbound packets set DF and are
never larger than the MTU.** Reassembly needs a hold buffer, a per-fragment offset list, a timer and
an eviction policy — the one place in this design that wants a growable collection `@bare` DCDart does
not have. SLIRP does not fragment; nothing on the path to 10.0.2.2 will. **The consequence is real and
should be stated in the ADR: a peer that fragments cannot talk to this machine**, and the counter is
how anyone would ever find out.

The counters, all of them printed by a `netReport` on the model of `fileExitReport`:

```
   netRxFrames  netRxDrops    netTxFrames  netTxErrs
   netArpReqs   netArpReps    netArpMiss
   netIpBadCsum netIpFrags    netIpNotUs
   netIcmpEchoes
   netUdpIn     netUdpOut     netUdpDrops
   netTcpRetrans netTcpResets netChanOverflows
```

**No counter that nothing reads.** GAP-0120 recorded, from `m14-fat`'s mutation round, that an unread
counter is a mutation survivor by construction — `fatMetaHits` was one. Every word above is printed;
spare words are declared as spares.

---

## 6. The device

### 6.1 e1000, and the argument is mostly "it is already here"

| candidate | for | against |
|---|---|---|
| **e1000** (`8086:100E`) | **On the default machine already** (§0.2 fact 1) — twenty harnesses boot with one and none of them asked. `pci.dart:195` already names it. Registers already mapped (fact 3), bus master already on (fact 4), no capability list to walk (fact 5). Exhaustively documented; every hobby OS has one | Descriptor rings and DMA — more concepts than PIO. ~15 registers to initialise |
| **ne2k_pci** | **No DMA at all** — 16 KiB of on-card memory through a data port, which is `ata.dart`'s exact shape with `port_inw`. Would need no frames and no §5 | Not on the default machine (`-device ne2k_pci` everywhere). Register *windows*, and a remote-DMA state machine that is fiddlier than it looks. And a second driver later anyway |
| **rtl8139** | Genuinely the simplest ring: four TX buffers at plain physical addresses, one circular RX buffer | Not on the default machine. The RX wrap semantics (the `WRAP` bit, and reading past the end of the buffer on purpose) are a famous source of one-off bugs |
| **virtio-net** | Fastest; the "right" answer on a hypervisor | Virtqueues are three structures with three alignment rules plus feature negotiation. **And its legacy interface is an I/O BAR**, which `fbFindVgaBar`'s BAR reader (`fb.dart:329-332`) currently returns 0 for |

**Recommendation: e1000.** Facts 3, 4 and 5 remove the three things I expected to be hard, and fact 1
means the device costs the harness nothing.

**And a named fallback, because being wrong about this should be cheap:** if DMA proves harder than
§5 makes it look, **`ne2k_pci` is the retreat**, it is `ata.dart` in a different hat, and it invalidates
nothing above L2 — §§2–4 do not know what the device is.

### 6.2 What the driver does, in the order it does it

Fifteen register writes, and the reset is the only subtle one.

```
   CTRL   (0x0000)  |= RST(0x04000000);  spin;  then |= SLU|ASDE, clear LRST|PHY_RST|ILOS|VME
   IMC    (0x00D8)  = 0xFFFFFFFF          mask every interrupt source -- see 6.3
   MTA    (0x5200)  = 0 x 128 entries     multicast table, must be cleared
   RAL0   (0x5400) / RAH0 (0x5404)        READ the MAC out of here; set AV in RAH
   RDBAL/RDBAH (0x2800/0x2804) = ring physical address, high half zero
   RDLEN  (0x2808)  = 256                 16 descriptors x 16 bytes; multiple of 128
   RDH/RDT(0x2810/0x2818) = 0 / 15
   RCTL   (0x0100)  = EN | BAM | SECRC | BSIZE(2048)
   TDBAL/TDBAH (0x3800/0x3804), TDLEN (0x3808) = 128, TDH/TDT (0x3810/0x3818) = 0
   TCTL   (0x0400)  = EN | PSP | CT(0x10) | COLD(0x40)
   TIPG   (0x0410)  = 0x0060200A
```

**Provenance, because this repo cares:** the register offsets and bit values above are **quoted from
memory of the Intel 8254x software developer's manual and are the one block in this document that was
not measured.** Every one of them should be checked against that manual — or against QEMU's own
`hw/net/e1000_regs.h` — before a line of driver code is written. Everything in §0.2 was measured;
this was not, and the difference should not be blurred.

**The MAC comes from `RAL0`/`RAH0`, not from the EEPROM.** QEMU's e1000 populates the receive-address
registers at reset from the `mac=` property, so an EEPROM read (`EERD`, the bit-banged fallback, and
the two different EEPROM layouts real 8254x parts have) is not needed. If a real card ever appears it
will be, and that is a note in the ADR rather than code today.

**Access: MMIO through BAR0, at `0xFEBC0000`, already mapped.** Register access is a `u32` load/store
at `bar0 + offset` — but note **DCDart GAP-0034 makes every `Pointer<u32>` access volatile, which is
exactly what MMIO requires**, so the language limitation that makes `fbFill` slow is the language
guarantee that makes this correct. Worth saying out loud once.

**And there is a second way in, if it is ever wanted:** BAR1 is an I/O range at `0xC000` (fact 3) —
the e1000's `IOADDR`/`IODATA` window, which reaches the whole register file through `port_outl`/
`port_inl`, both of which exist (`portio.S:49-76`). That path needs no MMIO and no mapping at all.
Not recommended (it is two port accesses per register instead of one load) but recorded, because it
means **a build that cannot reach BAR0 for any reason is not blocked.**

### 6.3 Poll the NIC. Do not use its interrupt. (For now, and the "for now" is precise.)

`IMC = 0xFFFFFFFF` above masks every interrupt source in the device, and `netTick` (§4.3) polls the RX
descriptor ring's `DD` bits every tick.

**Why**, in order of how much each one matters:

1. **The interrupt is on the slave PIC.** Fact 6: IRQ 11. `0xA1` is `0xFF` at all four mask sites, and
   `picEoiMaster` (`interrupts.dart:288-290`) is the only EOI this kernel has — a slave IRQ needs
   `0xA0 ← 0x20` *before* the master EOI and that code does not exist. **Using the interrupt means
   building the cascade path, which is the first three items of `display-protocol.md` §6's D1** and
   should be built once, for both.
2. **10 ms latency does not matter here.** §3.2's arithmetic: 1% of a 1-second RTO.
3. **Polling is this kernel's existing idiom.** `ata.dart` deliberately writes `nIEN` to `0x3F6` to
   tell the drive *not* to raise an interrupt (`ata.dart:583`), on the reasoning at `ata.dart:180-185`
   that "the interrupt cannot be delivered" and "the drive was told not to raise one" are different
   claims and it wants both. Same discipline, same reason.
4. **An IRQ handler that runs protocol code runs it with interrupts off** (IDT gates are `0x8E`,
   `interrupts.dart:199-204`). A TCP receive path is not something to run with `IF` clear.

**When to revisit:** when the machine does something where 10 ms of added latency per round trip is
the dominant cost — which, given §1.4's checksum ceiling, is further away than it sounds.

**One bound the polling loop must have, and `ata.dart` already set the precedent.** `netTick` must
process **at most N descriptors per tick** and leave the rest for the next one. An unbounded drain
loop, on a path that runs inside the timer interrupt, is a way to never leave the timer interrupt.
`ataPollLimit = 0x200000` (`ata.dart:206`) is the same instinct: a bound in iterations, because there
is no clock available to the thing that needs one.

### 6.4 What has to be built in `pci.dart` first, and it is small

Two functions, and neither writes configuration space:

* **`pciFindByClass(cls, sub) -> bdf`**, returning a packed bus/device/function or a sentinel.
  `fbFindVgaBar` (`fb.dart:320-339`) is the template and is bus-0/function-0 only; a NIC on the
  default machine is at 00:03.0, so that restriction is survivable, but the bridge boot in
  `m5-pci` proves it is not general. GAP-0067 item 1 records that `pci.dart` retains nothing, so this
  is a second walk, and the duplication is already acknowledged at `fb.dart:307-312`.
* **`pciReadBar(bdf, n)`**, honouring the I/O bit exactly as `fb.dart:329-332` does.

And **one read that is really an assertion**: read `cfg[0x04]` and refuse to initialise unless bits 1
(memory decode) and 2 (bus master) are set. Fact 4 says the firmware sets them; **a design that
depends on the firmware and does not check is a design that fails silently on the day it stops being
true.** The refusal is a named status and a printed line, and the cost is one `pciRead32`.

**GAP-0067 item 2 — no configuration-space write — is therefore not on this milestone's critical
path.** It stays open, it is still real, and it is what a *second* NIC or a *hot-added* device would
need.

---

## 7. What this deliberately does not do

### 7.1 Not in the stack, and not by accident

No IPv6. No IP fragmentation or reassembly (§5.4). No IP options — a packet with `IHL > 5` is dropped
and counted. No routing table: one interface, one gateway, one netmask, and "not on my subnet" means
"send it to the gateway". No multicast, no IGMP. No ICMP beyond echo request/reply and the one
outbound port-unreachable that UDP owes. No TCP options except MSS — **no window scaling, no SACK, no
timestamps**. No congestion control (§8). No Nagle, no delayed ACK. No `SO_*` options of any kind. No
raw sockets in ring 3 (§7.2). No forwarding — this machine is a host, never a router. No firewall, no
NAT, no VLANs, no bonding, no promiscuous mode, no checksum offload, no TSO, no jumbo frames, no
loopback interface.

**A loopback interface deserves its own sentence** because its absence is surprising: two programs on
this machine cannot talk to each other over TCP. It is not hard (a fake device that hands frames
straight back), it is a genuinely good test vehicle, and I have left it out because **it would be the
first IPC on this OS**, arriving as a side effect of a network stack, and §1.3 already argues that
kind of thing should not happen by accident. §10's Q4 asks.

### 7.2 The security fact, stated once and plainly

**Ring 3 never sees a frame it did not earn.** A program's channel receives only the payload of
packets addressed to its 4-tuple; it cannot set a source address, cannot choose a source MAC, cannot
transmit an arbitrary ethertype and cannot observe another program's traffic. Every one of those is
free under this design, because the kernel builds every header.

The corollary is the thing that must not be quietly undone later: **`/net` must never grow a "raw"
mode.** A raw-frame channel is exactly the hole §1.3 rejects, and it will be asked for — for a packet
sniffer, for a DHCP client that wants to see broadcasts, for a debugging tool. **The DHCP case is the
one that is really needed and it does not require raw frames**: a UDP channel bound to port 68 that
accepts broadcast destination addresses covers it, and that is a narrow, nameable exception rather
than an open door.

### 7.3 Ruled out permanently, so nobody costs it twice

**Running an unmodified Linux or BSD network application.** That needs `socket`/`bind`/`listen`/
`accept`/`connect`/`send`/`recv`, `struct sockaddr` and its union, `poll` or `epoll`, `fcntl`
`O_NONBLOCK`, `getaddrinfo` and a resolver, `errno`, and — because every real one of them is threaded
— threads and futexes. `display-protocol.md` §5.2's accounting applies unchanged and its conclusion is
the same: **the blocker is not the API surface, it is that nothing on this machine can block.** A
`recv()` that cannot wait is not `recv()`.

**What is NOT ruled out**, and is worth saying because it is the cheerful half: a program written for
*this* API is a few hundred lines, and every wire protocol — DNS, DHCP, HTTP, TFTP — is pure userland
parsing that needs no OS support at all (`display-protocol.md` §5.2 says the same of the Wayland wire
format: *"Free. Pure userspace parsing"*).

---

## 8. TCP's real size, stated honestly

The brief asks for this and it is the number most likely to be wrong in somebody's plan, so here it is
before the ladder rather than inside it.

**Everything below TCP is small.** Ethernet framing, ARP with a four-entry cache, IPv4 in and out with
one checksum routine, ICMP echo, and UDP: call it **900–1,300 lines** of `@bare` DCDart including the
comment density this repo writes at. The e1000 driver is **another 400–600**. None of it has state
that outlives a packet except the ARP cache. **This half of the document is a normal-sized milestone
and I am confident in that number.**

**TCP is not.** A minimal-but-correct TCP is:

| piece | lines | can it be cut? |
|---|---|---|
| the 11-state machine, as `if`-chains because there is no `switch` and no jump table this repo controls (GAP-0088) | 600–900 | no |
| wraparound-safe sequence arithmetic — four comparison helpers | 80 | no, **and this is where the subtle bugs are** |
| segment build/parse, options (MSS only), pseudo-header checksum | 250 | no |
| the retransmit path, **with one segment outstanding** | 200 | this is already the cut version; see below |
| accept-in-order-only receive | 120 | this is already the cut version |
| the deadline words and `netTick`'s four comparisons (§4.3) | 60 | no |
| **total** | **1,300–1,600** | |

**So TCP alone is roughly the size of everything beneath it, and it is the harder half by more than
that ratio suggests** — because everything beneath it is stateless per packet and TCP is not.

**Two deliberate cuts are what keep it at 1,300 rather than 4,000**, and both should be in the ADR as
choices with named successors:

* **Stop-and-wait: one segment outstanding, `cwnd` fixed at one MSS.** This is legal TCP, not a
  simplification of it — a sender may always send less than the window allows. It deletes the
  retransmit *queue*, fast retransmit, duplicate-ACK counting, slow start, congestion avoidance, the
  congestion window, and — per §5.2 — **it is why a channel's retransmit buffer is one MSS instead of
  a window's worth.** What it costs is throughput: **one segment per round trip**, so at §3.2's 10 ms
  polling latency, about **146 KB/s**, and that is a ceiling no amount of tuning moves.
* **In-order receive only: an out-of-order segment is dropped, and the ACK repeats the last
  contiguous sequence number.** Legal, correct, and it deletes the reassembly queue entirely — which
  is the other place `@bare` DCDart would have wanted a data structure it does not have. It costs a
  full RTO per reordering event, and on a SLIRP link there is no reordering.

**For calibration, and flagged as recollection rather than measurement:** lwIP — the smallest widely
deployed stack, and one with `switch`, function pointers, structs and `malloc` — spends on the order
of **5,000–6,000 lines of C on TCP alone** across `tcp.c`, `tcp_in.c` and `tcp_out.c`. **I am quoting
that from memory and it should be checked against a checkout before anyone plans around it.** The
shape of the comparison is what matters: the estimate above is a quarter of lwIP's TCP because it
gives up the two things (a real window, and reassembly) that most of lwIP's TCP is about.

**The honest summary in one line: the gap between "no network" and "ping works" is one ordinary
milestone. The gap between that and "TCP works" is three, and the last of them is bigger than the
first two together.**

---

## 9. The milestone ladder

**Every criterion below is written to this repo's rules for a derived expectation**, which the M5–M19
harnesses established:

* compute the expectation from a source the kernel does not control — here that is **the pcap** and
  **the QEMU command line the harness itself typed**;
* restate the kernel's rules in the harness, never import them;
* assert every constant copied from the kernel against the kernel's source;
* **guard against a vacuous pass** — and for this ladder that guard has a specific, mandatory form:

> **EVERY BOOT THAT PRODUCES A PCAP MUST PASS `romfile=`, AND EVERY PCAP ASSERTION MUST FAIL IF THE
> PCAP CONTAINS ZERO PACKETS.** §0.2 fact 8: without `romfile=` the option ROM emits seven frames the
> kernel did not send, and *every* "the guest transmitted" assertion passes against a kernel that
> transmits nothing. This is `check-pixels.py`'s zero-foreground-pixels rule, in its network form.

* structural checks before boot checks, and a negative control that must fail.

The harness change to `drive_session()` is **purely additive** — three flags — which matters because
that function is shared:

```
   -netdev user,id=n0
   -device  e1000,netdev=n0,mac=<derived>,romfile=
   -object  filter-dump,id=f0,netdev=n0,file=$outdir/net.pcap
```

And the pcap parser is ~40 lines of `struct.unpack`: magic `0xa1b2c3d4`, 24-byte global header,
16-byte per-record header, linktype 1 (§0.2 fact 10). **No scapy, no tshark, no new host dependency.**

---

### N0 — The kernel finds the NIC and reads its MAC address

**Blocked on: work only.** Touches `pci.dart` (§6.4's two functions) and a new `net.dart`. Moves no
packet. Independent of everything else in this document and of everything in the display one.

Find class `02/00`, read BAR0, check `cfg[0x04]` bits 1 and 2 and refuse if either is clear (§6.4),
reset the device, read `RAL0`/`RAH0`, print the MAC.

*Binary:* the harness passes `mac=52:54:00:AB:CD:EF` — **a value it chose, that appears nowhere in the
kernel** — and requires the kernel's printed MAC to equal it, byte for byte. It additionally requires
QEMU's own `info pci` from the same boot to agree the device is at the bus/device/function the kernel
printed, and that BAR0 is where the kernel said — two independent programs describing one device,
which is precisely the claim `m5-pci` already makes about six of them. *Negative control:* a boot with
`-nic none` must print the NODEV status and **no MAC line anywhere in the capture** — and `-nic none`
really does remove the device, which was checked (`info pci` reports no `8086:100e` at all) — the
same shape as `m6-disk`'s no-drive control, which is the assertion that makes the rest of that
harness mean anything. *Anti-vacuity:* the harness must fail if the expected MAC string is empty.

---

### N1 — One frame leaves the machine

**Blocked on: N0.**

The TX ring, one frame from `allocFrame()`, one descriptor, one `TDT` write, one `DD` poll. Send a
broadcast frame with a reserved ethertype and a body the harness generated.

*Binary:* the pcap contains **exactly one** packet; its bytes equal the bytes the harness itself
generated, byte for byte; its source MAC equals the `mac=` from the command line. *Negative control,
and it is the one that proves the doorbell is load-bearing:* a build with the `TDT` write removed must
produce a pcap with **zero** packets. *Anti-vacuity:* a zero-packet pcap fails the positive
assertion — which is exactly what the `romfile=` rule above buys, because without it this control
passes.

---

### N2 — ARP: a frame arrives, and the kernel understood it

**Blocked on: N1.**

The RX ring, `netTick`'s poll, and the ARP request/reply pair. Resolve the gateway.

**This is the milestone that proves reception, and it needs no way to inject a frame** — SLIRP answers
ARP for 10.0.2.2 itself, which is why this comes before anything that needs a host-side helper.

*Binary:* the pcap contains an ARP request from the derived source MAC for 10.0.2.2, followed by a
reply; **the MAC the kernel prints as resolved equals the source MAC of the reply as read out of the
pcap** — not a constant typed into the harness, even though §0.2 fact 9 says what it will be. The
harness additionally asserts the derived form (`52:55` ‖ the four address bytes) *as a second,
independent check*, and a disagreement between the two fails. *Negative control:* a build whose ARP
opcode check is inverted must resolve nothing and print the miss counter non-zero.

---

### N3 — Ping, and the checksum is proved to matter

**Blocked on: N2.** This is the first milestone where the machine is *on a network* rather than *on a
wire*.

IPv4 out and in, the header checksum, ICMP echo request and reply. A `ping <n>` shell command.

*Binary:* the pcap contains **N** echo requests and **N** replies; the harness verifies **on the host**
that every outbound IPv4 header checksum and every ICMP checksum is correct — arithmetic the kernel
did not do — and that identifiers and sequence numbers match pairwise; the kernel printed exactly N
replies with the derived sequence numbers, in order. *Negative control, and this is the best one in
the ladder:* a build that computes the ICMP checksum with the final one's-complement omitted must
receive **zero** replies, because SLIRP will drop every request. **That makes the checksum code
load-bearing rather than decorative**, which is the same property `m15-fileio` establishes for its
short-read count by building a second program that ignores it. *Anti-vacuity:* N must be ≥ 1 and the
harness must fail if it is 0.

> **Target 10.0.2.2, never 8.8.8.8.** SLIRP answers echo requests to its own gateway address from
> inside libslirp with no host privilege at all; forwarding a ping to a real external host needs raw
> sockets or `ICMP_PROTO` datagram permission on the host and **will fail on a locked-down CI
> machine**. This should be verified before N3 is planned, and it is one boot to verify.

---

### N4 — A descriptor is a network endpoint, and a program uses it

**Blocked on: N3, and on the reserved-name branch of §2.4** — which is shared with the display
protocol and should be its own small milestone.

`open("/net")`, the record format of §2.3, the channel table, UDP, and the client library in
`core/user/libc/`. A ring-3 C program sends a datagram.

*Binary:* the pcap contains the datagram, with a **correct UDP checksum over the pseudo-header**
verified on the host, carrying the exact bytes a host-side generator produced; and a host-side UDP
listener reached through SLIRP receives those same bytes. Two independent observations of one
datagram. *Negative control:* a program that opens a fifth channel must be refused with a value at or
above `fileRetFloor` and **the pcap must be unchanged** — nothing sent, nothing allocated, nothing
leaked, which is `m15-fileio`'s five-`open` assertion in a new place.

---

### N5 — A datagram comes back, and a program reads it

**Blocked on: N4.**

Inbound demultiplexing to a channel, the per-channel receive ring, the MORE bit of §2.3, and the
`while (read(fd,...) == 0) yield();` loop of §3.1 doing real work for the first time.

*Binary:* a host-side echo responder returns a **derived** payload larger than 496 bytes; the program
prints a hash of what it reassembled and it equals the generator's. *Negative control:* a build of the
program that ignores the MORE bit must print a **different, also derived** hash — the hash of the
first 496 bytes. That is the `m15-fileio` short-read pattern exactly, and it is what makes MORE
load-bearing.

**Q4 of §10 should be answered before this milestone**, because "is TCP wanted" changes whether N5 is
the end of the ladder or the middle of it.

---

### N6 — A TCP connection opens and closes

**Blocked on: N5, AND on IRQ0 being permanently unmasked (§4.4) — which is `display-protocol.md`
D3's item 4 and moves `m3-shell`'s byte-exact `ticks` golden (GAP-0058). Budget it; do not discover
it.**

The state machine, sequence arithmetic, the handshake and the four-way close. **No data.**

*Binary:* the pcap shows SYN, SYN-ACK, ACK and then FIN/ACK/FIN/ACK; the harness verifies **on the
host** that every acknowledgement number is the arithmetic successor it must be (`ack == isn+1` at
each step, wraparound included), which is the property most likely to be subtly wrong; and the kernel
printed its state transitions in the derived order. *Negative control:* a build whose sequence
comparison uses `<` instead of the wraparound-safe form must still pass the handshake and **must fail
a second connection whose ISN is chosen near the 32-bit wrap** — which is how you test sequence
arithmetic at all, and it needs the ISN to be settable by the harness.

---

### N7 — TCP moves bytes, and a delayed acknowledgement is recovered from

**Blocked on: N6.** This is the milestone that is really TCP.

*Binary:* the program transfers K bytes from a host-side generator; the host listener's SHA-256 of
what it received equals the generator's. Then, on a second boot, **`-object filter-buffer,interval=N`
on the host→guest direction delays the acknowledgement past the 1-second RTO** — so the guest
retransmits, and the pcap contains **two segments carrying the same sequence number** — and the
transfer still completes with the same hash. **`filter-buffer` is in this QEMU and it takes exactly the
options this needs — `netdev`, `interval` and `queue` (a `NetFilterDirection`, so the host-to-guest
direction can be delayed on its own), checked with `-object filter-buffer,help`. It is how loss is
simulated without a tap device, netem, or root.** *Negative control:*
a build with the retransmit path removed must fail the delayed boot — the hash must not match, or the
transfer must not complete — while still passing the undelayed one. **That control is the whole point
of the milestone.**

---

### N8 — A listening endpoint accepts an inbound connection

**Blocked on: N7, and on §4.6's real TIME_WAIT**, which a listening endpoint needs and an outbound one
does not.

*Binary:* `-netdev user,hostfwd=tcp::PORT-:GUESTPORT` gives the host a way in — the only direction
SLIRP will originate — and a host-side client connects, exchanges derived bytes, and closes. The pcap
and both endpoints' byte counts must agree. *Negative control:* a connection to a port nothing is
listening on must produce a **RST** in the pcap and no endpoint allocated, asserted through the
counters.

---

### N9 — DHCP, as a program

**Blocked on: N5 only** — deliberately, because it is a *program* and not kernel code (§1.5), and it
can be built in parallel with N6–N8 by somebody else.

*Binary:* boot with a `-netdev user,net=192.168.76.0/24,dhcpstart=192.168.76.9` the kernel cannot
know; the program configures the interface from the OFFER; the address it prints equals the one the
harness put on the command line; a subsequent ping to the derived gateway succeeds. **The expectation
comes entirely from the QEMU command line**, which is the strongest form this repo has.

---

### Blocked on something other than work

Three items, each shared with `display-protocol.md`, and **each should be built once**:

| wanted | what it is | who else wants it |
|---|---|---|
| **a reserved device name** (§2.4) | one branch in `fileSysOpen` on a leading `/`, before `fatParseAt` | `display-protocol.md` §2.4 (as `WSYS`) |
| **IRQ0 permanently unmasked** (§4.4) | one mask value; moves `m3-shell`'s `ticks` golden, GAP-0058 | `display-protocol.md` §6, D3 item 4 |
| **the slave-PIC path** (§6.3, fact 6) | cascade unmask, IRQ2, and an EOI to both PICs | `display-protocol.md` §4.4/D1, for the mouse on IRQ12 |

And one that is genuinely a language question rather than a work item:

| wanted | blocked by |
|---|---|
| **out-of-order TCP reassembly** (§8) and **IP fragment reassembly** (§5.4) | no growable collection in `@bare` — `verify-freestanding.sh` treats `dc_alloc` as a reserved symbol whose appearance means a collection grew. Both are cut in this design for that reason and both have named successors |

**Nothing else in N0–N9 is blocked on DCDart.** Fixed-size records, hand-indexed header fields,
sentinel returns, `if`-chains and a per-endpoint deadline word are all expressible today — which was a
design constraint, not a discovery.

---

## 10. What I did not decide, and would rather be told

Five questions. Each changes something downstream, each is cheap to answer and expensive to guess.

**Q1 — Is a network stack wanted at all, at this point in the project?** Nothing above assumes it is.
This machine has no network programs, no resolver, no notion of a remote anything, and §8's honest
answer is that TCP is a bigger unit than any single milestone M0–M19. **It is entirely defensible to
build N0–N3 — "the machine can ping" — and stop**, and that would be a real capability with a real
exit criterion for about a fifth of the total cost. I have laddered §9 so that stopping after N3, N5
or N7 each leaves something whole.

**Q2 — Confirm the kernel stack (§1.6).** I recommend shape (A) and gave four independent arguments,
of which §1.2's is the one I would defend on its own. It is **the most expensive decision here to
reverse**, because moving TCP from `@bare` DCDart to C is a rewrite and not a move (no `switch`, no
structs in signatures, no function pointers). A confirmation, or a redirection, is worth having before
anyone writes code.

**Q3 — Should there be a `now()` syscall (syscall 10)?** §2.3 puts a tick in every record header,
which covers everything on the receive path and costs 8 bytes. A program that needs the time when
*nothing has arrived* — a timeout on a `read` that keeps returning 0 — still needs one, and it is four
lines. **I lean yes, and I have not put it in the ladder** because it is the kind of thing that should
be added when a program actually needs it rather than in advance. Syscalls 0–9 are taken; 10 is free.

**Q4 — Is a loopback interface wanted (§7.1)?** It is easy, it is a superb test vehicle (N4–N7 could
be built and tested with no NIC at all), and **it would be the first IPC on this operating system** —
two programs able to talk to each other. That last property is exactly why I did not put it in: the
first IPC on this OS should be a decision somebody took, not a side effect of a network stack.

**Q5 — May the reserved-name branch (§2.4) be built as its own milestone, spelled with a leading
`/`?** It serves this document and the display one, it is one test on one byte, and `/net` cannot
collide with any name a FAT volume can hold whereas `NET` and `WSYS` can. **This is the smallest
question here and it blocks two designs**, so it is the one I would most like answered first.

---

## 11. Notes for the coordinator to fold in elsewhere

**I have not touched `known-gaps.md` or `ROADMAP.md`**, per instruction. These are the things that
belong in them, with my reasoning, for whoever folds them in.

**GAP-0067 needs two corrections, and they are corrections in the cheerful direction.** Item 2 says
configuration space is read-only and lists bus-master enable among what that rules out — **and on this
machine the firmware has already set it** (§0.2 fact 4, `cfg[0x04] = 0x0107`). The gap is still real
and still worth closing; what should change is the *consequence* attributed to it, because as written
it says a DMA-capable device cannot be driven, and the measurement says otherwise. Item 4 says the
capability list is not followed and that "every modern interrupt path for a PCI device starts there" —
true, and **`cfg[0x34] = 0` on this device on this machine**, so it costs a NIC nothing here. Both
entries would be improved by a sentence saying what was measured.

**A new gap that this design would create and that should be recorded when it lands.** The stack
depends on firmware having enabled memory decode and bus mastering, and §6.4's answer is to *check and
refuse* rather than to *set*. That is the right answer for a first milestone and it is a dependency on
something outside the kernel, which is exactly what `known-gaps.md` is for.

**GAP-0058 is upstream of more than it says.** It reads as a testing convenience — the PIT is masked
at rest so `ticks` is byte-exact assertable. It is also, per §4.4, the reason **this machine would be
off the network whenever it is idle**, and per `display-protocol.md` D3 item 4 the reason a resident
compositor cannot exist. Two designs blocked by one golden is worth a line in the entry.

**Three gaps are upstream of this whole document** and their entries read as scheduler or console
limitations rather than as the network blockers they also are:

* **GAP-0097 / GAP-0141 — nothing blocks.** This is why the buffers must be in the kernel (§1.2), why
  the receive window doubles as backpressure (§3.3), and why a userland stack server is not merely
  inadvisable but inexpressible (§1.3).
* **DCDart GAP-0034 — every `Pointer<T>` access is volatile.** For the framebuffer this is a performance
  ceiling; here it is **both** — the performance ceiling on checksums (§1.4) and the correctness
  guarantee that makes MMIO register access safe without any language feature (§6.2). Worth recording
  that it cuts both ways.
* **GAP-0120 — an unread counter is a mutation survivor.** §5.4 adopts the rule; the entry deserves to
  be findable from any new subsystem, because it is a rule about how to write kernels here rather than
  a fact about `fatMetaHits`.

**A harness improvement that is not about networking.** `drive_session()` is shared by more than a
dozen harnesses and every one of them currently boots with a live e1000 and a live SLIRP network
nobody asked for (§0.2 fact 2). **That is an unasserted degree of freedom in every existing golden.**
Adding `romfile=` to all of them — or `-nic none` where a network is genuinely unwanted — makes the
machine those goldens describe smaller and more definite, and it is a purely additive change to one
function.

**A note the display unit will want.** §2.4 argues that `WSYS` should be `/wsys`, for a reason that
did not exist when `display-protocol.md` was written: **this OS now writes files**, so a reserved name
that is also a legal 8.3 name is a collision that can actually happen. The mechanism in
`display-protocol.md` §2.4 is unchanged and correct; only the spelling moves, and it is cheaper to
move it before either device exists than after both do.

**A tooling note.** Reading a pcap needs no host dependency: `filter-dump` writes a classic
little-endian pcap and forty lines of `struct.unpack` parse it (§0.2 fact 10). **Do not add scapy or
tshark to this project's host requirements for this.** The parser should live where `qmp-drive.py`
lives, additively, for the same reason that file is shared by seventeen harnesses and must only ever
grow.
