#!/usr/bin/env bash
# ONE freestanding ELF (two FAT names) + measured official CEF.SO slice.

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
)

clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/plat.o" \
  || fail "clang could not compile prog.c"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/plat.elf" "$OUT/plat.o" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "linker reported success but produced no plat.elf"

x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "INTERP" \
  && fail "plat.elf has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/plat.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "plat.elf has a W+X segment"

BYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
[[ "$BYTES" -le 65536 ]] || fail "plat.elf is $BYTES bytes — app ELF cap is 64 KiB"

READY="$CORE_DIR/build/cef-linux64/READY"
if [[ ! -f "$READY" ]]; then
  bash "$CORE_DIR/scripts/fetch-cef-linux64.sh" \
    || fail "fetch-cef-linux64.sh failed"
fi
CEF_LIB=$(grep -m1 '^CEF_LIB=' "$READY" | cut -d= -f2-)
[[ -f "$CEF_LIB" ]] || fail "CEF_LIB missing: $CEF_LIB"

python3 "$CORE_DIR/scripts/pack-cef-slice.py" "$CEF_LIB" "$OUT/cef.so" \
  || fail "pack-cef-slice.py failed"
[[ -s "$OUT/cef.so" ]] || fail "no cef.so"

x86_64-elf-readelf -hW "$OUT/cef.so" | grep -q "DYN (Shared object" \
  || fail "cef.so is not ET_DYN"
x86_64-elf-readelf -dW "$OUT/cef.so" | grep -c '(NEEDED)' | grep -qx 32 \
  || fail "cef.so does not carry 32 DT_NEEDED"
x86_64-elf-readelf -dW "$OUT/cef.so" | grep -q 'libcef.so' \
  || fail "cef.so lost SONAME libcef.so"
x86_64-elf-readelf -lW "$OUT/cef.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "cef.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/cef.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "cef.so has no RX LOAD — cef_initialize would stay NX"

# Official text bytes at file/VA 0x1000 — not a handwritten stub.
python3 - "$OUT/cef.so" <<'PY' || fail "cef.so text is not the official extract"
import hashlib, sys
EXTRACT = "82f0dac25f8ab79701da064984d3c49ef2bedf0b"
b = open(sys.argv[1], "rb").read()
got = hashlib.sha1(b[0x1000:0x1000 + 558]).hexdigest()
if got != EXTRACT:
    raise SystemExit("sha1 %s != %s" % (got, EXTRACT))
print("official cef_initialize sha1 ok")
PY

SO_BYTES=$(wc -c <"$OUT/cef.so" | tr -d ' ')
[[ "$SO_BYTES" -le 65536 ]] || fail "cef.so is $SO_BYTES bytes — image cap is 64 KiB"

echo "build-progs: PASS — $OUT/plat.elf ($BYTES bytes) + cef.so ($SO_BYTES bytes, official slice)"
exit 0
