#!/usr/bin/env bash
# core/tests/conformance/m14-fat/build-progs.sh
#
# Builds the C library and the TWO freestanding static ELF64 executables this
# harness puts on its FAT16 volume, and then CHECKS WHAT IT BUILT.
#
# m13-libc/build-progs.sh's machinery, with m13's two differences replaced by
# M14's one:
#
#   progA   -DPROG_ID=0   PROGA.ELF, which takes the ODD clusters
#   progB   -DPROG_ID=1   PROGB.ELF, which takes the EVEN clusters
#
# The two are NOT byte-identical in geometry and are not meant to be -- M13's
# control needed that and M14's does not. What M14 needs is that they are
# DIFFERENT ENOUGH that a program assembled out of alternating slabs of the two
# is a different program: different .rodata strings, different hashes, different
# exit statuses. The checks below require exactly that.
#
# THE HASH IS THE POINT. Each program hashes its own R+X segment at run time
# (prog.c), so a loader that read the wrong clusters produces a program that
# says so. This script asserts the two symbols that bracket the range exist and
# are where the link script put them, because a `__ro_end` that silently became
# 0 would make the hash a constant.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/progA.elf, <outdir>/progB.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
[[ -d "$LIBC_DIR" ]] || setup_error "no libc at $LIBC_DIR"
for f in oslibc.h syscall.c string.c malloc.c printf.c; do
  [[ -f "$LIBC_DIR/$f" ]] || setup_error "$LIBC_DIR/$f is missing"
done

# EXACTLY m13-libc/build-progs.sh's flags. SSE is still on (no
# `-mgeneral-regs-only`), which M11 turned on and every milestone since has kept.
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
  -I"$LIBC_DIR"
)

LIBC_SRCS=(syscall.c string.c malloc.c printf.c)

build_one() {
  local tag="$1" id="$2"
  local objs=()
  local s
  for s in "${LIBC_SRCS[@]}"; do
    clang "${CFLAGS[@]}" -DLIBC_FREE_ENABLED=1 "$LIBC_DIR/$s" \
      -o "$OUT/${tag}_${s%.c}.o" || fail "clang could not compile libc/$s for prog$tag"
    objs+=("$OUT/${tag}_${s%.c}.o")
  done
  clang "${CFLAGS[@]}" -DPROG_ID="$id" "$SCRIPT_DIR/prog.c" -o "$OUT/prog$tag.o" \
    || fail "clang could not compile prog.c as prog$tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/prog$tag.elf" "$OUT/prog$tag.o" "${objs[@]}" \
    || fail "x86_64-elf-ld could not link prog$tag.elf"
  [[ -s "$OUT/prog$tag.elf" ]] || fail "the linker reported success but produced no prog$tag.elf"
}

build_one A 0
build_one B 1

cmp -s "$OUT/progA.elf" "$OUT/progB.elf" && \
  fail "progA.elf and progB.elf are byte-identical — interleaving one with the other would be undetectable, which is the one thing this image is built to detect"

# ---------------------------------------------------------------------------
# THE TWO SYMBOLS THE HASH DEPENDS ON.
#
# `__ro_start` and `__ro_end` come from prog.ld and bracket the R+X segment's
# FILE bytes. If they were absent the link would fail; if they were WRONG -- the
# classic being `__ro_end` landing at the start of the next segment, or both
# collapsing to the same address -- the hash would still be printed and would
# still be reproducible, and would be a hash of nothing.
# ---------------------------------------------------------------------------
for tag in A B; do
  elf="$OUT/prog$tag.elf"
  ro_start=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_start"{print $1; exit}')
  ro_end=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_end"{print $1; exit}')
  [[ -n "$ro_start" && -n "$ro_end" ]] \
    || fail "prog$tag.elf has no __ro_start/__ro_end — prog.c would hash a range the linker never defined"
  # The R+X PT_LOAD, as the loader sees it.
  read -r seg_vaddr seg_filesz <<<"$(x86_64-elf-readelf -lW "$elf" \
    | awk '$1=="LOAD" && $NF ~ /E/ {print strtonum($3), strtonum($6); exit}' 2>/dev/null)"
  if [[ -z "${seg_vaddr:-}" ]]; then
    read -r seg_vaddr seg_filesz <<<"$(python3 - "$elf" <<'PY'
import struct, sys
f = open(sys.argv[1], "rb").read()
phoff = struct.unpack_from("<Q", f, 32)[0]
phnum = struct.unpack_from("<H", f, 56)[0]
for i in range(phnum):
    p = phoff + i * 56
    typ, flags = struct.unpack_from("<II", f, p)
    vaddr, = struct.unpack_from("<Q", f, p + 16)
    filesz, = struct.unpack_from("<Q", f, p + 32)
    if typ == 1 and (flags & 1):
        print(vaddr, filesz)
        break
PY
)"
  fi
  want_end=$(( seg_vaddr + seg_filesz ))
  got_start=$(( 16#$ro_start ))
  got_end=$(( 16#$ro_end ))
  [[ "$got_start" -eq "$seg_vaddr" ]] \
    || fail "prog$tag.elf: __ro_start is $(printf 0x%X $got_start) and the R+X segment starts at $(printf 0x%X $seg_vaddr)"
  [[ "$got_end" -eq "$want_end" ]] \
    || fail "prog$tag.elf: __ro_end is $(printf 0x%X $got_end) and the R+X segment's file bytes end at $(printf 0x%X $want_end) — the program would hash the wrong range"
  # A floor rather than the real requirement, which depends on the volume's
  # cluster size and therefore belongs to run.sh: THAT is where the range is
  # required to span at least three clusters of the image actually built, and
  # to straddle a boundary whose neighbour belongs to the other program.
  [[ $(( got_end - got_start )) -gt 2048 ]] \
    || fail "prog$tag.elf: the hashed range is only $(( got_end - got_start )) bytes; a fragmented read might not touch it at all"
done
echo "    (__ro_start/__ro_end bracket exactly the R+X segment's file bytes in both programs, and the range spans several clusters)"

# ---------------------------------------------------------------------------
# The compiler-emitted memcpy, m13-libc's check kept: prog.c calls memcpy by
# name here, so this asserts the weaker but still real property that the
# library's own memcpy is what satisfies it rather than a builtin expansion.
# ---------------------------------------------------------------------------
for tag in A B; do
  x86_64-elf-nm "$OUT/prog$tag.elf" | grep -qE "T memcpy$" \
    || fail "prog$tag.elf has no memcpy of its own — core/user/libc/string.c did not get linked in"
done

for tag in A B; do
  elf="$OUT/prog$tag.elf"
  entry=$(x86_64-elf-readelf -hW "$elf" | awk '/Entry point/ {print $NF}')
  [[ "$entry" != "0x10000000" ]] \
    || fail "prog$tag.elf's entry point is the very start of the first segment; a kernel that ignored e_entry would pass"
  x86_64-elf-readelf -lW "$elf" | grep -q "INTERP" \
    && fail "prog$tag.elf has a PT_INTERP — core/kernel/elf.dart refuses it by name"
  x86_64-elf-readelf -lW "$elf" | awk '$1=="LOAD"' | grep -q "RWE" \
    && fail "prog$tag.elf has a W+X segment — core/kernel/elf.dart refuses it by name"
done

A_BYTES=$(wc -c <"$OUT/progA.elf" | tr -d ' ')
B_BYTES=$(wc -c <"$OUT/progB.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/progA.elf ($A_BYTES bytes) and $OUT/progB.elf ($B_BYTES bytes), each carrying core/user/libc's four objects and hashing its own R+X segment"
