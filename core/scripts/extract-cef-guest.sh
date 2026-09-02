#!/usr/bin/env bash
# Official linux64 libcef.so → freestanding cef_initialize.o
# for the kernel triple. Mac CEF is arm64 and is rejected here.
set -euo pipefail

CORE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$CORE/build/cef-linux64/guest}"
FETCH="$CORE/scripts/fetch-cef-linux64.sh"
PY="$CORE/scripts/extract-cef-guest.py"

bash "$FETCH"
STAMP="$CORE/build/cef-linux64/READY"
# shellcheck disable=SC1090
CEF_LIB="$(awk -F= '/^CEF_LIB=/{print substr($0,9)}' "$STAMP")"
[[ -f "$CEF_LIB" ]] || { echo "extract-cef-guest: no $CEF_LIB" >&2; exit 2; }

# file(1) must say ELF x86-64, not Mach-O.
FILE_OUT="$(file "$CEF_LIB")"
echo "$FILE_OUT" | grep -q 'ELF' || { echo "extract-cef-guest: libcef.so is not ELF: $FILE_OUT" >&2; exit 2; }
echo "$FILE_OUT" | grep -q 'x86-64' || { echo "extract-cef-guest: libcef.so is not x86-64: $FILE_OUT" >&2; exit 2; }
if echo "$FILE_OUT" | grep -qi 'Mach-O'; then
  echo "extract-cef-guest: HARD BLOCK — Mac CEF cannot be copied into the x86_64 blob" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT")"
SHA_LINE="$(python3 "$PY" "$CEF_LIB" "$OUT" cef_initialize)"
echo "$SHA_LINE"
WANT_SHA="82f0dac25f8ab79701da064984d3c49ef2bedf0b"
GOT_SHA="$(echo "$SHA_LINE" | awk 'END{print $1}')"
if [[ "$GOT_SHA" != "$WANT_SHA" ]]; then
  # python prints the sha1 on the last line.
  GOT_SHA="$(echo "$SHA_LINE" | tail -1)"
fi
if [[ "$GOT_SHA" != "$WANT_SHA" ]]; then
  echo "extract-cef-guest: HARD BLOCK — official bytes sha1 $GOT_SHA != $WANT_SHA" >&2
  exit 2
fi
[[ -s "$OUT.bin" ]] || { echo "extract-cef-guest: no $OUT.bin" >&2; exit 2; }
[[ -s "$OUT.S" ]] || { echo "extract-cef-guest: no $OUT.S" >&2; exit 2; }

# Assemble next to the .bin so .incbin finds it by basename.
ASM_DIR="$(cd "$(dirname "$OUT")" && pwd)"
BASE="$(basename "$OUT")"
(
  cd "$ASM_DIR"
  clang -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib \
    -fno-pic -fno-pie -mno-red-zone -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-builtin \
    -o "$BASE.o" "$BASE.S"
)
[[ -f "$OUT.o" ]] || mv -f "$ASM_DIR/$BASE.o" "$OUT.o"
[[ -s "$OUT.o" ]] || { echo "extract-cef-guest: clang produced no $OUT.o" >&2; exit 2; }

NM="$(x86_64-elf-nm "$OUT.o")"
echo "$NM" | grep -q 'cef_initialize' \
  || { echo "extract-cef-guest: $OUT.o has no cef_initialize" >&2; exit 2; }
echo "extract-cef-guest: $OUT.o"
echo "$NM"
