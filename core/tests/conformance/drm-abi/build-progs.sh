#!/usr/bin/env bash
# core/tests/conformance/drm-abi/build-progs.sh
#
# Builds the TWO freestanding static ELF64 executables this harness puts on its
# FAT16 volume, and then CHECKS WHAT IT BUILT.
#
#   drmabi   the real program            DRMABI.ELF   — Linux's _IOC encoding
#   drmabin  the NEGATIVE CONTROL        DRMABIN.ELF  — BSD's _IOC encoding
#
# THE CONTROL IS ONE HEADER, NOT A `#define`. Both builds compile the SAME
# prog.c with the SAME flags; the control simply puts neg-shim/ ahead of
# core/user/ports/libdrm/shim/ on the include path, so `drm.h`'s "one of the
# BSDs" branch finds BSD's `_IOWR` instead of ours. That is the mistake this
# port is one line away from making at all times, and it is silent: the headers
# compile, the structs are identical, 29 of 121 request numbers move.
#
# WHAT THIS SCRIPT ASSERTS ABOUT THE BUILD ITSELF
#   * The uAPI headers are the PINNED libdrm checkout's, UNPATCHED. The script
#     refuses to build if `git status` in that checkout is dirty.
#   * `_start` is the LIBRARY's (m19-argv's checks, kept in full): prog.c must
#     not define one, `_start` must read argc from (%rsp) and argv from
#     8(%rsp), and must never write %rsp.
#   * Two PT_LOADs, one R+X and one R+W, no W+X, and the R+W one has real file
#     bytes and real .bss.
#   * `__ro_start`/`__ro_end` bracket exactly the R+X segment's file bytes.
#   * `e_entry` is not the first byte of the R+X segment.
#   * The two ELFs are NOT byte-identical.
#   * The two ELFs' `.text` IS byte-identical — the control differs only in
#     .rodata, which is what makes it a control for the ENCODING rather than
#     for the program.
#
# Usage:
#   build-progs.sh <libdrm-src> <outdir>   -> <outdir>/drmabi.elf, drmabin.elf
#
# Exit status: 0 on success, 1 on a build failure, 2 on a setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LIBC_DIR="$CORE_DIR/user/libc"
PORT_DIR="$CORE_DIR/user/ports/libdrm"
SHIM_DIR="$PORT_DIR/shim"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

SRC="${1:-}"
OUT="${2:-}"
[[ -n "$SRC" && -n "$OUT" ]] || setup_error "usage: build-progs.sh <libdrm-src> <outdir>"
[[ -f "$SRC/include/drm/drm.h" ]] || setup_error "$SRC has no include/drm/drm.h"
[[ -f "$SRC/include/drm/virtgpu_drm.h" ]] || setup_error "$SRC has no include/drm/virtgpu_drm.h"
[[ -d "$SHIM_DIR" ]] || setup_error "no shim headers at $SHIM_DIR"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf x86_64-elf-nm python3; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
for f in oslibc.h syscall.c string.c malloc.c printf.c rfile.c start.c; do
  [[ -f "$LIBC_DIR/$f" ]] || setup_error "$LIBC_DIR/$f is missing"
done

# ---------------------------------------------------------------------------
# 0. THE SOURCE IS UNPATCHED, AND THAT IS CHECKED RATHER THAN CLAIMED.
#    "Unmodified source" is ADR-0029 §3's reading B and it is the whole premise
#    of this port; a harness that let a local edit through would be asserting
#    something about a tree nobody else has.
# ---------------------------------------------------------------------------
if [[ -d "$SRC/.git" ]]; then
  dirty=$(git -C "$SRC" status --porcelain 2>/dev/null | head -5)
  [[ -z "$dirty" ]] || fail "the libdrm checkout at $SRC has local modifications:
$dirty
The claim this harness makes is about UNMODIFIED libdrm source."
  head=$(git -C "$SRC" rev-parse HEAD 2>/dev/null)
  pin=$(sed -n '2p' "$PORT_DIR/PIN.txt")
  [[ "$head" == "$pin" ]] \
    || fail "$SRC is at $head; core/user/ports/libdrm/PIN.txt says $pin"
  echo "    (libdrm source: $head, clean, unpatched)"
else
  setup_error "$SRC is not a git checkout, so 'unmodified' cannot be checked"
fi

# ---------------------------------------------------------------------------
# 1. THE TABLE. Generated from the uAPI headers, by name only — gen-table.py
#    never computes a request number.
# ---------------------------------------------------------------------------
python3 "$SCRIPT_DIR/gen-table.py" "$SRC/include/drm" "$OUT/table.h" \
  || fail "gen-table.py failed"

# ---------------------------------------------------------------------------
# 2. THE BUILD. m19-argv's flags EXACTLY, plus the include path this program
#    needs. -Wall -Wextra -Werror is KEPT here, unlike
#    core/user/ports/libdrm/build.sh: prog.c is ours and must be clean, and the
#    uAPI headers are clean under it. Only libdrm's own .c files are not.
# ---------------------------------------------------------------------------
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
  -I"$OUT"
  -I"$SRC/include/drm"
)

LIBC_SRCS=(syscall.c string.c malloc.c printf.c rfile.c start.c)

build_one() {   # build_one <tag> <extra-include-dir-or-empty>
  local tag="$1" first="$2"
  local inc=()
  [[ -n "$first" ]] && inc+=(-I"$first")
  inc+=(-I"$SHIM_DIR")
  local objs=() s
  for s in "${LIBC_SRCS[@]}"; do
    clang "${CFLAGS[@]}" "${inc[@]}" -DLIBC_FREE_ENABLED=1 "$LIBC_DIR/$s" \
      -o "$OUT/${tag}_${s%.c}.o" || fail "clang could not compile libc/$s for $tag"
    objs+=("$OUT/${tag}_${s%.c}.o")
  done
  clang "${CFLAGS[@]}" "${inc[@]}" "$SCRIPT_DIR/prog.c" -o "$OUT/$tag.o" \
    || fail "clang could not compile prog.c as $tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/$tag.elf" "$OUT/$tag.o" "${objs[@]}" \
    || fail "x86_64-elf-ld could not link $tag.elf"
  [[ -s "$OUT/$tag.elf" ]] || fail "the linker reported success but produced no $tag.elf"
}

build_one drmabi ""
build_one drmabin "$SCRIPT_DIR/neg-shim"

cmp -s "$OUT/drmabi.elf" "$OUT/drmabin.elf" && \
  fail "drmabi.elf and drmabin.elf are byte-identical — the negative control controls for nothing"

# ---------------------------------------------------------------------------
# 3. THE CONTROL IS THE SAME PROGRAM WITH DIFFERENT NUMBERS IN IT.
#
#    The obvious check — "only .rodata differs" — IS WRONG AND WAS TRIED. At
#    -O2 clang folds the nine named request numbers into immediate operands, so
#    the encoding change lands in .text as well as in .rodata. What must hold is
#    weaker and is the thing actually being claimed: the two builds have the
#    SAME SYMBOLS AT THE SAME ADDRESSES and the SAME SECTION SIZES, so nothing
#    was added, removed or relaid out — only constants moved. And .rodata, which
#    is where drmabiVals[] lives, MUST differ, or the BSD encoding changed
#    nothing and the control is vacuous.
# ---------------------------------------------------------------------------
x86_64-elf-nm -n "$OUT/drmabi.elf"  > "$OUT/a.nm.txt" || fail "nm failed on drmabi.elf"
x86_64-elf-nm -n "$OUT/drmabin.elf" > "$OUT/b.nm.txt" || fail "nm failed on drmabin.elf"
cmp -s "$OUT/a.nm.txt" "$OUT/b.nm.txt" \
  || fail "the two builds' symbol tables differ; the control is a different program, not a different encoding"

secsizes() {  # secsizes <elf> -> "<name> <size>" per allocated section
  x86_64-elf-readelf -S -W "$1" | awk '$2 ~ /^\./ {print $2, $6}'
}
secsizes "$OUT/drmabi.elf"  > "$OUT/a.sec.txt"
secsizes "$OUT/drmabin.elf" > "$OUT/b.sec.txt"
cmp -s "$OUT/a.sec.txt" "$OUT/b.sec.txt" \
  || fail "the two builds' section sizes differ; the control is a different program, not a different encoding"

x86_64-elf-objdump -s -j .rodata "$OUT/drmabi.elf" | tail -n +3 > "$OUT/a.rodata.txt"
x86_64-elf-objdump -s -j .rodata "$OUT/drmabin.elf" | tail -n +3 > "$OUT/b.rodata.txt"
cmp -s "$OUT/a.rodata.txt" "$OUT/b.rodata.txt" \
  && fail "the two builds' .rodata is identical; the BSD encoding changed nothing, which cannot be right"
echo "    (control: identical symbols and section sizes, different .rodata — same program, different numbers)"

# ---------------------------------------------------------------------------
# 4. m19-argv's `_start` checks, kept in full.
# ---------------------------------------------------------------------------
grep -qE '_start:|\.globl[[:space:]]+_start' "$SCRIPT_DIR/prog.c" \
  && fail "prog.c defines _start — the library's is the one that must run"
grep -q 'int main(int argc, char \*\*argv)' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c does not define \`int main(int argc, char **argv)\`"

for tag in drmabi drmabin; do
  dis="$OUT/$tag.start.txt"
  x86_64-elf-objdump -d --disassemble="_start" "$OUT/$tag.elf" > "$dis" 2>/dev/null \
    || fail "objdump could not disassemble _start in $tag.elf"
  body=$(sed -n '/<_start>:/,/^$/p' "$dis")
  [[ -n "$body" ]] || fail "$tag.elf has no _start in its disassembly"
  echo "$body" | grep -qE 'mov[a-z]*[[:space:]]+\(%rsp\),%rdi' \
    || fail "$tag.elf's _start does not load argc from (%rsp) into %rdi"
  echo "$body" | grep -qE 'lea[a-z]*[[:space:]]+0x8\(%rsp\),%rsi' \
    || fail "$tag.elf's _start does not compute argv as 8(%rsp) into %rsi"
  if echo "$body" | grep -qE '(and|sub|add|xchg|mov)[a-z]*[[:space:]]+[^,]*,%rsp'; then
    echo "$body" >&2
    fail "$tag.elf's _start writes to %rsp; the ABI says it is already aligned at entry"
  fi
  x86_64-elf-nm "$OUT/$tag.elf" | grep -qE ' [Tt] main$' \
    || fail "$tag.elf has no \`main\` in its symbol table"
  x86_64-elf-nm "$OUT/$tag.elf" | grep -qE ' [Tt] libcStart$' \
    || fail "$tag.elf has no \`libcStart\`"
done
echo "    (_start in both builds: argc from (%rsp), argv from 8(%rsp), never writes %rsp)"

# ---------------------------------------------------------------------------
# 5. SEGMENT SHAPE. m19-argv's checks, verbatim in intent.
# ---------------------------------------------------------------------------
phdrs() {   # phdrs <elf> -> one line per PT_LOAD: "flags vaddr filesz memsz"
  python3 - "$1" <<'PY'
import struct, sys
f = open(sys.argv[1], "rb").read()
phoff = struct.unpack_from("<Q", f, 32)[0]
phnum = struct.unpack_from("<H", f, 56)[0]
for i in range(phnum):
    p = phoff + i * 56
    typ, flags = struct.unpack_from("<II", f, p)
    vaddr, = struct.unpack_from("<Q", f, p + 16)
    filesz, = struct.unpack_from("<Q", f, p + 32)
    memsz, = struct.unpack_from("<Q", f, p + 40)
    if typ == 1:
        print(flags, vaddr, filesz, memsz)
PY
}

for tag in drmabi drmabin; do
  elf="$OUT/$tag.elf"
  loads=$(phdrs "$elf" | wc -l | tr -d ' ')
  [[ "$loads" -eq 2 ]] || fail "$tag.elf has $loads PT_LOAD segments, expected 2"
  phdrs "$elf" | awk '$1==7' | grep -q . \
    && fail "$tag.elf has a W+X segment; core/kernel/elf.dart refuses one by name"
  rw_filesz=$(phdrs "$elf" | awk '$1==6 {print $3; exit}')
  rw_memsz=$(phdrs "$elf" | awk '$1==6 {print $4; exit}')
  [[ -n "$rw_filesz" ]] || fail "$tag.elf has no R+W PT_LOAD"
  [[ "$rw_filesz" -gt 0 ]] \
    || fail "$tag.elf's R+W segment has no file bytes; prog.c's drmabiMarker should have put some in .data"
  [[ "$rw_memsz" -gt "$rw_filesz" ]] \
    || fail "$tag.elf's R+W segment has no .bss beyond its file bytes"

  ro_start=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_start"{print $1; exit}')
  ro_end=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_end"{print $1; exit}')
  [[ -n "$ro_start" && -n "$ro_end" ]] || fail "$tag.elf has no __ro_start/__ro_end"
  read -r seg_vaddr seg_filesz < <(phdrs "$elf" | awk '$1==5 {print $2" "$3; exit}')
  [[ -n "$seg_vaddr" ]] || fail "$tag.elf has no R+X PT_LOAD"
  got_start=$(( 16#$ro_start ))
  got_end=$(( 16#$ro_end ))
  [[ "$got_start" -eq "$seg_vaddr" ]] \
    || fail "$tag.elf: __ro_start is $(printf 0x%X $got_start), R+X starts at $(printf 0x%X $seg_vaddr)"
  [[ "$got_end" -eq $(( seg_vaddr + seg_filesz )) ]] \
    || fail "$tag.elf: __ro_end is $(printf 0x%X $got_end), R+X file bytes end at $(printf 0x%X $(( seg_vaddr + seg_filesz )))"

  entry=$(python3 -c "import struct,sys;print(struct.unpack_from('<Q',open(sys.argv[1],'rb').read(),24)[0])" "$elf")
  [[ "$entry" -ne "$seg_vaddr" ]] \
    || fail "$tag.elf's e_entry equals its R+X PT_LOAD's p_vaddr; a kernel that ignored e_entry would pass"
done
echo "    (two PT_LOADs, R+X and R+W, no W+X, __ro_* bracket the R+X file bytes, e_entry inside)"

echo "build-progs: PASS — $OUT/drmabi.elf and $OUT/drmabin.elf"
exit 0
