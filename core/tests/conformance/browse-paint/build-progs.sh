#!/usr/bin/env bash
# core/tests/conformance/browse-paint/build-progs.sh
#
# Builds PAINT.ELF (OnPaint stand-in delivers PAGE) and NOPAIN.ELF
# (--no-onpaint: callback disabled, pixel is not PAGE) against
# osframe.h + oschrome_guest.c + official linux64 cef_initialize.
#
# Usage: build-progs.sh <outdir> <kerneldir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
CHROME_DIR="$CORE_DIR/plat/chrome"
SRC="$FRAME_DIR/browse.c"
GUEST="$CHROME_DIR/oschrome_guest.c"
CEF_C="$CHROME_DIR/oschrome_cef.c"
EXTRACT="$CORE_DIR/scripts/extract-cef-guest.sh"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> <kerneldir>"
[[ -d "$KERNEL_DIR" ]] || setup_error "no kernel sources at $KERNEL_DIR"
[[ -f "$SRC" ]] || setup_error "no browse.c at $SRC"
[[ -f "$GUEST" ]] || setup_error "no oschrome_guest.c at $GUEST"
[[ -f "$CEF_C" ]] || setup_error "no oschrome_cef.c at $CEF_C"
[[ -f "$EXTRACT" ]] || setup_error "no extract-cef-guest.sh at $EXTRACT"
[[ -f "$FRAME_DIR/osframe.h" ]] || setup_error "no osframe.h at $FRAME_DIR"
[[ -f "$CHROME_DIR/oschrome.h" ]] || setup_error "no oschrome.h at $CHROME_DIR"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-nm python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

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
  -I"$CHROME_DIR"
)

bash "$EXTRACT" "$OUT/cef_initialize" \
  || fail "extract-cef-guest.sh could not produce official cef_initialize.o"
[[ -s "$OUT/cef_initialize.o" ]] || fail "no official cef_initialize.o"

clang "${CFLAGS[@]}" "$GUEST" -o "$OUT/oschrome_guest.o" \
  || fail "clang could not compile oschrome_guest.c"
clang "${CFLAGS[@]}" "$CEF_C" -o "$OUT/oschrome_cef.o" \
  || fail "clang could not compile oschrome_cef.c"
clang "${CFLAGS[@]}" "$SRC" -o "$OUT/paint.o" \
  || fail "clang could not compile browse.c (paint)"
clang "${CFLAGS[@]}" -DBROWSE_NO_ONPAINT "$SRC" -o "$OUT/nopain.o" \
  || fail "clang could not compile browse.c -DBROWSE_NO_ONPAINT"

x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/paint.elf" "$OUT/paint.o" "$OUT/oschrome_guest.o" \
     "$OUT/oschrome_cef.o" "$OUT/cef_initialize.o" \
  || fail "x86_64-elf-ld could not link paint.elf"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/nopain.elf" "$OUT/nopain.o" "$OUT/oschrome_guest.o" \
     "$OUT/oschrome_cef.o" "$OUT/cef_initialize.o" \
  || fail "x86_64-elf-ld could not link nopain.elf"
[[ -s "$OUT/paint.elf" ]] || fail "no paint.elf"
[[ -s "$OUT/nopain.elf" ]] || fail "no nopain.elf"

# Anti-vacuity: paint.o without guest cannot resolve the ABI.
if x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
     -o "$OUT/paint-nosym.elf" "$OUT/paint.o" 2>"$OUT/paint-nosym.err"; then
  fail "paint.o linked without oschrome_guest.o — client does not call the ABI"
fi
rm -f "$OUT/paint-nosym.elf"

NM=$(x86_64-elf-nm "$OUT/paint.elf")
echo "$NM" | grep -q 'oschrome_on_paint' \
  || fail "paint.elf has no oschrome_on_paint — OnPaint stand-in missing"
echo "$NM" | grep -q 'oschrome_load_url' \
  || fail "paint.elf has no oschrome_load_url"
echo "$NM" | grep -E '[Tt] cef_initialize' >/dev/null \
  || fail "paint.elf cef_initialize is not a defined text symbol"
# File size: TAP apps stay under elfImageMax; PLAT may be large.
BYTES=$(wc -c < "$OUT/paint.elf")
[[ "$BYTES" -le 65536 ]] || fail "paint.elf is $BYTES bytes; elfImageMax is 65536 (TAP)"
BYTES_N=$(wc -c < "$OUT/nopain.elf")
[[ "$BYTES_N" -le 65536 ]] || fail "nopain.elf is $BYTES_N bytes; elfImageMax is 65536 (TAP)"

echo "build-progs: PASS — paint.elf ($BYTES) nopain.elf ($BYTES_N) oschrome_on_paint + cef_initialize"
