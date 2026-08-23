#!/usr/bin/env bash
# core/tests/conformance/m16-filewrite/build-progs.sh
#
# Builds the C library and the THREE freestanding static ELF64 executables this
# harness puts on its FAT16 volume, and then CHECKS WHAT IT BUILT.
#
# m15-fileio/build-progs.sh's machinery, with one more build from the same
# source:
#
#   prog     -DPROG_NEG=0 -DPROG_VERIFY=0   PROG.ELF    the real thing
#   progn    -DPROG_NEG=1 -DPROG_VERIFY=0   PROGN.ELF   THE NEGATIVE CONTROL:
#                                                       it adds the length it
#                                                       ASKED for to its total
#                                                       instead of the count
#                                                       fdwrite RETURNED
#   verify   -DPROG_VERIFY=1                VERIFY.ELF  reads only; it is what
#                                                       the SECOND BOOT against
#                                                       the same image runs
#
# THE CONTROL IS WRONG ONLY WHEN THE VOLUME FILLS UP, which is why run.sh runs
# it on the `full` variant. On the ordinary volume PROG.ELF and PROGN.ELF do the
# same thing and print the same numbers — and the check below still requires
# them to be different BINARIES, because a control that compiled to the same
# bytes would be no control at all.
#
# Usage:
#   build-progs.sh <outdir>   -> <outdir>/{prog,progn,verify}.elf
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

# EXACTLY m13-libc/m14-fat/m15-fileio's flags.
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
  local tag="$1" neg="$2" verify="$3"
  local objs=()
  local s
  for s in "${LIBC_SRCS[@]}"; do
    clang "${CFLAGS[@]}" -DLIBC_FREE_ENABLED=1 "$LIBC_DIR/$s" \
      -o "$OUT/${tag}_${s%.c}.o" || fail "clang could not compile libc/$s for $tag"
    objs+=("$OUT/${tag}_${s%.c}.o")
  done
  clang "${CFLAGS[@]}" -DPROG_NEG="$neg" -DPROG_VERIFY="$verify" \
    "$SCRIPT_DIR/prog.c" -o "$OUT/$tag.o" \
    || fail "clang could not compile prog.c as $tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/$tag.elf" "$OUT/$tag.o" "${objs[@]}" \
    || fail "x86_64-elf-ld could not link $tag.elf"
  [[ -s "$OUT/$tag.elf" ]] || fail "the linker reported success but produced no $tag.elf"
}

build_one prog 0 0
build_one progn 1 0
build_one verify 0 1

cmp -s "$OUT/prog.elf" "$OUT/progn.elf" && \
  fail "prog.elf and progn.elf are byte-identical — the negative control controls for nothing"
cmp -s "$OUT/prog.elf" "$OUT/verify.elf" && \
  fail "prog.elf and verify.elf are byte-identical — PROG_VERIFY did nothing"

# ---------------------------------------------------------------------------
# THE ONE CALL THAT MUST BE IN THE WRITING BUILDS AND MUST NOT BE IN THE
# READ-ONLY ONE.
#
# VERIFY.ELF runs on the SECOND boot, against the image the first boot wrote,
# and its whole claim is that the bytes were already there. A build of it that
# still contained `fdwrite` could have put them there itself. This is the check
# that makes "persistence across a reboot" mean what it says.
# ---------------------------------------------------------------------------
for tag in prog progn; do
  x86_64-elf-nm "$OUT/$tag.elf" | grep -qE " T fdwrite$" \
    || fail "$tag.elf has no fdwrite — core/user/libc/syscall.c did not get linked in, or M16's call is missing"
done
x86_64-elf-objdump -d "$OUT/verify.o" | grep -q "call.*fdwrite" \
  && fail "verify.o calls fdwrite — the read-only build is not read-only, and a boot that found the right bytes would prove nothing"
x86_64-elf-objdump -d "$OUT/verify.o" | grep -q "call.*<create>" \
  && fail "verify.o calls create — the read-only build can change the volume"
echo "    (prog.elf and progn.elf call fdwrite; verify.o calls neither fdwrite nor create)"

# ---------------------------------------------------------------------------
# THE TWO SYMBOLS THE SELF-HASH DEPENDS ON. m15-fileio's check, unchanged.
# ---------------------------------------------------------------------------
for tag in prog progn verify; do
  elf="$OUT/$tag.elf"
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
echo "    (__ro_start/__ro_end bracket exactly the R+X segment's file bytes in all three builds)"

# ---------------------------------------------------------------------------
# THE R+X SEGMENT MUST NOT BE WRITABLE. It is the SOURCE of a write M16 requires
# to SUCCEED — the whole point being that a source needs the USER bit and does
# not need the WRITABLE one — so a linker that emitted it RWE would make that
# check vacuous rather than failing it.
# ---------------------------------------------------------------------------
for tag in prog progn verify; do
  elf="$OUT/$tag.elf"
  x86_64-elf-nm "$elf" | grep -qE "T memcpy$" \
    || fail "$tag.elf has no memcpy of its own — core/user/libc/string.c did not get linked in"
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
V_BYTES=$(wc -c <"$OUT/verify.elf" | tr -d ' ')
echo "build-progs: PASS — $OUT/prog.elf ($P_BYTES bytes), $OUT/progn.elf ($N_BYTES) and $OUT/verify.elf ($V_BYTES), each carrying core/user/libc's five objects"
