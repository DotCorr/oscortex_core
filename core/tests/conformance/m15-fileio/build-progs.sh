#!/usr/bin/env bash
# core/tests/conformance/m15-fileio/build-progs.sh
#
# Builds the C library -- INCLUDING M15's buffered reader, rfile.c -- and the
# TWO freestanding static ELF64 executables this harness puts on its FAT16
# volume, and then CHECKS WHAT IT BUILT.
#
# m14-fat/build-progs.sh's machinery, with m14's two programs replaced by M15's
# one program built twice:
#
#   prog    -DPROG_NEG=0   PROG.ELF   — uses the byte count `read` returns
#   progn   -DPROG_NEG=1   PROGN.ELF  — IGNORES it and hashes the whole chunk
#
# THE NEGATIVE CONTROL IS THE SECOND BUILD. It is the most common way to get a
# `read` loop wrong, it is wrong only on the LAST read of the file, and
# derive.py computes exactly what it produces. run.sh requires the control to
# print that number and NOT the true one.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/prog.elf, <outdir>/progn.elf
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
for f in oslibc.h syscall.c string.c malloc.c printf.c rfile.c; do
  [[ -f "$LIBC_DIR/$f" ]] || setup_error "$LIBC_DIR/$f is missing"
done

# EXACTLY m13-libc/m14-fat's flags.
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

LIBC_SRCS=(syscall.c string.c malloc.c printf.c rfile.c)

build_one() {
  local tag="$1" neg="$2"
  local objs=()
  local s
  for s in "${LIBC_SRCS[@]}"; do
    clang "${CFLAGS[@]}" -DLIBC_FREE_ENABLED=1 "$LIBC_DIR/$s" \
      -o "$OUT/${tag}_${s%.c}.o" || fail "clang could not compile libc/$s for $tag"
    objs+=("$OUT/${tag}_${s%.c}.o")
  done
  clang "${CFLAGS[@]}" -DPROG_NEG="$neg" "$SCRIPT_DIR/prog.c" -o "$OUT/$tag.o" \
    || fail "clang could not compile prog.c as $tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/$tag.elf" "$OUT/$tag.o" "${objs[@]}" \
    || fail "x86_64-elf-ld could not link $tag.elf"
  [[ -s "$OUT/$tag.elf" ]] || fail "the linker reported success but produced no $tag.elf"
}

build_one prog 0
build_one progn 1

cmp -s "$OUT/prog.elf" "$OUT/progn.elf" && \
  fail "prog.elf and progn.elf are byte-identical — the negative control controls for nothing"

# ---------------------------------------------------------------------------
# THE TWO SYMBOLS THE SELF-HASH DEPENDS ON, m14-fat's check kept verbatim in
# spirit: `__ro_start`/`__ro_end` bracket the R+X segment's FILE bytes, the
# program hashes that range before and after it aims a `read` at it, and a
# `__ro_end` that silently became 0 would make the hash a constant.
# ---------------------------------------------------------------------------
for tag in prog progn; do
  elf="$OUT/$tag.elf"
  rw_end=$(x86_64-elf-nm "$elf" | awk '$3=="__rw_end"{print $1; exit}')
  [[ -n "$rw_end" ]] \
    || fail "$tag.elf has no __rw_end — prog.c could not find the end of the mapped image, and the straddling-read check would aim at nothing"
  ro_start=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_start"{print $1; exit}')
  ro_end=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_end"{print $1; exit}')
  [[ -n "$ro_start" && -n "$ro_end" ]] \
    || fail "$tag.elf has no __ro_start/__ro_end"
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
  want_end=$(( seg_vaddr + seg_filesz ))
  got_start=$(( 16#$ro_start ))
  got_end=$(( 16#$ro_end ))
  [[ "$got_start" -eq "$seg_vaddr" ]] \
    || fail "$tag.elf: __ro_start is $(printf 0x%X $got_start), R+X starts at $(printf 0x%X $seg_vaddr)"
  [[ "$got_end" -eq "$want_end" ]] \
    || fail "$tag.elf: __ro_end is $(printf 0x%X $got_end), R+X file bytes end at $(printf 0x%X $want_end)"
  [[ $(( got_end - got_start )) -gt 2048 ]] \
    || fail "$tag.elf: the hashed range is only $(( got_end - got_start )) bytes"
done
echo "    (__ro_start/__ro_end bracket exactly the R+X segment's file bytes in both builds)"

# ---------------------------------------------------------------------------
# THE R+X SEGMENT MUST NOT BE WRITABLE, which is the property the `read` into
# `__ro_start` is supposed to be refused BY. If the linker ever emitted it
# RWE the kernel would refuse to load the program at all -- but a check that
# says so here names the cause instead of leaving it to a boot.
# ---------------------------------------------------------------------------
for tag in prog progn; do
  elf="$OUT/$tag.elf"
  x86_64-elf-nm "$elf" | grep -qE "T memcpy$" \
    || fail "$tag.elf has no memcpy of its own — core/user/libc/string.c did not get linked in"
  x86_64-elf-nm "$elf" | grep -qE "T rfopen$" \
    || fail "$tag.elf has no rfopen — core/user/libc/rfile.c did not get linked in"
  x86_64-elf-nm "$elf" | grep -qE "T (open|read|close|seek)$" \
    || fail "$tag.elf has none of open/read/close/seek — core/user/libc/syscall.c did not get linked in"
  entry=$(x86_64-elf-readelf -hW "$elf" | awk '/Entry point/ {print $NF}')
  [[ "$entry" != "0x10000000" ]] \
    || fail "$tag.elf's entry point is the very start of the first segment; a kernel that ignored e_entry would pass"
  x86_64-elf-readelf -lW "$elf" | grep -q "INTERP" \
    && fail "$tag.elf has a PT_INTERP — core/kernel/elf.dart refuses it by name"
  x86_64-elf-readelf -lW "$elf" | awk '$1=="LOAD"' | grep -q "RWE" \
    && fail "$tag.elf has a W+X segment — core/kernel/elf.dart refuses it by name"
done

P_BYTES=$(wc -c <"$OUT/prog.elf" | tr -d ' ')
N_BYTES=$(wc -c <"$OUT/progn.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/prog.elf ($P_BYTES bytes) and $OUT/progn.elf ($N_BYTES bytes), each carrying core/user/libc's FIVE objects including rfile.c"
