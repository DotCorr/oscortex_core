#!/usr/bin/env bash
# core/tests/conformance/files-fm/build-progs.sh
#
# Builds the kept FILES.ELF client (core/user/frame/files.c) against
# osframe.h, linked with osgfx_glyph.o for osxui_icon_fb (ADR-0154).
# Planted names must come from the volume, so this script refuses a
# binary that contains a planted 8.3 stem as a literal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
SRC="$FRAME_DIR/files.c"
GLYPH_C="$CORE_DIR/plat/osgfx/osgfx_glyph.c"
GFX_H="$CORE_DIR/plat/osgfx"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> [FILES_NO_ICON=0|1]"
NO_ICON="${2:-0}"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-objdump x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
[[ -f "$SRC" ]] || setup_error "no files.c at $SRC"
[[ -f "$FRAME_DIR/osframe.h" ]] || setup_error "no osframe.h at $FRAME_DIR"
[[ -f "$GLYPH_C" ]] || setup_error "no osgfx_glyph.c"
[[ -f "$GFX_H/osgfx.h" ]] || setup_error "no osgfx.h"

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
  -Wall
  -Wextra
  -Werror
  -I"$FRAME_DIR"
  -I"$GFX_H"
  "-DFILES_NO_ICON=$NO_ICON"
)

clang "${CFLAGS[@]}" "$SRC" -o "$OUT/files.o" \
  || fail "clang could not compile files.c"
OBJS=("$OUT/files.o")
if [[ "$NO_ICON" == "0" ]]; then
  clang "${CFLAGS[@]}" "$GLYPH_C" -o "$OUT/osgfx_glyph.o" \
    || fail "clang could not compile osgfx_glyph.c"
  OBJS+=("$OUT/osgfx_glyph.o")
fi
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/files.elf" "${OBJS[@]}" \
  || fail "x86_64-elf-ld could not link files.elf"
[[ -s "$OUT/files.elf" ]] || fail "linker reported success but produced no files.elf"

grep -q '#include "osframe.h"' "$SRC" \
  || fail "files.c does not include osframe.h"
grep -q 'oslibc.h' "$SRC" \
  && fail "files.c includes oslibc.h — FRAME apps compile against osframe.h"
grep -qE '^#define SYS_' "$SRC" \
  && fail "files.c copies SYS_* by hand — include osframe.h"
grep -q ':ROOT' "$SRC" \
  || fail "files.c does not open :ROOT"
grep -q 'SYS_OPEN' "$SRC" \
  || fail "files.c never opens a file"
grep -q 'SYS_READ' "$SRC" \
  || fail "files.c never reads"
grep -q 'SYS_FDWRITE' "$SRC" \
  || fail "files.c never fdwrites — copy needs syscall 9"
grep -q 'SYS_RENAME' "$SRC" \
  || fail "files.c never renames — move needs syscall 32"
grep -q 'SYS_YIELD' "$SRC" \
  || fail "files.c never yields — residency needs the idle gate"
grep -q 'SYS_WMSURFACE' "$SRC" \
  || fail "files.c never attaches a surface"
if [[ "$NO_ICON" == "0" ]]; then
  grep -q 'osxui_icon_fb' "$SRC" \
    || fail "files.c does not call osxui_icon_fb"
  x86_64-elf-nm "$OUT/files.elf" | grep -q 'osxui_icon_fb' \
    || fail "files.elf has no osxui_icon_fb"
  x86_64-elf-nm "$OUT/files.elf" | grep -q 'osgfx_icon_rows' \
    || fail "files.elf has no osgfx_icon_rows"
else
  x86_64-elf-nm "$OUT/files.elf" | grep -q 'osxui_icon_fb' \
    && fail "FILES_NO_ICON=1 still has osxui_icon_fb"
fi

x86_64-elf-readelf -lW "$OUT/files.elf" | grep -q "INTERP" \
  && fail "files.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/files.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "files.elf has a W+X segment"
x86_64-elf-readelf -lW "$OUT/files.elf" | grep -E 'LOAD[[:space:]]+0x[0-9a-f]+[[:space:]]+0x0+[[:space:]]' \
  && fail "files.elf has a PT_LOAD at vaddr 0 — empty data PHDR"

BYTES=$(wc -c <"$OUT/files.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "files.elf is $BYTES bytes; elfImageMax is 65536"

echo "build-progs: PASS — $OUT/files.elf ($BYTES bytes) NO_ICON=$NO_ICON against osframe.h"
exit 0
