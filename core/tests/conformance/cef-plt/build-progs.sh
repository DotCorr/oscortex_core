#!/usr/bin/env bash
# PLAT/ASK + LIBC.SO (memset) + CEF.SO ticket + host plant.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-nm python3; do
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

SO_CFLAGS=(
  -c -target x86_64-unknown-none-elf -ffreestanding -nostdlib
  -fPIC -fno-stack-protector -fno-asynchronous-unwind-tables
  -fno-builtin -Os -Wall -Wextra -Werror
)
clang "${SO_CFLAGS[@]}" "$SCRIPT_DIR/libc.c" -o "$OUT/libc.o" \
  || fail "clang could not compile libc.c"
x86_64-elf-ld -shared -z max-page-size=0x1000 --build-id=none \
  -T "$SCRIPT_DIR/libc.ld" \
  -o "$OUT/libc.so" "$OUT/libc.o" \
  || fail "x86_64-elf-ld could not link libc.so"
[[ -s "$OUT/libc.so" ]] || fail "no libc.so"
x86_64-elf-readelf -hW "$OUT/libc.so" | grep -q "DYN (Shared object" \
  || fail "libc.so is not ET_DYN"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] memset$' \
  || fail "libc.so has no exported memset"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] memcpy$' \
  || fail "libc.so has no exported memcpy"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] memmove$' \
  || fail "libc.so has no exported memmove"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] strlen$' \
  || fail "libc.so has no exported strlen"
x86_64-elf-nm "$OUT/libc.so" | grep -qE ' [Tt] memcmp$' \
  || fail "libc.so has no exported memcmp"
# Bodies live in the RX face slab (192 bytes); PLT gets trampolines.
MS_SIZE=$(x86_64-elf-nm -S "$OUT/libc.so" | awk '$4=="memset"{print $2; exit}')
[[ -n "$MS_SIZE" ]] || fail "could not read memset size"
MS_SIZE=$((16#$MS_SIZE))
[[ "$MS_SIZE" -le 80 ]] || fail "memset is $MS_SIZE bytes — face body max is 80"
x86_64-elf-readelf -dW "$OUT/libc.so" | grep -q '(HASH)' \
  || fail "libc.so has no DT_HASH"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "libc.so has a W+X segment"
x86_64-elf-readelf -lW "$OUT/libc.so" | awk '$1=="LOAD"' | grep -qE 'R E|RE' \
  || fail "libc.so has no RX LOAD — call would be NX"
SO_BYTES=$(wc -c <"$OUT/libc.so" | tr -d ' ')
[[ "$SO_BYTES" -le 65536 ]] || fail "libc.so is $SO_BYTES bytes"

READY="$CORE_DIR/build/cef-linux64/READY"
if [[ ! -f "$READY" ]]; then
  bash "$CORE_DIR/scripts/fetch-cef-linux64.sh" \
    || fail "fetch-cef-linux64.sh failed"
fi
CEF_LIB=$(grep -m1 '^CEF_LIB=' "$READY" | cut -d= -f2-)
[[ -f "$CEF_LIB" ]] || fail "CEF_LIB missing: $CEF_LIB"

python3 "$CORE_DIR/scripts/pack-cef-slice.py" "$CEF_LIB" "$OUT/cef.so" \
  || fail "pack-cef-slice.py failed"
CEF_BYTES=$(wc -c <"$OUT/cef.so" | tr -d ' ')
[[ "$CEF_BYTES" -le 65536 ]] || fail "cef.so ticket too big"

python3 "$CORE_DIR/scripts/pack-cef-loads.py" "$CEF_LIB" "$OUT/cef-plant.bin" \
  || fail "pack-cef-loads.py failed"
PLANT_BYTES=$(wc -c <"$OUT/cef-plant.bin" | tr -d ' ')
[[ "$PLANT_BYTES" -eq 231711248 ]] \
  || fail "plant is $PLANT_BYTES, expected 231711248"
[[ "$PLANT_BYTES" -gt 12288 ]] || fail "plant not larger than slice"

# Official memset@plt stub must sit inside the plant (GOT is past it).
python3 - "$OUT/cef-plant.bin" <<'PY' || fail "memset@plt not in plant"
import sys
plant = open(sys.argv[1], "rb").read()
off = 0xDCFA1E0
stub = plant[off:off + 6]
# Unpatched: ff 25 .. (jmp *GOT). After kernel bind it becomes 48 b8.
if stub[:2] != bytes([0xFF, 0x25]):
    raise SystemExit("plant memset@plt stub drifted: %r" % stub.hex())
print("plant: memset@plt at off 0x%x ok" % off)
PY

echo "build-progs: PASS — plat.elf ($BYTES) + libc.so ($SO_BYTES) + cef.so ($CEF_BYTES) + plant ($PLANT_BYTES)"
exit 0
