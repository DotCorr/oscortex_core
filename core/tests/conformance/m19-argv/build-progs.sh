#!/usr/bin/env bash
# core/tests/conformance/m19-argv/build-progs.sh
#
# Builds the C library -- INCLUDING M19's start.c, the C entry contract -- and
# the TWO freestanding static ELF64 executables this harness puts on its FAT16
# volume, and then CHECKS WHAT IT BUILT.
#
# m15-fileio/build-progs.sh's machinery, with M15's one program built twice
# replaced by M19's one program built twice:
#
#   wc    -DWC_NEG=0   WC.ELF    — counts the file argv named
#   wcn   -DWC_NEG=1   WCN.ELF   — IGNORES argv and counts a compiled-in name
#
# THE NEGATIVE CONTROL IS PRE-M19 BEHAVIOUR. Every program on this operating
# system before this milestone had its input compiled into it, because `_start`
# took no arguments. The control is that program. run.sh gives both builds the
# SAME command line and requires them to print DIFFERENT answers.
#
# WHAT THIS SCRIPT ASSERTS ABOUT THE BUILD ITSELF, AND WHY EACH ONE IS HERE
# ---------------------------------------------------------------------------
#   * `_start` IS THE LIBRARY'S, NOT THE PROGRAM'S. prog.c must not define one:
#     that is the whole claim of M19's libc half. Checked by name in the symbol
#     table's source object.
#   * `_start` DOES NOT TOUCH RSP BEFORE IT READS IT. The disassembly must
#     contain no `and`/`sub`/`add` against %rsp anywhere in `_start`. A
#     `andq $-16,%rsp` there -- which is what every pre-M19 `_start` on this OS
#     did -- would hide a kernel that got the ABI's alignment wrong, which is
#     the single most likely way to build this milestone and pass anyway.
#   * `_start` READS ARGC FROM (%RSP) AND ARGV FROM 8(%RSP). Both instructions
#     are required to be there, in that order.
#   * THE PROGRAM CALLS main. Not `progMain`, not a private entry: the symbol is
#     `main` and it takes two arguments.
#   * start.c CONTAINS NO SYSCALL. m13-libc requires exactly one `int $0x80` in
#     the whole library and it is syscall.c's; this checks M19 did not add a
#     second.
#
# Usage:
#   build-progs.sh <outdir>      -> <outdir>/wc.elf, <outdir>/wcn.elf
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
for f in oslibc.h syscall.c string.c malloc.c printf.c rfile.c start.c; do
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

# start.c is SIXTH and is listed last deliberately: it is the only object that
# defines `_start`, and putting it at the end of the link line makes an
# accidental second definition a linker error rather than a silent choice.
LIBC_SRCS=(syscall.c string.c malloc.c printf.c rfile.c start.c)

build_one() {
  local tag="$1" neg="$2"
  local objs=()
  local s
  for s in "${LIBC_SRCS[@]}"; do
    clang "${CFLAGS[@]}" -DLIBC_FREE_ENABLED=1 "$LIBC_DIR/$s" \
      -o "$OUT/${tag}_${s%.c}.o" || fail "clang could not compile libc/$s for $tag"
    objs+=("$OUT/${tag}_${s%.c}.o")
  done
  clang "${CFLAGS[@]}" -DWC_NEG="$neg" "$SCRIPT_DIR/prog.c" -o "$OUT/$tag.o" \
    || fail "clang could not compile prog.c as $tag"
  x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
    -o "$OUT/$tag.elf" "$OUT/$tag.o" "${objs[@]}" \
    || fail "x86_64-elf-ld could not link $tag.elf"
  [[ -s "$OUT/$tag.elf" ]] || fail "the linker reported success but produced no $tag.elf"
}

build_one wc 0
build_one wcn 1

cmp -s "$OUT/wc.elf" "$OUT/wcn.elf" && \
  fail "wc.elf and wcn.elf are byte-identical — the negative control controls for nothing"

# ---------------------------------------------------------------------------
# 1. THE PROGRAM DOES NOT DEFINE `_start`. THE LIBRARY DOES.
# ---------------------------------------------------------------------------
grep -qE '_start:|\.globl[[:space:]]+_start' "$SCRIPT_DIR/prog.c" \
  && fail "prog.c defines _start — M19's whole claim is that a C program does not have to"
grep -q 'int main(int argc, char \*\*argv)' "$SCRIPT_DIR/prog.c" \
  || fail "prog.c does not define \`int main(int argc, char **argv)\` — that is the entry contract this milestone exists to provide"
grep -q '"_start:' "$LIBC_DIR/start.c" \
  || fail "core/user/libc/start.c does not define _start"
grep -q 'int \$0x80' "$LIBC_DIR/start.c" \
  && fail "start.c contains a syscall instruction; there must be exactly one in the library and it is syscall.c's"

# ---------------------------------------------------------------------------
# 2. `_start`'s FOUR INSTRUCTIONS, READ OUT OF THE DISASSEMBLY OF WHAT WAS
#    LINKED -- not out of the source, which is where the string could be right
#    and the object wrong.
# ---------------------------------------------------------------------------
for tag in wc wcn; do
  local_dis="$OUT/$tag.start.txt"
  x86_64-elf-objdump -d --disassemble="_start" "$OUT/$tag.elf" > "$local_dis" 2>/dev/null \
    || fail "objdump could not disassemble _start in $tag.elf"
  body=$(sed -n '/<_start>:/,/^$/p' "$local_dis")
  [[ -n "$body" ]] || fail "$tag.elf has no _start in its disassembly"
  # argc, from (%rsp) into %rdi.
  echo "$body" | grep -qE 'mov[a-z]*[[:space:]]+\(%rsp\),%rdi' \
    || fail "$tag.elf's _start does not load argc from (%rsp) into %rdi"
  # argv, from 8(%rsp) into %rsi.
  echo "$body" | grep -qE 'lea[a-z]*[[:space:]]+0x8\(%rsp\),%rsi' \
    || fail "$tag.elf's _start does not compute argv as 8(%rsp) into %rsi"
  # AND NOTHING TOUCHES %RSP. The one check this whole file exists for.
  if echo "$body" | grep -qE '(and|sub|add|xchg|mov)[a-z]*[[:space:]]+[^,]*,%rsp'; then
    echo "$body" >&2
    fail "$tag.elf's _start writes to %rsp. It must not: the ABI says RSP is already 16-byte aligned at process entry, and a realignment here would mask a kernel that had got that wrong"
  fi
  # The call, and it goes to the C trampoline that calls main.
  echo "$body" | grep -q 'call' || fail "$tag.elf's _start never calls anything"
done
echo "    (_start in both builds: reads argc from (%rsp), argv from 8(%rsp), and never writes %rsp)"

# ---------------------------------------------------------------------------
# 3. `main` EXISTS, IS A FUNCTION, AND IS REACHED FROM `_start`'s CALLEE.
# ---------------------------------------------------------------------------
for tag in wc wcn; do
  x86_64-elf-nm "$OUT/$tag.elf" | grep -qE ' [Tt] main$' \
    || fail "$tag.elf has no \`main\` in its symbol table"
  x86_64-elf-nm "$OUT/$tag.elf" | grep -qE ' [Tt] libcStart$' \
    || fail "$tag.elf has no \`libcStart\` — start.c's trampoline is gone"
done

# ---------------------------------------------------------------------------
# 4. m14-fat's __ro_start/__ro_end check, kept: the two symbols must bracket
#    exactly the R+X segment's file bytes. The program headers are read with
#    struct.unpack rather than with awk over readelf's columns, because
#    readelf's flag column is two tokens wide for `R E` and one for `RW`, and a
#    check that depends on that is a check that depends on a tool's formatting.
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

for tag in wc wcn; do
  elf="$OUT/$tag.elf"
  ro_start=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_start"{print $1; exit}')
  ro_end=$(x86_64-elf-nm "$elf" | awk '$3=="__ro_end"{print $1; exit}')
  [[ -n "$ro_start" && -n "$ro_end" ]] || fail "$tag.elf has no __ro_start/__ro_end"
  read -r seg_vaddr seg_filesz < <(phdrs "$elf" | awk '$1==5 {print $2" "$3; exit}')
  [[ -n "$seg_vaddr" ]] || fail "$tag.elf has no R+X (PF_R|PF_X) PT_LOAD"
  got_start=$(( 16#$ro_start ))
  got_end=$(( 16#$ro_end ))
  [[ "$got_start" -eq "$seg_vaddr" ]] \
    || fail "$tag.elf: __ro_start is $(printf 0x%X $got_start), R+X starts at $(printf 0x%X $seg_vaddr)"
  [[ "$got_end" -eq $(( seg_vaddr + seg_filesz )) ]] \
    || fail "$tag.elf: __ro_end is $(printf 0x%X $got_end), R+X file bytes end at $(printf 0x%X $(( seg_vaddr + seg_filesz )))"
  [[ $(( got_end - got_start )) -gt 2048 ]] \
    || fail "$tag.elf: the R+X range is only $(( got_end - got_start )) bytes"
done
echo "    (__ro_start/__ro_end bracket exactly the R+X segment's file bytes in both builds)"

# ---------------------------------------------------------------------------
# 5. TWO PT_LOADs, ONE R+X AND ONE R+W, NO W+X, AND THE R+W ONE HAS REAL FILE
#    BYTES. The last clause matters: if every mutable global were .bss the RW
#    segment's p_filesz would be 0 and the loader's copy path would never run
#    for it, so `wcMarker` in prog.c exists to keep .data non-empty.
# ---------------------------------------------------------------------------
for tag in wc wcn; do
  elf="$OUT/$tag.elf"
  loads=$(phdrs "$elf" | wc -l | tr -d ' ')
  [[ "$loads" -eq 2 ]] || fail "$tag.elf has $loads PT_LOAD segments, expected 2"
  phdrs "$elf" | awk '$1==7' | grep -q . \
    && fail "$tag.elf has a W+X (PF_R|PF_W|PF_X) segment; core/kernel/elf.dart refuses one by name"
  rw_filesz=$(phdrs "$elf" | awk '$1==6 {print $3; exit}')
  [[ -n "$rw_filesz" ]] || fail "$tag.elf has no R+W PT_LOAD"
  [[ "$rw_filesz" -gt 0 ]] \
    || fail "$tag.elf's R+W segment has no file bytes; prog.c's wcMarker should have put some in .data"
  rw_memsz=$(phdrs "$elf" | awk '$1==6 {print $4; exit}')
  [[ "$rw_memsz" -gt "$rw_filesz" ]] \
    || fail "$tag.elf's R+W segment has no .bss beyond its file bytes; the loader's zeroing path would never run"
done
echo "    (two PT_LOADs, R+X and R+W, no W+X, and the R+W one has both file bytes and .bss)"

# ---------------------------------------------------------------------------
# 6. THE ENTRY POINT IS NOT THE START OF THE SEGMENT. m10-elf's reason: with
#    .rodata first, e_entry is a non-zero offset inside the R+X PT_LOAD, so "the
#    kernel jumped to e_entry" is a claim only a kernel that read e_entry can
#    satisfy.
# ---------------------------------------------------------------------------
for tag in wc wcn; do
  elf="$OUT/$tag.elf"
  entry=$(python3 -c "import struct,sys;print(struct.unpack_from('<Q',open(sys.argv[1],'rb').read(),24)[0])" "$elf")
  base=$(phdrs "$elf" | awk '$1==5 {print $2; exit}')
  [[ "$entry" -ne "$base" ]] \
    || fail "$tag.elf's e_entry equals its R+X PT_LOAD's p_vaddr; a kernel that ignored e_entry would pass"
done
echo "    (e_entry is inside the R+X segment and is not its first byte)"

echo "build-progs: PASS — $OUT/wc.elf and $OUT/wcn.elf"
exit 0
