#!/usr/bin/env bash
# PLAT/ASK + tiny CEF.SO ticket. Full LOADs come from the host plant.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fno-pic -fno-pie -mno-red-zone -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror
)

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/plat.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/plat.elf" "$OUT/plat.o" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "no plat.elf"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — app ELF cap is 64 KiB"

READY="$CORE_DIR/build/cef-linux64/READY"
if [[ ! -f "$READY" ]]; then
  bash "$CORE_DIR/scripts/fetch-cef-linux64.sh" \
    || fail "fetch-cef-linux64.sh failed"
fi
CEF_LIB=$(grep -m1 '^CEF_LIB=' "$READY" | cut -d= -f2-)
[[ -f "$CEF_LIB" ]] || fail "CEF_LIB missing: $CEF_LIB"

# Tiny ticket on FAT (name only). Full LOADs are the host plant.
python3 "$CORE_DIR/scripts/pack-cef-slice.py" "$CEF_LIB" "$OUT/cef.so" \
  || fail "pack-cef-slice.py failed"
SO_BYTES=$(wc -c <"$OUT/cef.so" | tr -d ' ')
[[ "$SO_BYTES" -le 65536 ]] || fail "cef.so ticket too big"

# Host plant: official RO+RX LOAD file bytes.
python3 "$CORE_DIR/scripts/pack-cef-loads.py" "$CEF_LIB" "$OUT/cef-plant.bin" \
  || fail "pack-cef-loads.py failed"
PLANT_BYTES=$(wc -c <"$OUT/cef-plant.bin" | tr -d ' ')
[[ "$PLANT_BYTES" -eq 231711248 ]] \
  || fail "plant is $PLANT_BYTES, expected 231711248"

# Anti-vacuity: plant must dwarf the 12 KiB slice.
[[ "$PLANT_BYTES" -gt 12288 ]] || fail "plant not larger than slice"
SLICE=$(wc -c <"$OUT/cef.so" | tr -d ' ')
[[ "$PLANT_BYTES" -gt "$SLICE" ]] || fail "plant not larger than CEF.SO ticket"

# OUR tiny LIBC.SO. Since ADR-0169 the dlopen path places our memset over
# official libcef's memset@plt, and that placement looks LIBC.SO up on the
# same volume, so a volume without it makes dlopen refuse with NOTFOUND
# before any LOAD is mapped. Built from cef-plt's sources so the two
# harnesses cannot disagree about what OUR libc is.
PLT_DIR="$CORE_DIR/tests/conformance/cef-plt"
[[ -f "$PLT_DIR/libc.c" && -f "$PLT_DIR/libc.ld" ]] \
  || fail "cef-plt/libc.c or libc.ld is missing — no source for OUR LIBC.SO"
SO_CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fPIC -fno-stack-protector -fno-asynchronous-unwind-tables
  -fno-builtin -Os -Wall -Wextra -Werror
)
clang "${SO_CFLAGS[@]}" "$PLT_DIR/libc.c" -o "$OUT/libc.o" \
  || fail "clang could not compile cef-plt/libc.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -T "$PLT_DIR/libc.ld" -o "$OUT/libc.so" "$OUT/libc.o" \
  || fail "x86_64-elf-ld could not link libc.so"
[[ -s "$OUT/libc.so" ]] || fail "no libc.so"
x86_64-elf-readelf -hW "$OUT/libc.so" | grep -q "DYN (Shared object" \
  || fail "libc.so is not ET_DYN"
LIBC_BYTES=$(wc -c <"$OUT/libc.so" | tr -d ' ')
[[ "$LIBC_BYTES" -le 65536 ]] || fail "libc.so is $LIBC_BYTES bytes — 64 KiB cap"

echo "build-progs: PASS — plat.elf ($BYTES) + cef.so ticket ($SO_BYTES) + libc.so ($LIBC_BYTES) + plant ($PLANT_BYTES)"
exit 0
