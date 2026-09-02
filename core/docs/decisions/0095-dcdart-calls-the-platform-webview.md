# ADR-0095 — DCDart calls the platform WebView

**Status:** accepted, implemented, verified (`tests/conformance/cmod-chrome1/run.sh`)
**Date:** 2026-08-30
**Milestone:** CMOD-CHROME1 (`docs/design/dcdart-c-ffi.md`, `docs/design/c-modules.md`)
**Files:** `core/plat/chrome/oschrome.dart`, `oschrome_ffi.c`, `ffi_main.c`,
`oschrome.h` (FFI-safe u64 decls only), `core/scripts/build-oschrome.sh`,
`core/tests/conformance/cmod-chrome1/`
**Depends on** ADR-0083 (`oschrome.h` / CEF) and ADR-0081 (`osgfx.dart` shape).
**Does not close** GAP-0313 items Graphite / Chromium **in the running OS image**.
**Number:** 0095 — 0083 is the C module; this is the DCDart call.
0082/0083 stay Graphite / Content. 0092–0094 are NVMe / virtgpu / compositor.

---

## 1. The question

BROWSER0 linked official CEF behind `oschrome.h`. A later browser app /
OSXStudio must call that platform WebView the way Android Java calls
JNI `WebView`. It must not embed CEF, and it must not be a guest
Chrome ELF.

## 2. The decision

1. **`oschrome.dart` `@extern`s `oschrome_ffi_*`.** Handles are `u64`
   (GAP-0025). `dcc --mode bare --target host` emits a Mach-O object.
   clang++ links `oschrome.mm` and `libcef_dll_wrapper`. One process,
   two compilers, a C ABI. That is JNI without Java.
2. **DCDart sees** `oschrome_ffi_init`, `create`, `load_url`, `pump`,
   `pixel` / `readback` / `ppm`, `destroy`, `shutdown`,
   `backend_chromium` / `backend_is_chromium`. `load_url` loads the
   default `data:` URL on the C side (GAP-0035: no `String`).
3. **`oschromeFfiPage` issues that sequence.** The harness PPM is that
   path. `--no-init` / `oschromeFfiNone` is the negative: `BACKEND none`,
   pixel is not PAGE. `nm` still shows `cef_initialize` /
   `oschrome_backend_chromium`.
4. **No syscall, no `.bss`, no `help` line.** Syscall 11 stays `fdwait`.
   Chromium is not linked into `kernel.elf`. Flutter is not embedded.

## 3. What this is not

It is not Chromium in the OS image. It is not a FRAME ELF. It is not
Flutter. It is not a fake HTML parser in DCDart.

## 4. Verification

`core/tests/conformance/cmod-chrome1/run.sh` — Mach-O `oschrome_ffi.o`
names `oschrome_ffi_load_url` and `oschromeFfiPage`; the linked binary
names `oschrome_backend_chromium` and a `cef_` symbol; the PPM PAGE
pixel matches `0xC03890`; `--no-init` is not PAGE.
