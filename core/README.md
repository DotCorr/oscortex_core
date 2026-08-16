# core/ — the project

Everything buildable lives here. See the repo root `README.md` for the project overview.

| Path | Contains | Status |
|---|---|---|
| `boot/` | `boot.S` — Multiboot1 header, 32-bit entry, GDT + PAE page tables, long-mode transition | **done, verified** |
| `kernel/` | `kmain.dart` — `@bare` DCDart kernel entry point (COM1 init + proof-of-life message) | **done, verified** |
| `link/` | `kernel.ld` — link script, `elf32-i386` output (QEMU's Multiboot loader rejects a 64-bit container), `ENTRY(_start)`, load base `0x100000` | **done, verified** |
| `tests/conformance/m0-boot/` | `run.sh` — real build, real QEMU boot, exact captured-serial-byte assertion | **`M0-boot: PASS`** |
| `scripts/` | `build-kernel.sh` (dcc build + assemble + link), `verify-freestanding.sh` (copied from the DCDart repo, adapted) | **done** |
| `tools/bare-symbol-allowlist.txt` | consumed by `verify-freestanding.sh` | starts empty |
| `docs/` | `decisions/` (ADRs), `known-gaps.md`, `escalations/` | 1 ADR, 3 gaps |

## Dependency on DCDart

Builds via a `DCDART_HOME` environment variable (defaults to a sibling `../DCDart` checkout), invoking
`dcc` directly from there — mirrors DCDart's own conformance harnesses' PATH-then-fallback pattern. No
git submodule: DCDart is still pre-M3 and changes daily, so `DCDART_PIN.txt` (one line: the commit hash
and date this was last verified against) is the entire dependency story for now.

## Current milestone: M0 — done

`core/tests/conformance/m0-boot/run.sh` reports an unqualified PASS: `dcc build --mode bare
kernel/kmain.dart` → assemble `boot/boot.S` → link via `link/kernel.ld` → `verify-freestanding.sh`
clean → a real `qemu-system-x86_64 -kernel` boot → captured COM1 serial output matches
`"OSCORTEX M0 OK\n"` byte-for-byte (`cmp`, not eyeballed). See `docs/decisions/0001-m0-boot-architecture.md`
for the full design and two real bugs found and fixed along the way (QEMU rejecting a 64-bit ELF
container; a missing `SHF_ALLOC` flag silently dropping the Multiboot header from the linked image).

See `ROADMAP.md` (local only, not published — see `.gitignore`) for what comes after M0, and
`OSCORTEX_SPEC.md` for the concrete boot architecture this milestone implements.
