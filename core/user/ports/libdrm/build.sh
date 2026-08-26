#!/usr/bin/env bash
# core/user/ports/libdrm/build.sh
#
# COMPILES UNMODIFIED libdrm SOURCE FOR THIS OPERATING SYSTEM, AND COUNTS WHAT
# IS MISSING.
#
# This is the whole of the first rung of the DRM ladder (docs/design/drm-abi.md
# §8.3, ADR-0031). It does not link a program and it does not run one: it
# produces ELF64 objects for x86_64-unknown-none-elf out of libdrm's own .c
# files, with NO patch applied to any of them, and then prints the exact list of
# symbols those objects need that core/user/libc does not have.
#
#   build.sh <libdrm-src> <outdir> [--with-modetest]
#
# Outputs in <outdir>:
#   obj/*.o                 the compiled objects
#   externals.txt           every symbol the objects need from outside themselves
#   provided.txt            those that core/user/libc defines
#   missing.txt             those that it does not          <-- THE MEASUREMENT
#   libc-symbols.txt        what core/user/libc actually exports
#
# WHAT IS AND IS NOT PROVED BY A GREEN RUN
#   PROVED:     libdrm's C compiles, unmodified, for this target, against a shim
#               header set that declares only names, and the set of external
#               symbols it needs is exactly <outdir>/missing.txt.
#   NOT PROVED: that any of it would run. Nothing here executes. Ten symbols
#               resolve against core/user/libc BY NAME and four of those have
#               INCOMPATIBLE SIGNATURES — see ../README.md §3 and
#               tests/conformance/drm-abi/run.sh, which asserts that hazard
#               rather than leaving it to be discovered.
#
# Exit status: 0 built, 1 a build failure, 2 a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"
SHIM_DIR="$SCRIPT_DIR/shim"

fail() { echo "build: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build: SETUP ERROR — $1" >&2; exit 2; }

SRC="${1:-}"
OUT="${2:-}"
WITH_MODETEST=0
[[ "${3:-}" == "--with-modetest" ]] && WITH_MODETEST=1
[[ -n "$SRC" && -n "$OUT" ]] || setup_error "usage: build.sh <libdrm-src> <outdir> [--with-modetest]"
[[ -f "$SRC/xf86drm.c" ]] || setup_error "$SRC does not look like a libdrm checkout (no xf86drm.c)"
[[ -d "$SHIM_DIR" ]] || setup_error "no shim headers at $SHIM_DIR"
[[ -d "$LIBC_DIR" ]] || setup_error "no libc at $LIBC_DIR"

for tool in clang x86_64-elf-nm python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

mkdir -p "$OUT/obj" "$OUT/libcobj" || setup_error "could not create $OUT"

# ---------------------------------------------------------------------------
# THE FLAGS, AND THE THREE THAT ARE NOT m19-argv's
#
# m19-argv/build-progs.sh's flags for every program this OS has ever built,
# minus three, and each subtraction is a finding rather than a convenience:
#
#   -Wall -Wextra -Werror is DROPPED. libdrm does not build clean under it and
#     it is not libdrm's job to: `xf86drm.c` alone produces fourteen -Werror
#     diagnostics, and the whole file produces EIGHT `#warning "Missing implementation of
#     drmParse*"` lines — real, deliberate,
#     upstream markers that this platform is not one libdrm knows. Turning
#     -Werror off does not make them go away; ../README.md §4 records what they
#     mean and the harness asserts they are still there.
#
#   -std=c11 is ADDED. libdrm's meson sets it; this repo's own C has never
#     needed to say.
#
#   -D... is ADDED. libdrm has no config.h in-tree; meson passes its whole
#     configuration on the command line and so must we.
# ---------------------------------------------------------------------------
CFLAGS=(
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
  -std=c11
  -DMAJOR_IN_SYSMACROS=1
  -DHAVE_VISIBILITY=1
  -DUDEV=0
  -DHAVE_SECURE_GETENV=0
  -DHAVE_LIBDRM_ATOMIC_PRIMITIVES=1
  "-I$SHIM_DIR"
  "-I$SRC"
  "-I$SRC/include/drm"
)

# libdrm's meson generates this header from drm_fourcc.h with its own script.
# We run the same script rather than transcribing its output.
[[ -f "$SRC/gen_table_fourcc.py" ]] || setup_error "$SRC has no gen_table_fourcc.py"
python3 "$SRC/gen_table_fourcc.py" "$SRC/include/drm/drm_fourcc.h" \
  "$OUT/generated_static_table_fourcc.h" \
  || fail "gen_table_fourcc.py failed"
CFLAGS+=("-I$OUT")

CORE_SRCS=(xf86drm xf86drmMode xf86drmHash xf86drmRandom xf86drmSL)

for f in "${CORE_SRCS[@]}"; do
  clang "${CFLAGS[@]}" "$SRC/$f.c" -o "$OUT/obj/$f.o" \
    || fail "clang could not compile libdrm/$f.c for x86_64-unknown-none-elf"
done
echo "    (libdrm core: ${#CORE_SRCS[@]} objects, unmodified source)"

if [[ "$WITH_MODETEST" -eq 1 ]]; then
  MT_CFLAGS=("${CFLAGS[@]}" "-I$SRC/tests" "-I$SRC/tests/util" "-I$SRC/tests/modetest")
  for f in tests/modetest/modetest tests/modetest/buffers tests/modetest/cursor \
           tests/util/format tests/util/kms tests/util/pattern; do
    b=$(basename "$f")
    clang "${MT_CFLAGS[@]}" "$SRC/$f.c" -o "$OUT/obj/$b.o" \
      || fail "clang could not compile libdrm/$f.c for x86_64-unknown-none-elf"
  done
  echo "    (modetest + util: 6 more objects, unmodified source)"
fi

# ---------------------------------------------------------------------------
# core/user/libc, built with ITS OWN flags — including -Werror, which it does
# pass — so that what it exports is measured rather than read out of oslibc.h.
# ---------------------------------------------------------------------------
LIBC_CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib -fno-pic -fno-pie
  -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin
  -O2 -Wall -Wextra -Werror "-I$LIBC_DIR" -DLIBC_FREE_ENABLED=1
)
for s in syscall string malloc printf rfile start; do
  clang "${LIBC_CFLAGS[@]}" "$LIBC_DIR/$s.c" -o "$OUT/libcobj/$s.o" \
    || fail "clang could not compile core/user/libc/$s.c"
done

# ---------------------------------------------------------------------------
# THE MEASUREMENT.
#
# externals = (undefined anywhere) minus (defined anywhere), across the whole
# object set — so libdrm's own internal cross-references do not count as gaps.
# ---------------------------------------------------------------------------
x86_64-elf-nm --undefined-only "$OUT"/obj/*.o | awk '{print $2}' | sort -u > "$OUT/.undef"
x86_64-elf-nm --defined-only   "$OUT"/obj/*.o | awk '{print $3}' | sort -u > "$OUT/.def"
comm -23 "$OUT/.undef" "$OUT/.def" > "$OUT/externals.txt"

x86_64-elf-nm --defined-only "$OUT"/libcobj/*.o \
  | awk '$2 ~ /^[TDBRtdbr]$/ {print $3}' | sort -u > "$OUT/libc-symbols.txt"

comm -12 "$OUT/externals.txt" "$OUT/libc-symbols.txt" > "$OUT/provided.txt"
comm -23 "$OUT/externals.txt" "$OUT/libc-symbols.txt" > "$OUT/missing.txt"
rm -f "$OUT/.undef" "$OUT/.def"

ne=$(wc -l < "$OUT/externals.txt" | tr -d ' ')
np=$(wc -l < "$OUT/provided.txt" | tr -d ' ')
nm_=$(wc -l < "$OUT/missing.txt" | tr -d ' ')
nl=$(wc -l < "$OUT/libc-symbols.txt" | tr -d ' ')

[[ "$ne" -gt 0 ]] || fail "the objects need nothing from outside themselves — the measurement is vacuous"

echo "build: PASS — $ne external symbols, $np provided by core/user/libc ($nl exported), $nm_ MISSING"
exit 0
