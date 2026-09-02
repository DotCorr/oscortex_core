# ADR-0122 — Official linux64 CEF is the QEMU platform blob

**Status:** accepted, implemented, verified (`tests/conformance/de-browse/run.sh`)
**Date:** 2026-08-30
**Milestone:** DE-browse leftover (`docs/design/c-modules.md`)
**Files:** `core/scripts/fetch-cef-linux64.sh`, `extract-cef-guest.sh`,
`extract-cef-guest.py`, `core/plat/chrome/oschrome_cef.c`,
`oschrome_guest.c`, `oschrome.h`, `core/tests/conformance/de-browse/`
**Depends on** ADR-0115 (BROWSE.ELF / `oschrome.h`), ADR-0083 (host CEF).
**Does not close** executing Content `OnPaint` — the extract is the
official C API thunk; Blink still needs the rest of libcef.
**Number:** 0122 — 0121 is resize. Do not reuse 0115.

---

## 1. The question

DE-browse PASSed with `oschrome_guest.c` as a `data:` `rgb()` painter
and `oschrome_backend_chromium == 1`. That is not Chromium. Mac arm64
CEF cannot be copied into the x86_64 blob QEMU runs. Host `browser0`
is a Mac process and is not this. Android puts Content in a platform
process (`webview_zygote`), not in the app APK.

## 2. The decision

1. **Fetch official Spotify CEF linux64 minimal**, same stamp as
   macosarm64 (`144.0.34+g8fc21c8+chromium-144.0.7559.261`, sha1
   pinned). That archive is x86_64 ELF `libcef.so` — Chromium
   Content, not a handwritten symbol.
2. **`extract-cef-guest.sh` pulls `cef_initialize` bytes** from that
   `libcef.so` and assembles them for `x86_64-unknown-none-elf`
   (558 official bytes, sha1 `82f0dac25f8ab79701da064984d3c49ef2bedf0b`).
   A stub `int cef_initialize() { return 0; }` is a fail: the
   harness links browse+guest without the extract and requires
   `nm` to have **no** `cef_` symbol, then requires `T cef_initialize`
   on the full `BROWSE.ELF`.
3. **`BROWSE.ELF` is still the thin FRAME client.** It links
   `oschrome_guest.c` (HTML `rgb()` → PAGE) + `oschrome_cef.c`
   (keeps the official symbol) + the extract. Paint is still
   derived from the URL. A fill that ignores parse is a stub.
   `cef_initialize` is not called — the thunk needs the rest of
   libcef. Leftover: `OnPaint` from executing Content.
4. **CEF stays out of `kernel.elf`.** The platform blob QEMU runs
   is `BROWSE.ELF`. Mac `oschrome.mm` / `browser0` are unchanged.
   No new syscall. No help line. `wmeventStore` stays last `.bss`.

## 3. What this is not

It is not executing Blink in the OS. It is not Mac CEF copied into
`kernel.elf`. It is not host `browser0`. It is not a FRAME ELF that
contains all of libcef. It is not Flutter.

## 4. Verification

`core/tests/conformance/de-browse/run.sh` — `nm` of `BROWSE.ELF`
names `T cef_initialize`; browse+guest without the extract has no
`cef_`; sit-in-class QEMU + hidden `go browse.elf` paints PAGE
`0xC03890` at the derived body pixel; `go ninit.elf` is not PAGE.
