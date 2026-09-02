# OSXUI — a native desktop widget kit, not Flutter

**Status: DESIGN. Not an ADR, not numbered.** Nothing in this file is
implemented except the compositor facts it cites. When a piece is built it
gets its own numbered ADR; this document is the thing those ADRs will
point back at.

The UI language is the C paint ABI `core/plat/osgfx/osgfx.h`.
DCDart calls it (`osgfx.dart`, ADR-0081). Host harnesses sample
a PPM. Sit-in boots the OS. Chromium is a **platform** WebView,
not an app ELF (`c-modules.md`). Skia-on-GPU (Graphite → Vulkan
/ virgl / Venus → VirtIO scanout) is the leftover (ADR-0097).

**It cites rather than re-derives.** Surfaces are ADR-0051. Chrome is
ADR-0056. Input-as-a-queue is ADR-0054. A left press is ADR-0055. Keyboard
focus is ADR-0062. The compositor owns the framebuffer (ADR-0050). Right
and middle buttons are decoded by D1 and ignored by the window manager
(GAP-0302). Configure and enter/leave are ADR-0142. The host-side
ABI is `app-framework.md` / `osframe.h`. Language identity is `dcdart.md`:
**apps are DCDart or freestanding C against osframe, never Flutter.** A
widget here is pixels a client painted and a rectangle it hit-tests. It
is not a Flutter `Widget`, not a scene graph, and not a reflective
object. **No syscall is invented here.**

**Ladder prefix `OSXUI`.** `APP` is the Unix-tooling ladder
(`applications.md`). `FRAME` is the ABI-and-surface ladder
(`app-framework.md`). This is the *desktop chrome and widget* ladder.
Identity with an existing milestone is stated rather than counted twice.

---

### The five things this document lands on, for a reader in a hurry

1. **There is no Flutter on this machine, and this kit is not a port of
   one.** `dcdart.md` §2–§3: `@bare` is a cut, not Flutter-native;
   pointing `dcc` at Flutter sources does not produce Skia, Impeller, a
   Dart runtime, or isolates. OSXUI is compositor policy plus client
   pixels. A "button" is a dirty rectangle and a hit test the **client**
   runs on a `wmevent` press.
2. **Title bars exist when chrome is on.** ADR-0075: an 18-pixel
   compositor-drawn caption on the top of each window's content,
   colour `0x00D8B060`, gated on `wm chrome` so `d2-compositor` does
   not move. Close and minimise landed behind `wm de` (ADR-0106).
   Resize is still unbuilt. A FRAME client that paints its own caption
   is still painting, not chrome.
3. **The taskbar exists and is off by default.** `wm chrome` (ADR-0056)
   paints the bottom `wmChromeH` (24) rows and consumes a press on that
   strip. It is compositor policy, not a client surface, not a syscall,
   not a `help` line (GAP-0304). OSXUI does not re-derive it and does
   not turn it on for every boot — `d2-compositor` and `d8-chrome`
   already own that contract.
4. **Right-click is a decoded bit that nobody consumes.** D1 stores left,
   right, and middle in the packed mouse word (`mouse.dart`
   `mousePktButtons = 0x07`). `wmPointerTick` then masks to bit 0
   (`mouseWordButtons & 1`) and only a left down-edge calls `wmGrab`.
   GAP-0302: *"Only the LEFT button."* **OSXUI1 is the compositor
   context popover** — the first consumer of that ignored right bit.
5. **First rungs use the syscalls that already exist:** `wmsurface` (23),
   `kbdevent` (24), `wmevent` (25), `mouse` (20), plus `shmcreate` (16)
   to hold pixels. They are named in `osframe.h`. A kit that waits on a
   new "widget" syscall is a different project.

---

## 0. Horizon — TODAY / NEXT / BLOCKED / FANTASY

A sentence in this document that does not name its bucket is a bug in
the document.

### 0.1 TODAY — true of the tree this was written against

| fact | value | citation |
|---|---|---|
| surfaces | `wmsurface` attach/commit; 64-byte descriptor; no address in it; client is **told** the pixel address | ADR-0051; `osframe.h` |
| composition | kernel compositor (`wm.dart`); newest surface on top; 3-pixel compositor-drawn border (bright/dim) | ADR-0050 |
| chrome / taskbar | 24-pixel bottom strip, colour `0x00C09048`, **off unless `wm chrome`** | ADR-0056; `wmchrome.dart`; `d8-chrome` |
| title bars | 18-pixel content-top strip, colour `0x00D8B060`, **off unless `wm chrome`** | ADR-0075; `wmchrome.dart`; `d8-title` |
| left click | per-window queue; syscall 25; surface-relative coords; desktop click enqueues nothing | ADR-0055 |
| keys | 32-event ring; syscall 24; focused window's owner pops, else the shell | ADR-0054; ADR-0062 |
| mouse | syscall 20 is a **level poll** of x/y/buttons/packets; every reader sees the same word | ADR-0042; GAP-0253 |
| right / middle | decoded by D1, **ignored** by `wmPointerTick` | GAP-0302; `wm.dart` `wmPointerTick` |
| configure / enter/leave | under `wm de`, attach/move/resize enqueue type 2; focus change is enter/leave on syscall 25 | ADR-0142; `de-cfg/` |
| widgets | **OSXUI2** one hit rectangle (`btn.c`); **OSXUI3** one client, two surfaces (`menu.c` / `MENU.ELF`); **OSXUI-kit** C module (`osxui.h`) paints through `osgfx.h` | ADR-0051; ADR-0113; this file; `osxui2/`; `osxui3/`; `osxui4/` |
| Flutter / Dart VM / reflection | **not present.** `@extern` carries no descriptors | `dcdart.md`; GAP-0166 |
| host session chrome | `osgfx_scene_compose` on Graphite; same colours/sizes as `wm*` | ADR-0094; `gfx2-compose/` |
| sit-in chrome | Skia CPU raster in `kernel.elf`; compositor calls `osgfx_fill_rrect` → live `SkCanvas::drawRRect`; `wm gfx` | ADR-0110; ADR-0125; `de-osgfx/` |
| sit-in chrome on VIRGL | same compose buffer uploaded to a 3D resource + `SET_SCANOUT` | ADR-0107; `g11-osgfx-gl/` |

Positively, a program today can attach a small surface, paint, commit
damage, pop a key if it is focused, pop a left press if it owns the
window, and poll the pointer. That is enough for OSXUI1–OSXUI3.

### 0.2 NEXT — kernel or userland, no new syscall, no DCDart language feature

* **OSXUI1.** The compositor notices a right down-edge and paints a
  transient popover. Same class of work as ADR-0056: policy in
  `wm.dart` / a sibling part, not a descriptor field, not a syscall.
* **OSXUI2.** **Done** — `core/user/frame/btn.c` / `BTN.ELF`, harness
  `osxui2/`. A FRAME client paints one control (a hit rectangle and two
  colours) and reads `kbdevent` / `wmevent` against `osframe.h`.
* **OSXUI3.** **Done** — `core/user/frame/menu.c` / `MENU.ELF`, harness
  `osxui3/`. One client owns two regions (main + menu). Click or key
  opens the menu. Still `wmsurface` + `wmevent` + `kbdevent`.
* **OSXUI4.** **Done** — `wm de` (ADR-0106, `de-chrome/`). Taskbar
  slots, close, min, start/spotlight, reflection panel. Gated so
  `wm chrome` alone does not move d8 goldens.
* **OSXUI-kit.** **Done** — `core/plat/osxui/osxui.h` (`osxui_button`,
  `osxui_panel`, `osxui_hit`, `osxui_label`). Implementation calls
  `osgfx_fill_rrect` / `osgfx_fill_rect` / `osgfx_fill_glyph`
  (ADR-0113, ADR-0117, ADR-0132, ADR-0133, ADR-0136, harness `osxui4/` /
  `de-glyph/` / `de-title/` / `de-osxui/` / `de-panel/`). Same `.c`
  compiles for the kernel triple. Live Start / close / min call
  `osxui_button`. Title-bar `PID` is chrome glyphs. Panel hex pids
  are `osxui_hex` glyphs (ADR-0136).
* **OSXUI-text.** **Done for DE chrome** — ADR-0187, harness
  `de-skia-text/`. `osxui_label` no longer stamps an 8×16 cell when it
  holds an `OsGfx`: it calls `osgfx_text`, which replays a real Roboto
  TrueType outline (build-time `glyf` extraction, font units, real
  `hmtx` advances — `core/scripts/gen-osgfx-font.py`) into an
  `SkPathBuilder` and fills it with `SkCanvas::drawPath` antialiased at
  a caller-chosen px size. Proportional and live-rasterised, but **not**
  `SkFont`/`SkTypeface`: the guest-elf Skia has no scaler context or
  font manager, so there is no shaping, kerning, hinting or subpixel
  positioning, and the table is ASCII only (GAP-0327). Chrome shapes in
  the same rung became Skia `drawRRect`/`drawPath` with AA plus
  `SkShaders::LinearGradient` and `SkMaskFilter::MakeBlur` elevation;
  the CPU `rrect_cover` span walker is the no-canvas fallback only.
  `osgfx_fill_glyph` and its `osgfx-glyph-aa` soft-coverage door remain
  for the packed-scanout label path — soft-edged, and not to be called
  Skia.
* Title `PID` on chrome is ADR-0132. Live hex pids on the panel are
  ADR-0136. Configure / enter/leave are ADR-0142 (`de-cfg/`).
* `unlink` / `rename` so a kit that persists layout does not destroy the
  previous file (`applications.md` APP4). Not a widget problem. That
  is the leftover after GAP-0308.

### 0.3 BLOCKED ON DCDART

| wanted | blocked by | where |
|---|---|---|
| a widget that can name itself to an AI driver | type descriptors in `.rodata`; escalation 0004 not ratified | GAP-0166; `app-framework.md` FRAME7 |
| `String` titles, labeled menus in `@bare` | DCDart GAP-0035 (`StringLiteral`) | `display-protocol.md` §6; `dcdart.md` §2 |
| live-edit of a compiled handler | introspection, intercession, a guest compiler | `app-framework.md` §4 |
| a Flutter embedder, Impeller, isolates | a Dart runtime this OS does not have | `dcdart.md` §3 |

Until those exist, a "labeled" control is bytes the client wrote into
its own pixels (a baked glyph blit, or a solid colour plus a serial
line). That is a kit. It is not a reflective UI tree.

### 0.4 FANTASY — do not plan, do not cost, do not imply

* **Flutter, GTK, Qt, SwiftUI, a web view.** There is no HTML engine, no
  JS runtime, no sockets for "load this URL". Native UI is FRAME pixels.
* **CSS, a layout engine, constraints, a scene graph.** `@bare` has no
  growable collection and no function pointers
  (`display-protocol.md` §6). A first kit is a static array of
  rectangles in `.bss`.
* **Title-bar traffic as protocol.** Position is compositor policy
  (`display-protocol.md` §1.1). Putting a title string in the 64-byte
  attach descriptor would make every client carry decoration policy
  (ADR-0056 §3).
* **Wayland xdg-shell, CSD libraries, `mmap` of the framebuffer.**
  Ring 3 never touches VRAM (ADR-0050 §2 point 2).

---

## 1. What a widget is on this machine

`display-protocol.md` §0.1: a surface has pixels and a position; a
window has a title bar, a close button, a stacking order and a manager.
**We have surfaces. We have a 3-pixel compositor border. We have a
taskbar strip that is off. We do not have windows in that fuller
sense.**

OSXUI therefore splits in two, and the split is the same one ADR-0050
already made between protocol and policy:

| layer | who paints | who hit-tests | examples |
|---|---|---|---|
| **compositor policy** | kernel (`wmCompose`, `wmChromeDraw`) | `wmHit`, `wmChromeHit`, and (OSXUI1) a popover hit | border, taskbar, context popover |
| **client kit** | the process that attached the surface | the process, on `wmevent` coords it was told | button, label, list row, client menu |

The kit does **not** become a kernel object. A button is not a syscall.
The compositor does not walk a widget tree — there is no tree, and
GAP-0166 says there is no membrane that would describe one.

A FRAME client already knows the loop (`app-framework.md` §2):

```
  shmcreate → wmsurface attach → paint → wmsurface commit
  yield loop: kbdevent pop; wmevent pop; (optional) mouse poll
```

OSXUI2 and OSXUI3 are that loop plus a rectangle table in `.bss`. They
do not wait on `String`, reflection, or a new number in
`syscall-registry.md`.

---

## 2. Chrome that exists, chrome that does not

**Taskbar — exists, off by default.** ADR-0056: `wmMetaChrome` is word
19 of the existing `wmStore` block; `wm chrome` sets it; the strip is
the bottom 24 rows, full `fbWidth`, drawn after windows and before the
pointer; a press on it is consumed and is not a drag and is not a
`wmevent`. Damage does not repaint the strip; only a full compose does.
OSXUI must not turn this on inside `d2-compositor`'s default path.

**Title bars — exist, off by default.** ADR-0075: `wmTitleH` is 18,
colour `wmTitleColor`, painted on the top of each live window's
content when `wmMetaChrome` is set. The strip is inside the surface so
a press still raises. Under `wm de` only the caption starts a drag
(ADR-0111); a body press goes to the client. Close and minimise are
ADR-0106. Resize under `wm de` is ADR-0121 (clip). A FRAME client that paints its own
caption (OSXUI2's shape) still loses those rows when chrome is on.

**Popover / context menu — does not exist.** The right button is the
hole. OSXUI1 fills it as compositor policy so a person sitting at the
machine has one menu that does not require a FRAME client to be
written first.

---

## 3. OSXUI1 is the compositor context popover

GAP-0302: right and middle are decoded by D1 and ignored here.
`wmPointerTick` keeps only bit 0 of the button bitmap. A right press
today moves the pointer (the packet was applied) and does nothing else.

**The popover is compositor policy, like the taskbar, not a surface
protocol.** Reasons, all already decided for chrome:

1. When OSXUI1 landed a FRAME client was not told configure or
   enter/leave (GAP-0308, now ADR-0142). A menu that must appear at
   the pointer cannot wait for the client to learn where it is.
2. Putting a "show menu" op in the 64-byte descriptor would make every
   client carry compositor decoration policy (ADR-0056 §3).
3. `shmMax` was 2 when the first menu landed. A popover that is a
   third attached surface was `wmRetNoSpace` on a two-window sit-in
   (ADR-0109 raised the table to 4; the first menu stays compositor
   chrome anyway). The first menu cannot be a surface.
4. The kernel already hit-tests (`wmHit`, `wmChromeHit`) and already
   paints rectangles it owns (`wmFillRect`, `wmChromeDraw`).

**What OSXUI1 is.** On a right-button down-edge (bit 1 of the D1
bitmap, the bit `wmPointerTick` currently throws away):

* do **not** start a drag and do **not** `wmeventEnqueue` that press
  (left press stays ADR-0055);
* record a popover origin at the pointer, clamped so a  N×M rectangle
  fits the framebuffer including the taskbar strip if chrome is on;
* compose a compositor-owned rectangle — a derived colour, a derived
  size, a small number of rows (a "New surface" tile is enough for the
  first binary);
* a later left press that hits the popover is consumed as chrome is
  consumed; a left press that misses dismisses it; Escape is still not
  special for focus (ADR-0062) and is not required for this rung.

Off unless a right press happened. `wmInit` zeroes state, so every
harness that never injects a right button keeps today's pixels.

**What OSXUI1 is not.** It is not a client menu (that is OSXUI3). It is
not title bars. It is not a new syscall. It is not `wmevent` type 2.
It does not close GAP-0302 — resize under `wm de` is ADR-0121
(clip, not configure); close and minimise are ADR-0106; title-drag
under `wm de` is ADR-0111. It
does not deliver a right press to the client; the client still does
not see button 2 on `wmevent` (ADR-0055's packed word is type = press,
and "press" means the left down-edge the compositor already noticed).

---

## 4. The OSXUI ladder

Each early criterion follows the repo's derived-expectation rules
(`display-protocol.md` §6): compute the expectation from a source the
kernel does not control; restate constants in the harness; guard a
vacuous pass; carry a negative control.

**OSXUI1–OSXUI3 assume no new syscall, no `String`, no reflection, no
Flutter, no hosted Dart SDK.** Title bars are compositor chrome
(ADR-0075), not a client kit.

---

### OSXUI1 — The compositor paints a context popover on right-click

**Blocked on: work only.** D1 already decodes the right bit. The
compositor already hit-tests and fills rectangles. Touches `wm.dart` /
a chrome-class part, not `user.dart`, not the registry.

Deliverable: `wmPointerTick` distinguishes a right down-edge from a
left one. A right press paints a popover; a left press keeps today's
raise/drag/`wmevent` path. The popover is compositor-owned pixels, a
derived colour, a derived origin at the injected pointer.

*Binary:* `wm on`, one surface or none; inject a right-button packet at
a host-derived `(x, y)` that is not on the taskbar; a `pmemsave` (or
`xp` of RAM, not of a BAR — `design/README.md`) shows the popover
rectangle in the derived colour and desktop (or client) colour
outside it. Serial may print a `WM POPOVER` line with origin and size
the host computed. A subsequent left press outside the popover leaves
those pixels at the composed desktop/client colour again.
*Anti-vacuity:* popover area is not zero; the derived colour is not the
desktop colour and not `wmChromeColor`.
*Negative control:* a build that still masks `mouseWordButtons & 1`
only leaves the framebuffer unchanged at the popover rectangle (the
right press is still ignored). A build that treats a right press as a
left press fails `d7-click` / drag assertions — the two edges must
stay distinct.

Uses **existing** `mouse` state (the D1 bitmap). Does not add a
syscall. Does not require a FRAME client.

---

### OSXUI2 — A client paints one control and reads keys and a click

**Done.** Kept client `core/user/frame/btn.c` compiled against `osframe.h`
(no private `SYS_*`). Harness `core/tests/conformance/osxui2/` (PASS).
`proc spawn` starts `BTN.ELF` so the prompt returns (ADR-0053).

`wmsurface`, `kbdevent`, and `wmevent` were already built. This is a kept
program against `osframe.h`, not a new compositor property.

Deliverable: `BTN.ELF` (8.3), `proc spawn`ed (ADR-0053). It attaches a
small surface (240×160 or 256×256 — `display-protocol.md` §1.2), paints
a control rectangle in a derived colour, commits, and in a `yield` loop
pops `kbdevent` and `wmevent`. A derived scancode or a left press
*inside* the control rectangle flips the control to a second derived
colour and commits that damage (ADR-0052).

*Binary:* after spawn and `wm on`, the framebuffer shows the control
rectangle; after the harness injects the derived key (ADR-0054's 50 ms
method) **or** a left press whose surface-relative point `derive.py`
computed inside the control, the rectangle holds the second colour.
*Anti-vacuity:* the two colours differ; the control area is not the
whole surface, so a client that fills everything cannot pass the
outside-the-control probe.
*Negative control:* a click injected on the surface but **outside** the
control (and still inside the window — ADR-0055 still enqueues it)
must **not** flip the control; a build that treats any `wmevent` as a
hit fails that probe.

Uses existing syscalls only: `shmcreate` 16, `wmsurface` 23,
`kbdevent` 24, `wmevent` 25. `mouse` 20 remains a level poll if the
client wants hover it cannot yet be told (GAP-0308).

Identity note: FRAME2 is "a surface client that is not a harness"
(`surf.c` / `SURF.ELF`). OSXUI2 is a second kept client **plus one
hit rectangle** (`btn.c` / `BTN.ELF`). Both have landed; they are
not the same program.

---

### OSXUI3 — A second surface is a client-owned menu

**Done.** Kept client `core/user/frame/menu.c` / `MENU.ELF`, harness
`osxui3/` (PASS). One process may own more than one `wmMaxWindows` slot;
`wmCommit` finds the window by region, `wmevent` pops every ring the
caller owns. `shmMax` is 4 (ADR-0109). This rung boots **one
client**: the app attaches its main surface, then a click or a derived
key attaches a small menu surface at a geometry it asked for, paints
items as colour bands, commits, and reports a main-surface press
without flipping the band. Escape dismisses (stops treating the menu
as live).

*Binary:* one client, two attach/commit pairs; the framebuffer shows
both rectangles in host-derived colours; a click on a menu band flips
that band; a click on the main surface but not the menu leaves the
menu colour unchanged and is reported on the main window's `wmevent`
queue (ADR-0055: only the owning slot sees its events — here one
process owns both, so the program hit-tests **which handle** the press
landed on using the surface-relative coords and the geometries it
asked for).
*Anti-vacuity:* menu area is not zero and does not equal the main
surface.
*Negative control:* a client that attaches the menu and never commits
it leaves those pixels at desktop/background (D4's control).

No new syscall. The menu is a surface, not compositor chrome. It is
the shape a later "File" menu takes. It is **not** OSXUI1; the
compositor popover still exists for the case where no client offered a
menu, and for the desktop.

**Two-window sessions can attach a third surface** after ADR-0109
(`shmMax` 4). OSXUI3 still boots one client; it uses two of four
slots. State that in the harness.

---

### OSXUI4 — Taskbar slots, close, min, start, panel *(policy, not protocol)*

**Done** — ADR-0106, `wmde.dart`, harness `de-chrome/`. `wm de` raises
the chrome word to level 2. Close destroys the surface; min holds
without paint; start lists FAT ELF names and spawns through syscall
26's guts; the panel lists live slots and pids. Off unless `wm de`.
A boot that only types `wm chrome` is unmoved (`d8-chrome` /
`d8-title`). Sit-in's disk is that FAT volume (ADR-0108,
`de-sitfat/`): `FILES.ELF`, `SET.ELF`, `PING.ELF`, `STUDIO.ELF`.
Title-drag under `wm de` is ADR-0111 (`de-wm/`). Resize under
`wm de` is ADR-0121 (`de-resize/`): clip, no configure.

---

### OSXUI5 — A click's right-button twin reaches a client that asked

**Blocked on: OSXUI1, and on a decision, not on a new number.**
`wmevent` already has a type field (ADR-0055: type 1 = left press). A
right press that a **client** wants (a surface that drew its own
context affordance) can be type 2 on the same syscall 25, same queue,
same surface-relative coords. The compositor popover (OSXUI1) remains
the default when the client has not claimed the right button.

Do not allocate syscall 26 for this. If an ADR later disagrees, it
takes a registry row in that commit.

Until this rung, a FRAME client that wants "right-click edit" polls
syscall 20's button bits (GAP-0253: every program sees the same
coordinates) or does not offer that gesture. `app-framework.md` §4
already said right-click-to-edit of **data** waits on a press the
client receives. Left press landed at D7; right press is this rung.

---

### Capstone, with no binary criterion — a widget tree, Flutter

Title bars started as compositor chrome (ADR-0075). A widget tree that
an AI driver can walk is FRAME7 / DCDart escalation 0004
(`app-framework.md` §5). Flutter is `dcdart.md` §3. **This entry
exists to say those are not OSXUI rungs.**

---

## 5. What I did not decide, and would rather be told

1. **Does a right-click on a surface show the compositor popover, the
   client's menu, or the client's first?** OSXUI1 takes compositor
   first so a machine with no FRAME app still has a menu. OSXUI5 is
   the opt-in the other way. The owner can reverse that.
2. **How many popover rows, and are they glyphs or colour tiles?**
   `text.md` T1 is still "this machine cannot type a capital `A`" for
   *input*; the kernel already blits 8×16 glyphs to the framebuffer.
   I recommend colour tiles for OSXUI1's binary and glyphs only when
   a row's bytes are `@rodata`, not `String`.
3. **Confirm no new syscall through OSXUI3.** I have treated `wmevent`
   type 2 as OSXUI5 and as a packed-word extension, not a number.

---

## 6. Notes for the coordinator

* **Prefix `OSXUI`.** Do not call these D10+ — the display ladder is
  protocol; this is policy and a userland kit.
* **OSXUI2 may be FRAME2.** Count once.
* **GAP-0302 is not closed by OSXUI1.** A popover is one more piece of
  chrome, like the taskbar.
* **GAP-0166 is not reopened.** A widget with a field table is FRAME7.
* **Apps that use this kit are DCDart or C against osframe**
  (`dcdart.md`). A Flutter `.apk` / `pubspec.yaml` is a different
  operating system.
