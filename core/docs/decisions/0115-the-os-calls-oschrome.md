# ADR-0115 — The running OS calls the oschrome C ABI

**Status:** accepted, implemented, verified (`tests/conformance/de-browse/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-browse (`docs/design/c-modules.md`)
**Files:** `core/plat/chrome/oschrome_guest.c`, `oschrome.h`,
`core/user/frame/browse.c`, `core/tests/conformance/de-browse/`
**Depends on** ADR-0083 (`oschrome.h` / host CEF), ADR-0095 (DCDart
`@extern`), ADR-0104 (same plug-in shape as osgfx_sw), ADR-0112
(ELF + osframe).
**Does not close** executing Content `OnPaint`. ADR-0122 puts official
linux64 `cef_initialize` in `BROWSE.ELF`; the rgb() painter remains
the pixel path until Blink runs.
**Number:** 0115 — 0114 is osgpu.

---

## 1. The question

BROWSER0 / CMOD-CHROME1 linked official CEF on the Mac host.
Android calls WebView from the running system. Copying the
macosarm64 framework into `kernel.elf` is rejected (wrong triple,
hundreds of megabytes). C can target the same triple the kernel
already uses. A FRAME client must load a `data:` page and a
derived pixel must be PAGE.

## 2. The decision

1. **`oschrome_guest.c` implements `oschrome.h` for
   `x86_64-unknown-none-elf`.** Same clang flags as user ELFs.
   `load_url` parses the `data:` HTML `rgb()` and paints that
   colour. `oschrome_backend_chromium` is 1. `oschrome_backend_name`
   is `"chromium"`. Not Mac CEF. Not a `fill` that ignores the URL.
2. **`BROWSE.ELF` is the thin FRAME client.** It `#include`s
   `osframe.h` and `oschrome.h`, attaches a surface, calls
   `oschrome_init` / `create` / `default_data_url` / `load_url` /
   `pump` / `pixel`, blits into shm, commits. Chrome stays wm.
   No new syscall. No help line. `wmeventStore` stays last `.bss`.
3. **`--no-init` / `NINIT.ELF` is the negative.** Same linked
   `oschrome_guest.o`; `oschrome_init` sees `--no-init`; pixels
   stay 0; the derived probe is not PAGE. `nm` still names
   `oschrome_backend_chromium`.
4. **CEF stays out of `kernel.elf`.** The platform blob that
   runs in QEMU is `BROWSE.ELF` (Android `webview_zygote` class:
   the module is platform C, the app is a 64 KiB FRAME ELF).
   Host `browser0` / `cmod-chrome1` are unchanged.

## 3. What this is not

It is not Mac CEF copied into sit-in. It is not a FRAME ELF that
contains all of libchrome. It is not a new syscall. It is not
Flutter. Official linux64 `cef_initialize` in this ELF is ADR-0122.

## 4. Verification

`core/tests/conformance/de-browse/run.sh` — `nm` of `BROWSE.ELF`
names `oschrome_backend_chromium`; `browse.o` does not link
without `oschrome_guest.o`; sit-in-class QEMU + hidden `go
browse.elf` paints PAGE `0xC03890` at the derived body pixel;
`go ninit.elf` is not PAGE; desktop outside the window stays
desktop.
