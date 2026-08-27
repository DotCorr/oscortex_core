#!/usr/bin/env bash
# core/scripts/build-kernel.sh
#
# dcc build (kmain.dart + its part files) + assemble (boot.S, isr.S, kdata.S) +
# link (kernel.ld) -> build/kernel.elf. Mirrors DCDart's own conformance harnesses' PATH-
# then-fallback pattern for finding dcc.
#
# Usage:
#   DCDART_HOME=/path/to/DCDart core/scripts/build-kernel.sh   # explicit
#   core/scripts/build-kernel.sh                                # default: ../DCDart sibling checkout
#
# Exit status: 0 on success, 1 on a build/assemble/link failure, 2 on
# harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

fail() {
  echo "build-kernel: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "build-kernel: FAIL — $1" >&2
  exit 2
}

DCDART_HOME="${DCDART_HOME:-$REPO_DIR/../DCDart}"
[[ -d "$DCDART_HOME" ]] || setup_error "DCDART_HOME not found at $DCDART_HOME (set DCDART_HOME explicitly, or checkout DCDart as a sibling of $REPO_DIR — see core/README.md)"
[[ -f "$DCDART_HOME/core/dcc/bin/dcc.dart" ]] || setup_error "$DCDART_HOME does not look like a DCDart checkout (missing core/dcc/bin/dcc.dart)"

# ---------------------------------------------------------------------------
# SAY WHICH COMPILER THIS IS. (M21, GAP-0242.)
#
# `DCDART_PIN.txt` exists to record the DCDart commit this kernel is verified
# against. Until now the ONLY thing that checked it was `m7-frames`, which
# compares the FILE against a LITERAL IN A SHELL SCRIPT -- so the pin could
# only ever catch somebody editing one of two files, and never noticed what the
# build actually used. M21 was built and verified end-to-end against a commit
# two past the pin, in a working tree another agent was editing at the time,
# and nothing anywhere said so.
#
# So the identity of the compiler is now PRINTED ON EVERY BUILD and lands in
# every harness log. Three facts, because all three can differ independently:
# where the toolchain is, what commit it is on, and whether that commit is what
# is actually on disk (a dirty tree is NOT the commit it claims to be, which is
# the case a hash alone cannot catch).
#
# A MISMATCH IS A WARNING, NOT A FAILURE, AND THAT IS DELIBERATE FOR NOW: the
# pin is currently behind the only toolchain on this machine that can build the
# kernel at all, so failing here would take all 24 harnesses red for a reason
# that is not theirs. Set OSCORTEX_REQUIRE_PIN=1 to make it fatal -- and that
# should become the default the moment the pin and the toolchain agree.
DCDART_DESC="(not a git checkout)"
DCDART_DIRTY=""
if command -v git >/dev/null 2>&1 && git -C "$DCDART_HOME" rev-parse --git-dir >/dev/null 2>&1; then
  DCDART_DESC="$(git -C "$DCDART_HOME" rev-parse --short HEAD 2>/dev/null)"
  if [[ -n "$(git -C "$DCDART_HOME" status --porcelain 2>/dev/null)" ]]; then
    DCDART_DIRTY=" +DIRTY"
  fi
fi
PIN_FILE="$REPO_DIR/DCDART_PIN.txt"
PIN_WANT="(no DCDART_PIN.txt)"
[[ -f "$PIN_FILE" ]] && PIN_WANT="$(awk '{print $1; exit}' "$PIN_FILE")"
echo "build-kernel: toolchain $DCDART_HOME @ ${DCDART_DESC}${DCDART_DIRTY}; DCDART_PIN.txt says $PIN_WANT"
if [[ "$DCDART_DESC" != "$PIN_WANT"* && "$PIN_WANT" != "(no DCDART_PIN.txt)" ]]; then
  echo "build-kernel: WARNING — the toolchain is NOT the pinned commit. This kernel is being built" >&2
  echo "              against $DCDART_DESC and DCDART_PIN.txt claims $PIN_WANT. Either bump the pin" >&2
  echo "              deliberately after a green sweep, or point DCDART_HOME at the pinned commit." >&2
  [[ "${OSCORTEX_REQUIRE_PIN:-0}" == "1" ]] && setup_error "toolchain $DCDART_DESC != pinned $PIN_WANT (OSCORTEX_REQUIRE_PIN=1)"
fi
if [[ -n "$DCDART_DIRTY" ]]; then
  echo "build-kernel: WARNING — the toolchain working tree is DIRTY, so '$DCDART_DESC' does not identify it." >&2
  echo "              A build that picks up somebody's in-flight compiler change can move every" >&2
  echo "              byte-exact golden in this suite for a reason no commit in THIS repo explains." >&2
  [[ "${OSCORTEX_REQUIRE_PIN:-0}" == "1" ]] && setup_error "toolchain working tree is dirty (OSCORTEX_REQUIRE_PIN=1)"
fi

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$DCDART_HOME/core/dcc/bin/dcc.dart")
else
  setup_error "neither dcc nor dart found on PATH"
fi

if ! command -v clang >/dev/null 2>&1; then
  setup_error "clang not found on PATH"
fi
# Linker: needs to be an ELF linker that understands GNU linker scripts (-T).
# Apple's ld64 (the default `ld` on macOS) does NOT -- it rejects -T outright --
# so probe for a real ELF linker rather than assuming `ld` is one. Override with
# LD explicitly if neither is on PATH under the name we look for.
find_elf_linker() {
  if [[ -n "${LD:-}" ]]; then
    command -v "$LD" >/dev/null 2>&1 && { echo "$LD"; return 0; }
    return 1
  fi
  local candidate
  # GNU ld first, deliberately: core/link/kernel.ld sets OUTPUT_FORMAT(elf32-i386)
  # (QEMU's Multiboot loader rejects a 64-bit ELF container -- see the script's
  # own header comment), and GNU ld links x86-64 input objects into that output
  # while lld refuses it as "incompatible with elf32-i386". lld is kept as a
  # fallback only because it is the easier install; it will not work with the
  # current link script.
  for candidate in x86_64-elf-ld x86_64-linux-gnu-ld ld.lld; do
    command -v "$candidate" >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  # Homebrew installs lld keg-only on macOS -- not on PATH by default.
  local brewed
  for brewed in /opt/homebrew/opt/x86_64-elf-binutils/bin/x86_64-elf-ld \
                /opt/homebrew/opt/lld/bin/ld.lld; do
    [[ -x "$brewed" ]] && { echo "$brewed"; return 0; }
  done
  # Plain `ld` only if it is NOT Apple's ld64 (which cannot link ELF at all).
  if command -v ld >/dev/null 2>&1 && ! ld -v 2>&1 | grep -qi 'PROJECT:ld'; then
    echo ld
    return 0
  fi
  return 1
}

LD_CMD="$(find_elf_linker)" || setup_error "no ELF linker found (need x86_64-elf-ld or GNU ld; on macOS: brew install x86_64-elf-binutils). Set LD=<linker> to override."

BUILD_DIR="$CORE_DIR/build"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare kmain.dart -o build/kmain.o
# ---------------------------------------------------------------------------
( cd "$CORE_DIR/kernel" && "${DCC_CMD[@]}" build --mode bare kmain.dart -o "$BUILD_DIR/kmain.o" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare kmain.dart -o kmain.o' exited $DCC_STATUS"
fi
[[ -f "$BUILD_DIR/kmain.o" ]] || fail "dcc reported success but kmain.o was not produced"

# ---------------------------------------------------------------------------
# Step 2 — assemble boot.S, isr.S and kdata.S
#
# isr.S (M1: interrupt entry stubs, IDT/tick storage, the privileged-
# instruction helpers DCDart calls through @extern) is a separate object
# rather than more of boot.S: boot.S runs once, in 32-bit mode, before any
# DCDart code exists, while isr.S is entirely 64-bit and entirely driven from
# DCDart. Keeping them apart keeps CLAUDE.md rule 4's "boot-time assembly"
# boundary meaningful.
#
# portio.S (M5) is a FOURTH object, and it is there for the reason kdata.S is
# there taken one step further again: it is neither boot code, nor interrupt
# code, nor storage -- it is a MISSING LANGUAGE PRIMITIVE standing in for
# itself. DCDart's Port class is byte-wide only (its ADR-0029), and PCI
# configuration mechanism #1 is defined in terms of 32-bit accesses to
# 0xCF8/0xCFC, so `outl`/`inl` had to come from somewhere. Naming the file
# after that keeps the workaround countable and makes its eventual deletion
# mechanical -- docs/known-gaps.md GAP-0066.
#
# kdata.S (M2) is a third object for the same reason taken one step further:
# it is not boot code and it is not interrupt code, it is DONATED MUTABLE
# STORAGE, and it exists only because DCDart has no mutable static data of any
# kind. Folding it into isr.S would have quietly turned "the interrupt file"
# into "the file where we keep globals"; a separate file keeps the workaround
# legible and its size countable (docs/known-gaps.md GAP-0053).
# ---------------------------------------------------------------------------
for asm in boot isr kdata portio; do
  clang -c -target x86_64-unknown-none-elf "$CORE_DIR/boot/$asm.S" -o "$BUILD_DIR/$asm.o"
  ASM_STATUS=$?
  if [[ $ASM_STATUS -ne 0 ]]; then
    fail "assembling $asm.S exited $ASM_STATUS"
  fi
done

# ---------------------------------------------------------------------------
# Step 3 — link via kernel.ld
# ---------------------------------------------------------------------------
# -Map is M17 (ADR-0021) and it is not a convenience. The kernel's mutable
# storage is now DCDart `@bss`, and a `@bss` symbol is LOCAL to kmain.o; the
# link script's OUTPUT_FORMAT(elf32-i386) container discards every local symbol,
# so `pmmStore` and `procStore` have no entry in kernel.elf's symbol table at
# all. The link map is where the linker states, in its own words, the address it
# placed kmain.o's `.bss` at -- which is what m7-frames needs to prove the frame
# bitmap is inside the kernel image, and what m11-proc needs to prove every
# FXSAVE area is 16-byte aligned in the LINKED image rather than only in the
# declaration.
"$LD_CMD" -T "$CORE_DIR/link/kernel.ld" -Map "$BUILD_DIR/kernel.map" -o "$BUILD_DIR/kernel.elf" "$BUILD_DIR/boot.o" "$BUILD_DIR/isr.o" "$BUILD_DIR/kdata.o" "$BUILD_DIR/portio.o" "$BUILD_DIR/kmain.o"
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  fail "linking kernel.elf with $LD_CMD exited $LINK_STATUS"
fi
[[ -f "$BUILD_DIR/kernel.elf" ]] || fail "ld reported success but kernel.elf was not produced"

echo "build-kernel: PASS — $BUILD_DIR/kernel.elf"
exit 0
