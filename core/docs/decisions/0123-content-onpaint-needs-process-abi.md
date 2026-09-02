# ADR-0123 — Content OnPaint is blocked on the process ABI

**Status:** accepted, leftover recorded (`tests/conformance/de-browse/prove-onpaint-block.py`)
**Date:** 2026-08-30
**Milestone:** DE-browse leftover after ADR-0122
**Files:** `core/tests/conformance/de-browse/prove-onpaint-block.py`,
`oschrome_guest.c`, `oschrome_cef.c`, GAP-0322
**Depends on** ADR-0122 (official linux64 extract), ADR-0115 (BROWSE.ELF),
ADR-0014 (ELF loader), ADR-0029 (no Linux personality).
**Does not close** Content `OnPaint`. Does not raise the `de-browse/`
floor. A call of the 558-byte extract is not this.
**Number:** 0123 — 0122 is the official extract. Do not reuse 0122.

---

## 1. The question

ADR-0122 linked official linux64 `cef_initialize` (558 bytes from
`libcef.so`) into `BROWSE.ELF`. Paint is still `oschrome_guest.c`
`parse_rgb` of the `data:` HTML. That is not Chromium. The assigned
exit was a QEMU path that **calls** `cef_initialize` (or Content)
and a frame that comes from that stack. `nm` alone is not that.

A 64 KiB FRAME ELF cannot hold Blink. The next try is a larger
platform process on the FAT image (not `kernel.elf`) that CEF can
start, with `BROWSE.ELF` talking to it.

## 2. The decision

1. **Do not call the 558-byte extract.** Official `cef_initialize`
   at `libcef.so` vaddr `0x2ce7700` is 558 bytes of a larger
   function. Null `args` returns 0 without leaving the extract
   (`xor %eax,%eax; test %rdi,%rdi; je` to the epilogue). A
   non-null call reaches `memset@plt` then
   `cef_string_utf16_clear@plt` then `CefInitialize`. Those PLT
   slots are not in the extract. Calling it in QEMU is either the
   null-args thunk or a `#PF`. Neither is `OnPaint`.
2. **Do not ship a larger FAT `CEFHOST.ELF` that still paints
   `rgb()`.** Android `webview_zygote` is the right *shape*. This
   process ABI cannot start CEF. A second rgb painter on the volume
   is another thunk. `kernel.elf` still does not link CEF.
3. **The blocker is measured, not guessed.** Official Spotify
   linux64 minimal `libcef.so` (stamp
   `144.0.34+g8fc21c8+chromium-144.0.7559.261`):

   | fact | value |
   |---|---|
   | file | 1.5 GiB, `ET_DYN`, `PT_DYNAMIC`, `PT_TLS` |
   | `.text` | 189,095,087 bytes (size(1) text 231,709,928) |
   | undefined dynsym | 1,336 (`clone`, `dlopen`, `mmap64`, `pthread_*` @ `GLIBC_*`) |
   | `elfImageMax` | 65,536 (`elf.dart`) |
   | process window | 2 MiB `[0x10000000, 0x10200000)` |
   | `.text` / window | 90× |

   `DT_NEEDED` (32), in order:

   `libdl.so.2` `libpthread.so.0` `libglib-2.0.so.0`
   `libgobject-2.0.so.0` `libnspr4.so` `libnss3.so`
   `libnssutil3.so` `libsmime3.so` `libdbus-1.so.3`
   `libgio-2.0.so.0` `libatk-1.0.so.0` `libatk-bridge-2.0.so.0`
   `libcups.so.2` `libX11.so.6` `libXcomposite.so.1`
   `libXdamage.so.1` `libXext.so.6` `libXfixes.so.3`
   `libXrandr.so.2` `libgbm.so.1` `libexpat.so.1`
   `libxcb.so.1` `libxkbcommon.so.0` `libcairo.so.2`
   `libpango-1.0.so.0` `libudev.so.1` `libasound.so.2`
   `libm.so.6` `libatspi.so.0` `libgcc_s.so.1`
   `libc.so.6` `ld-linux-x86-64.so.2`

   The loader refuses `PT_INTERP` / `PT_DYNAMIC` by name
   (`ELF REFUSED 11`). There is no POSIX, no glibc, no TLS, no
   `mmap`/`clone`/`futex`, two processes, a 4 KiB stack. The CEF
   archive also has `*.pak` / ICU blobs; `fetch-cef-linux64.sh`
   extracts only `libcef.so`. ADR-0029 already rejected a Linux
   personality for prebuilt `.so` files. `oslibc.h` is 41 symbols.
4. **`de-browse/` stays at floor 87.** PAGE is still derived
   `rgb()`. `--no-init` is still not PAGE. `nm` still names
   `T cef_initialize`. That is ADR-0122. It is not `OnPaint`.
   `prove-onpaint-block.py` re-measures this leftover. Raising
   the floor because the extract exists, or because a null-args
   call returned 0, is refused.
5. **No new syscall. No help line. `wmeventStore` stays last
   `.bss`.** Host `browser0` / `oschrome.mm` `OnPaint` is
   unchanged and is not this QEMU.

## 3. What this is not

It is not Content painting in QEMU. It is not a handwritten
`OnPaint`. It is not Mac CEF copied into `kernel.elf`. It is not
a Linux personality in the image. It is not Flutter.

## 4. What would unblock (the next binary)

A **ring-3 libc / process ABI** that can load a platform
Content process:

1. `PT_INTERP` + `PT_DYNAMIC` (or a static rebuild of Content
   for the kernel triple, FFmpeg-shaped — not a 558-byte slice).
2. A process window that can map `libcef.so` `.text` (hundreds
   of MiB), not 2 MiB.
3. POSIX the 1,336 UND symbols need: `mmap`, `clone` / pthread,
   `futex`, TLS, `dlopen`.
4. The 32 `DT_NEEDED` libraries (or their static rebuild).
   picolibc / newlib is not `libc.so.6` `GLIBC_2.2.5`…`GLIBC_2.17`.
5. CEF resource blobs (`*.pak`, ICU). Multi-process Blink needs
   more than two slots.

Then `BROWSE.ELF` stays the thin FRAME client and talks to that
platform process. Do not raise `de-browse` on another extract.

## 5. Verification

`core/tests/conformance/de-browse/prove-onpaint-block.py` — official
`libcef.so` still has those 32 `NEEDED`; `cef_initialize` still
calls `memset@plt`; `oschrome_guest.c` still has `parse_rgb` and
does not call `cef_initialize`; `elf.dart` still refuses
`PT_INTERP`. `de-browse/run.sh` still PASSes at floor 87 with
the rgb() pixel. `OnPaint` did not run.
