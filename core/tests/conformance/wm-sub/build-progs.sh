#!/usr/bin/env bash
# core/tests/conformance/wm-sub/build-progs.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
OUT="${1:-}"; [[ -n "$OUT" ]] || fail "usage: build-progs.sh <outdir>"
mkdir -p "$OUT"
CFLAGS=(-c -target x86_64-unknown-none-elf -ffreestanding -nostdlib -fno-pic -fno-pie
  -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror)
clang "${CFLAGS[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/prog.o" || fail "clang"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/prog.elf" "$OUT/prog.o" || fail "ld"
grep -q 'WM_SUB' "$SCRIPT_DIR/prog.c" || fail "no WM_SUB"
echo "build-progs: PASS — $OUT/prog.elf"
