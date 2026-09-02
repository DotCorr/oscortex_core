# DRAFT — GitHub Release notes for DCDart (DO NOT PUBLISH YET)

**Status:** outline only. **No** `gh release create`, **no** Homebrew/winget/`.deb` artifacts.  
**Reason:** language readiness is **not ready** — see `/LANGUAGE.md` in this repo.  
**Intended remote when gates pass:** https://github.com/DotCorr/DCDart  
**Suggested first public tag:** `v0.1.0-preview` with `--prerelease` (only after gates in `LANGUAGE.md`).

---

## Title (draft)

`DCDart v0.1.0-preview — native AOT systems language (Dart spelling, ARC, no VM)`

## Highlights (capabilities proven by oscortex)

- Compiles `@bare` programs to freestanding native objects with a C ABI (`dcc build --mode bare`).
- Powers a from-scratch OS kernel and compositor policy (interrupts, memory, ELF, processes, Surface
  protocol) under QEMU — see DotCorr oscortex / this tree’s conformance harnesses.
- ARC with mechanical freestanding checks (`verify-freestanding.sh`) and ARC accounting
  (`dc-objdump --arc`).
- Multi-target object emission (ELF / Mach-O / COFF); `--emit-header` for C FFI.

## Honest limitations (must stay in the notes)

- **Not Dart / not Flutter.** Stock Dart apps do not run.
- **M3 ARC gate not passed** (~1.31× vs ≤1.10× vs trap-matched C at last recorded full suite).
- **`@bare` subset:** many everyday constructs missing or rejected (capturing closures, growable
  collections for some OS shapes, `&&`/`||`, etc.).
- **Hosted mode unfinished.** Hello-world today is `.dart` + `.c` + clang.
- **SDK install** still clone + vendor frontend + Dart 3.12.2 until packaging gates close.

## Codebase map (for the Release body)

```
DCDart/
  core/dcc/           CLI
  core/dcc-lower/     Kernel IR → DC-IR
  core/dc-ir/         typed SSA + retain/release
  core/dc-elide/      elision passes
  core/backend/       DC-IR → LLVM → .o
  core/runtime/       dc-core-bare prelude
  core/tests/         conformance (truth)
  core/bench/         M3 gate
  docs/               ADRs, known-gaps, escalations
```

Downstream OS (separate repo): kernel in `@bare`, apps via `osframe` / plat C modules.

## Assets checklist (when publishing for real)

- [ ] `dcdart-<ver>-macos-arm64.tar.gz` (+ optional x86_64)
- [ ] `dcdart-<ver>-linux-x86_64.tar.gz` (and `.deb` built from it)
- [ ] `dcdart-<ver>-windows-x86_64.zip` + winget manifests under `packaging/winget/`
- [ ] SHA256SUMS
- [ ] `LANGUAGE.md` / changelog excerpt
- [ ] Link to M3 bench report (pass or explicit accepted bar)

## Exact owner command (placeholder)

```bash
# ONLY after LANGUAGE.md gates and clean artifacts:
gh release create v0.1.0-preview \
  --repo DotCorr/DCDart \
  --prerelease \
  --title "DCDart v0.1.0-preview" \
  --notes-file docs/release-notes-v0.1.0-preview.md \
  dist/*.tar.gz dist/*.zip dist/*.deb dist/SHA256SUMS
```

## What this draft deliberately omits

- Shipping the oscortex disk image as “the language”
- Claiming Homebrew / apt / winget availability before formulas exist and install a working `dcc`
