# ADR-0051 — The surface protocol: one syscall, a 64-byte descriptor, and no address in it

**Status:** accepted, implemented (`core/kernel/wm.dart`, `core/tests/conformance/d2-compositor`).
**Depends on ADR-0050** (the compositor is in the kernel and owns the framebuffer).
**Converges with ADR-0045** (`shmaddr`) on the one thing both are really about: **userland is TOLD an
address, it does not derive one.**

---

## 1. Three questions a display protocol has to answer

| question | answer |
|---|---|
| what does a client send to get a surface? | `wmsurface(desc)` with `desc.op = wmOpAttach`, naming a **capability handle** it already holds and a geometry. The reply in `rax` is **the address its own address space has that region at.** |
| how does it say "this frame is ready"? | the same syscall with `desc.op = wmOpCommit`, naming the same handle and a damage rectangle. |
| how does the compositor say "I am done with your buffer"? | **the commit syscall returns.** |

### 1.1 The third answer is the interesting one

Composition happens **synchronously, inside the caller's own syscall**. So the return is not a promise
that the compositor will be finished later; it is the statement that it already is.

That is not a shortcut, it is the only shape this machine has. `proc.dart` has five process states —
FREE, READY, RUNNING, EXITED, KILLED — and there is no sixth. GAP-0141 puts it in three words:
*"Nothing ever waits."* No sleep, no wakeup, no signal. A design in which the answer arrives later
needs a queue, a wakeup and a sixth state, and none of the three exists. `display-protocol.md` §0
item 4 says this is upstream of more of that design than anything else in it, and it is upstream of
this too.

**What it costs is that a client pays for its own composite** — 561,672 pixel stores at the moment,
on the client's own time, with interrupts on. GAP-0303.

---

## 2. Why the descriptor is 64 bytes

Because that is `chanMsgBytes`.

`chan.dart`'s header says a message *"is enough for every frame descriptor a compositor needs"* and
ADR-0027 §2.3 promised the message and the shared region would compose *without either mechanism
changing*. **This descriptor is byte-for-byte a legal channel message.** When D3 lands and the
compositor moves to ring 3, the identical eight words go through `chansend` and **nothing about the
wire format moves** — only who reads them. That is the whole reason the size was chosen rather than,
say, six words, and `d2-compositor/run.sh` asserts `wmDescBytes == chanMsgBytes` so that the promise
cannot quietly expire.

```
  word  ATTACH                          COMMIT
  ----  ------------------------------  ------------------------------
   0    op = 1                          op = 2
   1    capability handle               capability handle
   2    x                               damage x
   3    y                               damage y
   4    w                               damage w
   5    h                               damage h
   6    stride in bytes (0 = w*4)       the client's own frame counter
   7    byte offset of pixel (0,0)      -
```

Words 2..5 are overlaid because a geometry and a damage rectangle **are** the same four numbers; which
one a word means is decided by word 0 and by nothing else.

---

## 3. THE ABI RULE: no slot-derived address, anywhere

The owner has ratified that a syscall returns a region's address so userland stops deriving it from a
slot number. This protocol is built so the question cannot arise.

* **A descriptor names a capability HANDLE, never an address.** The kernel resolves
  handle → capability → region → frame vector → physical pages, and it validates the handle against
  **the caller's own** capability table, in `shmSysMap`'s order — index in range, slot non-empty,
  generation matches the capability, region live, generation matches the region. A forged handle
  reaches nothing and gets `wmRetBadCap`; `d2-compositor/prog.c` sends itself one and requires that
  answer.
* **Where a client draws is something it is TOLD.** Before `wmOpAttach` existed there was no syscall
  by which a region's *creator* could learn its own region's address: `shmcreate` maps the region and
  returns a handle, and `shmmap` on that handle is then refused as already-mapped. Writing
  `vmShmBase + slot * pages * 4096` into a client was the only thing a creator could do —
  **`m21-shmem/prog.c` contains the literal `0x10200000` for exactly that reason** — and a dependency
  nobody chose still becomes ABI the moment a client ships.

  `d2-compositor/prog.c` contains no address at all. `build-progs.sh` reads `vmShmBase` **out of the
  kernel** and fails if that value appears as a literal in the source *or* as an immediate in the
  emitted code, so the check keeps working if the window ever moves — which is precisely the freedom
  ADR-0045 is preserving.
* **Pixels inside a descriptor are addressed by OFFSET and STRIDE, never by pointer**, so a descriptor
  stays meaningful when it crosses an address space. Which is what will happen to it under D3.

### 3.1 Relationship to `shmaddr` (ADR-0045)

`shmaddr(handle) -> address` does the same job for `shm` generally, on another line, and 21 is its
number. When it merges, `wmOpAttach`'s return value becomes a convenience rather than the only way to
learn the address. **The wire format does not move either way, because it never carried one.**

---

## 4. The number is 23

20 is `mouse`. 21 (`shmaddr`) and 22 (`shmpublish`) are taken by two lines that had not merged when
this one forked, and which this line can see only because it went and looked. The kernel constants
would have merged clean — `wmSysSurfaceNo` lives in a file neither of those branches has — and only
`docs/syscall-registry.md` would have conflicted, which is exactly the shape
`docs/design/hot-files.md` §5.1 warns about. Taking 23 up front is the same move the registry has now
recorded four times: *the cheaper move is the correct one, and the number is not the interface.*

---

## 5. What the compositor does with a commit, and what it does not

**It composes a full frame.** Desktop, then every window bottom-up, then the pointer. The damage
rectangle is carried, validated and **printed**, and then not used to make the pass smaller.
GAP-0301 records that as a cost. Composing only the damage is D6, whose exit criterion is a
pixels-per-frame count that has to come out *small*; `wmMetaPixels` is that count and it is printed on
every frame, so the milestone that makes it small has something to make smaller and a harness that can
watch it happen.

**Stacking is "the newest surface is on top", and the border says which one that is.** The compositor
draws a 3-pixel border around every window in a colour that is a function of stacking position —
bright for the top window, dim for everything under it. That is not ornament: two client regions could
in principle hold the same pixels, and a border *the compositor* draws is the compositor's own
statement about order, in pixels, at a coordinate a harness can name. `d2-compositor` asserts it at
the coordinate where the top window's border overwrites the bottom window's content.

**The protocol is ONE-WAY, and that is a gap rather than a design.** A client is never told where it
was placed, when it was moved, when the pointer entered it, or when it was clicked — and D5b now
moves windows underneath clients that have no way to find out. The mechanism for the reverse
direction already exists (the descriptor is a legal channel message and `chanrecv` is built); what is
missing is that a kernel compositor has no endpoint to send from. GAP-0308.

**Refused rather than clamped, in three places**, because a clamp turns a client's arithmetic error
into a kernel that reads memory nobody meant it to:

* a geometry that does not fit the screen **with its border** — and the border is part of the bound
  because `x - wmBorder` in unsigned arithmetic is not a small negative number;
* a stride or offset that is not a multiple of 4 — this is what makes a pixel unable to straddle a
  page, and without it the read path would need a second page lookup and be silently wrong for exactly
  one pixel per page;
* a region too small for the geometry it claims: `offset + (h-1)*stride + w*4` past the end.
