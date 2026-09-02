#!/usr/bin/env bash
# core/tests/conformance/wm-seat/build-progs.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
OUT="${1:-}"; mkdir -p "$OUT"
CFLAGS=(-c -target x86_64-unknown-none-elf -ffreestanding -nostdlib -fno-pic -fno-pie
  -mno-red-zone -fno-stack-protector -fno-asynchronous-unwind-tables -fno-builtin -O2 -Wall -Wextra -Werror)
for s in a b; do
  clang "${CFLAGS[@]}" "$SCRIPT_DIR/$s.c" -o "$OUT/$s.o" || fail "clang $s"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none -o "$OUT/$s.elf" "$OUT/$s.o" || fail "ld $s"
done
echo "build-progs: PASS"
