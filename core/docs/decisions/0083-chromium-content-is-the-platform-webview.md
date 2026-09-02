# ADR-0083 — Chromium Content is the platform WebView

**Status:** accepted, implemented, verified (`tests/conformance/browser0/run.sh`)
**Date:** 2026-08-30
**Milestone:** BROWSER0 (`docs/design/c-modules.md`)
**Files:** `core/plat/chrome/oschrome.h`, `oschrome.mm`, `headless_main.c`,
`core/scripts/fetch-cef.sh`, `core/scripts/build-oschrome.sh`,
`core/tests/conformance/browser0/`
**Depends on** ADR-0080 (`osgfx.h` is a sibling module, not this one).
**Does not close** GAP-0313 items Vulkan / Graphite-in-the-OS-image.
**Number:** 0083 — 0082 is Graphite behind `osgfx.h`; this is Content
behind `oschrome.h`.

---

## 1. The question

GFX0/GFX1 painted `osgfx.h` on Graphite/Metal. BROWSER0 is the
system browser the way Android has WebView: Chromium Content as a
**platform** C++ module. Not an app ELF. Not Flutter. Not
`preview.html`. Not Metal rewritten as "Chrome".

## 2. The decision

1. **Fetch the official Spotify CEF macosarm64 minimal prebuilt**
   (`fetch-cef.sh`). Stamp
   `144.0.34+g8fc21c8+chromium-144.0.7559.261`, sha1 pinned.
   That is Chromium Content, not a fake HTML parser.
2. **`oschrome.h` is the C ABI** a later Studio / DCDart caller
   `@extern`s: `oschrome_init`, `oschrome_create`,
   `oschrome_load_url`, `oschrome_pump`, `oschrome_pixel` /
   `oschrome_readback` / `oschrome_ppm_write`,
   `oschrome_backend_chromium`.
3. **`oschrome.mm` calls `CefInitialize` and windowless `OnPaint`.**
   A stub that only exports `oschrome_backend_chromium` and fills a
   rect is a fail. The harness requires a `cef_` / `CefInitialize`
   symbol and greps the `.mm` for `CefInitialize`, `OnPaint`,
   `SetAsWindowless`.
4. **`OSCHROME_NO_CHROMIUM=1` / `--no-init` is the negative.** Same
   binary, no `CefInitialize`, pixels are not the HTML colour. CEF
   symbols stay in the image (`nm`).
5. **Do not edit `osgfx_metal.m` / `osgfx.dart`.** Live paint stays
   Graphite. Chrome lives in `core/plat/chrome/`.
6. **No syscall, no `.bss`, no `help` line.** FRAME apps still do
   not contain libchrome.

## 3. What this is not

It is not Flutter. It is not an app ELF. It is not `preview.html`.
It is not WebKit. It is not Graphite-in-the-kernel. It is a host
platform process with a real address space (Android
`webview_zygote` class).

## 4. Verification

`core/tests/conformance/browser0/run.sh` — Mach-O arm64, `nm` has
`oschrome_backend_chromium` and a `cef_` symbol, the framework is
present, default PPM `BACKEND chromium` and derived pixel is PAGE,
`--no-init` is `BACKEND none` and not PAGE, CEF symbols remain.
