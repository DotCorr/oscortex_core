# DCDart — language readiness (as proven by this OS)

**Date:** 2026-09-02  
**Verdict:** **not ready** for public package release (Homebrew / winget / `.deb` / `.rpm`).  
**Language home:** [github.com/DotCorr/DCDart](https://github.com/DotCorr/DCDart) (`dcc`).  
**This repo’s identity line:** `core/docs/design/dcdart.md`.

This file rates the **programming language**, not the desktop demo. oscortex may show Skia chrome
and a glass dock; that does not make `dcc` installable or the language surface finished.

---

## Identity

| | |
|---|---|
| **Name** | **DCDart** |
| **Public line** | Its own language that uses Dart’s *spelling*. It is **not** Dart. A Dart / Flutter app will not run on it. |
| **Compiler** | `dcc` — Dart-hosted pipeline (vendored CFE → Kernel IR → DC-IR → LLVM IR → `clang -c`) |
| **Modes** | `--mode bare` works (freestanding / `@bare`). `--mode hosted` still throws (no hosted backend). |
| **Memory** | ARC with compile-time elision; no VM, no tracing GC. |
| **ABI** | C ABI at every boundary (`--emit-header`, `@extern`). |
| **What it compiles to** | Native object files (ELF / Mach-O / COFF), linked with ordinary `clang`. |
| **OS cut** | Kernel, WM policy, and shell are **`@bare` DCDart**. Freestanding apps may be DCDart *or* C against `osframe`. UI paint is **`osgfx.h` (C)**; C++ stays behind that fence (Skia / CEF). |

`DCDART_HOME` (defaults to a sibling `../DCDart`) selects the pin this tree builds against. There is
no git submodule: the language still moves daily.

---

## What works today

- End-to-end `@bare` compile → freestanding object → zero undeclared undefined symbols
  (`verify-freestanding.sh`).
- Sized integers, `@packed` structs, `Pointer<T>`, `Result` / `.propagate()`, generics
  (functions + classes), non-capturing closures, function pointers / indirect calls, `@rodata`,
  `@extern` to C, port I/O, weak refs, loops, `-O2`, multi-`--target` (incl. `host`,
  `bare-x86_64`, `aarch64`, Windows COFF objects).
- Conformance: on the order of **36** harnesses PASS on Darwin/arm64 (see DCDart `core/README.md`).
- Fresh clone *can* build after `bash core/scripts/vendor-frontend.sh` + Dart **3.12.2** + clang/LLVM
  (documented in DCDart `core/docs/testing-setup.md`).
- **This OS:** Multiboot kernel, IDT/PIC/PIT, VGA/console, PS/2, PCI, PMM, paging, ELF loader,
  cooperative processes, FAT/NVMe paths, compositor / Surface protocol, sit-in DE chrome policy —
  largely authored in `@bare` DCDart and proved by QEMU harnesses.

## What does not work (blunt)

- **M3 THE GATE fails.** Geometric mean ARC overhead vs trap-matched C is **~1.31×** (nonatomic)
  against a **≤1.10×** bar (DCDart GAP-0051b / `core/bench/`). Linked-structure elision (GAP-0062)
  dominates. `ROADMAP.md`: nothing downstream is supposed to depend on a green gate — this OS
  already does, deliberately, as a proving ground.
- **No installable SDK.** No Homebrew formula, no winget, no `.deb`/`.rpm`, no single tarball that
  drops `dcc` + prelude + docs on `PATH` without a git clone and a ~245 MB vendored frontend.
- **No package manager, no REPL, no DCDart LSP.** Hello-world still needs a C `main`, an absolute
  (or in-tree relative) prelude import (no `--prelude` / `dc:` URI — GAP-0003 / GAP-0049), and a
  pinned Dart SDK that runs the compiler.
- **`@bare` is a small language.** No `&&` / `||` / general `!`, historically no growable collections
  for damage regions, no capturing closures, `Pointer<T>` banned in signatures (GAP-0025), one
  return value, analyzer (stock Dart) fights every `@bare` file.
- **ABI / memory model not frozen.** Memory model freezes *after* M3. Elision, heap policy, and
  codegen still move. Generated headers leak `$`-bearing synthesized symbols.
- **Windows as a *host* for outsiders is unfinished.** Object emission for Windows targets is
  exercised; a supported “install DCDart on Windows and ship apps” story is not.
- **This OS is not a language showcase for apps.** Many FRAME apps are freestanding C; paint and
  web/media sit in C modules. The DE is still incomplete (e.g. 800×600 cocoa door, partial chrome).

---

## Rating (1–10) with OS-tied evidence

| Dimension | Score | Evidence |
|---|---:|---|
| **Expressiveness** (systems / UI / concurrency) | **5** | **Systems:** kernel + WM policy in `@bare` is real proof. **UI:** not a UI language — surfaces via `osframe` / `osgfx.h`; `@bare` text/collections remain painful. **Concurrency:** atomics/fences exist in DCDart; no first-class threading story for apps; capturing closures still rejected. |
| **Tooling** | **3** | `dcc`, conformance, `dc-objdump --arc`, bench harness — strong *for a lab*. Missing: package manager, REPL, installable binary, prelude resolution, hosted mode, IDE that understands DCDart. |
| **Stability / ABI / break risk** | **3** | Pre-M3; gate failing; pin trees dirty in day-to-day work; volatile/`Volatile<T>` migration still bites rebuilds (GAP-0069); signature/`@extern` limits remain load-bearing for the kernel. |
| **Portability** (macOS / Windows / Linux *hosts*) | **5** | Freestanding objects across ELF/Mach-O/COFF; Darwin conformance green; Linux verified for earlier suite slices; Windows host path documented with caveats — not a redistributable toolchain. |
| **Ecosystem readiness** | **2** | Outsider path is clone → vendor frontend → pin Dart 3.12.2 → source `dcdart-env.sh` → write `.dart` + `.c`. No `brew install dcdart`. |
| **Proven by the OS** | **8** | Strongest score: a reflective OS kernel and compositor policy compiled by `dcc` and run under QEMU is rare proof for a language this young. Do **not** confuse that with package readiness. |

### Overall

**not ready** for public multi-platform package release.

Closest soft label for *source* enthusiasts only: early **preview** of a git-clone compiler — and even
that should wait on an install script that does not require knowing `DCDART_HOME`, plus a tagged
commit that builds clean with a green “vendor + one hello” check. **Not** beta. **Not** ready.

---

## Binary gates before Homebrew / winget / `.deb` / `.rpm`

Do **not** publish installers until all of the following are true:

1. **M3 gate ≤ 1.10×** (or owner-ratified higher bar written into `ROADMAP.md` / a release ADR) on a
   clean machine, recorded in DCDart docs.
2. **Versioned SDK artifact:** `dcc` + `dc-objdump` + `dc:core.bare` prelude + manpage/README, built
   for macOS (arm64 ± x86_64), Linux (x86_64), Windows (x86_64), *without* requiring consumers to
   vendor a Dart frontend tree by hand.
3. **`dcc --prelude` or a real `dc:` package URI** so hello-world does not hardcode absolute paths
   (closes GAP-0003 / GAP-0049 for outsiders).
4. **One-command hello:** documented `dcc` + link recipe; optional `dcdart new` / template; no C
   *required* for the tutorial path (C interop remains a feature, not the only entry).
5. **Pinned, reproducible release tag** on `DotCorr/DCDart` with CI green on at least macOS + Linux;
   Windows CI or an explicit “experimental” badge.
6. **SemVer + compatibility promise** for `@bare` + generated C headers (even if narrow).
7. **License + security surface** reviewed for redistributing the vendored frontend / LLVM IR path.
8. **This OS pin:** `DCDART_PIN` / documented hash builds `kernel.elf` without DIRTY warnings for the
   release tag (packaging the language ≠ shipping the OS disk image).

Suggested package shape *when* gates pass (do not invent taps early):

| Platform | Fit |
|---|---|
| macOS | Homebrew formula or small tap installing the SDK tarball |
| Linux | `.deb` (Debian/Ubuntu) first; optional Arch `PKGBUILD`; avoid AppImage unless the SDK is a single relocatable tree |
| Windows | zip SDK + winget manifest; document MSVC vs MinGW link of the user’s C `main` |

---

## Codebase map (short)

| Tree | Role |
|---|---|
| `DotCorr/DCDart` `core/dcc` | CLI driver |
| `…/dcc-lower`, `dc-ir`, `dc-elide`, `backend` | Compiler pipeline |
| `…/runtime/dc-core-bare` | Freestanding prelude (`@bare`) |
| `…/tests/conformance` | Language truth |
| `…/bench` | M3 gate |
| This repo `core/kernel/*.dart` | OS written in `@bare` |
| `core/user/frame/osframe.{h,dart}` | App ABI (C ↔ DCDart siblings, no `#include` in `dcc`) |
| `core/plat/` | C modules (`osgfx`, …) called from the running image |

Identity cuts and Flutter refusal: `core/docs/design/dcdart.md`.  
FFI shape: `core/docs/design/dcdart-c-ffi.md`.  
Draft release notes (unpublished): `docs/release-draft-language.md`.

---

## Interaction with live OS doors

Language packaging work must **not** kill `oscortex-abs-pointer`, SSH, or OTA QEMU doors used by
siblings. This assessment left those processes alone.
