# DCDart ↔ C — the FFI, like JNI and `extern "C"`

**Status: DESIGN. Not an ADR, not numbered.** CMOD-FFI1 is implemented
(`osgfx.dart`, ADR-0081, harness `cmod-ffi1/`). CMOD-CHROME1 is
implemented (`oschrome.dart`, ADR-0095, harness `cmod-chrome1/`).
MEDIA0 adds `osmedia.dart` `@extern`s (`osmedia_ffi_*`, ADR-0103;
C harness `media0/` is the floor).
Nothing here is a language change and no syscall is allocated. This
file is the contract so a later agent does not invent a "draw"
syscall or embed Flutter.

**It cites rather than re-derives.** `@extern` is DCDart ADR-0038: a
name sidecar, not a descriptor (GAP-0166). Escalation 0004 §6 says
C libraries are zombies and recommends **describe the boundary**.
Surfaces are ADR-0051. Shared regions are ADR-0041. Platform C
modules are `c-modules.md`. Syscall 11 remains `fdwait`.

---

### The one-paragraph answer

Android's Java does not instantiate `SkCanvas`. It calls a native
method; C++ on the other side of JNI does the work. Rust does the
same with `extern "C"`. DCDart already has the **name** half
(`@extern`) and uses it for kernel assembly (`boot.S`, `isr.S`,
`portio.S`). It does not have the **descriptor** half. Until
escalation 0004 ships descriptors, oscortex describes the C paint
boundary in this repo: a header, integer arguments, and an optional
shm display list. `@bare` calls C the way the kernel already calls
`outb` — a symbol, integers and pointers, one return — or it does
not call C at all. It does not `#include`. It does not instantiate
`SkCanvas`. **There is no guest in this sentence.** The C++ is
platform. DCDart is the caller.

---

## 0. Horizon

### 0.1 TODAY

| fact | value |
|---|---|
| kernel `@extern` | names of asm functions; SysV x86_64 / AAPCS64; integers and pointers |
| `@extern` sidecar | permitted-undefined **names** (ADR-0038), not types |
| hosted `dcc` | CLI. Links `osgfx` (CMOD-FFI1), `oschrome` (CMOD-CHROME1), `osmedia` (MEDIA0) |
| `@bare` | no `String`, no function pointers, no `&&` / `\|\|`, one return |
| FRAME apps | C `#include osframe.h` **or** `osframe.dart` literals (`dcdart.md` §4) |
| platform paint | `osgfx.h` / Graphite (ADR-0082), Metal fallback |
| platform WebView | `oschrome.h` / CEF (ADR-0083); DCDart `@extern` (ADR-0095) |
| platform media | `osmedia.h` / FFmpeg (ADR-0103); DCDart `@extern` (`osmedia.dart`) |

### 0.2 NEXT — CMOD-FFI1 **done**; CMOD-CHROME1 **done**

`core/plat/osgfx/osgfx.dart` `@extern`s `osgfx_ffi_*`. `dcc --mode
bare --target host` emits Mach-O. clang++ links Graphite
(`osgfx_graphite.mm`) and the Metal fallback.
`osgfxFfiPaint` clears, `fill_rrect`, flushes, writes a PPM.
Harness `cmod-ffi1/` (ADR-0081). The harness samples that PPM.

`core/plat/chrome/oschrome.dart` `@extern`s `oschrome_ffi_*`.
`oschromeFfiPage` inits, creates, loads the default `data:` URL,
pumps, reads a pixel, writes a PPM. Harness `cmod-chrome1/`
(ADR-0095). `--no-init` is the negative.

That is JNI without Java: **one process, two compilers, a C ABI.**
It is not a Mac UI program.

### 0.3 BLOCKED on DCDart

| wanted | blocked by |
|---|---|
| `@extern` that states arity, widths, ownership | escalation 0004 §6; GAP-0166 |
| calling C++ (`SkCanvas::drawRRect`) from `@bare` | no C++ ABI in `@bare`; wrap C++ in C (`osgfx.h`) |
| function pointers / callbacks from Skia into `@bare` | GAP-0023 |
| `String` titles crossing the boundary | GAP-0035 |

### 0.4 FANTASY

* A new syscall 27 `osgfx`. The paint list is bytes in a region the
  caller already holds (`shmcreate` 16, `wmsurface` 23).
* Dart `dart:ffi` / `@Native`. That is Dart. DCDart is not Dart.
* Passing ARC / C++ objects through `@extern` (ADR-0038 already
  refuses ARC-managed types).

---

## 1. Calling convention (what both compilers must agree)

Until DCDart publishes a descriptor, the **written** convention is:

1. **Name.** The C symbol is the DCDart `@extern` name. If `dcc`
   emits `_osgfx_fill_rrect` on Mach-O, the C side is
   `osgfx_fill_rrect` and Darwin's underscore is the linker's
   problem. Measure it on CMOD-FFI1.
2. **Integer arguments** in the platform C ABI registers (`rdi…`
   on x86_64 SysV; `x0…` on AAPCS64). Widths are `u32` / `u64` /
   `Pointer<T>` as `@bare` already uses for `Port.outb`.
3. **One return.** `Pointer` or integer. `@bare` cannot return a
   struct. `osgfx_create` returns a pointer; failures are 0.
4. **No hidden `this`.** C++ stays behind `osgfx.h`. Graphite's
   `skgpu::graphite::Recorder` is not an `@extern` type.
5. **No callbacks.** Skia completion procs wait on function
   pointers this language does not have. Flush is synchronous, as
   `osgfx_flush` already is.

That is Rust's `extern "C"` and Android's JNI, without either
runtime.

---

## 2. Shared-memory display list (when the caller is an app)

A FRAME app does not link libskia. It does not need to. Android
apps do not link libchrome. They call WebView; the platform
rasterizer runs in the system.

An app that wants the **language** without the library writes an
array of words into a shm region it already created:

```
  word0  opcode     1=clear 2=fill_rect 3=fill_rrect 4=vgrad 5=shadow
  word1  x
  word2  y
  word3  w
  word4  h
  word5  radius_or_0
  word6  colour0    0x00RRGGBB
  word7  colour1    (vgrad) or blur (shadow)
```

Eight words, 32 bytes, same size class as the `wmsurface`
descriptor. The **platform** rasterizer — today host Graphite
in `core/plat`, later Vulkan / Chromium — walks the list and
calls `osgfx_*`. The app only stores integers.

**Commit stays `wmsurface` op commit.** Either:

* **A.** DCDart and the C module share a process (CMOD-FFI1 / JNI
  shape). This is the next binary.
* **B.** A platform rasterizer process maps the same shm, paints
  pixels, and the app `wmsurface`-commits those pixels
  (ADR-0051 unchanged). Android's renderer process is this shape.
* **C.** The kernel grows a walker. Later ADR. Not a new syscall
  if it reuses commit.

Prefer A, then B. Do not take syscall 21, 22, or 27.

---

## 3. What must land where

| piece | repo | rung |
|---|---|---|
| C header `osgfx.h` | oscortex `core/plat` | **GFX0 done** |
| Metal backend | oscortex platform | **GFX0 done** |
| DCDart sibling `osgfx.dart` + `@extern` | oscortex | **CMOD-FFI1 done** |
| `dcc` link with Graphite + Metal fallback | oscortex scripts | **CMOD-FFI1 done**; **GFX1 done** |
| `@extern` descriptors | DCDart | escalation 0004; GAP-0166 |
| Skia Graphite behind the same C symbols | oscortex platform | **GFX1 done** (ADR-0082) |
| Chromium Content as platform WebView | oscortex platform | **BROWSER0 done** (ADR-0083, `oschrome.h`) |
| DCDart sibling `oschrome.dart` + `@extern` | oscortex | **CMOD-CHROME1 done** (ADR-0095, `cmod-chrome1/`) |
| C header `osmedia.h` + FFmpeg | oscortex platform | **MEDIA0 done** (ADR-0103, `media0/`) |
| DCDart sibling `osmedia.dart` + `@extern` | oscortex | **MEDIA0** (`osmedia_ffi_*`; C harness is the floor) |

---

## 4. Sibling files, no `#include`

`dcdart.md` §4: DCDart does not `#include`. CMOD-FFI1 adds
`osgfx.dart` next to `osgfx.h` the way `osframe.dart` sits next to
`osframe.h`. CMOD-CHROME1 adds `oschrome.dart` next to `oschrome.h`. MEDIA0 adds `osmedia.dart`
next to `osmedia.h`.
An author keeps the numbers equal. A harness greps both for
`OSGFX_RADIUS` / the integer `14`, or `OSCHROME_W` / `u64(128)`,
or `OSMEDIA_PX` / `u64(16)`.
