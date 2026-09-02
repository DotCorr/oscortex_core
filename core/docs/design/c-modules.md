# C/C++ platform modules — libc, osgfx, Skia Graphite, Vulkan, Chromium, FFmpeg

**Status: DESIGN. Not an ADR, not numbered.** GFX0 / CMOD1 is implemented
(`core/plat/osgfx/`, harness `gfx0-host/`, ADR-0080). GFX1 is implemented
(`osgfx_graphite.mm`, harness `gfx1-graphite/`, ADR-0082). COMPOSE0 is
implemented (`osgfx_scene_compose`, harness `gfx2-compose/`, ADR-0094):
session chrome through Graphite. BROWSER0 is implemented
(`core/plat/chrome/oschrome.h`, harness `browser0/`, ADR-0083): official
CEF macosarm64, one `data:` URL, derived pixel.
CMOD-CHROME1 is implemented (`oschrome.dart`, harness `cmod-chrome1/`,
ADR-0095): DCDart `@extern`s the same C ABI.
MEDIA0 is implemented (`core/plat/media/osmedia.h`, harness `media0/`,
ADR-0103): official brew FFmpeg, one planted frame, derived pixel.
Vulkan is **not in the tree**. This file is the contract those rungs
must keep. A sentence that does not name TODAY / NEXT / BLOCKED /
FANTASY is a bug in this document.

**It cites rather than re-derives.** App packages (the 64 KiB ELF
window) are `app-system.md` §4. libc inventory is `libc-roadmap.md`.
Language identity is `dcdart.md`. `@extern` without descriptors is
GAP-0166. The DCDart↔C call shape is `dcdart-c-ffi.md`. **No syscall
is invented here.**

---

### The five things this document lands on, for a reader in a hurry

1. **These libraries are oscortex, not apps.** Android did not put
   Chromium in an APK size cap and call it a guest. It put C++ in the
   platform (WebView / Trichrome, Skia in hwui, Vulkan as the GPU
   API) and let Java call it through JNI. oscortex is the same
   shape: DCDart is the language; Skia Graphite, Vulkan, and
   Chromium are **platform C++**. The 64 KiB / 2 MiB numbers are
   the **app** sandbox (`exec-format.md`). They do not apply to
   WebView. Do not write "guest Chrome" again.
2. **A platform module is a C ABI you link into the OS**, the way
   `oslibc.h` is a C ABI an app links. `osgfx.h` is the second
   module: paint. Graphite, Vulkan, and Chromium Content sit behind
   the same kind of header. DCDart never `#include`s them
   (`dcdart.md` §4). It calls the C symbols, like Java calls JNI.
3. **The UI language is `osgfx.h` (rrects, fills, shadows).** Host
   harnesses prove the module. QEMU sit-in is how we boot the OS.
   Sit-in chrome is Skia CPU raster in `kernel.elf` (ADR-0110,
   `osgfx_skia.cpp` / ELF `libskia.a`), not a host window.
   `osgfx_sw.c` stays in-tree. Graphite `MakeVulkan` is linked
   (ADR-0129). ADR-0134 opens a kernel ICD when Venus is
   offered; one Graphite GPU pixel lands. Chrome rrects
   (ADR-0153) and desktop/taskbar fills (ADR-0159) go through
   Graphite + ICD DRAW. Curved `MakeRectXY` paints via host-precompiled
   SPIR-V + ICD radius (ADR-0161, `de-graphite5/` PASS) — freestanding
   AnalyticRRect SkSL still #GPs if invoked. Venus encodes retained
   SPIR-V via CONTEXT_INIT + blob (ADR-0172, `de-graphite6/` PASS,
   `OSGFX VENUS SPIRV`); full lavapipe CreateShaderModule / Graphite FS
   coverage is leftover.
4. **Skia Graphite belongs in oscortex core.** Chrome already
   depends on it. GFX1 fetches and builds it as `libskia.a`
   (ADR-0082). brew `graphite2` is a font library. Flutter is on
   PATH; do not embed it (`dcdart.md`).
5. **DCDart talks to C/C++ the way Java talks to C on Android and
   Rust talks to C:** a C ABI, shared memory, or a direct call.
   Today `@extern` is a name, not a descriptor (GAP-0166). The
   contract is `dcdart-c-ffi.md`. No new syscall on this rung.

---

## 0. Horizon

### 0.1 TODAY

| fact | value | citation |
|---|---|---|
| first C module (app libc) | `oslibc.h`, 41 symbols, 9 of them C89 | `libc-roadmap.md`; ADR-0017 |
| first platform paint module | `core/plat/osgfx/osgfx.h`, Graphite + Metal fallback | ADR-0080; ADR-0082; ADR-0094; `gfx0-host/`; `gfx1-graphite/`; `gfx2-compose/` |
| widget kit through that paint ABI | `core/plat/osxui/osxui.h` (`osxui_button`, `osxui_panel`, `osxui_hit`, `osxui_label`, `osxui_hex`) | ADR-0113; ADR-0117; ADR-0133; ADR-0136; `osxui4/`; `de-glyph/`; `de-osxui/`; `de-panel/` |
| platform toolchain (this Mac) | Apple clang, arm64 Mach-O, `-framework Metal` | `build-preview-ui.sh` |
| app toolchain | `clang -target x86_64-unknown-none-elf` | `app-system.md` §4.1 |
| app image / window | 64 KiB ELF, 2 MiB — **apps only** | `exec-format.md` |
| app UI today | shm pixels + `wmsurface` | ADR-0051 |
| Skia Graphite | **host `libskia.a`** (not in the kernel image) | ADR-0082; `gfx1-graphite/` |
| Vulkan / MoltenVK | **not installed** | GAP-0313 |
| Chromium in-tree | **host CEF** (`oschrome.mm`, `browser0/`) **and** official linux64 `cef_initialize` in `BROWSE.ELF` (QEMU, ADR-0115 / ADR-0122) | ADR-0083; ADR-0115; ADR-0122; `de-browse/` |
| FFmpeg in-tree | **in `kernel.elf`** (`x86_64-unknown-none-elf` `libavcodec` / `libavformat` / `libavutil`; host brew remains `media0/`) | ADR-0103; ADR-0116; `media0/`; `de-media/` |
| Flutter on PATH | ignore it; not an embedder | `dcdart.md` §3 |

### 0.2 NEXT — binary, not a paragraph

| rung | binary next step | not done when |
|---|---|---|
| **GFX1** | **Done** — Skia Graphite behind `osgfx.h`. Harness `gfx1-graphite/`. Metal is fallback only. | |
| **COMPOSE0** | **Done** — session chrome through `osgfx.h` / Graphite. Harness `gfx2-compose/`. | |
| **G9** | **Done** — `GET_CAPSET_INFO` on the VirtIO-GPU control queue. Harness `g9-virtgpu/`. Not Skia-on-GPU. | |
| **GFX2** | Vulkan (MoltenVK on this Mac) as a platform backend behind `osgfx.h`. Harness `gfx2-vulkan/`: same probe, `nm` shows a Vulkan symbol. | "Vulkan is portable" with no dylib. |
| **BROWSER0** | **Done** — Chromium Content behind `oschrome.h`. Official CEF macosarm64. Harness `browser0/`. `--no-init` is the negative. | |
| **CMOD-FFI1** | **Done** — `osgfx.dart` `@extern`s the C module; `dcc --target host`; harness `cmod-ffi1/`. | |
| **CMOD-CHROME1** | **Done** — `oschrome.dart` `@extern`s `oschrome_ffi_*`; `dcc --target host`; harness `cmod-chrome1/`. PAGE pixel; `--no-init` is the negative. Not in the kernel image. | |
| **MEDIA0** | **Done** — FFmpeg behind `osmedia.h`. Official brew 8.1.2. Harness `media0/`. `--no-init` / `--missing` are the negatives. Host-only. | |
| **DE-media** | **Done** — official FFmpeg rebuilt for `kernel.elf`'s triple; hidden `play` decodes planted `CLIP.MP4` to serial PIX (`de-media/`, ADR-0116). **ADR-0131 (`de-vblit/`)** blits that tile onto the sit-in scanout. **ADR-0135 (`de-vwin/`)** commits it through a `wmsurface` at (200, 80). Missing file / `OSMEDIA_NO_BLIT` / `OSMEDIA_NO_WIN` are the negatives. Leftover: a movie (more than one still). | |
| **DE-osgfx** | **Done** — Skia CPU raster linked into `kernel.elf` (ADR-0110); live `osgfx_fill_rrect` → `SkCanvas::drawRRect` (ADR-0125). Harness `de-osgfx/`. | |
| **DE-graphite** | **Door** — guest-elf Graphite + `MakeVulkan` in `kernel.elf` (ADR-0129). **VkDevice** — Venus capset 4 + kernel ICD (ADR-0134, `de-graphite2/`). **Chrome rrect** — Graphite `drawRRect` + ICD DRAW (`de-graphite3/`, ADR-0153, `RRECT 00C45A20`). **Desktop fill** — Graphite `drawRect` + ICD DRAW (`de-graphite4/`, ADR-0159, `DESK 001C6A38`). **Curve** — host-precompiled SPIR-V + ICD radius (`de-graphite5/`, ADR-0161, `CURVE 00A87C14`); freestanding AnalyticRRect SkSL still #GPs if invoked. **Venus SPIR-V** — CONTEXT_INIT + blob encode (`de-graphite6/`, ADR-0172, `OSGFX VENUS SPIRV`). Homebrew stays `NONE`. Leftover: lavapipe executes CreateShaderModule / Graphite FS. | |
| **OSXUI-kit** | **Done** — `osxui.h` button / panel / hit / label / hex through `osgfx.h`. Harness `osxui4/` + `de-glyph/` + `de-title/` + `de-panel/`. Glyphs via `osgfx_fill_glyph`. Title `PID` on chrome (ADR-0132). Panel hex pids (ADR-0136). | |
| **G11** | **Done** — that compose buffer reaches `virtio-gpu-gl-pci` via `TRANSFER_TO_HOST_3D` + `SET_SCANOUT`. Harness `g11-osgfx-gl/`. Not Graphite. Leftover: bind Graphite/Vulkan paint to that scanout. | |
| **G12** | **Done** — explicit app GPU (`osgpu.h` create / submit / readback). Hidden `osgpug` hits G10 virgl. Harness `gpu-app0/`. UI never calls osgpu. Leftover: swapchain, shaders. | |
| **DE-browse** | **Done** (extract + rgb pixel) — leftover **OPEN** (ADR-0123): `OnPaint` is not called. Official `libcef.so` needs 32 `DT_NEEDED` (`libc.so.6`, `ld-linux-x86-64.so.2`, …). Floor stays 87. **PLAT-PROC** (ADR-0124): named `PLAT.ELF` may use a 16 MiB window; TAP/FILES stay 64K/2MiB. **PLAT-DYN** (ADR-0126): that name may carry `PT_INTERP` → our `LD.SO`; missing interp is still 11. **PLAT-REL** (ADR-0127): that name may carry `PT_DYNAMIC`; `LD.SO` applies RELA; ASK.ELF is still 11. **PLAT-MAP** (ADR-0128): that name may `mmap` anonymous pages (syscall 27); ASK.ELF of that size is refused; teardown frees the frames. **PLAT-CLONE** (ADR-0130): that name may `clone(fn, stack)` (syscall 28) onto the same page tables; ASK.ELF of the same bytes is refused; first FREED is 0. **PLAT-DL** (ADR-0144): `dlopen` (syscall 29). **PLAT-FUTEX** (ADR-0146): `futex` wait/wake (syscall 30). **PLAT-TLS** (ADR-0148): `setfs` / `IA32_FS_BASE` (syscall 33). **PLAT-LIBC** (ADR-0152): OUR tiny `LIBC.SO` `write` through `dlopen`. **PLAT-HUGE** (ADR-0155): 189 MiB platform `mmap`. **PLAT-NEED** (ADR-0157): two FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO`) → derived `LINE1`/`LINE2`; **2/32**. **PLAT-NEED2** (ADR-0160): four FAT `DT_NEEDED` (`LIBC.SO` + `LIBM.SO` + `LIBDL.SO` + `LIBPT.SO`) → derived `LINE1`..`LINE4`; **4/32** stand-ins, **28 remain**. **PLAT-NEED3** (ADR-0162): eight FAT `DT_NEEDED` (+ `LIBGB.SO` + `LIBGO.SO` + `LIBNP.SO` + `LIBNS.SO`) → derived `LINE1`..`LINE8`; **8/32** stand-ins, **24 remain**. **PLAT-NEED4** (ADR-0163): sixteen FAT `DT_NEEDED` (+ `LIBNU.SO` + `LIBSM.SO` + `LIBDB.SO` + `LIBGI.SO` + `LIBAT.SO` + `LIBAB.SO` + `LIBCU.SO` + `LIBX1.SO`) → derived `LINE1`..`LINE16`; **16/32** stand-ins, **16 remain**. **CEF-DL** (ADR-0174): real `DT_NEEDED` `libdl.so.2` via planted `SOMAP.TXT` → `LIBDL.SO`; missing map refuses. Leftover: rest of UND / other 31 sonames / `OnPaint`. | |

### 0.3 BLOCKED

| wanted | blocked by | what would unblock |
|---|---|---|
| Official Content / Graphite **in the running OS image** | `libcef.so` is 1.5 GiB `ET_DYN`, 32 `DT_NEEDED`, 189 MiB `.text`; ADR-0126 opened `PT_INTERP` for `PLAT.ELF` → our `LD.SO` (`plat-dyn/`). ADR-0127 opened `PT_DYNAMIC` on that name (`plat-rel/`, one `R_X86_64_64`). ADR-0128 opened anonymous `mmap` on that name (`plat-map/`, syscall 27). ADR-0130 opened `clone` on that name (`plat-clone/`, syscall 28). ADR-0144 opened `dlopen` (`plat-dl/`, syscall 29). ADR-0146 opened `futex` (`plat-futex/`, syscall 30). ADR-0148 opened `setfs` (`plat-tls/`, syscall 33). ADR-0152 opened OUR tiny `LIBC.SO` `write` (`plat-libc/`). ADR-0155 opened the full 189 MiB platform window (`plat-huge/`). ADR-0157 walks two FAT `DT_NEEDED` (`plat-need/`, 2/32 stand-ins). ADR-0160 walks four (`plat-need2/`, 4/32 stand-ins). ADR-0162 walks eight (`plat-need3/`, 8/32 stand-ins). ADR-0163 walks sixteen (`plat-need4/`, 16/32 stand-ins). ADR-0124 opened a 16 MiB platform `sbrk` window (`plat-proc/`). Graphite is a host `libskia.a` | other **16** `DT_NEEDED` (or a static rebuild), then a platform Content process. Not another 558-byte extract. FFmpeg **is** in `kernel.elf` (ADR-0116) |
| DCDart descriptors on `@extern` | escalation 0004; GAP-0166 | that repo |
| `@bare` calling C++ methods (`SkCanvas::drawRRect`) | no C++ ABI in `@bare` | wrap C++ in C (`osgfx.h` is that wrap), same as JNI |

### 0.4 FANTASY — do not plan, do not cost, do not imply

* **Stuffing libchrome into `BTN.ELF`.** That was the wrong box.
  Apps do not contain WebView. The platform does.
* **`dcc` on Flutter sources / embed Flutter engine.** `dcdart.md` §3.
* **HTML as the UI language.** Deleted.
* **A new "draw" syscall.** Prefer `@extern` + shm + `wmsurface`.

---

## 1. Android's split, restated for this tree

```
  Android                         oscortex
  --------                        --------
  Java / Kotlin                   DCDart (@bare)
  JNI / native method             @extern + C ABI  (dcdart-c-ffi.md)
  libhwui + Skia                  osgfx.h → Skia Graphite
  Vulkan                          Vulkan (same)
  WebView / Trichrome             Chromium Content in core/plat
  MediaCodec / Stagefright        FFmpeg in core/plat/media
  app APK                         FRAME ELF (64 KiB / 2 MiB)
  system_server / webview_zygote  platform process / OS image
```

An Android app does not compile Chromium. It calls `WebView`. A
FRAME app does not compile Chromium. It talks to the platform
module. QEMU is a **boot** of oscortex, the way an emulator boots
Android. It is not a "guest" Chromium has to fit inside.

**Two compile lines, two jobs — not two worlds:**

```
  PLATFORM (oscortex core)
    clang / clang++   →  osgfx, later libskia, later Content
    Apple clang on this Mac is the same sources, for host harnesses

  APP (a program the user runs)
    clang -target x86_64-unknown-none-elf -I oslibc -I osframe
    → ELF ≤ 64 KiB in [0x10000000, 0x10200000)
```

A module that needs a C++ runtime, a GPU process, or a hundred
megabytes is a **platform module**. It is not a FRAME app.
`app-system.md` §4 still holds for apps. It never applied to WebView.

---

## 2. What GFX0 proved

`osgfx.h` records rounded rects, axis-aligned fills, vertical
gradients, and shadows. `osgfx_graphite.mm` executes them on
Skia Graphite (Metal GPU). `osgfx_metal.m` is the fallback.
`osgfx-headless` writes a P6 PPM. `gfx0-host` and `gfx1-graphite`
assert the AABB corner of the first window is **desktop**, not
title — a `fill_rect` implementation fails that probe, and
`--square` exists so the harness can see the failure mode on
purpose. `gfx2-compose` (`--compose`) is the same language on the
real compositor policy scene (ADR-0094).

That is the platform paint module. Chromium plugs in behind the
same header. It does not replace it with a web page.

---

## 3. Chrome as the system browser

Android ships Chromium in the platform. Apps embed a view. The
browser is C++ that Java can call because the boundary is C.

oscortex wants that **shape**: Chromium is a `core/plat` module;
DCDart (and C apps) talk to it through a described C ABI; the
compositor owns scanout.

**What that is not, today:** Host CEF is `oschrome.mm` (ADR-0083).
DCDart `@extern`s it on the Mac (`oschrome.dart`, ADR-0095). The
running OS calls the same header through `oschrome_guest.c` linked
into `BROWSE.ELF` with official linux64 `cef_initialize` (ADR-0115,
ADR-0122). Mac CEF is not in `kernel.elf`. Do not stuff all of
libchrome into a FRAME ELF. Leftover: Content `OnPaint` (ADR-0123)
needs a ring-3 libc / process ABI — 32 `DT_NEEDED`, not another
extract.

---

## 4. FFmpeg as the platform decoder

Android ships a decoder in the platform. Apps do not contain
libavcodec. `exec-format.md` §4 gated ffmpeg on the **app** 64 KiB
window. That number never applied here.

**What MEDIA0 is:** `osmedia.h` opens a container, decodes one
frame, reads a derived pixel (`osmedia_open`,
`osmedia_decode_frame`, `osmedia_pixel`). brew FFmpeg 8.1.2
(`libavcodec` 62.28.102 / `libavformat` 62.12.102 /
`libavutil` 60.26.102). Harness `media0/`. `--no-init` and
`--missing` are the negatives. `osmedia.dart` `@extern`s the same
ABI.

**What DE-media added:** the same C ABI is linked into `kernel.elf`
for the kernel triple (ADR-0116, `de-media/`). Hidden `play` decodes
a planted H.264 clip to a derived serial pixel. **ADR-0131
(`de-vblit/`)** blits that RGB tile onto the sit-in framebuffer.
Missing file is not FRAME. `OSMEDIA_NO_BLIT=1` is the skip-blit
miss. **ADR-0135 (`de-vwin/`)** commits the decoder buffer as a
`wmsurface`. `OSMEDIA_NO_WIN=1` is the skip-window miss. Do not stuff
libavcodec into a FRAME ELF. Do not invent a decode syscall.
