# The oscortex display protocol — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered, nothing implemented.** This document exists so that the
agent who builds the first piece does not have to re-decide anything. When a piece is built it gets
its own numbered ADR; this file is the thing those ADRs will point back at.

**Provenance of the one decision that is already made.** The owner has chosen **an own display
protocol rather than Wayland compatibility**. That decision was **relayed to me by the coordinator and
not witnessed by me**, and this project records the difference. It is consistent with a call the owner
made one layer down — a native syscall ABI with a Linux compatibility layer deferred, explicitly
accepting that nothing from the C ecosystem runs until a libc is ported — and the argument is the same
one level up: **Wayland is Linux's paradigm**, so adopting it contradicts the premise. §5 is the
honest price of that choice, written out rather than implied.

**Everything else in this document is a proposal.** Where I am genuinely unsure I say so and give the
options rather than picking silently.

### The four things decided here, for a reader in a hurry

| | decision | where |
|---|---|---|
| **Pixels** | **Copy on commit**, not a shared frame. Three independent arguments land there, and it is the reversible choice. | §1.3 |
| **Transport** | **One synchronous syscall**, request in and reply out, with **input events riding the reply** — because nothing can block. A handle array is **reserved and unused** so the wire format never has to change. | §2.2 |
| **Presentation** | **The kernel owns the framebuffer and page-flips.** Ring 3 cannot execute `out`, so this was never a choice. There is 16 MiB of VRAM and the flip register is already driven. | §3.1, §3.2 |
| **Input** | **The compositor owns focus; the kernel knows nothing about surfaces.** But first there must be an input queue at all — today there is none. | §4 |

**What to build first: D3 — a process that outlives the command that started it (§6).** It has almost
nothing to do with display, it is the one thing every other milestone waits on, and its exit criterion
is written in terms of counters that already exist. Until it lands there is nowhere for a compositor
to live.

**And the two findings that surprised me most**, neither of which is about graphics:

* the binding constraint on a window system is **the 2 MiB ring-3 address window** — a full-screen
  surface is 1.92 MB of it (§1.2); and
* mapping one physical frame into two address spaces is **unsound today**, in a way that is silent at
  the machine level and only loud at the harness level (§1.3). That is the most dangerous thing in
  this document, and it is most of why the recommendation is the option that never creates it.

---

## 0. What this has to be true of

Three constraints shape every choice below, and they are properties of this machine rather than
tastes:

1. **There are no sockets, no `mmap`, no fd passing, and no `poll`.** Anything that assumes them is
   not a design for this OS, it is a description of Linux.
2. **The kernel is one compilation unit and every harness asserts a byte-exact serial capture.** A
   design that needs six kernel subsystems changed at once is a design that cannot be landed
   incrementally here, and this project lands things incrementally with a binary exit criterion each
   time.
3. **`@bare` DCDart is a small language.** Anything the protocol needs that the language cannot
   express is a DCDart milestone before it is an oscortex one, and §6 marks those separately.
4. **NOTHING ON THIS MACHINE CAN BLOCK.** `proc.dart` has five process states — FREE, READY, RUNNING,
   EXITED, KILLED — and there is no sixth. GAP-0141 puts it in three words: *"Nothing ever waits."*
   No sleep, no wakeup, no signal. This is upstream of more of the design than anything else here: it
   is why events ride the reply (§2.2) and why a Wayland client would be impossible even with sockets
   and shared memory (§5.2).

---

## 0.1 Naming, so the rest of the document is unambiguous

| term | meaning here |
|---|---|
| **surface** | a rectangle of pixels a client owns and draws into |
| **compositor** | the one process allowed to touch the framebuffer |
| **client** | any other process that has a surface |
| **present** | the client telling the compositor "this region of my surface is now what I mean" |
| **damage** | the region a client says changed since its last present |
| **frame** | one composition pass, ending in bytes reaching the display |

**Deliberately NOT called "window".** A window has a title bar, a close button, a stacking order and a
manager. A surface has pixels and a position. Window management is a policy that lives in the
compositor and is not part of the protocol — see §5.

---

## 1. The object model, and the constraint that actually binds

### 1.1 A surface

A **surface** is a rectangle of pixels with a size, a position, a format and an owner. Format is
`0x00RRGGBB` little-endian, 4 bytes per pixel, because that is what the hardware scans out
(`fb.dart:224`) and a second format means a converter nobody has asked for.

Position is **compositor policy, not client property.** A client asks for a size and is told where it
is; it does not choose. That is one sentence of protocol and it removes an entire class of question
(what happens when two clients both want to be at 0,0).

### 1.2 THE BINDING CONSTRAINT IS NOT THE FRAMEBUFFER — IT IS THE 2 MiB USER WINDOW

This is the most important thing in this document and it is not what I expected to find.

The ring-3 address window is **`vmProgBase = 0x10000000` to `vmProgEnd = 0x10200000` — 2 MiB,
512 pages, one page-directory entry** (`vm.dart:1976`). Inside it, index 511 is the stack, index 510
is a permanently-unmapped heap guard page, and the heap grows up to index 509.

**A full-screen surface is 800 × 600 × 4 = 1,920,000 bytes.** That is 469 pages of a 512-page window —
it would leave a client 43 pages for its code, its heap and its stack, and it would leave a compositor
no room to hold a composed frame at all.

So: **you cannot have a full-screen surface in a client's address space today, and this is the thing
that has to move before a window system is possible.** It is a bigger constraint than the transport,
than damage, than the mouse. Three ways out, and I do not think this is my decision:

1. **Give ring 3 more address space — but NOT by growing `vmProgEnd`.** The window is one
   page-directory entry today. `vm.dart:1958` says `[128 MiB, 1 GiB)` holds "62 unused
   page-directory entries"; **that number is wrong and I repeated it.** A page directory covers
   1 GiB in 512 entries of 2 MiB, so `[128 MiB, 1 GiB)` is 896 MiB — **448 entries, of which 447 are
   free.** The 62 is the count of the *preceding* range `[4 MiB, 128 MiB)`, which is used. The
   memory specialist also found a second reserve nobody has touched: **PDPT entries 1 and 2 are
   unwritten, so `[1 GiB, 3 GiB)` of kernel virtual space is unclaimed** (`vm.dart:1168-1169` writes
   only 0 and 3).

   **And the cheap way to spend it is not to widen `vmProgEnd`.** That constant is doing two jobs —
   it bounds where an ELF may load *and* it bounds what ring 3 may address — and **47 golden
   window-address occurrences** across the harnesses depend on the second. Splitting it into a load
   bound (unchanged) and a new `vmUserEnd` leaves `heapTop`, the guard page, the stack, all nine
   `prog.ld` files and every one of those goldens alone. That is a much smaller change than the one I
   proposed and it is the memory specialist's recommendation, not mine.
2. **Small surfaces only.** A 256 × 256 surface is 256 KB — 64 pages, comfortable. Every milestone in
   §6 up to D7 works with small surfaces. **This is what I would build first**, and it defers the
   decision without pretending it is not there.
3. **Compose in strips.** The compositor never holds a whole frame: it composes a band at a time into
   a small buffer and asks the kernel to blit each band. Works in today's window, costs a syscall per
   band, and makes damage tracking more valuable rather than less.

**Recommendation: build D1–D7 on (2), and treat (1) as its own milestone with its own ADR** — because
"how big is a program's address space" is exactly the kind of thing that should not be decided as a
side effect of a display protocol.

### 1.3 Where a surface's pixels live — REVISED, and the revision is the point

**I got this wrong the first time and the correction is worth more than the original.** My first
answer weighed a shared frame against copy-on-commit and recommended copy-on-commit. A survey of how
minimal window systems actually do this came back with the arithmetic I failed to do:

> **`fileWriteMax` is 512 bytes. That is 128 pixels. One sixth of one scanline.**

**Sending pixels through this OS's transport is not slow — it is structurally impossible.** A 256×256
surface is 512 `fdwrite` calls per repaint. The question "shared frame or copy?" was the wrong
question, because both answers assume the protocol moves pixels.

#### What replaces it: the client never owns pixels at all

**Server-side allocation, drawing verbs, and a server-side backing store** — the Plan 9 `/dev/draw`
model, which is 30 years old, is a *file* protocol (which matters here, because this OS has files),
and was designed for machines with less than this one has.

A client does not get a buffer. It gets an **image id**, and it draws by sending verbs:

```
   'F' fill rect        'd' draw/blit from a server-owned image
   's' glyph run        'L' line
   'o' move             't' restack        'v' flush (present)
```

A `d` verb is about 36 bytes, so **one 512-byte `fdwrite` carries roughly fourteen drawing
operations** instead of 128 pixels. That is the difference between a protocol that works and one that
cannot.

#### What this deletes — and it is most of the hard parts of this document

| problem | status under this model |
|---|---|
| shared-frame lifetime, the `freeFrame` use-after-free (my §1.3 Option A) | **gone.** No frame is ever mapped into two address spaces. `pmm.dart` and `vm.dart` need no change and no harness assertion needs inverting |
| the copy cost, made brutal by DCDart's volatile-everything (GAP-0034) | **gone.** Verbs are tens of bytes; the server draws once, in place |
| a buffer-release protocol | **never exists.** Wayland's `wl_surface.get_release` is scar tissue from getting this wrong; there is nothing to get wrong when the client holds no pixels |
| expose/repaint events, and a display list in every client | **gone.** The server keeps per-window backing store (Plan 9's `Refbackup`). Plan 9's client-repaint mode `Refmesg` is documented as *an incomplete implementation* — even they never needed it |
| the 2 MiB user window (§1.2) as a blocker | **much weaker.** A client needs room for a batch buffer, not for a framebuffer. §1.2 still matters for the *server*, not for every client |

**§1.2's constraint has not vanished, it has moved.** The compositor still needs somewhere to compose.
But a soft screen belongs to one process, not to every client, and §3.4 is where that is now sized.

#### What it costs, stated plainly

* **The verb set is now load-bearing.** If a client cannot express what it wants to draw, it has no
  fallback — pixel upload exists (`'y'`) but at 128 pixels per syscall it is an escape hatch, not a
  path. Fonts, blits and rects must cover the real cases.
* **The server draws for everybody**, so a slow client is a slow server. Plan 9 lived with this.
* **A GPU would change the calculus**, and this is the one place where the design has a ceiling.
  Verb-based protocols are what you want when the server draws in software; a GPU wants buffers and
  command rings. That is a bridge to cross when a GPU exists, and §5 is honest about how far away that
  is.

**Recommendation: server-side allocation with drawing verbs. Both of my earlier options are
withdrawn.**

### 1.4 If a shared frame is ever wanted anyway: where the page goes, and the hazard first

The window is full at the top: 511 stack, 510 heap guard, heap growing to 509. The cheapest clean
answer is **index 509 (`0x101FD000`), with `heapTop` moved down one page** — three constants in
`heap.dart` and the derived checks in `m12-heap`. Index 510 would cost the guard page, which
`m12-heap` explicitly asserts is never mapped, and that guard is worth more than a page.
## 2. The transport — REVISED: no new syscall at all

**My first proposal was a new syscall 11 carrying a fixed request and reply. It is withdrawn**, for
the same reason §1.3 changed: once the protocol carries *verbs* rather than pixels, the machinery to
carry it **already exists and was built by M15 and M16.**

### 2.1 The clone-file idiom

Plan 9's `/dev/draw/new` is a file you open to get a private session. Applied here:

```
   fd = open("WSYS")              the fd IS the session. No handshake, no connect, no registry.
   fdwrite(fd, batch, <=512)      a batch of binary verbs
   read(fd, buf, <=512)           fixed-width event records; returns 0 when there are none
   close(fd)                      the session ends, the server frees the client's windows
```

**That is four calls this OS already has**, with the refusal floor, the four-descriptor limit and
**both** pointer validators that M16 mutation-tested. A display protocol that adds **zero** syscalls
and inherits a pointer-safety property that has already been attacked by fourteen mutants is a better
outcome than anything I proposed on day one.

**A session costs one of a process's four descriptors** (`fileMaxFds = 4`). That is a real budget and
worth stating.

### 2.2 Events: a non-blocking read plus `yield`

§0 constraint 4 stands — **nothing on this machine can block.** So `read` on the session fd returns
whole event records or **returns 0 immediately**, and a client loop is:

```
   while (read(fd, ev, sizeof ev) == 0) yield();     /* syscall 3, already exists */
```

**This is the correct answer for this OS and not a workaround.** It needs no fifth process state, no
wait queue and no wakeup — none of which exist (GAP-0141: *"Nothing ever waits."*). It costs a spin
through the scheduler, which since M18 is preemptive and will not hang the machine.

**What it costs:** a client polls. **The fix is now specified elsewhere and is smaller than I
assumed.** The scheduler specialist's `blocking-and-threads.md` designs it as:

```
    fdwait(mask, timeoutTicks) -> readyMask        syscall 11
```

A **bitmask, not an array** — `fileMaxFds` is 4, so a descriptor set fits in a nibble, which means
**no pointer, which means no new validator**. A **tick deadline, not milliseconds**, on ADR-0022 §10's
argument that a millisecond timeout can only be asserted with a tolerance while a tick deadline is
exact on any host. `sleep` is `fdwait(0, n)` and a poll is `fdwait(mask, 0)` — one primitive, one
block point.

**So the client loop above is the temporary form, not the permanent one**, and the permanent one costs
one syscall rather than a subsystem. A window system can be built on either.

### 2.3 Batching is what makes 512 bytes enough

Plan 9's `libdraw` accumulates verbs in a userland buffer (`bufimage`) and flushes on full or on
present (`flushimage`). **Applications almost never call it explicitly.** Here that means: the client
library batches, and one `fdwrite` carries ~14 drawing operations instead of one.

**Without batching this design does not work** — a syscall per rectangle would be worse than the
pixel-copying design it replaces. The batch buffer is the client library's single most important
piece and it belongs in `core/user/libc/`, not in the kernel.

### 2.4 This sharpens Q1 rather than answering it

`open` resolves an 8.3 name in the **root directory of the mounted FAT volume**. `WSYS` is not a file
on a disk. So the namespace question from my first draft has not gone away — but **its price has
changed completely**, and in the direction that makes it worth paying:

* **Before:** a namespace would save one syscall.
* **Now:** a namespace buys **the entire transport** — open, read, write, close, refusals, validators,
  descriptor accounting — for the cost of *one name that is not on the disk*.

**My recommendation has flipped.** I now think the device name is right, and the narrowest possible
version is one branch that recognises a single reserved name — not a `/dev` tree, not a mount table,
not a VFS, the way ADR-0029 added one port primitive rather than inline assembly.

**BUT I PUT THE BRANCH IN THE WRONG FUNCTION, AND AS WRITTEN IT WAS A VOLUME CORRUPTION.** I said
"`fatLookup` gains one branch". The namespace specialist showed why that is unsafe, and the reasoning
is about code I wrote myself at M16:

> `fatLookup` has **four** callers — the read `open`, `fileMakeEmpty` (from `open(…, O_WRITE)`),
> `shellFatCat`, and `shellElfRunName`. They disagree about what its return codes mean.
> `fileMakeEmpty` treats `fatErrOk` **and** `fatErrEmpty` as *"the entry is there"* and then calls
> `fatTruncate(first)` and `fatDirWrite(entry, 0, 0)` using `fat_store`'s metadata words. **So a
> device branch in `fatLookup` makes `open(":WSYS", O_WRITE)` a ring-3-reachable volume corruption**
> — and returning `fatErrNotFound` instead is no better, because then the write path *creates a real
> file that permanently shadows the device.* There is no safe return value.

**The correct placement is `fileSysOpen` (`file.dart:1360`)** — after the pointer-validated copy into
the bounce buffer, before `fatParseAt`. Same one branch, same zero new syscalls, and it leaks into
nothing.

**And the name should carry a sigil: `open(":WSYS")`.** `:` is one of the fifteen bytes
`fatNameByteBad` already forbids — a check I added at M16 for a completely different reason — so
device names and disk names are disjoint **by construction**, which deletes the shadowing and
ordering questions rather than answering them. Not `#` (legal in FAT); not `/` (a future path grammar
wants it).

Q1 in §7 asks for confirmation of the *direction*; the placement above is no longer in question.

**Two specialists proposed different sigils and I am keeping `:`.** The network-stack specialist
independently reached the same clone-file conclusion and proposed `/` — "illegal in 8.3,
collision-proof, one byte test". It is collision-proof, but the namespace specialist's objection is
the stronger one: **`/` is the character a future path grammar wants**, and spending it on a device
sigil now forecloses `SUB/X.TXT` later for no gain, since `:` is equally illegal and equally cheap.
Both are already in `fatNameByteBad`'s fifteen forbidden bytes.

### 2.5 Reserve the handle slot anyway

§5.3's argument is unchanged and survives the redesign: **reserve four words in the verb-batch header
for out-of-band handles, defined as "must be zero".** Nothing fills them today. If a GPU ever arrives,
or a bridge, buffer handles are what they will need, and a wire format that has nowhere to put them is
a wire format that gets a version 2.

---

## 3. Damage and presentation

### 3.1 The fact that settles who owns the final blit

**Presentation is necessarily a kernel operation, and not because of taste.** The Bochs VBE registers
are I/O ports — `vbeIndexPort = 0x1CE`, `vbeDataPort = 0x1CF` (`fb.dart:153`) — and **ring 3 cannot
execute `out`**: there is no IOPL grant and no I/O permission bitmap in the TSS (m9-ring3 asserts the
TSS has no I/O bitmap). A compositor in ring 3 therefore *cannot* flip a page or change a mode however
much of the framebuffer it can see. The final act of presentation is a syscall, and that is a property
of the hardware rather than a policy anyone chose.

### 3.2 There is more VRAM than anyone has used, and the flip register is already being written

Three facts from the machine, and together they are better news than I expected:

* The BAR is **16 MiB at `0xFD000000`**, discovered from PCI class 0x03/0x00 BAR0 (`fbFindVgaBar`,
  `fb.dart:319`) and stored in `fbStateBlock` word 0.
* A frame is **800 × 600 × 4 = 1,920,000 bytes**. Sixteen mebibytes holds **eight of them.**
* `fbSetMode` **already writes `vbeRegYOffset = 9` and `vbeRegVirtWidth = 6`** (`fb.dart:392`) — it
  sets the virtual width to 800 and the offsets to zero precisely so the computed pitch is the real
  pitch. **The register that scrolls the scanout origin is therefore already understood and already
  driven by this kernel.**

**So this machine can page-flip.** Draw into an off-screen frame in VRAM, write one 16-bit value to
`0x1CF`, and the display begins scanning out the other frame. That is real double buffering, it costs
one port write, and none of it needs a copy.

### 3.3 What that buys, and the honest limit

Today `conPutc` blits glyphs **straight into the scanned-out framebuffer** — GAP-0070 item 6 says so
and calls it "invisible at this rate; it stops being invisible the moment anything animates." A
window system animates.

With a flip:

* **No shearing.** A slow blit into the live buffer tears wherever the beam happens to be, and a full
  screen is 480,000 individual `u32` stores (`fbFill`, `fb.dart:436`) — a very long time to be racing
  the beam. A flip replaces that race with a single register write.
* **It does not eliminate tearing, and I will not claim it does.** There is **no vblank interrupt of
  any kind** — the std VGA device's interrupt line is never read from config space and never unmasked,
  and a repo-wide grep for vsync/vblank/retrace finds only two prose lines and zero code. A flip issued
  mid-scanout still shows the top of one frame and the bottom of the next. What it removes is the
  *partial-blit* tear; what remains is a whole-frame tear at the flip point.
* **The honest options for going further**, none of them free: poll the VGA input-status register at
  0x3DA for the retrace bit (a busy-wait in the kernel with interrupts off — the thing this project
  keeps refusing to do unbounded); or wait for a real display interrupt, which this device does not
  offer through the path the kernel currently uses. **My recommendation is to flip, accept the
  whole-frame tear, and record it** rather than spin.

### 3.4 Where the pixels live on the way to the screen — revised

**I drafted this section once before reading `vm.dart` and got it wrong**, and the correction is worth
keeping visible because it is the same constraint as §1.2. My first proposal was to map VRAM
user-writable into the compositor so it could draw straight into the off-screen frame and the kernel
would only flip. **That cannot work: the ring-3 window is 2 MiB and two frames of VRAM are 3.84 MB.**
The compositor cannot see enough VRAM to compose into it.

**The corrected proposal, which is simpler than the one it replaces:**

```
   client surface (shared frame, client writes)
        │  compositor reads and composes
        ▼
   compositor's composed buffer  (ordinary user pages, in its own window)
        │  ONE syscall: present
        ▼
   off-screen VRAM frame   (kernel copies — ring 3 never touches VRAM)
        │  one 16-bit port write to 0x1CF
        ▼
   scanout
```

Four properties fall out of it, and all four are good:

1. **Ring 3 never touches video memory.** No client and not even the compositor gets a writable
   aperture onto the display. The isolation M8/M9/M11 built stays intact and no PCI-hole page ever
   becomes user-accessible.
2. **The copy does not tear.** It lands in the frame that is *not* being scanned out. Today
   `conPutc` blits glyphs directly into the live framebuffer — GAP-0070 item 6 calls that "invisible
   at this rate; it stops being invisible the moment anything animates."
3. **The flip is one port write**, and it must be a syscall regardless (§3.1): ring 3 cannot execute
   `out`, so presentation was always going to be a kernel operation.
4. **It works in a 2 MiB window**, either with small surfaces or by presenting a band at a time —
   which is what makes it buildable before the window question of §1.2 is settled.

**What it costs, stated plainly:** one copy per presented region, in a kernel whose copy loops are
byte-at-a-time. That is the price of not handing ring 3 the display, and I think it is obviously worth
paying. It is also the number that makes damage tracking (§3.5) worth building rather than optional:
the copy is proportional to the damaged area, so a blinking cursor costs a cursor, not a screen.

**The VRAM arithmetic, since the next agent will need it.** The BAR is 16 MiB at `0xFD000000`; a frame
is 1,920,000 bytes; eight frames fit. Two are enough. Frame 0 is at Y-offset 0, frame 1 at Y-offset
600 — `Y_OFFSET` is expressed in **lines**, and `fbSetMode` already writes both `VIRT_WIDTH` and the
offsets (`fb.dart:392`), so the register is already understood by this kernel. The PCI hole is mapped
supervisor and NX (`vm.dart:1196`), which is exactly right for a region only the kernel writes.

### 3.5 Damage

**Per-surface damage rectangles, unioned by the compositor into a dirty region, and only the dirty
region is composed.** The client says "this rectangle of my surface changed"; the compositor unions
those with the rectangles vacated by anything that moved, and composes that.

**Why not whole-surface repaint:** a full screen is 480,000 stores today. A blinking cursor should not
cost 480,000 stores.

**Why not a fancy region algebra:** an exact region requires a data structure `@bare` DCDart cannot
express yet (§6). **A bounding-box union of the damage rectangles is one function and four `u64`s**,
it over-draws and it is never wrong. Start there; the exact-region version is a later milestone with a
measurable win (pixels composed per frame is a number the kernel can print, exactly as
`fatMetaReads`/`fatMetaHits` made caching a number).

**With a flip there is a subtlety that must be written down:** damage is per-*buffer*. After a flip
the back buffer is two frames stale, not one, so a compositor that composes only the current damage
into the buffer it is about to show will leave the previous frame's damage unrepaired. The fix is
either to keep damage for both buffers and compose the union, or to compose full frames. **This is the
single most likely bug in the first implementation** and it belongs in the ADR that builds it.
## 4. Input routing — and the two things that must exist before any of it

**This section is the consumer of item 1 in the ladder, so it specifies what item 1 must deliver.**
Two findings from reading the machine changed what I was going to write, and both are load-bearing.

### 4.1 There is no keystroke queue at all. Depth zero.

`kbdHandle` (`keyboard.dart:222`) reads port 0x60, runs the `0xE0` prefix state machine, indexes a
128-entry scan-code-set-1 `@rodata` table, and calls `shellKey` — **which appends to the shell's line
buffer and echoes to the screen, all in interrupt context, before the EOI.** Nothing is queued for
later. The only storage between the interrupt and the consumer is the 256-byte *line* buffer, and that
is not a queue: there is no head, no tail, no ring.

And there is a guard at `keyboard.dart:263`:

```
if (shellState() > 0) return;
```

**While a command is running, every keystroke is discarded silently** — no queue, no echo, no
diagnostic. Type-ahead capacity while a process is on the CPU is **zero bytes**. GAP-0055 item 4
already records this.

So item 1 is not "route input to a surface". Item 1 is **"there is an input queue at all"**, and
routing is what the milestone after it does.

### 4.2 What item 1 must deliver, specified

1. **A ring buffer in `@bss`**, head and tail, written by the IRQ handler and read in task context —
   with the `cli`-around-the-test discipline `shellMain` already uses (`shell.dart:1626`), because
   the producer is an interrupt handler and the consumer is not.
2. **A defined overflow rule with a visible counter.** A queue that drops the oldest event silently
   turns a missed keypress into a mystery. Drop, count, and let the count be readable — the same
   instinct as `fatMetaHits` and `procHeadKernTicks`.
3. **A reset in `shellRecover`** (`shell.dart:1594`). That function already resets `shell_len`,
   `shell_state` and `kbd_prefix` after a fault, and issues a bare `picEoiMaster()` because a fault
   inside an IRQ handler abandons that handler's EOI (GAP-0062). **A queue that is not reset there
   survives a fault with stale contents.**
4. **Raw events, not characters.** The shell wants ASCII; a surface wants a key *identity* and a
   press/release edge. The existing table throws both away — break codes are dropped at
   `keyboard.dart:252` and modifiers map to `0x00`. An event queue that stores translated ASCII cannot
   ever support a shift key, and this OS has no shift handling today (GAP-0055). **Store the scancode
   and the edge; translate at the consumer.**
5. **The shell keeps working.** The shell must become *a consumer of the queue* rather than a thing
   the IRQ handler pokes directly, or there will be two input paths that disagree.

### 4.3 Routing, once a queue exists

**Proposal: the compositor owns focus and the kernel knows nothing about surfaces.**

The kernel delivers input events to **one process — the compositor** — and the compositor decides
which surface they belong to and hands them on in that client's next reply (§2.2). The kernel's model
stays "there is a process that receives input", which is one concept, not a window system in ring 0.

* **Keyboard → the focused surface.** Focus is compositor policy. The proposal is click-to-focus with
  an explicit "focus follows the topmost surface at the pointer" fallback when there is no pointer yet.
* **Pointer → the topmost surface whose rectangle contains the point**, with coordinates delivered
  **surface-relative**, because a client that has to know its own screen position to interpret a click
  is a client that breaks when the compositor moves it.
* **Enter/leave events** so a client can stop drawing a hover state it can no longer see. Cheap, and
  the absence is the kind of thing that gets discovered as a visual bug rather than a missing feature.

**What I am unsure about, stated rather than guessed:** whether the compositor should be the *only*
recipient of input, or whether the kernel should keep delivering to the shell when no compositor is
running. The first is cleaner; the second means the machine still has a usable console if the
compositor dies. **I lean toward the second — a compositor that crashes should not take the keyboard
with it** — but it means the kernel has a notion of "input goes here now", which is a small piece of
policy in ring 0. This is a question worth an owner's answer.

### 4.4 The mouse does not exist, and here is exactly what it costs

Not one line: no `IRQ12`, no `mouse`, no `0xA8`, no `0xD4` anywhere under `core/`. The 8042 command
port at 0x64 is **never written** — `kbdInit` deliberately uses SeaBIOS's power-on state as-is
(`keyboard.dart:12`). And **the slave PIC is masked `0xFF` at every point in the kernel**, so even if
IRQ12 fired it would be dead.

A mouse milestone is therefore, precisely:

1. enable the auxiliary port (`0xA8`) and write to it (`0xD4`) to enable reporting;
2. unmask **IRQ2, the cascade** as well as IRQ12 — this is the first time the slave PIC is used at all;
3. a vector `0x2C` arm in `isrDispatch`;
4. **EOI to both PICs**, which no existing path does;
5. a three-byte packet state machine, with the overflow/desync recovery that PS/2 mice need.

**AND A SIXTH STEP I MISSED, which the network specialist found while costing the same problem for
IRQ 11.** The PIC mask in this kernel is not read-modify-write — it is a **literal whole-byte `out`
at six separate sites**: `keyboard.dart:173` and `:190`, `kmain.dart:272`, `shell.dart:1085` and
`:1090`, `proc.dart:2006` and `:2434`, and `vga.dart:426`. **Every one of them re-masks everything it
did not name.** So a mouse IRQ unmasked in step 2 works until the next `ticks` command and then stops,
silently, with no diagnostic — and the same is true of a NIC, a disk interrupt, or any future device.

**This is a cross-cutting blocker on every interrupt-driven device this OS will ever have, and it is
not recorded anywhere.** It also is not free to fix: `m18-preempt` asserts those site counts exactly,
so consolidating them behind a single mask accessor moves a harness assertion. The network design
routes around it by polling for its first seven milestones and taking interrupts only at the eighth;
**a mouse cannot do that**, because polling a PS/2 port from a shell loop is not a design anyone
wants. So for input, the mask consolidation is a prerequisite rather than an option.

Even so this remains a self-contained milestone with a binary exit criterion, touching
`interrupts.dart`, `keyboard.dart` and the six mask sites, and it is independent of everything else in
this document.
## 5. What this deliberately does not do, and what the owner's choice actually costs

### 5.1 Not in the protocol, and not by accident

No window decorations, no title bars, no minimise/maximise, no stacking commands from clients, no
subsurfaces, no transforms or scaling, no transparency or alpha blending, no clipboard, no drag and
drop, no multiple outputs, no hotplug, no colour management, no scaling for high-DPI, no GPU, no
hardware cursor, no screen capture, no remote display.

**Window management is compositor policy and is not part of the protocol at all.** A client asks for a
size and is told where it is (§1.1). Everything in the list above is a thing that can be added to a
compositor without changing one byte of the wire format, and that is the test I applied.

### 5.2 The price of the owner's choice, itemised

The owner has chosen a native protocol over Wayland compatibility. **Nothing from the existing
graphical software ecosystem will run on this OS**, and the honest measure of that is what a
compatibility layer would have to bridge *later*, if anyone ever wants it.

**The blocker is not sockets and not shared memory.** It is that **nothing on this OS can block.**
`wl_display_dispatch` is `poll` plus read; registry enumeration alone needs two blocking round trips
before a client can draw anything. GAP-0097 — restated at M18 as "there is no fifth state, so a disk
read spins the whole machine" — is upstream of every other item here. **Without a scheduler that can
suspend a process inside a syscall there is no Wayland client of any kind, however thin the rest of
the shim is.**

After that, in order of how hard they are to retrofit:

| what a client needs | thin shim or deep port |
|---|---|
| `SCM_RIGHTS` fd passing over the connection | **The single hardest thing to retrofit.** Buffers, keymaps, clipboard all ride on it. See §5.3. |
| `poll` on the connection with a timeout | **Deep** — it is GAP-0097 again |
| `mmap(MAP_SHARED)` of an anonymous, growable memory object | **Medium-to-deep.** The PMM and page mapper exist; the *object* does not, and `sbrk` is the only way to get a page today |
| dynamic linking (`PT_INTERP`, `PT_DYNAMIC`) | **Deep.** `elf.dart:1280` refuses both by name. Avoidable for a static client; unavoidable for GTK, which `dlopen`s at runtime |
| threads, TLS, futexes | **Deep.** libwayland links mutex ops unconditionally |
| `clock_gettime(CLOCK_MONOTONIC)` | **Thin** — arithmetic over the PIT tick counter that already exists |
| environment variables | **Medium**, and M19 already built the hard half of the initial stack |
| the wire format itself | **Free.** Pure userspace parsing, no OS support at all |
| libinput / evdev / udev | **Not required, and should be explicitly ruled out.** A Wayland *client* never touches them — input arrives over the protocol. They only matter if someone wants to run an unmodified Linux *compositor*, which is a far deeper port |

**And the libc, which is the number that makes the scale concrete — AMENDED, because the C-library
specialist measured what I estimated.** I wrote "roughly twenty symbols"; that was the M13 figure.
`x86_64-elf-nm` over the six libc objects built with the harnesses' own flags reports **41 exported
symbols** (35 `T`, 6 `R`) — but only **nine are C89 names, and 130 of C89's ~139 functions are
absent.** The growth since M13 has been almost entirely oscortex-only names, which is the honest
shape: the library got bigger without getting more standard.

A hand-written Wayland client needs **80–120**. ffmpeg needs **~220–260** — *beside* Cairo rather than
above it, because `libavutil/libm.h` ships its own fallbacks for about twenty-five math functions. A
GTK application needs **800+ plus a working dynamic linker**, which is not a libc port but a Linux
personality.

**And the correction that matters more than the count: ffmpeg is not blocked by the libc. It is
blocked by this kernel** — a 2 MiB address space against a 20–60 MiB working set, a 4 KiB stack that
cannot grow, `READ_MAX` of 512, four descriptors, 8.3 names in one root directory, and **append-only
writes, so no container format can be muxed at all.** That last one is M16's, which is mine. A design
that can only append cannot seek back to patch a header, and every container wants to.

**The honest summary, revised: the gap between "no client" and "a Cairo client" is one order of
magnitude of libc; the gap between that and GTK is another; and the gap between either and ffmpeg is
not libc at all, it is address space and file semantics.**

### 5.3 Three decisions to take NOW that make a future bridge cheap and cost the native design nothing

These are the part of this section that is actionable rather than descriptive. **Each is defensible on
native grounds alone** — that is the test I applied before listing it.

**(1) Put out-of-band HANDLE transfer in the transport from its first line.** Define the call as
carrying bytes *and* handles, not bytes with memory reached through a side channel:

```
    verb-batch header:  [ magic | nVerbs | handle0..handle3 ]   handles MUST BE ZERO today
```

(§2.5 is where this lands now that the transport is the clone-file idiom rather than the withdrawn
`dcall` syscall. The principle is unchanged: the *slot* exists from version one.)

`SCM_RIGHTS` is the hardest item in §5.2 to retrofit and everything rides on it. With an in-band
handle slot a future shim is a copy of an array; without one, the shim must invent a global handle
namespace that outlives the message and leaks on every client crash. **Native justification, which is
the real one:** capability-style handle passing is strictly better than a global name registry,
because a compositor can never be tricked into mapping memory a client did not actually own.

**(2) Make the wait primitive multi-handle with a monotonic timeout, the day there is one.**

```
    wait(handles[], n, timeoutNanos) -> readyMask
```

Not a special blocking call for the display. **Every main loop ever written is exactly "wait on N
handles until one is ready or a deadline passes"** — GLib's, Qt's, SDL's and libwayland's own. A
single-handle wait, or one with no timeout, forces a shim to use a thread per handle on an OS with no
threads. **Native justification:** it is precisely what a native application needs for "redraw when
the compositor says so, but also in 16 ms", and it is the shape GAP-0097 has to be answered in
regardless of whether anyone ever writes a bridge.

**(3) Choose the buffer-ownership direction explicitly, and write down which.** §1.3 is where I make
the recommendation; the point here is that **the failure mode to avoid is the third option nobody
chooses on purpose** — a client-allocated buffer with implicit lifetime and no release event, which is
both unbridgeable and unsafe.

**A half-decision that constrains nothing:** let clients allocate protocol object IDs from a
client-owned range, with an explicit "you may reuse this ID" event from the compositor. Wayland does
exactly this (`delete_id`). Matching it means a future proxy needs no bidirectional ID map, which is
otherwise among the most bug-prone parts of any bridge.

### 5.4 What is ruled out permanently, so nobody costs it twice

**Running an unmodified Linux compositor on this OS.** That needs `/dev/input/event*` character
devices with the full `EVIOCGBIT`/`EVIOCGABS` ioctl surface, udev enumeration, `epoll`, and DRM/KMS.
It is deeper than the client side by a wide margin and it buys nothing the native compositor does not
already do. **If a bridge is ever built, it bridges clients, not compositors.**
## 6. The milestone ladder

**Every criterion below is written to this repo's rules for a derived expectation**, which the M7–M16
harnesses established and which I restate here because the next agent has to follow them:

* compute the expectation from a source the kernel does not control (`readelf`/`objcopy` on the built
  artefact, QEMU's own `info pci`/`info registers`, or the generator that made the input);
* restate the kernel's rules in the harness, never import them — if the two disagree, one is wrong;
* assert every constant copied from the kernel against the kernel's source;
* **guard against a vacuous pass** — `check-pixels.py` fails if zero foreground pixels were expected,
  because otherwise it would pass against a blank screen. Every criterion below needs its own version
  of that guard;
* structural checks before boot checks, and a negative control that must fail.

**The PNG is not evidence.** This repo asserts eight magic bytes and nothing else, deliberately: "a
pixel comparison would be brittle against font and palette changes that say nothing about the kernel."
The `xp` read-back is the substitute. Do not write a criterion that depends on a screenshot.

---

### D1 — A mouse exists

**Blocked on: work only.** Touches `interrupts.dart` and a new `mouse.dart`. Independent of
everything else in this document — it can be built in parallel with D2.

Enable the 8042 auxiliary port (`0xA8`), enable reporting (`0xD4` + `0xF4`), unmask **IRQ2 (the
cascade) and IRQ12** — the first use of the slave PIC in this kernel, which has been `0xFF` at every
point until now — add a vector `0x2C` arm to `isrDispatch`, **EOI to both PICs**, and decode the
three-byte packet with a resync rule for the desync every PS/2 mouse eventually produces.

**Prerequisite, per §4.4: the eight whole-byte PIC-mask writes must be consolidated first**, or the
unmask does not survive the next shell command. That is a small change to `interrupts.dart` plus one
moved assertion in `m18-preempt`, and it is shared with every future interrupt-driven device.

**Exit criterion.** QEMU is driven with QMP `input-send-event` — which `qmp-drive.py` does not do yet
and which needs a `--pointer` sibling to `--keys`. Note the axis convention: `abs` events are
**normalised 0..32767, not pixels**, so the harness must state the conversion
`value = round(px * 32767 / (width - 1))` and assert the coordinate **the kernel reports**, never the
one the harness assumed. `input-send-event` batches events atomically in one call, which `send-key`
cannot — that atomicity is what makes "click at exactly this point" deterministic.

*Binary:* three injected motions and two button events produce, on COM1, exactly the derived sequence
of packet decodes; the accumulated position matches the derived pixel coordinate; a deliberately
desynchronised byte stream is resynchronised and the harness asserts the resync counter is non-zero.
*Negative control:* a boot with no pointer events must print no packet line at all.

---

### D2 — Input is a queue, and ring 3 can read it

**Blocked on: work only, but it collides with the argv unit** — it touches `keyboard.dart`,
`shell.dart` and `interrupts.dart`. Sequence it after argv lands.

§4.2 is the specification. A ring buffer in `@bss`, raw scancode + edge (not translated ASCII), a
counted overflow rule, a reset in `shellRecover`, the shell becoming a consumer rather than a thing
the IRQ handler pokes, and a syscall that hands ring 3 the next event.

**This is the milestone that removes GAP-0055 item 4** — today, type-ahead while a command runs is
**zero bytes** and every keystroke is silently discarded by the `shellState() > 0` guard at
`keyboard.dart:263`.

*Binary:* with a ring-3 program running, the harness injects N keystrokes at 50 ms intervals; the
program reads back **exactly** the derived sequence, in order, with none lost. Then it injects
`depth + 3` keys faster than they are drained and the program reads `depth` events **and a dropped
count of exactly 3**. *Negative control:* a build with the queue depth set to 1 must fail the first
assertion — proving the test is sensitive to the queue actually existing.

---

### D3 — A process can outlive the command that started it

**Blocked on: work — and it is the structural blocker nobody has costed. It is also, in my view, the
milestone that should be built first of all of these**, because it is the one everything else waits
on and the one with the least to do with display.

**THIS IS THE SAME MILESTONE AS THE SCHEDULER'S B1 (a blocked process state), and that is a finding
rather than a coincidence.** `blocking-and-threads.md` reaches it from the other end: parking a
process in a `sti; hlt` loop *inside* a syscall is unsound, because the parked frame sits below RSP0
and the next entry from ring 3 overwrites it. The sound way to park is to leave through the same door
the shell already uses — `user_return` into `idle_once` — and re-enter with an `enter_user`-shaped
resume. **That door is exactly what a resident process needs.** Whoever builds either one has built
both; they should not be scheduled as two units.

A compositor is a **resident** process. Today a process comes only from `proc run <lbaA> <lbaB>` typed
at the shell — no `fork`, no `exec`, no init, no daemon — and **the shell does not get the CPU back
until the whole session tears down**. `shellProcRun` creates both slots and calls `procStart(0)`,
which enters ring 3 and returns only when every process has exited, a fault kills them all, or the
quantum budget expires. There is no path in which the shell runs a command while a process is alive.
**Until this changes there is nowhere for a compositor to live**, and no amount of protocol design
substitutes for it.

**The shape I would reject:** a compositor that runs in the shell's context, in ring 0. It would work,
it would be quicker, and it would throw away the isolation M8, M9 and M11 were built to establish —
the compositor is the one process that touches every client's pixels, and it is the last thing that
should be inside the kernel.

**The blocking point is one line.** `proc.dart:2478` calls `procStart(0)`, which calls `enter_user`
(`proc.dart:2323`) — and `enter_user` is a one-way door: it records a single kernel RSP into the
assembly-owned resume words and `iretq`s. The only way back onto that stack is `user_return`, called
from exactly two places, both of which mean "the session is over". **The shell's continuation is a
stack frame, not a schedulable context**, so "keep the process and give the shell the CPU back" is not
expressible today.

**The good news is that half the machinery is already there.** `procCreate` leaves a slot fully READY
with a synthesised 22-word resume frame that `procSwitchTo` can resume **without** `enter_user`. A
`spawn` that calls `procCreate` and *returns* is a small change. What it lacks is a context to return
*to*.

**Five consequences the implementer will meet, two of which cost somebody else a golden:**

1. The shell needs a schedulable context of its own — a kernel task with its own saved frame and ring-0
   stack, or a ring-3 process. Today `procTick` refuses to preempt anything at CPL 0.
2. `procSysExit`'s "nobody left → `user_return`" must become "switch to the idle context".
3. **Keyboard input must be queued** — this is D2, and it is a hard prerequisite rather than a
   neighbour: `shell.dart:1630` sets state 2 for the whole of any command and `keyboard.dart` drops
   every key while it is set.
4. **IRQ0 must stay unmasked.** It is unmasked per-session and re-masked at every exit today, and a
   resident process needs it permanently on — **which moves `m3-shell`'s byte-exact `ticks` golden
   (GAP-0058).** That is a real cost in somebody else's harness and it should be budgeted, not
   discovered.
5. The two-program session model has to go: `shellProcRun` creates exactly two processes, refuses
   `lbaA == lbaB`, refuses to start while anything is live, and wipes all four slots at each start.
   **There is no single-program form at all.**

*Binary:* start a resident program; then type an ordinary command (`ticks`) at the shell **while it is
still live** and get its normal output; then confirm the resident program is **still live and still
making progress** — its per-slot preempt counter, which `proc sched` already prints, must be strictly
greater after the shell command than before. Three derived numbers, all from counters that exist
today. *Negative control:* the same session with the resident program replaced by one that exits
immediately must show the shell command working and the preempt counter **not** advancing, so the
assertion is sensitive to liveness rather than to the shell merely being responsive.

---

### D4 — One frame reaches the screen through the protocol

**Blocked on: D3 only** — and that is a consequence of recommending Option B in §1.3. A shared-frame
design would also have blocked this on the `freeFrame` lifetime fix and on inverting an isolation
assertion in somebody else's harness; copy-on-commit needs no change to `pmm.dart` or `vm.dart` at
all.

The smallest end-to-end thing: one client, one surface, one solid colour, one present, composed by the
compositor and flipped by the kernel.

*Binary, and this is the one that has to be unfakeable:* the harness dumps the **visible** framebuffer
with `xp/<n>wx {addr}` at the address the kernel printed — exactly m5-pci's mechanism — and requires
the surface's rectangle to hold the derived colour **and the pixels outside it to hold the background**,
so a kernel that filled the whole screen fails. **The anti-vacuity guard:** the harness must fail if
the expected surface area is zero pixels. *Negative control:* a client that creates a surface and
never presents must leave the framebuffer at background, everywhere.

---

### D5 — Two surfaces, overlapping, and the right one is on top

**Blocked on: D4.**

*Binary:* the derived image is computed on the host by compositing two known rectangles in a known
order; every pixel of the overlap region must match the **top** surface's colour and none may match
the bottom's. *Negative control:* swap the stacking order and require the previous expectation to
fail — a compositor that ignores order passes one of the two and cannot pass both.

---

### D6 — Damage is real, and it is a number

**Blocked on: D5.**

*Binary:* the kernel (or compositor) prints pixels-composed-per-frame, exactly as `fatMetaReads`/
`fatMetaHits` made caching a number at M14. A client that damages a 16×16 rectangle of a full-screen
surface must cause the derived small count, **not** 480,000. *Negative control:* a build that unions
damage to the full surface must produce the big number, so the assertion is sensitive.

---

### D7 — A click reaches the surface under the pointer

**Blocked on: D1, D2, D5.**

*Binary:* with two overlapping surfaces at derived positions, a click injected at a point inside the
overlap is reported **by the client that owns the top surface** and by no other, with
**surface-relative** coordinates matching the derived value. *Negative control:* a click outside both
surfaces must be reported by neither.

---

### D8 — Zero-copy surfaces *(the named successor to §1.3's recommendation)*

**Blocked on: D4, and on the `freeFrame` lifetime fix.**

This is Option A of §1.3, built as an optimisation once the protocol works rather than as a
foundation. It needs the small shared-frame table and the one branch in `freeFrame`, and it needs
`m11-proc`'s isolation assertion inverted for exactly one address.

**It changes no byte of the wire format**, which is the property §1.3 chose Option B to preserve:
`present` already means *"these pixels are now yours"*, so where the bytes were sitting beforehand is
an implementation detail of both ends.

*Binary:* the derived pixel comparison of D4 must pass **unchanged**, and the kernel's copied-bytes
counter — the one D6 introduces — must drop to zero for the client-to-compositor step while the
composited output is byte-identical. *Negative control:* the frame-lifetime test — client exits first,
compositor keeps drawing, then compositor exits — must leave `pmmMetaErrors` at zero and the
allocator's free count at its baseline. **That control is the whole point of the milestone**, and it
is the one that would have caught the hazard §1.3 describes.

---

### Blocked on a LANGUAGE feature rather than on work

These cannot be built *well* until DCDart grows something, and they are marked separately because they
are a different repo's milestone first. **The language facts below are taken from the kernel's own
source comments and from `known-gaps.md`, not from a survey of the DCDart repo** — each cites where I
read it, and a DCDart-side check should confirm them before anyone plans around them.

| wanted | blocked by | where I read it |
|---|---|---|
| an **exact damage region** instead of a bounding box | no growable collection in `@bare` | `verify-freestanding.sh` treats `dc_alloc` as a reserved symbol whose appearance means "a collection grew" |
| **surface titles / client names** | no `String`, no string literals at all | DCDart GAP-0035 — `unsupported expression StringLiteral`. See the correction below |
| a message passed or returned **as a value** | `@packed class … extends Struct` exists but **cannot appear in any signature**, and there is no tuple and no multiple return | DCDart ADR-0011, GAP-0025; `fat.dart`'s "`@bare` DCDart returns one value and has no out-parameters", which is why `fatAlloc` signals full-or-failed through sentinel cluster numbers |
| a **compound predicate** in a validator | **no `&&`, no `\|\|`, no general `!`** | DCDart GAP-0023 — short-circuiting needs control flow, not an instruction. Every guard in this kernel is a chain of single-test `if`s for this reason |
| **`switch`** on a message opcode | no `switch`, no `enum`, no function pointers, no dynamic dispatch | DCDart GAP-0023/GAP-0002; and GAP-0088 warns LLVM turns a dense `if`-chain into a jump table in a section this repo does not control |
| a **fast blit** | **every `Pointer<T>` access is volatile**, so no vectorisation, no coalescing, no hoisting | DCDart GAP-0034. This is why `fbFill` is 480,000 individual stores and why §3.4's copy is the cost it is |
| **one validator parameterised** by which bit it requires | no bool parameters, no default arguments | `file.dart`'s note on why `fileOwnsRead` and `fileOwnsWrite` are written out twice |
| a **table of message handlers** indexed by opcode | no array of function pointers; a dense `if`-chain becomes a jump table in a section this repo does not control | GAP-0088, GAP-0079, cited at every refusal-dispatch chain in `fat.dart` and `file.dart` |
| passing a **`Pointer<T>`** across the extern seam | forbidden in extern signatures | DCDart GAP-0025, cited in `fat.dart`'s storage-seam comment |

**A CORRECTION I OWE, because I repeated something on trust and an independent check says it is
wrong.** Earlier in this unit I wrote that `String` is "DCDart's last M3 prerequisite" — I was told
that and I passed it on without checking. It is not true on two counts:

* **M3 is not a language milestone at all.** DCDart's M3 is a *gate*: measure ARC overhead against C
  and stock Dart AOT on a benchmark suite, exit criterion **geometric-mean overhead ≤ 10%**.
* **`String` is not the last thing missing.** DCDart GAP-0035's own table lists **closures**
  (`unsupported expression FunctionExpression`) and **generic classes** (GAP-0040) alongside it. The
  summary line that says "two prerequisites remain" contradicts the table three lines above it in the
  same entry. GAP-0035's honest sentence is the one to quote: ***"M3 is not one unit away. It is most
  of the remaining language."***

Nothing in this design depends on that being true either way — **the protocol is built to need none of
it** — but a plan built on "String lands and then M3 is done" would be a plan built on a wrong number,
and I would rather have said so than have it repeated a third time.

**Three limits that used to be on this list and are not any more.** `DCDART_PIN.txt` is now
**`8713298` (2026-08-23)**, which is ADR-0051's mutable-static storage — the commit that let M17 delete
13,952 bytes of donated `.bss`. I checked what else that pin swept in, and it is more than I expected:

* **nested `while` loops compile** (ADR-0044);
* **`break` and `continue` exist** (ADR-0047);
* **word and doubleword port I/O is native** (ADR-0045) — `Port.inw` / `Port.outw`.

Several functions in `fat.dart` and `fb.dart` are still split into helpers with comments explaining a
restriction that no longer applies — `fbFillRow` says so in as many words. **New code need not
contort**, and a reader of those comments should not believe them.

**One of these has a consequence for a check I wrote myself, and I would rather flag it than let
somebody trip over it.** ADR-0045's commit message says it "deletes the kernel's portio.S", and
`core/boot/portio.S` is still present and still used — the kernel has not taken the new primitive up
yet. When it does, `port_outw(u64(ataRegData), …)` becomes `Port.outw(u16(ataRegData), …)`, and
**m14-fat's and m16-filewrite's structural check that "the only `port_outw` aimed at 0x1F0 is inside
`ataWriteFrom`" will stop matching.** The property is still worth asserting; the grep needs to learn
the new spelling. It is a two-line change in two harnesses, made by whoever does the migration.

**The protocol is designed so that none of these blocks D1–D8.** Fixed-size messages, hand-indexed
fields, sentinel returns, `if`-chains and a bounding-box damage union are all expressible today, and
each has a named successor above.

**The protocol is designed so none of these blocks D1–D7.** Fixed-size messages, hand-indexed fields
and a bounding-box union are all expressible today, and each has a named successor above.
## 7. What I did not decide, and would rather be told

Five questions. Each changes something downstream, each is cheap to answer and expensive to guess, and
this project has shown that a well-posed question gets an answer.

**Q0 — Is D3 (a resident process) agreed as the first thing built?** (§6)

It is the milestone everything else waits on, it has almost nothing to do with display, and it is the
one I would hand to the next agent. I have written its exit criterion in terms of counters that
already exist. **If it is built by someone else for their own reasons, this document does not care —
it only cares that it exists.**

**Q1 — Should the protocol grow toward a DEVICE NAMESPACE, or stay a dedicated syscall?** (§2.3)

This OS *has* files, and Plan 9's `/dev/draw` is a display protocol expressed entirely as file
operations. On an OS with `open`/`read`/`fdwrite`/`close`, four descriptors per process, a refusal
floor and two pointer validators, a compositor a client `open`s by name would need **no new syscall at
all**. What it needs instead is somewhere for a name that is not on the FAT volume to live — and that
is a filesystem decision with consequences far beyond display. The syscall is smaller now; the
namespace is what makes a second, third and fourth server cost nothing. **I have designed the message
format so it can be re-expressed as a device later without changing, but I would rather be told than
guess.**

**Q2 — Grow the 2 MiB ring-3 window, or accept small surfaces for now?** (§1.2)

A full-screen surface is 469 of the window's 512 pages. There are **447 free page-directory entries**
in `[128 MiB, 1 GiB)` — not the 62 `vm.dart:1958` claims, see §1.2 — so the address space exists.
But "how big is a program's address space" should not be decided as a side effect of a display
protocol, and the cheap form of the change is **splitting `vmProgEnd` into a load bound and a user
bound** rather than widening it. **My recommendation is to build D1–D7 on small surfaces and make the
address-space change its own milestone with its own ADR.**

**Q3 — When no compositor is running, who gets input?** (§4.3)

If the compositor is the only recipient, the design is cleaner. If the kernel keeps delivering to the
shell when no compositor is live, **a compositor that crashes does not take the keyboard with it** and
the machine stays usable. I lean to the second, and it costs a small piece of policy in ring 0.

**Q4 — Confirm copy-on-commit.** (§1.3)

I recommend Option B and gave three independent reasons. It is the **only choice in this document that
is expensive to reverse**, and B is the reversible one — which is most of why I recommend it. A
confirmation, or a redirection, is worth having before anyone writes code.

---

## 8. Notes for the coordinator to fold in elsewhere

**I have not touched `known-gaps.md` or `ROADMAP.md`**, per instruction, while the argv unit is in
flight. These are the things that belong in them, with my reasoning, for whoever folds them in.

**A latent hazard that deserves a GAP entry whether or not this protocol is ever built.**
`freeFrame` is a bit-clear and `procSpaceFree` frees every present leaf in the window unconditionally,
so **any** future feature that maps one physical frame into two address spaces inherits a
use-after-free that is silent at the machine level and only loud at the harness level (§1.3, Option A).
That is not a display gap — it is a property of `pmm.dart` and `proc.dart` that is true today and that
nothing currently records. The one-branch fix is written out in §1.3.

**A constraint nobody has costed, and a comment that miscounts the way out of it.** The 2 MiB ring-3
window (§1.2) is the binding limit on any window system — a bigger obstacle than IPC, damage or the
mouse. **And `vm.dart:1958` states the free page-directory count as 62 when it is 447**; 62 is the
size of the *preceding, used* range. That one wrong number appears in this document's earlier drafts
and in the memory specialist's report as a correction, so it should be fixed at the source before it
propagates further.

**Three existing gaps are upstream of this whole document**, and I would like their entries to say so,
because right now they read as scheduler and console limitations rather than as the display blockers
they are:
* **GAP-0097 / GAP-0141 — nothing blocks.** No blocked process state, no sleep, no wakeup. This is
  what forces events to ride the reply (§2.2), and it is what makes a Wayland client impossible
  independently of sockets or shared memory (§5.2).
* **GAP-0055 item 4 — no input queue.** Type-ahead while a command runs is *zero bytes*, and every
  keystroke is dropped by the `shellState() > 0` guard. D2 is the milestone that closes it.
* **GAP-0070 item 6 — no double buffering.** Its own text says it "stops being invisible the moment
  anything animates". §3.2 is the answer: the Y-offset register is already written by `fbSetMode` and
  there are eight frames' worth of VRAM behind a 1.92 MB frame.

**A harness change that is an improvement, not a concession.** If Option A is ever taken,
`m11-proc/derive.py`'s isolation assertion must be **inverted for exactly one address**, not relaxed —
making it say *these two spaces share exactly one page, at exactly this address, and nothing else*,
which is a stronger claim than it makes today (§1.3).

**A direct interaction with the argv unit, which is why I am flagging it rather than acting on it.**
`procCreate` sets a new process's RSP to `vmProgStackTop` raw; **only `run <name>` builds a System V
initial stack**, via `argsBuild` in `elf.dart`. So the moment there is a `spawn` (D3), a spawned
compositor has **no `argv`** until that stack-building path moves from the `run` path into
`procCreate`. The argv agent is building exactly that machinery right now and will not necessarily
know that `proc`-created processes bypass it. It is a small move; it is much cheaper to know about
than to discover.

**A correction that belongs in the DCDart repo, not this one.** GAP-0035's summary line says two
prerequisites remain for M3; its own table three lines above lists three, including closures. And M3
is a benchmark gate, not a language milestone. I have written this up in §6 because it changed what I
planned around, but the fix belongs where the entry lives.

**Two DCDart limits worth knowing before anyone plans graphics work**, both already tracked upstream:
every `Pointer<T>` access is **volatile** (GAP-0034), so no blit in kernel DCDart can ever be
vectorised or coalesced; and a `@packed` struct **cannot appear in a signature** (GAP-0025), so the
kernel and its C userland cannot share a message type and both ends must hand-write the offsets.
Neither blocks this design. Both set the performance ceiling.

**A documentation bug in `known-gaps.md`, found by the scheduler specialist.** GAP-0141's blocking
bullet says *"four states — FREE, READY, RUNNING, EXITED, KILLED — and no fifth"*. It names five and
says four. ADR-0022 §12 is the correct original and excludes FREE, which is where the off-by-one came
in. §0 of this document quotes GAP-0141, so I have written *five* there and flagged it here rather
than silently propagating either number.

**A CONTRADICTION BETWEEN TWO SPECIALISTS THAT I THINK RESOLVES, AND THE RESOLUTION INVALIDATES AN
EXIT CRITERION.** The e1000 specialist says the driver must enable PCI bus mastering (a config-space
*write*, which `pci.dart` cannot do — GAP-0067 item 2). The network-stack specialist measured
`cfg[0x04] = 0x0107` and concluded SeaBIOS has **already** enabled it, so GAP-0067's stated
consequence is wrong on this machine. Both cannot be true as stated.

**They are both right, in different QEMU configurations, and the difference is the option ROM.** The
e1000 specialist independently measured that with a default `-device e1000` the **iPXE option ROM
completes a full DHCP exchange before any guest OS runs** — seven frames in the pcap. An option ROM
cannot do that without bus mastering, so in that configuration BME is set before the kernel starts.
That same specialist then mandates `romfile=` (empty) to get a clean pcap — **and with no option ROM,
nothing has run to set BME.** So the bit's state depends on exactly the flag one of them added and the
other did not use.

**The consequence is concrete and it costs a check:** the e1000 ladder's N2 negative control is
"remove the bus-master-enable write, require zero packets". That control is only valid *because*
`romfile=` is mandated. Anyone who drops `romfile=` for convenience silently converts N2 into a test
that passes without the driver doing anything. Neither document says this, because neither author
could see the other's measurement. **A driver should set BME defensively regardless** — it is required
on real hardware and free here.

**A FACTUAL ERROR IN `known-gaps.md` GAP-0122 ITEM 2, found by the namespace specialist.** The entry
claims `open("SUB/X.TXT")` is `fileRetBadName` "because `/` is not a character an 8.3 name may contain
here." **It is not.** `fatParseAt` accepts every byte in `0x21..0x7E` except `.`, and `/` is `0x2F` —
so the name folds silently to `SUB/X   TXT` and comes back `fileRetNotFound`. The claim became true
only for the *write* path at M16, via `fatNameLegal`. Two consequences: the gap entry needs
correcting, and **`fatParseAt` should refuse `0x2F` explicitly** — a one-line fix worth doing in
whatever milestone is next, because a name that silently folds is worse than one that is refused.

**A HAZARD THAT DESERVES ITS OWN GAP ENTRY INDEPENDENT OF ANY DISPLAY WORK.** `fatLookup`'s four
callers disagree about what its return codes mean, and `fileMakeEmpty` — which I wrote at M16 — acts
on `fatErrOk` and `fatErrEmpty` by *truncating and rewriting a directory entry*. Any future change
that makes `fatLookup` return one of those codes for something that is not a plain file on the volume
is a volume corruption reachable from ring 3. Nothing records this today.

**THE SILENT MERGE HAZARD, found by the build-architecture specialist, and it is the most important
operational finding in any of these documents.** `kmain.dart`'s `part` list *looks* order-free —
Dart parts are a textual union — but **`@bss` blocks are emitted in part order**, and every harness
from M2 onward measures "donated bytes from MY block to the end of `.bss`". So the part list is
**append-only and load-bearing**. The consequence for a fleet: **two agents who each correctly append
their own file last cannot both be last after a merge, and the loser's harness number is now wrong in
a file neither of them touched.** Git merges it cleanly. Nothing fails until the suite runs.

The same specialist found the one collision that is genuinely undetectable: **syscall numbers have no
registry.** Constants 0–10 live in four different files, so **two agents both writing `= 11` merge
clean and mis-dispatch silently.** That nearly happened here — the scheduler specialist claimed 11 for
`fdwait` while an earlier draft of this document claimed 11 for a display call. It was caught only
because both drafts happened to cross my desk. A registry is the cheapest fix named in any of these
documents.

**The one CI rule worth adopting even if nothing else is: run the full conformance suite on the MERGE
RESULT, never only per-branch.**

**A kernel gap three separate specialists independently hit: there is no way to ask a file's size.**
`SEEK_END` needs it, `stdio`'s buffering decisions need it, and *any* libc port needs it. GAP-0122
item 4 named it at M15 and **I did not narrow it at M16** — GAP-0127 should have, and did not. The
C-library specialist calls it the highest value-per-line kernel work available. It is a `stat`-shaped
call, and ADR-0019 §3's argument for leaving it out (a `stat` worth having returns a struct, and
copying a struct to ring 3 is the pointer problem `read` already solved) is now weaker than it was,
because M16 solved that problem twice more.

**Two work items the hygiene audit surfaced that are bigger than a comment fix**, both now written
up in `core/docs/design/stale-comments.md`:

* **`core/boot/portio.S` is dead weight and its deletion is milestone-sized.** ADR-0045 put
  `Port.inw`/`outw`/`inl`/`outl` in the language and the pin took them, but 10 call sites still route
  through the assembly helpers — `pci.dart:267-268`, `fb.dart:348/349/355/356`, `ata.dart:679/815/935`
  and `ata.dart:1079` (which is M16's write path, mine). Deleting it means 10 call-site edits, 4
  `external` declarations, 4 fewer declared externs, and edits to the `portio.o` assertions in **nine**
  conformance harnesses — including the "only `port_outw` aimed at 0x1F0" structural checks I wrote
  into m14-fat and m16-filewrite, which would silently stop matching. It deserves its own gap entry so
  nobody starts it by accident.
* **41 stale comments, and the damage is directional.** The M17 migration updated every storage
  declaration and missed the file headers, so `elf.dart`, `user.dart`, `fat.dart`, `ata.dart` and
  `proc.dart` each now contradict themselves a few hundred lines apart. Several actively instruct a
  reader to go and edit `core/boot/kdata.S` for symbols that are no longer in it — which would
  reintroduce the seam M17 spent a milestone deleting. `ata.dart` states a superseded pin hash twice.
  **Three of the flagged comments are mine, written during M16**, and one of the suggested fixes is
  better than what I wrote: `fileSysWrite`'s `stop` flag is justified in my comment by "DCDart has no
  `break`", which is now false — but the flag also records *why* the loop stopped, which a `break`
  would lose. That is the durable reason and I did not give it.

**MY OWN M16 DECISION NOW HAS A MEASURED PRICE, and the loop closes on my own mutation round.**
ADR-0020 §2 chose **one `FLUSH CACHE` per sector**, calling it "more conservative than it needs to be
and the right default". The storage specialist measured what that costs: a 512-byte file is **five
sector writes and five flushes** (directory create, both FAT copies, the data sector, the directory
entry at close), and steady state is **6 writes and 12 ATA commands per 1024 bytes of payload —
3× byte amplification and 6× command amplification, forever.** A 64 KiB write is 382 flushes **with
interrupts off**, which is 0.06–6 seconds in which no tick is delivered and `ticks` silently
under-counts. The cost is not throughput, it is scheduling.

**And the fix is blocked by something I proved myself.** Batching the flushes is about ten lines and
60–80% of the write cost — but it modifies the one property **no test in this repository can
observe**, because GAP-0129's bypass experiment established that removing the flush entirely passes
all seven M16 boots. I wrote that experiment to be honest about a weakness; it now marks the exact
edge of what can be changed safely. The storage specialist's honest version is **two** flushes, not
one, keeping a barrier between the FAT writes and the directory write so ADR-0020 §3's rules 2 and 3
survive. That is the right answer and it should be built with the ordering argument attached, not as
a performance patch.

**A TOOLING FILE THAT THREE SPECIALISTS NOW WANT TO CHANGE, SHARED BY SEVENTEEN HARNESSES.**
`core/tests/conformance/m2-console/qmp-drive.py` sends **one qcode per `send-key`**, so it cannot
express a chord — which means **shift is untestable, and this machine cannot currently type a capital
`A`** (shift maps to `0x00` and break codes are dropped at `keyboard.dart:252`). The text specialist
needs a chord syntax; this document's §6 D1 needs `--pointer` for `input-send-event`; the network
ladder needs nothing there but the mouse and the keyboard both do. **All three changes are additive
and should be made in one pass by whoever gets there first**, because seventeen harnesses import that
file and a second pass is a second chance to break them.

**A tooling gap with a known shape.** `qmp-drive.py` can inject keys and cannot inject pointer events.
QMP's `input-send-event` does it, batches events atomically in one call — which `send-key` cannot, and
which is what makes "click at exactly this point" deterministic — and uses **normalised 0..32767 axes,
not pixels**. D1 needs a `--pointer` sibling to `--keys`. That file is shared by thirteen harnesses, so
the change must be purely additive.
