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

# NOTE (ADR-0043): a `dcc` on PATH is deliberately NOT used any more, even when
# one exists. `dcc` derives the prelude it type-checks annotations against from
# its OWN script location, so a PATH `dcc` is a second, invisible answer to
# "which DCDart is this build using" that $DCDART_HOME does not control. That
# divergence is exactly the defect this ADR closes; a wrapper on PATH would
# re-open it. dcc is always run out of $DCDART_HOME, through the symlink built
# below.
command -v dart >/dev/null 2>&1 || setup_error "dart not found on PATH (source env.sh)"

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
# Step 0 — ONE ROOT FOR THE TOOLCHAIN. (ADR-0043, GAP-0003.)
#
# `dcc` has no library resolution: it computes the prelude whose annotation
# classes define `@bare`/`@extern`/`@rodata` as
# `Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart')`, and then
# accepts an annotation only if the class's enclosing-library URI is EQUAL to
# that (DCDart core/dcc-lower/lib/lower.dart:622). Equality is exact, on a
# lexically normalised absolute path: `..` is folded, symlinks are resolved on
# NEITHER side. Measured, not assumed -- see the ADR for the six experiments.
#
# The consequence is unforgiving. If kmain.dart's import and dcc's own script
# location name the same prelude by two different strings -- a symlink on one
# side, a different checkout three directories up, /tmp vs /private/tmp -- then
# NOTHING in kmain.dart is annotated as far as dcc is concerned, and the build
# dies with `no @bare top-level function found in kmain.dart`. That message
# describes a broken compiler. It has already been read as one, for four
# consecutive clean DCDart checkouts, none of which was the problem.
#
# So this build gives both sides ONE path prefix and derives everything from it:
# `$BUILD_DIR/dcdart` is a symlink to $DCDART_HOME, dcc is invoked THROUGH it,
# and kmain.dart imports THROUGH it. They cannot disagree, because they are the
# same characters. This works for any $DCDART_HOME at any real path -- which the
# old hard-coded `../../../DCDart` import did not, and could not.
# Both sides must be built from the PHYSICAL path of the directory dcc will be
# run in, because that is the one Dart uses. `dart compile kernel` takes the
# importing library's URI from `File('kmain.dart').absolute.uri`, i.e. from
# getcwd(), which the kernel returns symlink-free; `pwd` in a shell does not.
# Reaching this checkout through a symlinked parent would otherwise hand dcc a
# logical prefix and the front end a physical one -- two spellings of one file,
# which is precisely the failure being closed here.
KERNEL_DIR="$(cd "$CORE_DIR/kernel" && pwd -P)"
LINK_DIR="$(dirname "$KERNEL_DIR")/build"   # what `../build` resolves to from KERNEL_DIR
mkdir -p "$LINK_DIR"

DCDART_LINK="$LINK_DIR/dcdart"
if [[ -L "$DCDART_LINK" ]]; then
  rm -f "$DCDART_LINK"
elif [[ -e "$DCDART_LINK" ]]; then
  setup_error "$DCDART_LINK exists and is not a symlink — remove it (build-kernel.sh owns that name)"
fi
ln -s "$DCDART_HOME" "$DCDART_LINK" || setup_error "could not create toolchain symlink $DCDART_LINK -> $DCDART_HOME"

DCC_CMD=(dart "$DCDART_LINK/core/dcc/bin/dcc.dart")
PRELUDE_PATH="$DCDART_LINK/core/runtime/dc-core-bare/prelude.dart"
[[ -f "$PRELUDE_PATH" ]] || setup_error "no prelude at $PRELUDE_PATH (DCDART_HOME=$DCDART_HOME does not look like a DCDart checkout)"

# The import line is asserted LITERALLY, not parsed. `dcc`'s comparison is a
# string comparison, so the check that protects it should be one too: any edit
# that points kmain.dart at DCDart by some other spelling gets named here, in
# one line, instead of surfacing later as a missing `@bare`.
EXPECTED_IMPORT="import '../build/dcdart/core/runtime/dc-core-bare/prelude.dart';"
if ! grep -qxF -- "$EXPECTED_IMPORT" "$CORE_DIR/kernel/kmain.dart"; then
  setup_error "core/kernel/kmain.dart does not import the prelude through core/build/dcdart.
              expected exactly: $EXPECTED_IMPORT
              found:            $(grep -n "dc-core-bare/prelude.dart'" "$CORE_DIR/kernel/kmain.dart" | head -1)
              dcc matches annotation libraries by exact URI; any other spelling of this path
              makes every @bare/@extern/@rodata in kmain.dart invisible to it (ADR-0043, GAP-0003)."
fi

# PRINT THE FACT THAT DECIDES THE BUILD. The toolchain banner already says which
# tree and which commit; this says which prelude, which is the thing `@bare`
# resolution actually turns on. Both the path dcc computes and the tree it lands
# in, because the first is what must match and the second is what a human needs.
echo "build-kernel: prelude  $PRELUDE_PATH"
echo "build-kernel:          -> $(cd "$DCDART_HOME" && pwd -P)/core/runtime/dc-core-bare/prelude.dart"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare kmain.dart -o build/kmain.o
# ---------------------------------------------------------------------------
( cd "$KERNEL_DIR" && "${DCC_CMD[@]}" build --mode bare kmain.dart -o "$BUILD_DIR/kmain.o" )
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
