# Text and fonts on oscortex — a design, not yet a decision

**Status: DESIGN. Not an ADR, not numbered, nothing implemented, and no file outside this one was
touched to produce it.** When a piece of this is built it gets its own numbered ADR; this file is the
thing those ADRs will point back at, the same way `display-protocol.md` is for the window system and
`exec-format.md` is for `.osx`.

**Scope.** Everything between a key being pressed and a shape appearing on a screen: the font that
exists today, the glyph-run verb `display-protocol.md` §1.3 named but did not specify, what it would
take to render something that is not an 8×16 bitmap, and what Unicode actually costs. It is the text
half of the display protocol; it assumes that document's transport (§2) and its milestone ladder
(§6) and does not re-argue either.

**Where I measured something I say so and give the command. Where I could not measure it I say
UNVERIFIED and say what would settle it.** Two of the load-bearing facts below are in the second
category and both are flagged in §7 as questions rather than asserted as findings.

### The five things this document lands on, for a reader in a hurry

| | claim | where |
|---|---|---|
| **The font** | 1536 bytes, 96 glyphs, `0x20`–`0x7E` plus a fallback box. Its *generator is not in the repo*, so its provenance is a comment rather than an artefact. | §1.4 |
| **The verb** | One index byte on the wire paints 512 bytes of screen — **a 512:1 amplification**, and that ratio is the entire argument for a glyph-run verb. | §2.2 |
| **Coverage** | Because the client sends font-relative *indices*, **the server never needs a cmap and can never have a "missing character"** — only an out-of-range index, which is a client bug. This is the biggest simplification in the document. | §2.5 |
| **TrueType** | Belongs in **userland C, in the compositor, using stb_truetype**, never in the kernel and never in DCDart. Userland has had hardware floating point since M11 and the kernel has none. Rasterise once, upload to the server's glyph cache, draw by index forever. | §3 |
| **Unicode** | The distance from here to "types a capital `A`" is about two days. The distance from here to correct Unicode text is a multi-year project that **Plan 9 — which invented UTF-8 — never finished**. These are not points on the same line. | §4 |

### And the three findings that surprised me

* **This machine cannot type an uppercase letter.** Not "does not yet render one" — cannot produce
  one. `keyboard.dart` drops every break code and has one 128-entry table, so `shift` maps to `0x00`
  and is discarded (`keyboard.dart:252`, `keyboard.dart:31`). An OS that cannot type `A` cannot type
  a filename, and that is a text bug wearing a driver's clothes.
* **The font's own generator does not exist in this repository.** `fb.dart:590` says the glyphs "were
  authored at 5x9 and PLACED mechanically … in a generator script"; `ls core/scripts/` returns
  `build-kernel.sh` and `verify-freestanding.sh`. The claim is almost certainly true — `check-font.py`
  proves the *placement invariant* holds across all 1536 bytes, which is very hard to achieve by hand
  — but the artefact that would let anyone regenerate it is gone. **T2 in §6 exists to fix that**, and
  its exit criterion is the strongest kind this repo has: regenerate and require byte-identity.
* **`check-font.py` and `check-pixels.py` restate the font's geometry as Python literals** — `GLYPHS =
  96`, `FONT_FIRST, FONT_LAST = 0x20, 0x7E`, `FONT_FALLBACK = 95` — and **nothing anywhere asserts
  those against `fb.dart`'s `fontGlyphCount` / `fontFirstChar` / `fontFallbackIndex`.** Restating
  rather than importing is this repo's rule and it is the right rule; the rule's other half is that
  the copy is checked against the source (m13-libc checks eleven such numbers, ADR-0017 §2). These
  four are not. Today they agree. The first milestone that widens the font is the one where they stop
  agreeing, silently, in the direction of a harness that still passes.

---

## 0. What is true today, with citations

Everything in this section was read out of the tree, not remembered.

| fact | where |
|---|---|
| The font is `@rodata final List<u8> fbFont8x16`, 1536 bytes | `fb.dart:604` |
| 96 glyphs × 16 bytes; glyph *n* at byte `n * 16`; no header, no per-glyph length | `fb.dart:200`, `fb.dart:203` |
| Coverage is `0x20`–`0x7E` (95 glyphs) plus a fallback box at index 95 | `fb.dart:209`–`fb.dart:222` |
| One byte per pixel row, **MSB leftmost**, 16 rows | `fb.dart:201` |
| Glyphs are authored 5 px wide and placed in columns 1..5, so bits 7, 1 and 0 are clear in all 1536 bytes | `fb.dart:590`, `check-font.py:25` (`EDGE_BITS = 0x83`) |
| The blit is **opaque** — background is written too, deliberately | `fb.dart:466` |
| One glyph is 128 individual volatile 32-bit stores | `fb.dart:483`, GAP-0070 item 7 |
| Console geometry is 100 × 37 cells at 800×600 | `fb.dart:505` |
| Running off the bottom **stops the console**; there is no scroll | `fb.dart:534`, GAP-0070 item 1 |
| One compiled-in colour pair, `0x00C8C8C8` on `0x00101018`; no attributes, no cursor | `fb.dart:230`, GAP-0070 item 5 |
| The keyboard is one 128-entry scan-code-set-1 table, unshifted US QWERTY | `keyboard.dart:78` |
| Break codes are discarded; `0xE0`-prefixed keys are consumed and do nothing | `keyboard.dart:243`–`keyboard.dart:253` |
| Every keystroke is dropped while a command runs | `keyboard.dart:263`, GAP-0055 item 4 |
| The shell line buffer is 256 **bytes** | `shell.dart:840` |
| `fdwrite` carries at most 512 bytes; `read` at most 512; a process has 4 descriptors | `file.dart:310`, `file.dart:300`, `file.dart:281` |
| The console `write` syscall carries at most **128** bytes, and `printf` at most 120 | `oslibc.h:95`, `oslibc.h:99` |
| Userland C may use SSE/SSE2; every process has a 512-byte FXSAVE area saved across switches | ADR-0015, GAP-0092 (closed at M11) |
| No AVX, no XSAVE, no `#XF` handler, x87 untested | GAP-0103 |
| Every `Pointer<T>` access in DCDart is volatile — no vectorisation, no coalescing | DCDart GAP-0034 |
| DCDart `@bare` has no `String`, no array type, no mutable statics outside `@bss`, no `&&`/`\|\|`, no `switch`, no function pointers | DCDart GAP-0023/0025/0035/0088, restated in `display-protocol.md` §6 |

---

## 1. THE CURRENT FONT

### 1.1 Storage

```
   @rodata final List<u8> fbFont8x16 = const [ … 1536 u8 literals … ];

   glyph n            →  bytes [n*16, n*16+16)
   character c        →  glyph (c - 0x20), or glyph 95 if c ∉ [0x20, 0x7E]
   row r of a glyph   →  one byte; bit (7 - x) is the pixel at column x
```

**This is the flattest possible representation and that is why it works in this language.** There is
no header, no per-glyph offset, no length table and no indirection, because DCDart `@bare` cannot
express any of them: `@rodata` tables carry no length (ADR-0040, GAP-0060), cannot be sliced, cannot
be passed to a function and cannot be indexed with a bounds check. A font that needed a per-glyph
offset would need a second table and a second hand-maintained count. **A font that is pure arithmetic
needs neither**, and `fbGlyphAddr` (`fb.dart:452`) is six lines because of it.

The one non-obvious consequence: the *fallback is a glyph in the same table*, at index 95, one past
the last real one. It is not a special case in the renderer — it is a different result from the same
multiply. `check-font.py:47` asserts it is **not blank**, because a blank fallback would make an
unrenderable byte indistinguishable from a space, which is the failure this whole arrangement exists
to prevent.

### 1.2 Coverage

95 printable ASCII characters. Nothing else. No accents, no box drawing, no code page, no arrows, no
`£`, no `°`, no `—`. GAP-0070 item 8 says it plainly: *"this console cannot render text most of the
world writes in."*

**What "coverage" costs, in bytes, at this cell size:**

| coverage | glyphs | table size |
|---|---|---|
| today (ASCII + fallback) | 96 | 1,536 B |
| + Latin-1 Supplement (`0xA0`–`0xFF`) | 192 | 3,072 B |
| + Latin Extended-A | 320 | 5,120 B |
| CP437, the whole 8-bit code page | 256 | 4,096 B |
| Latin + Greek + Cyrillic, a "European" set | ~1,000 | 16 KB |
| **CJK, the ~28,000 common ideographs, at 16×16 (2 bytes/row)** | 28,000 | **~900 KB** |

The first four rows are free — nobody will notice 3 KB in `.rodata`. **The last row is the wall**, and
it is worth stating exactly where the wall is: 900 KB does not fit in a `.rodata` table anybody wants
to maintain, does not fit alongside a program in the 2 MiB ring-3 window (`display-protocol.md` §1.2),
and is not the sort of thing that lives in a kernel at all. **CJK is not a bigger version of Latin-1.
It is a different architecture** — a font on disk, paged in, with a cache. §2.6 is the mechanism that
makes that possible without changing anything else, and it is the reason to build the cache before
anyone needs it.

### 1.3 Limits, honestly

Beyond coverage, in rough order of how soon each one bites:

1. **Fixed 8×16 cell, monospace, no advance width.** The cursor is a `(col, row)` pair in
   `fbStateBlock` and `fbPutc` does `col + 1`. Proportional text is not a font change, it is a
   *cursor model* change: an x-position in pixels and a per-glyph advance. Everything downstream of
   `fbPutc` assumes cells.
2. **One colour pair, compiled in.** `fbColorFg`/`fbColorBg` are `const int`s (`fb.dart:230`). A
   terminal needs per-run colour; a window system needs it per glyph run. The glyph-run verb in §2
   carries both as operands, which costs 8 bytes of a 512-byte batch and removes the constant forever.
3. **No scrolling.** `fbPutc` returns early past row 37 (`fb.dart:534`). This reads as a framebuffer
   limitation and is filed as one (GAP-0070 item 1), but **it is a text limitation** — no text system
   is usable without it. The honest fix on this device is not `memcpy`; it is the dispi Y-offset
   register, which `fbSetMode` already writes (`fb.dart:392`), driven as a ring buffer over VRAM.
4. **No cursor.** The text console has a CRTC hardware cursor; the framebuffer console has nothing
   showing where the next character goes (GAP-0070 item 5).
5. **128 volatile stores per glyph** (GAP-0034). A full screen of text at 100×37 is 3,700 glyphs =
   473,600 stores, none of which LLVM may coalesce. This sets the ceiling on everything in §3: any
   scheme that makes glyphs *bigger* or *blended* multiplies a number that is already the reason
   `fbFill` is noticeable under emulation.
6. **The blit is opaque, and that is load-bearing in both directions.** It makes overwriting a
   character correct (`fb.dart:466`), and it makes antialiasing impossible without changing it —
   coverage blending needs to read the destination, which an opaque blit never does.

### 1.4 The provenance problem, and why it is worth a milestone

`fb.dart:590` describes a generator: nine rows of five cells per glyph, placed with one line of code
(`bits << 2`) that every glyph goes through, explicitly *"generated rather than counted"* in the
spirit of GAP-0060. **That script is not in the repository.** `core/scripts/` holds two shell scripts
and neither mentions a glyph.

`check-font.py` is a genuinely strong substitute — it proves the *invariant* the generator produces
(no byte anywhere in the table sets bit 7 or bits 1:0, exactly one blank glyph, a non-blank fallback),
across all 1536 bytes, which is not something a hand-typed table would survive. So the claim is
believable. But:

* nobody can add a glyph the way the existing ones were added;
* the next person to widen this font will hand-type hex, which is the exact activity GAP-0060 exists
  to warn about, and they will do it for 96 or 224 glyphs;
* and the invariant `check-font.py` asserts (`EDGE_BITS = 0x83`) is a property of a 5-px-wide design
  that a wider or proportional font would legitimately violate — so the check that guards the font's
  quality is also the check that blocks the font from improving.

**T2 in §6 restores the generator and proves it by regeneration.** That is the cheapest milestone in
this document and the one everything else in §1 waits on.

---

## 2. THE GLYPH-RUN VERB

`display-protocol.md` §1.3 lists `'s' glyph run` among the drawing verbs and specifies none of them.
This section specifies that one.

### 2.1 The premise, restated because it is the whole design

The client holds **no pixels and no font**. The server holds the font, the backing store and the
rasteriser. The client sends **indices**. This is Plan 9's `/dev/draw` model — `s`/`x` string verbs
over a subfont the server already has — and it is thirty years old because it is correct for exactly
this shape of machine.

### 2.2 The arithmetic that justifies it

`fileWriteMax` is 512 bytes (`file.dart:310`). Three ways to put a screen of text on the display:

| method | bytes on the wire | `fdwrite` calls for a full 100×37 screen |
|---|---|---|
| pixel upload | 1,920,000 | **3,750** |
| one verb per character (a `d` blit, ~36 B) | 133,200 | 261 |
| **glyph runs, one index byte per character** | ~3,900 incl. headers | **~9** |

**One index byte on the wire paints an 8×16 cell — 128 pixels, 512 bytes of framebuffer. A 512:1
amplification.** That is the number the verb exists for, it is why text is the *easiest* thing to put
through this transport rather than the hardest, and it is why a text-first window system is a sensible
thing to build on a machine with a 512-byte syscall cap.

### 2.3 Wire format

Little-endian throughout, matching everything else this kernel touches. Fixed offsets, hand-indexed,
because a `@packed` struct cannot appear in a signature (DCDart GAP-0025) and both ends must therefore
write the offsets out by hand anyway.

```
   's' GLYPH RUN — 18-byte header, then n indices

   off  size  field
     0    1   op = 's' (0x73)
     1    1   font id      — 0 is the server's built-in 8x16; others come from discovery (§2.4)
     2    2   dst image id — the destination the client got at surface creation
     4    2   x            — signed, pixels, relative to the destination image's origin
     6    2   y            — signed, pixels; for a bitmap font this is the TOP of the cell,
                             for a scalable font it is the BASELINE (§2.4 says which)
     8    4   fg           — 0x00RRGGBB
    12    4   bg           — 0x00RRGGBB, or 0xFF000000 meaning TRANSPARENT (do not write bg)
    16    1   n            — 1..255 indices follow
    17    1   w            — index width in bytes: 1 or 2
    18  n*w   indices      — font-relative glyph indices, NOT codepoints
```

**Why the index is not a codepoint** — this is the design decision in the whole section, and §2.5 is
the payoff. **Why `w` is a field rather than fixed at 2:** ASCII-range text is the common case by a
wide margin and `w = 1` doubles the characters per syscall. **Why `bg` has a transparent sentinel
rather than a flags byte:** `0xFF000000` is not expressible as a colour in this format (`fb.dart:224`
— byte 3 is unused and every colour written by this kernel has it zero), so it is a free sentinel, and
a flags byte would be a second field to validate.

**Capacity.** A batch is 512 bytes; `display-protocol.md` §2.5 reserves four words (32 bytes) of batch
header for out-of-band handles that must be zero. That leaves 480 bytes: **one glyph run of 462
single-byte indices**, or several shorter runs. A 100-column line of text is one run using 118 of 512
bytes, so a full screen is nine calls with room to spare — which is where §2.2's table comes from.

### 2.4 Font discovery

A client must never hardcode a cell size. It asks.

```
   'i' FONT INFO — 4-byte request, 24-byte reply record read back off the session fd

   request:  op = 'i' (0x69), font id (1), reserved (2, must be zero)

   reply:    off  size  field
               0    1   record type = 'i'
               1    1   font id, echoed
               2    2   flags — bit 0: 1 = proportional (per-glyph advance), 0 = monospace
                                bit 1: 1 = y is a baseline, 0 = y is the cell top
                                bit 2: 1 = glyphs are 8-bit coverage, 0 = 1 bit per pixel
               4    2   cell width  (monospace) or maximum advance (proportional)
               6    2   cell height
               8    2   ascent      — pixels above the baseline
              10    2   descent     — pixels below, positive
              12    2   line gap
              14    2   index count — indices 0 .. count-1 are drawable
              16    2   fallback index — what an out-of-range index draws
              18    2   cache capacity — how many client-uploaded glyphs this session may hold (§2.6)
              20    4   glyph-miss counter (§2.5)
```

Fixed-width, so it rides the existing non-blocking `read` alongside input events with no framing
work: `display-protocol.md` §2.2's event records already have a leading type byte and this is another
record type.

**Font *enumeration* — "what fonts are there?" — is deliberately not in this design.** Font id 0 is
the built-in and always exists; other ids come from whatever created them (§2.6). A registry, a name
lookup, a matching algorithm and a fallback chain are the front half of fontconfig and §5 says never.

**Why the reply carries `ascent`/`descent`/`line gap` even though today's font is a cell.** They cost
six bytes, a client that lays out two lines of text needs them the moment the font is not monospace,
and a wire format that has nowhere to put them is a wire format that gets a version 2 — the same
argument `display-protocol.md` §2.5 makes about handles, and it was right there too.

### 2.5 What happens for a glyph the server lacks

**It cannot happen, and that is the point.**

Because the client sends font-relative indices and the server told the client the index count, a
"missing glyph" is not a coverage failure — it is an **out-of-range index**, which is a client bug.
**The server never needs a cmap, never needs a codepoint table, never needs a fallback chain, and can
never be asked for a character it has not heard of.** Codepoint → index is the client's problem,
solved once in the client library against the coverage the server reported.

That is a large simplification and it should be stated as loudly as it deserves: **the hardest part of
text rendering has been moved out of the server by choosing an index protocol over a character
protocol.**

What the server does with an out-of-range index, in order of preference:

1. **Draw the fallback glyph.** Index `fallbackIndex` from the info record — the hollow box, for
   exactly `fb.dart:214`'s reason. **Visible beats silent**, and this repo has already paid for that
   lesson once.
2. **Count it.** A per-session `glyphMiss` counter, returned in the info record at offset 20 and
   printable from the shell. This repo's standing pattern is that a thing you care about is a *number*
   — `fatMetaReads`/`fatMetaHits` made caching measurable at M14, and D6 in `display-protocol.md`
   applies the same rule to damage. A glyph miss is the same kind of thing.
3. **Do not tell the client synchronously.** Batches are fire-and-forget; there is no per-verb reply
   and adding one would mean a reply per verb, which is the design this transport cannot afford. A
   client that cares reads the counter.

Three answers explicitly **rejected**, with reasons, because each is what a plausible implementation
does by accident:

* **Draw nothing.** Indistinguishable from a space. This is the failure mode `fb.dart:214` and
  `check-font.py:47` were both written to prevent, and re-introducing it one layer up would be
  embarrassing.
* **Refuse the batch.** One bad index would discard 461 good glyphs, and the client has no way to
  find out which one. The refusal floor is right for *syscalls*; inside a batch it is wrong.
* **Substitute from another font.** That is font fallback. It needs a font chain, a coverage query
  per font and a matching policy, and it is the beginning of fontconfig. §5: never.

The remaining case is a **malformed batch** — a header that runs off the end of the 512 bytes, `n = 0`,
`w ∉ {1,2}`, an image id the session does not own. Those are syscall-level errors, they use the
existing refusal floor (`SYS_REFUSED`, `oslibc.h:83`), and the whole batch is refused, because a batch
whose length arithmetic does not close cannot be partially executed safely.

### 2.6 The glyph cache, and why it is the hinge of the whole document

Plan 9 does not only ship a font; it lets a client **load glyphs into the server**. `/dev/draw`'s
subfont machinery has explicit cache-load operations and `libdraw`'s `cachechars` uploads a glyph on
miss. That mechanism, here, is what makes everything in §3 and §4 possible without changing the
server, so it is worth building before there is a font that needs it.

```
   'n' NEW FONT   — 8 bytes. Asks the server to create an EMPTY font: cell/advance metrics,
                    index count, flags. Returns a font id in an 'i' record.

     off size field
       0   1  op = 'n' (0x6E)
       1   1  reserved, zero
       2   2  index count requested
       4   2  cell height
       6   2  max advance / cell width  … flags ride the low bits of index count's high byte

   'l' LOAD GLYPH — 10-byte header, then the glyph's bitmap.

     off size field
       0   1  op = 'l' (0x6C)
       1   1  font id — must be a font this session created with 'n'; font 0 is READ-ONLY
       2   2  index
       4   1  width in pixels
       5   1  height in pixels
       6   1  advance in pixels (proportional fonts)
       7   1  bearing x, signed
       8   2  bearing y, signed (from the baseline, positive up)
      10   *  the bitmap: 1 bit per pixel MSB-first row-padded to a byte, or
               8-bit coverage, one byte per pixel, per the font's flags
```

**Font 0 — the kernel's built-in — is immutable.** It lives in `.rodata`; it could not be written to
if anyone wanted to, and "the font the console uses cannot be changed by a client" is a property worth
having on purpose rather than by accident.

**Upload arithmetic, which is the number that decides whether this is viable:**

| glyph | bytes | glyphs per 480-byte batch | batches for 95 glyphs (ASCII) | for 191 (Latin-1) |
|---|---|---|---|---|
| 8×16, 1 bit | 16 | 30 | 4 | 7 |
| 16×16, 1 bit | 32 | 15 | 7 | 13 |
| 16×16, 8-bit coverage | 256 | 1 | 95 | 191 |
| 10×16 avg proportional, 8-bit coverage | ~160 | 2 | 48 | 96 |

**Uploading an entire antialiased proportional ASCII font costs about fifty `fdwrite` calls, once, at
startup.** That is nothing. It is less than a single screen repaint under the pixel-upload scheme this
protocol rejected. **Upload once, draw by index forever** is the shape, and it is the shape that makes
§3 an ordinary userland program instead of a kernel project.

**Two policies the implementer must decide and should decide narrowly:**

* **Eviction: none.** A session-created font has a fixed index count, allocated at `'n'`. When it is
  full, `'l'` is refused. An LRU eviction policy needs a replacement algorithm, a pin protocol and a
  way to tell a client its index went away — and the alternative is one number in a header. Take the
  number.
* **Lifetime: the session.** `close(fd)` frees the session's fonts along with its windows, which
  `display-protocol.md` §2.1 already says happens. No sharing between clients, no reference counts, no
  name-based lookup. Two clients that want the same font upload it twice, and at 30 KB that is fine.

### 2.7 What the client library owes

In `core/user/libc/`, next to the batch buffer `display-protocol.md` §2.3 says belongs there:

* the batch accumulator, shared with every other verb;
* **codepoint → index**, per font, built once from what the client knows about its own font;
* a `drawstring(img, x, y, fg, bg, s)` that splits a run at 255 indices and at the batch boundary;
* and **nothing else.** No layout, no shaping, no line breaking above `§5`'s "eventually must" line.

---

## 3. BEYOND BITMAP FONTS

### 3.1 First: does this system have floating point at all?

**Asked first because every answer downstream depends on it, and because the answer is different for
the two halves of the machine.**

**In the kernel / `@bare` DCDart: UNVERIFIED, and this document assumes NO.**

What I actually found:

* `DCDART_SPEC.md:178` lists `f32 f64` in §4.1's first-class integer-and-scalar type list.
* A grep for `f32|f64|float|floating` across **every** `.md` in the DCDart mirror
  (`dcdart-internal/`: `README.md`, `DCDART_SPEC.md`, `ROADMAP.md`, `SKILL.md`, `AGENTS.md`,
  `CLAUDE.md`, and the four `skills/*/SKILL.md`) returns **that one line and nothing else.** No
  decision record, no gap entry, no example, no lowering note, no ABI note.
* `known-gaps.md`'s GAP-0092 says, of the compiler as it stands: ***"`dcc` emits integer code
  only"*** — written about why SSE was never needed in ring 0.
* And the kernel agrees: there is not one floating-point value anywhere in `core/kernel/`.

So the *type names* are in the specification and the *implementation* is unproven from where I am
standing. **The DCDart repo's own decisions and gap list are not in this mirror**, so I cannot settle
it and I will not guess — Q1 in §7 asks. **Everything below is written so that the answer does not
matter**, which is a better outcome than being right about it.

**In userland C: YES, in hardware, and it is asserted rather than assumed.**

* M11 (ADR-0015) closed GAP-0092: `boot.S` probes CPUID leaf 1 for FXSR and SSE, sets
  `CR4.OSFXSR | CR4.OSXMMEXCPT` and `CR0.MP`, clears `CR0.EM`, runs `fninit` — all four guarded by the
  probe.
* Every process gets a 16-byte-aligned 512-byte FXSAVE area, saved and restored across every switch.
* `m11-proc/build-progs.sh:62` asserts `-mgeneral-regs-only` is **absent** from `CFLAGS`, and
  `build-progs.sh:188` disassembles a function containing no inline assembly and requires an `%xmm`
  register in it. **A flag is not evidence; the disassembly is.**
* On a CPU whose probe says no, `proc run` is refused by name (`procErrNoSse`).

**Three limits on that, from GAP-0103, and each one has a consequence for a rasteriser:**

1. **`fxsave`/`fxrstor`, not `xsave`. No AVX.** stb_truetype must not be built with `-mavx` or
   `-march=` anything that implies it. `-O2` with the default x86-64 baseline is SSE2 and is exactly
   what is covered.
2. **No `#XF` handler.** `CR4.OSXMMEXCPT` is set, so an *unmasked* SIMD floating-point exception
   raises `#XF` and there is nothing to catch it. MXCSR's default masks everything and `fninit` leaves
   it that way, so a divide by zero in the rasteriser produces an infinity rather than a fault —
   **provided nothing ever unmasks.** Write that down in the ADR; it is one sentence and it is the
   difference between a NaN and a triple fault.
3. **Nothing tests the x87 half.** `long double` is 80-bit x87 on this ABI and is correct only by
   construction. stb_truetype uses `float` throughout and never `long double`, so this does not bite —
   but any libm you write must not reach for it either.

**The conclusion that shapes the rest of §3: the rasteriser goes in userland, in C, in the compositor.
Not in the kernel, not in DCDart, not ever.** That is not a workaround for a missing language feature.
It is the right place for it independently — a font rasteriser is thousands of lines of arithmetic
with a heap, it has no business at CPL 0, and the machine that has the hardware to run it is the one
that already has `malloc`.

### 3.2 What TrueType actually costs, in four pieces

Written out because "add TrueType support" is one phrase covering four unrelated projects of wildly
different sizes.

**1. The parser — the smallest piece, and the only one that is merely tedious.**
An sfnt file is a table directory plus tables. A minimal renderer needs `head` (units per em, index-to-
loc format), `maxp` (glyph count), `hhea` + `hmtx` (advances), `loca` (glyph offsets), `glyf` (outlines)
and `cmap` (codepoint → glyph). Outlines are quadratic B-splines with a compressed point encoding
(flag run-length, delta-coded coordinates, and *implied on-curve midpoints* between consecutive
off-curve points — the detail everyone gets wrong first). **Composite glyphs** are the second: `é` is
usually a transform-and-offset reference to `e` plus `´`, recursively, with optional point-matching
anchors. And `cmap` is not one format — format 4 (segmented BMP) and format 12 (32-bit) are both
mandatory in practice, and format 6 and 0 turn up in old fonts.
**Then OpenType/CFF is a second, entirely different outline format** — Type 2 charstrings, cubic
béziers, a charstring interpreter with subroutines and hint operators. `.otf` files contain no `glyf`
table at all. Half the fonts anyone will hand this OS are CFF. **stb_truetype handles both**, which is
most of why it is the recommendation.

**2. The rasteriser — the piece with real algorithmic content.**
Flatten quadratics (and cubics) to line segments at a tolerance derived from the scale; build an edge
list; scanline-fill with the **nonzero winding rule** (not even-odd — TrueType contours are directional
and even-odd renders holes wrong); and handle self-intersecting contours, which real fonts contain.
stb's v2 rasteriser computes **analytic coverage** — the exact area of each pixel covered by the
polygon — rather than supersampling, which is both faster and better and is the reason its output is
usable.

**3. Hinting — the piece to never build.**
TrueType hinting is a **bytecode virtual machine** embedded in the font: its own stack, ~200 opcodes,
a graphics state with freedom and projection vectors, a control-value table, function and instruction
definitions, and — the part that makes it unbounded — thirty years of per-font quirks that real
implementations work around by name. FreeType's interpreter is tens of thousands of lines and has had
security advisories. **stb_truetype does not implement it and neither should this OS**, at any point,
for any reason. The mitigation is trivial and well-understood: hinting matters at 8–12 px and stops
mattering above ~16 px, so **render at 16 px or larger and skip it**. §5 makes this permanent.

**4. Antialiasing — cheap to compute and expensive to *draw*, here.**
The rasteriser hands back an 8-bit coverage bitmap. Turning that into pixels means
`dst = fg·a + bg·(1−a)` per channel — three multiplies, three shifts and an add per pixel, and
critically **it must read the destination**, which today's blit never does (`fb.dart:466` is opaque by
design). At 3,700 cells × 128 pixels that is 473,600 blends per screen, each one a volatile read plus
a volatile write (GAP-0034), on top of the 473,600 stores the opaque path already costs.

**So the recommendation is: build the pipeline with 1-bit glyphs first and make antialiasing its own
milestone with its own number.** A 1-bit glyph from stb (threshold the coverage at 128, or use
`stbtt_GetGlyphBitmap` and threshold) drops straight into the existing blit and the existing
`check-pixels.py` comparison. Antialiasing then becomes a change whose *cost* is measurable against a
baseline that exists, which is this repo's usual standard.

Two further "never"s that belong here rather than in §5's list because they are specifically about
antialiasing: **subpixel (RGB) antialiasing** is a bet on a physical panel's subpixel geometry and
QEMU's std VGA is not a panel; and **gamma-correct blending** requires either a lookup table or a
`pow` per channel and produces a difference nobody on this machine will ever be in a position to see.

### 3.3 stb_truetype in userland C: the realistic path, and exactly what it needs

**Recommendation: port `stb_truetype.h` into `core/user/`, build it against `oslibc`, run it in the
compositor, upload the results through §2.6's `'l'` verb.**

Why this and not FreeType: one header, public domain (no licence file to vend, no attribution
plumbing), no build system, no configuration, handles both `glyf` and CFF, no hinting to disable, and
it has exactly one dependency surface — a short list of macros it expects you to define.

**The libc surface it needs.** `stb_truetype.h` routes *every* external call through an `STBTT_*`
macro, each of which falls back to a libc name if you do not define it. That list is the entire port:

| macro | falls back to | in `oslibc.h` today? |
|---|---|---|
| `STBTT_malloc(x,u)` | `malloc` | **yes** (`oslibc.h:396`) |
| `STBTT_free(x,u)` | `free` | **yes** (`oslibc.h:397`) |
| `STBTT_memcpy` | `memcpy` | **yes** (`oslibc.h:381`) |
| `STBTT_memset` | `memset` | **yes** (`oslibc.h:382`) |
| `STBTT_strlen` | `strlen` | **yes** (`oslibc.h:383`) |
| `STBTT_assert` | `assert` | **no** — define to `((void)0)`, or to a `printf` + `exit` |
| `STBTT_ifloor(x)` | `(int)floor(x)` | **no** |
| `STBTT_iceil(x)` | `(int)ceil(x)` | **no** |
| `STBTT_fabs(x)` | `fabs` | **no** |
| `STBTT_sqrt(x)` | `sqrt` | **no** |
| `STBTT_pow(x,y)` | `pow` | **no** |
| `STBTT_fmod(x,y)` | `fmod` | **no** |
| `STBTT_cos(x)` / `STBTT_acos(x)` | `cos` / `acos` | **no** |

**Five of thirteen exist. Eight are missing and all eight are math.** The good news is how small they
are in this context:

* **`ifloor`/`iceil` are two lines each** and need no libm — for the value ranges a rasteriser sees,
  `(int)x - (x < 0 && x != (int)x)` and its ceiling twin are exact.
* **`fabs` is one line** — clear the sign bit, or `x < 0 ? -x : x`.
* **`sqrt` is one instruction.** `sqrtss`/`sqrtsd` is SSE2, it is IEEE-exact, and M11 turned SSE on. A
  one-line `__builtin_sqrtf` or an inline `asm` is the whole implementation. **This is the single best
  argument for putting the rasteriser in userland**: the hard math function is free in hardware there
  and does not exist at all in the kernel.
* **`pow`, `fmod`, `cos`, `acos`** are used only by the **signed-distance-field** path
  (`stbtt_GetGlyphSDF` and friends), which this OS has no use for. Define them to a function that
  `printf`s and `exit`s, and compile with `STBTT_STATIC`; if the SDF path is never called, they are
  never reached. **`fmod` deserves a second look during the port** — if it turns out to be reachable
  from the ordinary path, `fmodf` for the ranges here is `x - trunc(x/y)*y`, four lines.

**And do not take that table on trust — this repo's standard is evidence, and the evidence here is two
commands.** Derive the list rather than restating mine:

```
   grep -o 'STBTT_[A-Za-z_]*' stb_truetype.h | sort -u        # what it can possibly want
   clang -c … -ffreestanding stb_truetype.c && x86_64-elf-nm -u stb_truetype.o
```

**`nm -u` on the object is the real answer**, and it is exactly the kind of derived expectation the
M7–M16 harnesses are built on: the undefined-symbol set of the compiled object, checked against the
declared `oslibc` surface, with **zero symbols outside it**. That belongs in the harness (T7, §6), not
in a comment.

**Four things it does *not* need, which is as important as the list above:**

* **No file I/O.** `stbtt_InitFont` takes a pointer to the font file already in memory. The client
  reads it with the `rfread`/`read` path that exists (`oslibc.h:317`).
* **No `realloc`, no `calloc`, no `memmove`, no `strcmp` beyond what is listed** — none of which
  `oslibc` has, and none of which stb asks for.
* **No `setjmp`, no exceptions, no threads, no locale, no `errno`.**
* **No floating-point *library*.** Every operation is `+ - * /` and `sqrt` on `float`, all of which are
  SSE instructions the compiler emits directly.

**The two constraints that actually bite, and neither is the code:**

1. **Memory.** `stbtt_InitFont` indexes the font file *in place* and never copies it, so **the whole
   font file must be resident** for as long as any glyph is rasterised from it. The ring-3 window is
   2 MiB / 512 pages (`display-protocol.md` §1.2). DejaVu Sans is ~750 KB = 183 pages, leaving 329 for
   the compositor's code, heap, stack and composed output — possible, uncomfortable, and it competes
   with the thing §1.2 already says is the binding constraint on the whole window system. **A
   subsetted font of 30–100 KB is 8–25 pages and is not a problem at all.** Recommendation: subset
   offline, check in the subset, and let Q2 in `display-protocol.md` (grow the window) be settled on
   its own merits rather than by a font.
2. **Reading it in.** `read` carries at most 512 bytes (`file.dart:300`), so a 100 KB font is 200
   syscalls and a 750 KB font is 1,500. Slow, bounded, one-time, and correct — but it is a real reason
   to prefer the small font beyond the memory argument.

**And the shape of the whole thing, which is three steps:**

```
   compositor startup:   read font file  →  stbtt_InitFont  →  for each glyph in the
                         coverage set: stbtt_GetCodepointBitmap at the chosen px size
                                    →  'n' NEW FONT, then 'l' LOAD GLYPH ×N   (§2.6)
   every frame after:    's' GLYPH RUN with indices                            (§2.3)
```

**The rasteriser runs once, at startup, and then never again.** Nothing in the steady-state path
touches a bézier, a float or a font file. That is what makes this affordable on a machine whose blits
are 128 volatile stores per glyph.

---

## 4. UNICODE, COSTED END TO END

**This is the section that is routinely underestimated, and the way it is underestimated is specific:
people cost the *font* and forget the other five layers.** The font is the cheapest part. Below is
every layer, with what it costs here.

### 4.0 The starting point is worse than "ASCII"

It is not "we support ASCII". It is: **one 128-entry table, unshifted US QWERTY, break codes
discarded, extended keys consumed and ignored** (`keyboard.dart:78`, `:243`, `:252`). Consequences:

* **No uppercase letters exist on this machine.** `shift` is scancode `0x2A`/`0x36`, both map to
  `0x00`, both are discarded. There is no path by which `A` can be typed.
* No `!`, `@`, `#`, `%`, `^`, `&`, `*`, `(`, `)`, `_`, `+`, `{`, `}`, `|`, `:`, `"`, `<`, `>`, `?`, `~`
  — every shifted punctuation character. **The font has all of them; the keyboard cannot produce
  them.**
* No Ctrl, so no `^C`, no `^D`, no `^L`.
* No arrow keys — they are `0xE0`-prefixed and explicitly consumed to do nothing
  (`keyboard.dart:249`).

So the first Unicode-adjacent milestone is not Unicode at all. It is **shift**, and it is small, and
it is blocking in a way nobody notices until they try to type a capital letter into a filename.

### 4.1 Layer by layer

**1. Keyboard — small, then unbounded.**

| step | cost |
|---|---|
| Shift + caps lock | A second 128-byte `@rodata` table, two bits of modifier state in `@bss`, and **acting on break codes**, which `keyboard.dart:252` currently drops wholesale. Half a day. |
| Ctrl (`0x01`–`0x1A`) | An arithmetic case, not a table. An hour. |
| AltGr / a second layout | A third table and a layout selector. A day. |
| Dead keys (`´` + `e` → `é`) | A state machine over the *previous* key plus a composition table. Days. |
| Compose key sequences | A trie of multi-key sequences. X11's `Compose` file has ~5,000 entries. |
| **An IME (Chinese, Japanese, Korean)** | **A process, not a table.** Phonetic input, a candidate list, a dictionary of 100k+ entries, a UI that floats over the focused window, and a protocol between it and every client. This is a project on the scale of the window system itself. |

**2. The byte pipe — free now, expensive later.**

Everything from `shellKey(u8)` down is bytes, so **UTF-8 transports through this system unchanged and
costs nothing today.** That is not the same as working:

* `shellLineMax = 256` becomes 256 **bytes**, which is between 64 and 256 characters. Any limit
  expressed in characters is now a different number from the buffer size.
* **Backspace breaks.** `fbPutc` on `0x08` moves back one *cell* (`fb.dart:543`); the shell's editor
  deletes one *byte*. Deleting one byte of a three-byte character produces an invalid sequence and
  half a character on screen. A correct backspace deletes a whole **grapheme cluster** — which can be
  several codepoints, which can be many bytes.
* Every byte-oriented loop that assumes `advance by one` needs to become `advance by the sequence
  length`, and every one of them is a place to get it wrong.

**Decide UTF-8 now anyway.** Declaring "the byte encoding of every text pipe in this OS is UTF-8" is
free today, is a one-line ADR, and is invasive later. Plan 9's single best decision was this one.

**3. Protocol — already done, and this is the payoff from §2.5.**

The glyph-run verb carries **indices, not codepoints**. It does not change. It never changes. Whatever
encoding the system settles on, whatever coverage a font has, the wire format is unaffected. **The
entire Unicode question is invisible to the server.**

**4. Font — cheap until it is not.** §1.2's table. Latin-1 is 1.5 KB more `.rodata`. Latin + Greek +
Cyrillic is 16 KB. **CJK is ~900 KB and is a different architecture** — a font on disk, a glyph cache
(§2.6), and paging. The cache is what turns that from impossible into merely slow, which is the
argument for building it before anyone needs it.

**5. Rendering — where the cell model dies.** Three separate breakages, each fatal to `fbPutc`'s
`col + 1`:

* **Proportional advance.** `i` and `W` are different widths. The cursor becomes an x in pixels.
* **Double-width characters.** East Asian Width `W`/`F` (CJK, and many emoji) occupy **two** cells in a
  terminal. A per-codepoint width property table, and every column calculation gets it wrong until it
  has one.
* **Combining marks.** `e` + U+0301 is *two codepoints, one advance, two glyphs drawn at the same
  position*. `col + 1` is wrong. So is "one codepoint, one column". So is "one codepoint, one cursor
  stop".

**6. The five things everyone forgets. This is the part that is underestimated.**

* **Normalisation (UAX #15).** `é` is U+00E9 *or* `e`+U+0301. They must compare equal, sort together
  and be one cursor stop. NFC/NFD need the decomposition and combining-class tables — **tens of
  kilobytes of data, before any code.** Without it, two filenames that look identical are different
  files, and that is a bug in the *filesystem*, reached from the keyboard.
* **Case mapping is not a function on characters.** It is not 1:1 (`ß` → `SS` — one character to two),
  it is not context-free (final sigma `ς` vs `σ`), and it is not locale-free (Turkish dotless `ı`
  round-trips wrong through a naïve `toupper`). `c ^ 0x20` is correct for exactly 52 characters in the
  world.
* **Grapheme cluster segmentation (UAX #29).** "One user-perceived character" is a *cluster*, not a
  codepoint: combining marks, Hangul jamo, regional indicators, ZWJ emoji sequences. **Backspace,
  arrow keys, cursor position and text selection are all defined on clusters**, and each needs the
  property table. There is no shortcut; there is only the table.
* **Bidirectional text (UAX #9).** Arabic and Hebrew run right to left, embedded in left-to-right, with
  explicit embedding controls, a resolution algorithm over 23 character classes, an implicit
  reordering pass, and a *cursor* that has two positions at every direction boundary. It is one of the
  most intricate algorithms in the standard and it is required for correctness, not decoration.
* **Shaping (OpenType GSUB/GPOS).** Arabic letters change form by position; Devanagari reorders
  vowels *before* the consonant they follow; Thai stacks marks. **Codepoint order is not glyph
  order**, and a renderer that assumes it is produces text that native readers cannot read. HarfBuzz
  is 30,000+ lines and is the small implementation.

### 4.2 The honest summary

| target | realistic cost |
|---|---|
| Shift, caps, ctrl — a machine that can type `A` and `!` | **~2 days** |
| Latin-1 in the font and through the pipe | ~3 days on top |
| UTF-8 declared and decoded, cluster-unaware | ~1 week |
| Proportional antialiased Latin text via stb_truetype | ~2 weeks on top of a working compositor |
| Normalisation + case + cluster segmentation, correct | **months**, mostly data |
| Bidi + shaping + CJK + an IME | **years, and no small OS has finished it** |

**Say the last row out loud.** Plan 9 invented UTF-8, put it through the entire operating system, and
still does not do bidi or Indic shaping. ToaruOS, Serenity and Redox all render Latin text well and
none of them is close. **The reason this is underestimated is that the first two rows are genuinely
easy and feel like progress on the same axis. They are not on the same axis.** Rows 1–4 are a font
and a table. Rows 5–6 are the Unicode standard, and the Unicode standard is a research programme with
an annual release.

---

## 5. WHAT THIS OS SHOULD NEVER DO, AND WHAT IT EVENTUALLY MUST

### 5.1 Never

Each of these is a thing a text system can grow, each is genuinely useful somewhere, and each is a
bad trade **for this machine** — a single-user OS on emulated hardware with 512-byte syscalls, volatile
blits and a 2 MiB address window.

| never | why |
|---|---|
| **TrueType bytecode hinting** | A VM with ~200 opcodes, a graphics state, per-font quirks and a history of CVEs. Render at ≥16 px and the problem it solves does not exist. |
| **Subpixel (RGB) antialiasing** | A bet on a physical panel's subpixel order. There is no panel. |
| **Gamma-correct blending** | A `pow` or a LUT per channel for a difference nobody here can see. |
| **OpenType shaping (GSUB/GPOS)** | HarfBuzz is 30k+ lines and is the *small* one. Without a user who reads Arabic or Devanagari, this is a library nobody exercises and therefore a library that is wrong. |
| **Bidi (UAX #9)** | Same argument, plus a cursor model with two positions per boundary. |
| **Font fallback chains / fontconfig-style matching** | §2.5's whole simplification is that the server cannot have a missing glyph. A fallback chain re-introduces it, plus a matching policy, plus per-font coverage queries. |
| **Colour fonts and colour emoji (COLR/CPAL, CBDT, sbix)** | Needs alpha compositing, 136×136 source bitmaps, and a second rasteriser for layered vectors. |
| **Vertical writing modes** | A second layout axis for a use case this OS will not have. |
| **Knuth–Plass justification, hyphenation, optical margins** | Document typesetting. Not an OS's job at any size. |
| **A separate font *server* process** | The compositor is already the server. A second one is a second protocol and a second failure mode. |
| **Any text shaping, layout or rasterisation in the kernel** | The kernel keeps `fbFont8x16` and the glyph-run blit and nothing more, forever. Everything else is ring 3. |
| **A `printf` that formats floats in kernel DCDart** | §3.1: assume no floating point in `@bare`. If a kernel number needs a decimal point, print a numerator and a denominator. |

### 5.2 Eventually must

Ordered by when each becomes the thing standing in the way.

1. **Shift, caps lock and ctrl.** An OS that cannot type `A` cannot type a filename or a shell
   argument. This is first and it is not close.
2. **Scrolling.** Filed as a framebuffer gap (GAP-0070 item 1); it is a text gap. Nothing is usable
   without it. The right mechanism on this device is the dispi Y-offset register, already written by
   `fbSetMode`, driven as a ring over VRAM — not a `memcpy` that does not exist.
3. **A cursor.** GAP-0070 item 5. Two rectangles a frame; trivial once damage tracking exists.
4. **Per-run foreground and background colour**, as verb operands rather than compiled-in constants.
   The verb carries them already (§2.3); the cost is deleting two `const int`s.
5. **UTF-8 declared as the encoding of every text pipe**, even while the font is ASCII. Free now,
   invasive later.
6. **The font generator, checked in**, and the harness deriving the font's shape from `fb.dart` instead
   of restating it (§1.4). Everything else in §1 waits behind this.
7. **Latin-1, or whatever coverage Q4 settles on.** 1.5 KB of `.rodata`.
8. **Variable advance width**, i.e. an x-in-pixels cursor. The moment the font is not 8×16 this is
   forced, and every layer above `fbPutc` learns about it at once.
9. **A glyph cache with client-uploaded glyphs** (§2.6). This is the hinge: it makes proportional
   fonts, larger sizes, CJK-by-paging and antialiasing all *the same mechanism*, and it is worth
   building before any of them is needed.
10. **Greedy line breaking at spaces (first-fit).** Every text view needs it; it is thirty lines. Not
    Knuth–Plass, not hyphenation, not the Unicode line-breaking algorithm (UAX #14) — just spaces.
11. **Grapheme-cluster-aware backspace**, *if* combining marks are ever accepted from the keyboard.
    Accepting them without it produces broken sequences in the line buffer, which is worse than not
    accepting them.
12. **Antialiasing**, as its own milestone with its own measured cost against a 1-bit baseline (§3.2).

---

## 6. THE MILESTONE LADDER

**Every criterion below is written to this repo's rules for a derived expectation**, restated here
because they are the reason these criteria are worth anything:

* compute the expectation from a source the kernel does not control — `readelf`/`objcopy` on the built
  artefact, QEMU's own `info pci`, or the generator that made the input;
* restate the kernel's rules in the harness, never import them — and **assert every restated constant
  against the kernel's source**, which is the half `check-font.py` is currently missing (§0);
* **guard against a vacuous pass.** `check-pixels.py:115` fails if the expected image has zero
  foreground pixels, because otherwise it would pass against a blank screen. Every criterion below
  needs its own version of that guard;
* structural checks before boot checks, and a negative control that must fail;
* **the PNG is not evidence.** The `xp` read-back is.

**And the pattern to follow, because it is already built and it is the best thing in this repository.**
`m5-pci` proves rendered text like this:

```
   1. readelf -sW kmain.o | awk '$8=="fbFont8x16"'      → the symbol's offset in .rodata
   2. objcopy -O binary --only-section=.rodata kmain.o  → the bytes
   3. drive QEMU over QMP; the kernel PRINTS its framebuffer base on COM1 ("FB BAR FD000000")
   4. qmp-drive.py substitutes that address into 16 monitor commands:
         xp/408wx {addr}+<scanline * 3200>              → the actual pixels, out of guest memory
   5. check-pixels.py re-renders the banner ON THE HOST from the font read in step 2,
      and compares every pixel.                          (run.sh:1005, check-pixels.py)
```

**The expected image is not a golden anybody typed.** If the font changes, the expectation follows it.
If the *blit* is wrong — bit order, stride, colour, an off-by-one in the glyph index, a background
never painted — the pixels disagree and the failure names the exact pixel. Every criterion below is
an application of this pattern one layer further out, and **T7 is where it becomes something new:
the host re-renders using the same *algorithm*, not the same *table*.**

Milestones are numbered **T**, and their dependencies on `display-protocol.md`'s **D** ladder are
stated. **T1–T3 depend on nothing in that ladder and can be built today.**

---

### T1 — The machine can type a capital letter

**Blocked on: work only.** Touches `keyboard.dart` and one shared harness tool.

Modifier state in `@bss` (shift-left, shift-right, caps), a second 128-byte `@rodata` shifted table,
and **acting on break codes** rather than dropping them at `keyboard.dart:252` — the release edge is
what clears shift, so today's unconditional `return` is precisely why this does not already work.

**A shared-tool change is required and it must be additive.** `qmp-drive.py:247` sends exactly one
qcode per `send-key` call. A chord needs `keys=[{shift}, {a}]` in **one** call — QEMU then emits
make(shift), make(a), break(a), break(shift), which is exactly the sequence a modifier state machine
must survive. That file is shared by seventeen harnesses (`display-protocol.md` §8 flags the same
constraint for `--pointer`), so the change is a new `+`-joined chord syntax in `--keys`, with every
existing spelling unchanged.

*Binary:* the harness injects `shift+a, shift+1, b, caps, c, caps, d` and COM1 carries **exactly**
`A!bCd`. Then the framebuffer `xp` read-back of that line matches the host re-render of those five
glyphs from `kmain.o`'s own font — m5-pci's mechanism, unchanged. *Anti-vacuity:* the assertion fails
if the expected string contains no character that differs between the shifted and unshifted tables.
*Negative control:* a build whose shifted table is a byte-for-byte copy of the unshifted one must fail
the first assertion — proving the test is sensitive to the second table existing rather than to the
keyboard merely working.

---

### T2 — The font's shape is derived, not restated

**Blocked on: nothing.** The cheapest milestone here and the one §1 waits behind.

Check the generator in, at `core/scripts/gen-font.py` or beside `fb.dart`, taking the 5×9 authored
grids and emitting the exact `@rodata` block. Then make the harness derive from the kernel instead of
agreeing with it by luck: `check-font.py`'s `GLYPHS`, `HEIGHT`, `FONT_FIRST`, `FONT_LAST`,
`FONT_FALLBACK` and `EDGE_BITS` must each be checked against `fontGlyphCount`, `glyphHeight`,
`fontFirstChar`, `fontLastChar` and `fontFallbackIndex` in `fb.dart` — the way m13-libc checks eleven
numbers against `user.dart`, `proc.dart` and `heap.dart` (ADR-0017 §2). Same for `check-pixels.py`.

*Binary:* running the generator regenerates the `fbFont8x16` block and the resulting `fb.dart` is
**byte-identical** to the checked-in one, `diff` exit 0. And the harness fails if any of the six
restated constants differs from `fb.dart`'s. *Anti-vacuity:* the regeneration check fails if the
generator emits fewer than `fontGlyphCount × glyphHeight` bytes, so a generator that emits nothing
cannot pass a `diff` against a truncated write. *Negative control:* perturb one authored grid cell and
require both the `diff` and `check-font.py` to fail; perturb `fontGlyphCount` in `fb.dart` alone and
require the constant check to fail.

---

### T3 — The font covers more than ASCII

**Blocked on: T2.** Widening the font before the generator exists means hand-typing hex, which is
GAP-0060's own warning.

Coverage per Q4. The font stops being one contiguous range, so `fbGlyphAddr`'s two comparisons become
a range table — and **`EDGE_BITS = 0x83` must be reconsidered**, because a wider design legitimately
violates the invariant that currently guards the font's quality (§1.4).

*Binary:* a string containing at least one character outside `0x20`–`0x7E` is printed, and the `xp`
read-back matches the host re-render from the widened table. In the same boot, a byte outside the
*new* coverage still draws the fallback box, asserted by pixel comparison. *Anti-vacuity:* the check
fails if the test string contains no character outside the old range — otherwise it passes against the
old font. *Negative control:* the old 96-glyph font must fail the new string's comparison.

---

### T4 — A glyph run reaches the screen through the protocol

**Blocked on: D3 (a resident process) and D4 (one frame through the protocol).** Nothing here is
buildable until there is a compositor to hold the font.

The `'s'` verb of §2.3, font 0, into a surface, composed and flipped.

*Binary:* a client sends one batch containing a glyph run of N derived indices at a derived (x, y);
the harness dumps the **visible** framebuffer with `xp/<n>wx {addr}` at the address the kernel printed
and requires every pixel of the run's bounding box to match the host re-render from `kmain.o`'s font,
**and the pixels outside it to hold the background** — so a server that filled the surface fails.
*Anti-vacuity:* fail if the expected image has zero foreground pixels (`check-pixels.py:115`'s guard,
carried forward verbatim). *Negative control:* a batch with `n = 0` must leave the surface at
background, everywhere.

---

### T5 — Nothing hardcodes a cell size, and a miss is a number

**Blocked on: T4.**

The `'i'` verb of §2.4, and the `glyphMiss` counter of §2.5.

*Binary:* a client that contains no font geometry at all queries `'i'`, prints what it got, and the
printed cell width, height, ascent, index count and fallback index match `glyphWidth`, `glyphHeight`,
`fontGlyphCount` and `fontFallbackIndex` **read out of `fb.dart` by the harness**. Then it draws a run
containing exactly K out-of-range indices; the pixel comparison shows K fallback boxes at the derived
positions, **and the counter read back in a second `'i'` reply is exactly K.** *Anti-vacuity:* fail if
K is 0. *Negative control:* a build in which the server drops out-of-range indices instead of drawing
the fallback must fail the pixel comparison — a run of six characters would be six cells wide either
way, so **the criterion must compare the boxes' pixels, not the run's width.**

---

### T6 — The server draws a glyph it did not have

**Blocked on: T5.** This is the hinge milestone (§2.6).

`'n'` and `'l'`. The harness **generates** a distinctive bitmap — not a character, a pattern with no
symmetry, so a mirrored or transposed blit is visible — and the client uploads it.

*Binary, and this is the strong form:* **in a single boot**, the client draws index I from a
session-created font *before* uploading it and the pixels are the fallback box; then it uploads the
harness-generated bitmap and draws index I again, and the pixels match the harness's own bitmap
exactly. **Two states, one run, one comparison each.** *Anti-vacuity:* fail if the generated bitmap is
blank, or if it is symmetric under horizontal flip (which would make a reversed bit order pass).
*Negative control:* an upload to font 0 must be refused with the refusal floor and must leave the
built-in font's pixels unchanged — asserted by re-rendering an ordinary string from `kmain.o` after
the attempt.

---

### T7 — Proportional text, rasterised in userland by stb_truetype

**Blocked on: T6.** The end of the path §3 describes.

Port `stb_truetype.h` into `core/user/`, build it against `oslibc`, check in a small subsetted font
under a licence that permits it (SIL OFL or public domain — Q5).

**Two structural checks before any boot**, both derived:

* `x86_64-elf-nm -u` on the compiled object reports **zero** undefined symbols outside the declared
  `oslibc.h` surface, with the harness reading that surface out of the header rather than listing it;
* the disassembly of a compiler-generated function contains `%xmm` and contains **no** `%ymm`/`%zmm`
  — reusing `m11-proc/build-progs.sh:188`'s check verbatim, because GAP-0103 says AVX is not covered
  and a `-march` change is exactly the kind of thing that arrives silently through a build flag.

*Binary, and this is the criterion the whole document is aimed at:* the program rasterises glyph G
from the checked-in font at a derived pixel size, uploads it via `'l'`, and draws it. The harness
compares the `xp` read-back against **the same glyph rasterised on the host, by a host build of the
same `stb_truetype.h`, from the same font file, at the same size.** That is m5-pci's pattern moved one
level up: the expectation is produced by an independent execution of the same algorithm rather than
read out of a table — so it catches a wrong scale, a wrong glyph index through `cmap`, a flipped
y-axis (the rasteriser's origin is the baseline and grows *up*, the framebuffer's grows *down*, and
this is the bug), a wrong bearing, and a threshold applied at the wrong point.

*Anti-vacuity:* fail if the host rasterisation produces zero set pixels — a wrong glyph index often
lands on `.notdef` or on a space, and a blank-versus-blank comparison passes. *Negative control:*
re-run the host side at pixel size ± 1 and require the comparison to **fail**, proving it is sensitive
to the rasterisation rather than to both sides being empty.

---

### T8 — UTF-8 through the whole pipe

**Blocked on: T1 and T3, and on Q3 being answered.** Listed last because it is the one whose *scope*
is a decision rather than a size, and because §4.2's honest table applies to everything past it.

*Binary:* a multi-byte sequence typed at the keyboard survives the line buffer, is stored in a file,
is read back, and renders as one glyph in the derived position — with backspace deleting **the whole
sequence**, asserted by a pixel comparison of the cell after the backspace against the background.
*Negative control:* a build whose backspace deletes one byte must leave a fallback box on screen, and
the comparison must catch it.

---

## 7. WHAT I DID NOT DECIDE, AND WOULD RATHER BE TOLD

**Q1 — Does `@bare` DCDart have working `f32`/`f64` today?** (§3.1)

`DCDART_SPEC.md:178` lists them; a grep across every markdown file in the DCDart mirror returns that
one line and nothing else; `known-gaps.md` GAP-0092 says `dcc` *"emits integer code only"*; and there
is not one floating-point value in `core/kernel/`. **The DCDart repo's own decision records and gap
list are not in this mirror, so I cannot settle it.** This document is written so the answer does not
matter — the rasteriser goes in userland C either way, for reasons independent of the language — but
it should be settled before anyone plans kernel-side graphics arithmetic around it.

**Q2 — Does the server font live in the kernel or in the compositor?** (§2.6)

Font 0 is `kmain.o`'s `.rodata` today and the console needs it there. The *window system's* default
font does not have to be the same object. Keeping it there means the harness can `objcopy` it, which
is the entire basis of the m5-pci verification pattern and worth a great deal. Moving it to the
compositor makes it replaceable and removes 1.5 KB (or 16 KB) from the kernel. **My recommendation is
to keep font 0 in the kernel permanently** — it is the console font, it must exist before any process
does, and its being in an object file the harness can read is a testing property this repo should not
give up.

**Q3 — UTF-8 now, or bytes now?** (§4.1)

Declaring UTF-8 as the encoding of every text pipe is free today and invasive later. **My
recommendation is to decide it before T1**, because T1 is the milestone that doubles the keyboard
table, and a second layout arriving after the encoding decision is much cheaper than before it.

**Q4 — What is the coverage target?** (§1.2, T3)

"English forever" is a legitimate answer and it makes T3 unnecessary. Latin-1 is 1.5 KB. Latin +
Greek + Cyrillic is 16 KB. CJK is a different architecture and should be named as such rather than
arrived at. I have no basis for guessing which, and T3's size depends entirely on it.

**Q5 — May a font file be checked into this repository?** (T7)

stb_truetype needs a font to rasterise, and the harness needs the *same* font on the host. SIL OFL and
public-domain faces exist. But this repo has a strong preference for generated inputs over checked-in
binaries (§1.4 is a complaint about exactly that), and a 100 KB binary blob is a different kind of
artefact from a generator script. The alternative — generate a tiny synthetic TTF from a script — is
real work and would test the parser less honestly.

---

## 8. NOTES FOR THE COORDINATOR TO FOLD IN ELSEWHERE

**I have not touched `known-gaps.md` or `ROADMAP.md`.** These are the things that belong in them.

* **A new gap: the font's generator does not exist.** `fb.dart:590` describes it; `core/scripts/` does
  not contain it. `check-font.py` proves the invariant it would produce, which is why this has gone
  unnoticed, but nobody can add a glyph the way the existing ones were added. §1.4, T2.
* **A new gap, and it is the sharper one: four font constants are restated in Python and checked
  against nothing.** `check-font.py`'s `GLYPHS = 96`, `FONT_FIRST/LAST = 0x20/0x7E` and
  `FONT_FALLBACK = 95`, and `check-pixels.py`'s copies of the same, have no assertion against
  `fb.dart`'s `fontGlyphCount`, `fontFirstChar`, `fontLastChar` and `fontFallbackIndex`. m13-libc
  checks eleven such numbers against three kernel files (ADR-0017 §2); these four are the exception.
  **The first milestone that widens the font is the one where a harness silently keeps passing.**
* **GAP-0055 deserves a fifth item, or item 2 deserves widening: this machine cannot type an uppercase
  letter.** It currently reads as "no shift handling", which sounds like a missing feature. It is
  closer to a missing capability: no capitals, no shifted punctuation, no ctrl, no arrows. §4.0.
* **GAP-0070 item 1 (no scrolling) is a text gap filed as a framebuffer gap**, and its suggested fix
  ("a `memcpy` primitive in DCDart") is the more expensive of the two answers it names. The dispi
  Y-offset register is already written by `fbSetMode` (`fb.dart:392`) and `display-protocol.md` §3.2
  establishes there are eight frames of VRAM behind it.
* **GAP-0070 item 8 (the font is ASCII-only) should point at this document** for what widening it
  costs, and at §1.2's table for the number at which it stops being a `.rodata` change.
* **A tooling gap with a known shape, and it is the second one on this file.** `qmp-drive.py` sends one
  qcode per `send-key` (`:247`) and therefore cannot inject a chord — no shift, no ctrl. T1 needs a
  `+`-joined chord syntax; `display-protocol.md` §8 needs `--pointer` for D1. **Both are additive
  changes to a file shared by seventeen harnesses, and whoever touches it first should make room for
  the other.**
* **A note for whoever ports a libc math function.** §3.1 item 2: `CR4.OSXMMEXCPT` is set and there is
  no `#XF` handler (GAP-0103). MXCSR's defaults mask every SIMD exception and `fninit` leaves them
  masked; **nothing in userland may unmask them** until a handler exists. That is one sentence in an
  ADR and it is the difference between a NaN and a triple fault.
