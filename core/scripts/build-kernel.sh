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
COMPAT_PROBE="$SCRIPT_DIR/verify-dcdart-compat.sh"
[[ -f "$COMPAT_PROBE" ]] || setup_error "missing DCDart compatibility probe: $COMPAT_PROBE"

# NOTE (ADR-0043): a `dcc` on PATH is deliberately NOT used any more, even when
# one exists. `dcc` derives the prelude it type-checks annotations against from
# its OWN script location, so a PATH `dcc` is a second, invisible answer to
# "which DCDart is this build using" that $DCDART_HOME does not control. That
# divergence is exactly the defect this ADR closes; a wrapper on PATH would
# re-open it. dcc is always run out of $DCDART_HOME, through the symlink built
# below.
command -v dart >/dev/null 2>&1 || setup_error "dart not found on PATH (source env.sh)"

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
# A mismatch is a warning by default.  With OSCORTEX_REQUIRE_PIN=1, every
# checkout must pass verify-dcdart-compat.sh, which compiles and inspects the
# load-bearing Volatile, @rodata/GlobalDCE and no-FP semantics.
#
# DCDART_PIN.txt is a base+patch identity (see DCDART_MANIFEST.json).
# The public DCDart tip is df3d053 (origin/main). 02631a77 was rewritten
# out of GitHub and is not a valid object. 8d53e38 / b07cec6 exist only
# as local tips and must not be claimed reachable. Bootstrap:
#   bash core/scripts/bootstrap-dcdart.sh
# writes a repo-owned .dcdart-bootstrap/src and never mutates a user
# DCDart checkout.
DCDART_DESC="(not a git checkout)"
DCDART_FULL=""
DCDART_DIRTY=""
if command -v git >/dev/null 2>&1 && git -C "$DCDART_HOME" rev-parse --git-dir >/dev/null 2>&1; then
  DCDART_DESC="$(git -C "$DCDART_HOME" rev-parse --short HEAD 2>/dev/null)"
  DCDART_FULL="$(git -C "$DCDART_HOME" rev-parse HEAD 2>/dev/null)"
  if [[ -n "$(git -C "$DCDART_HOME" status --porcelain 2>/dev/null)" ]]; then
    DCDART_DIRTY=" +DIRTY"
  fi
fi
PIN_FILE="$REPO_DIR/DCDART_PIN.txt"
MANIFEST="$REPO_DIR/DCDART_MANIFEST.json"
PIN_WANT="(no DCDART_PIN.txt)"
[[ -f "$PIN_FILE" ]] && PIN_WANT="$(awk '{print $1; exit}' "$PIN_FILE")"
BOOT_ID=""
[[ -f "$DCDART_HOME/.oscortex-dcdart-identity" ]] && \
  BOOT_ID="$(tr -d '[:space:]' <"$DCDART_HOME/.oscortex-dcdart-identity")"
echo "build-kernel: toolchain $DCDART_HOME @ ${DCDART_DESC}${DCDART_DIRTY}; DCDART_PIN.txt says $PIN_WANT${BOOT_ID:+; bootstrap $BOOT_ID}"
# Compare the FULL hash against the pin as a prefix, not the abbreviated one.
# `rev-parse --short` picks its own length, so a pin recorded at eight characters
# against a seven-character abbreviation compared unequal and warned on a
# correctly pinned tree -- a guard that cries wolf exactly when it is satisfied
# gets ignored, which is the failure mode this whole check exists to remove.
PIN_OK=0
if [[ -n "$BOOT_ID" && "$BOOT_ID" == "$PIN_WANT" ]]; then
  PIN_OK=1
fi
if [[ -n "$DCDART_FULL" && "$DCDART_FULL" == "$PIN_WANT"* ]]; then
  PIN_OK=1
fi
if [[ "$PIN_OK" -eq 0 && -n "$DCDART_FULL" && "$PIN_WANT" != "(no DCDART_PIN.txt)" ]]; then
  echo "build-kernel: WARNING — toolchain git $DCDART_DESC is not pin $PIN_WANT." >&2
  echo "              Use bash core/scripts/bootstrap-dcdart.sh for the reachable" >&2
  echo "              base+patch, or point DCDART_HOME at that tree." >&2
fi
if [[ -n "$DCDART_DIRTY" ]]; then
  echo "build-kernel: WARNING — the toolchain working tree is DIRTY, so '$DCDART_DESC' does not identify it." >&2
  echo "              A build that picks up somebody's in-flight compiler change can move every" >&2
  echo "              byte-exact golden in this suite for a reason no commit in THIS repo explains." >&2
fi
if [[ "${OSCORTEX_REQUIRE_PIN:-0}" == "1" ]]; then
  echo "build-kernel: strict mode; proving compiler compatibility" >&2
  bash "$COMPAT_PROBE" "$DCDART_HOME" \
    || setup_error "toolchain failed the required semantic compatibility probe"
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

# Isolated harnesses (files-fm OSGFX_SKIA=0) must not mv onto the live
# Skia kernel. Honour BUILD_DIR; the prelude symlink stays at
# core/build/dcdart because kmain.dart imports that spelling.
BUILD_DIR="${BUILD_DIR:-$CORE_DIR/build}"
mkdir -p "$BUILD_DIR"

# Byte-reproducible objects: remap every host-absolute prefix the compiler
# would otherwise bake into DWARF / __FILE__. Diagnostics stay.
CANON_CFLAGS="$(bash "$SCRIPT_DIR/oscortex-canon-cflags.sh" \
  "$CORE_DIR=/oscortex" \
  "$DCDART_HOME=/dcdart" \
  "$BUILD_DIR=/oscortex-build" \
  "$CORE_DIR/build/skia=/skia" \
  ${BUILD_DIR:+"$BUILD_DIR/skia=/skia"})"
export OSCORTEX_CANON_CFLAGS="$CANON_CFLAGS"
# shellcheck disable=SC2206
CANON_ARR=($CANON_CFLAGS)
# Stable, remapped compile manifest (not a host-absolute command log).
{
  echo "canon_cflags$CANON_CFLAGS"
  echo "core=/oscortex"
  echo "dcdart=/dcdart"
  echo "build=/oscortex-build"
  echo "skia=/skia"
  echo "prelude=../build/dcdart/core/runtime/dc-core-bare/prelude.dart"
} >"$BUILD_DIR/CANON_CFLAGS.txt"
printf '%s\n' "$CANON_CFLAGS" >"$BUILD_DIR/COMPILE.manifest"

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

# ADR-0043 made both sides spell the prelude the same way by running dcc THROUGH
# the symlink, so that `Platform.script.resolve(...)` landed on the same string
# kmain.dart imports. That worked, but it worked by coincidence of where dcc.dart
# happened to be reached from -- an invisible coupling that broke the moment
# anything invoked dcc by its real path (measured: a clean toolchain clone plus a
# symlinked spelling produced `no @bare top-level function found`, which reads as
# a broken compiler and is not one).
#
# DCDart b94666a added `dcc build --prelude <path>`. The agreement is now STATED
# rather than arranged: dcc is invoked at its real location and TOLD which file
# is the prelude, in exactly the spelling kmain.dart imports. dcc makes the value
# absolute and lexically normalises it, which is the same normalisation the front
# end applies to the import, so the two cannot drift apart.
DCC_CMD=(dart "$DCDART_HOME/core/dcc/bin/dcc.dart")
# Relative prelude spelling is identical across checkouts; dcc still
# resolves it for @bare URI equality (ADR-0043).
PRELUDE_PATH="$DCDART_LINK/core/runtime/dc-core-bare/prelude.dart"
PRELUDE_REL="../build/dcdart/core/runtime/dc-core-bare/prelude.dart"
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
( cd "$KERNEL_DIR" && "${DCC_CMD[@]}" build --mode bare --prelude "$PRELUDE_REL" \
    kmain.dart -o "$BUILD_DIR/kmain.o" )
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
  clang -c -target x86_64-unknown-none-elf \
    "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
    "$CORE_DIR/boot/$asm.S" -o "$BUILD_DIR/$asm.o"
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
# Mailbox + Skia CPU raster (same osgfx.h, x86_64-elf). Sit-in / wm gfx
# calls osgfx_fill_rrect -> SkCanvas::drawRRect. OSGFX_SKIA=0 is the
# anti-vacuity link (no Skia symbols). osgfx_sw.c stays in-tree; it is
# not the default backend.
clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall \
  "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
  -I "$CORE_DIR/plat/osgfx" \
  -o "$BUILD_DIR/osgfx_cmd.o" "$CORE_DIR/plat/osgfx/osgfx_cmd.c" \
  || fail "compiling osgfx_cmd.c failed"
clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall \
  "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
  -I "$CORE_DIR/plat/osgfx" \
  -o "$BUILD_DIR/osgfx_glyph.o" "$CORE_DIR/plat/osgfx/osgfx_glyph.c" \
  || fail "compiling osgfx_glyph.c failed"
GUEST_OBJS=("$BUILD_DIR/osgfx_cmd.o" "$BUILD_DIR/osgfx_glyph.o")
# OSGFX_SW=0 is the old anti-vacuity name (ADR-0104). Same omit.
if [[ "${OSGFX_SW:-1}" == 0 ]]; then
  OSGFX_SKIA=0
fi
if [[ "${OSGFX_SKIA:-1}" == 1 ]]; then
  bash "$CORE_DIR/scripts/build-skia-guest.sh" || fail "build-skia-guest.sh failed"
  bash "$CORE_DIR/scripts/build-skia-guest-graphite.sh" \
    || echo "build-kernel: Graphite guest lib not ready — CPU Skia stays linked"
  # Isolated BUILD_DIR still compiles into $BUILD_DIR, but the durable
  # Skia tree and skia-guest objects live under core/build. Reuse them
  # so a harness worktree does not rebuild Skia or miss osgfx_skia.o.
  if [[ "$BUILD_DIR" != "$CORE_DIR/build" ]]; then
    if [[ -d "$CORE_DIR/build/skia" && ! -e "$BUILD_DIR/skia" ]]; then
      ln -s "$CORE_DIR/build/skia" "$BUILD_DIR/skia"
    fi
    for obj in osgfx_skia.o osgfx_cxxrt.o osgfx_guest_crt.o; do
      if [[ -f "$CORE_DIR/build/$obj" ]]; then
        cp -f "$CORE_DIR/build/$obj" "$BUILD_DIR/$obj"
      fi
    done
  fi
  OSGFX_CFLAGS=(
    -c
    -target x86_64-unknown-none-elf
    -ffreestanding
    -nostdlib
    -fno-pic
    -fno-pie
    -mno-red-zone
    -fno-stack-protector
    -fno-asynchronous-unwind-tables
    -fno-builtin
    -O2
    -Wall
    "${CANON_ARR[@]+"${CANON_ARR[@]}"}"
    -I "$CORE_DIR/plat/osgfx"
  )
  clang "${OSGFX_CFLAGS[@]}" -o "$BUILD_DIR/osgfx_scene.o" \
    "$CORE_DIR/plat/osgfx/osgfx_scene.c" || fail "compiling osgfx_scene.c failed"
  clang "${OSGFX_CFLAGS[@]}" -o "$BUILD_DIR/osgfx_desk.o" \
    "$CORE_DIR/plat/osgfx/osgfx_desk.c" || fail "compiling osgfx_desk.c failed"
  clang "${OSGFX_CFLAGS[@]}" -o "$BUILD_DIR/osgfx_chrome.o" \
    "$CORE_DIR/plat/osgfx/osgfx_chrome.c" || fail "compiling osgfx_chrome.c failed"
  # Real TrueType outlines for chrome text. osgfx_font_data.c is generated
  # by core/scripts/gen-osgfx-font.py from a real .ttf `glyf` table; Skia
  # rasterises the outlines live via drawPath (ADR-0187). Regenerate only
  # when the .c is missing, so the build stays hermetic.
  if [[ ! -f "$CORE_DIR/plat/osgfx/osgfx_font_data.c" ]]; then
    bash "$CORE_DIR/scripts/gen-osgfx-font.sh" \
      || fail "gen-osgfx-font.sh failed (no outline table for chrome text)"
  fi
  clang "${OSGFX_CFLAGS[@]}" -o "$BUILD_DIR/osgfx_font.o" \
    "$CORE_DIR/plat/osgfx/osgfx_font.c" || fail "compiling osgfx_font.c failed"
  clang "${OSGFX_CFLAGS[@]}" -o "$BUILD_DIR/osgfx_font_data.o" \
    "$CORE_DIR/plat/osgfx/osgfx_font_data.c" \
    || fail "compiling osgfx_font_data.c failed"
  clang "${OSGFX_CFLAGS[@]}" -I "$CORE_DIR/plat/osxui" -o "$BUILD_DIR/osgfx_session.o" \
    "$CORE_DIR/plat/osgfx/osgfx_session.c" || fail "compiling osgfx_session.c failed"
  if [[ -f "$CORE_DIR/plat/osxui/osxui.c" ]]; then
    clang "${OSGFX_CFLAGS[@]}" -I "$CORE_DIR/plat/osxui" -o "$BUILD_DIR/osxui.o" \
      "$CORE_DIR/plat/osxui/osxui.c" || fail "compiling osxui.c failed"
    GUEST_OBJS+=("$BUILD_DIR/osxui.o")
    if [[ -f "$CORE_DIR/plat/osxui/osxui_fb.c" ]]; then
      clang "${OSGFX_CFLAGS[@]}" -I "$CORE_DIR/plat/osxui" \
        -o "$BUILD_DIR/osxui_fb.o" "$CORE_DIR/plat/osxui/osxui_fb.c" \
        || fail "compiling osxui_fb.c failed"
      GUEST_OBJS+=("$BUILD_DIR/osxui_fb.o")
    fi
  fi
  GUEST_OBJS+=("$BUILD_DIR/osgfx_skia.o" "$BUILD_DIR/osgfx_guest_crt.o" \
    "$BUILD_DIR/osgfx_cxxrt.o" "$BUILD_DIR/osgfx_scene.o" \
    "$BUILD_DIR/osgfx_desk.o" "$BUILD_DIR/osgfx_chrome.o" "$BUILD_DIR/osgfx_session.o" \
    "$BUILD_DIR/osgfx_font.o" "$BUILD_DIR/osgfx_font_data.o")
  SKIA_SRC="$CORE_DIR/build/skia/src"
  [[ -d "$SKIA_SRC" ]] || SKIA_SRC="$BUILD_DIR/skia/src"
  GRAPHITE_LIB="$BUILD_DIR/skia/out/guest-elf-graphite/libskia.a"
  if [[ -f "$GRAPHITE_LIB" ]]; then
    clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
      -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
      -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall \
      "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
      -I "$CORE_DIR/plat/osgfx" \
      -isystem "$CORE_DIR/plat/osgfx/guest_inc" \
      -I "$SKIA_SRC/include/third_party/vulkan" \
      -o "$BUILD_DIR/osgfx_vk.o" \
      "$CORE_DIR/plat/osgfx/osgfx_vk.c" \
      || fail "compiling osgfx_vk.c failed"
    bash "$CORE_DIR/scripts/skia-guest-cxx.sh" -c -O2 -Wall \
      -I "$CORE_DIR/plat/osgfx" -I "$SKIA_SRC" \
      -I "$SKIA_SRC/include/third_party/vulkan" \
      -DSK_VULKAN \
      -o "$BUILD_DIR/osgfx_graphite_guest.o" \
      "$CORE_DIR/plat/osgfx/osgfx_graphite_guest.cpp" \
      || fail "compiling osgfx_graphite_guest.cpp failed"
    GUEST_OBJS+=("$BUILD_DIR/osgfx_vk.o" "$BUILD_DIR/osgfx_graphite_guest.o" \
      "$GRAPHITE_LIB")
  elif [[ -f "$BUILD_DIR/skia/out/guest-elf/libskia.a" ]]; then
    GUEST_OBJS+=("$BUILD_DIR/skia/out/guest-elf/libskia.a")
  else
    fail "no guest-elf libskia.a"
  fi
else
  clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
    -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall \
    "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
    -I "$CORE_DIR/plat/osgfx" \
    -o "$BUILD_DIR/osgfx_desk.o" "$CORE_DIR/plat/osgfx/osgfx_desk.c" \
    || fail "compiling osgfx_desk.c (no-skia) failed"
  clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
    -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall \
    "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
    -I "$CORE_DIR/plat/osgfx" \
    -o "$BUILD_DIR/osgfx_client_stub.o" \
    "$CORE_DIR/plat/osgfx/osgfx_client_stub.c" \
    || fail "compiling osgfx_client_stub.c failed"
  GUEST_OBJS+=("$BUILD_DIR/osgfx_desk.o" "$BUILD_DIR/osgfx_client_stub.o")
fi

# FFmpeg / osmedia.h for kernel.elf's triple (ADR-0116). Not a Mac dylib.
# OSMEDIA_FFMPEG=0 is the anti-vacuity link (no avcodec_ symbols).
MEDIA_CFLAGS=(
  -c
  -target x86_64-unknown-none-elf
  -ffreestanding
  -nostdlib
  -fno-pic
  -fno-pie
  -mno-red-zone
  -fno-stack-protector
  -fno-asynchronous-unwind-tables
  -fno-builtin
  -O2
  -Wall
  "${CANON_ARR[@]+"${CANON_ARR[@]}"}"
  -I "$CORE_DIR/plat/media"
  -I "$CORE_DIR/plat/osgfx"
  -isystem "$CORE_DIR/plat/media/guest_inc"
  -isystem "$CORE_DIR/plat/osgfx/guest_inc"
)
HAVE_CRT=0
for obj in "${GUEST_OBJS[@]+"${GUEST_OBJS[@]}"}"; do
  if [[ "$(basename "$obj")" == "osgfx_guest_crt.o" ]]; then
    HAVE_CRT=1
  fi
done
# 48MiB CRT heap blows the 16MiB vmFineBytes window (m8 / proc spawn).
# OSGFX_CRT=0 omits it when this boot does not call Skia/FFmpeg.
if [[ "$HAVE_CRT" -eq 0 && "${OSGFX_CRT:-1}" != 0 ]]; then
  # Default 3MiB Skia CRT plus FFmpeg fits in the 16MiB window.
  clang "${MEDIA_CFLAGS[@]}" -I "$CORE_DIR/plat/osgfx" \
    -DCRT_HEAP=4194304 \
    -o "$BUILD_DIR/osgfx_guest_crt.o" "$CORE_DIR/plat/osgfx/osgfx_guest_crt.c" \
    || fail "compiling osgfx_guest_crt.c for media failed"
  GUEST_OBJS+=("$BUILD_DIR/osgfx_guest_crt.o")
fi
FF_SRC="$CORE_DIR/build/ffmpeg/src"
FF_LIB="$CORE_DIR/build/ffmpeg/out/guest-elf"
HAVE_FFMPEG=0
if [[ "${OSMEDIA_FFMPEG:-1}" == 1 ]]; then
  if bash "$CORE_DIR/scripts/build-ffmpeg-guest.sh" \
    && [[ -f "$FF_LIB/libavcodec.a" ]]; then
    HAVE_FFMPEG=1
  else
    echo "build-kernel: ffmpeg guest not ready; linking osmedia without libav*" >&2
  fi
fi
if [[ "$HAVE_FFMPEG" -eq 1 ]]; then
  clang "${MEDIA_CFLAGS[@]}" -DOSMEDIA_GUEST=1 \
    -I "$FF_SRC" \
    -o "$BUILD_DIR/osmedia.o" "$CORE_DIR/plat/media/osmedia.c" \
    || fail "compiling osmedia.c for kernel triple failed"
  GUEST_BLIT_FLAGS=()
  if [[ "${OSMEDIA_NO_BLIT:-0}" == 1 ]]; then
    GUEST_BLIT_FLAGS+=(-DOSMEDIA_NO_BLIT=1)
  fi
  if [[ "${OSMEDIA_NO_WIN:-0}" == 1 ]]; then
    GUEST_BLIT_FLAGS+=(-DOSMEDIA_NO_WIN=1)
  fi
  if [[ "${OSMEDIA_NO_MOVIE:-0}" == 1 ]]; then
    GUEST_BLIT_FLAGS+=(-DOSMEDIA_NO_MOVIE=1)
  fi
  clang "${MEDIA_CFLAGS[@]}" "${GUEST_BLIT_FLAGS[@]}" \
    -o "$BUILD_DIR/osmedia_guest.o" "$CORE_DIR/plat/media/osmedia_guest.c" \
    || fail "compiling osmedia_guest.c failed"
  clang "${MEDIA_CFLAGS[@]}" \
    -o "$BUILD_DIR/osmedia_snprintf.o" "$CORE_DIR/plat/media/osmedia_snprintf.c" \
    || fail "compiling osmedia_snprintf.c failed"
  GUEST_OBJS+=("$BUILD_DIR/osmedia_guest.o" "$BUILD_DIR/osmedia.o" "$BUILD_DIR/osmedia_snprintf.o")
  GUEST_OBJS+=(--start-group "$FF_LIB/libavformat.a" "$FF_LIB/libavcodec.a" "$FF_LIB/libavutil.a" --end-group)
else
  clang "${MEDIA_CFLAGS[@]}" -DOSMEDIA_NO_FFMPEG_LINK=1 -DOSMEDIA_NO_WIN=1 \
    -DOSMEDIA_NO_MOVIE=1 \
    -o "$BUILD_DIR/osmedia_guest.o" "$CORE_DIR/plat/media/osmedia_guest.c" \
    || fail "compiling osmedia_guest.c (no ffmpeg) failed"
  GUEST_OBJS+=("$BUILD_DIR/osmedia_guest.o")
fi

# ADR-0154 — OTA TLS 1.2 record layer (AES128-SHA). Not plat-tls / FSGS.
# -mno-sse: freestanding tick path has no 16-byte stack ABI; clang -O2
# otherwise emits MOVAPS (0F29) and #GP on unaligned locals.
clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall \
  -mno-sse -mno-sse2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 \
  "${CANON_ARR[@]+"${CANON_ARR[@]}"}" \
  -I "$CORE_DIR/plat/otatls" \
  -o "$BUILD_DIR/otatls.o" "$CORE_DIR/plat/otatls/otatls.c" \
  || fail "compiling otatls.c failed"
GUEST_OBJS+=("$BUILD_DIR/otatls.o")

echo "build-kernel: linking ${#GUEST_OBJS[@]} guest objs (OSGFX_SKIA=${OSGFX_SKIA:-1})" >&2
# Atomic link — concurrent OSGFX_SKIA=0 harnesses must not truncate a
# half-written Skia image into an empty guest_tick (paper chrome).
LINK_TMP="$BUILD_DIR/kernel.elf.$$.tmp"
LINK_MAP_TMP="$BUILD_DIR/kernel.map.$$.tmp"
"$LD_CMD" -T "$CORE_DIR/link/kernel.ld" -Map "$LINK_MAP_TMP" -o "$LINK_TMP" \
  "$BUILD_DIR/boot.o" "$BUILD_DIR/isr.o" "$BUILD_DIR/kdata.o" "$BUILD_DIR/portio.o" \
  "$BUILD_DIR/kmain.o" "${GUEST_OBJS[@]}"
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  rm -f "$LINK_TMP" "$LINK_MAP_TMP"
  fail "linking kernel.elf with $LD_CMD exited $LINK_STATUS"
fi
[[ -f "$LINK_TMP" ]] || fail "ld reported success but link tmp was not produced"
# Paper-doodle guard: empty osgfx_guest_tick + missing fill_rrect means Skia
# never made the image (race / OSGFX_SKIA=0), and Dart osxui_scan stamps win.
if [[ "${OSGFX_SKIA:-1}" == 1 ]]; then
  if ! grep -q 'osgfx_skia\.o' "$LINK_MAP_TMP"; then
    rm -f "$LINK_TMP" "$LINK_MAP_TMP"
    fail "kernel.map missing osgfx_skia.o — Skia not linked (paper chrome)"
  fi
  if ! python3 -c "import sys; d=open(sys.argv[1],'rb').read(); sys.exit(0 if b'skia-draw' in d and b'osgfx-session-tick' in d else 1)" "$LINK_TMP"; then
    rm -f "$LINK_TMP" "$LINK_MAP_TMP"
    fail "link tmp lost skia-draw/session-tick — Skia paint not linked"
  fi
  if ! grep -q 'osgfx_fill_rrect' "$LINK_MAP_TMP"; then
    rm -f "$LINK_TMP" "$LINK_MAP_TMP"
    fail "kernel.map has no osgfx_fill_rrect — Skia paint ABI dropped"
  fi
  if ! grep -q 'osgfx_guest_tick' "$LINK_MAP_TMP"; then
    rm -f "$LINK_TMP" "$LINK_MAP_TMP"
    fail "kernel.map has no osgfx_guest_tick — session tick missing"
  fi
  # Durable copy — OSGFX_SKIA=0 anti-vacuity runs keep stomping kernel.elf.
  cp -f "$LINK_TMP" "$BUILD_DIR/kernel-skia.elf"
fi
mv -f "$LINK_MAP_TMP" "$BUILD_DIR/kernel.map"
mv -f "$LINK_TMP" "$BUILD_DIR/kernel.elf"

# UEFI/GOP ISO: same objects, 9MiB base, so Limine 12's usable-memory
# check does not span OVMF's reserved island at 8MiB.
if [[ "${OSGFX_SKIA:-1}" == 1 && -f "$CORE_DIR/link/kernel-uefi.ld" ]]; then
  UEFI_TMP="$BUILD_DIR/kernel-uefi.elf.$$.tmp"
  if "$LD_CMD" -T "$CORE_DIR/link/kernel-uefi.ld" \
      -o "$UEFI_TMP" \
      "$BUILD_DIR/boot.o" "$BUILD_DIR/isr.o" "$BUILD_DIR/kdata.o" \
      "$BUILD_DIR/portio.o" "$BUILD_DIR/kmain.o" "${GUEST_OBJS[@]}"; then
    mv -f "$UEFI_TMP" "$BUILD_DIR/kernel-uefi.elf"
    echo "build-kernel: UEFI image $BUILD_DIR/kernel-uefi.elf (9MiB base)"
  else
    rm -f "$UEFI_TMP"
    echo "build-kernel: WARNING — kernel-uefi.elf link failed" >&2
  fi
fi

echo "build-kernel: PASS — $BUILD_DIR/kernel.elf"
exit 0
