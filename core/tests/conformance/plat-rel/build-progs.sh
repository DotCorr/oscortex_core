#!/usr/bin/env bash
# plat-rel: named platform ELF with PT_DYNAMIC + our LD.SO that applies RELA.
# Not glibc. Not libc.so.6.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir>"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-readelf x86_64-elf-nm; do
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

clang "${CFLAGS[@]}" "$SCRIPT_DIR/plat.c" -o "$OUT/plat.o" \
  || fail "clang could not compile plat.c"
x86_64-elf-ld -T "$SCRIPT_DIR/plat.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/plat.elf" "$OUT/plat.o" \
  || fail "x86_64-elf-ld could not link plat.elf"
[[ -s "$OUT/plat.elf" ]] || fail "linker reported success but produced no plat.elf"

clang "${CFLAGS[@]}" "$SCRIPT_DIR/nodyn.c" -o "$OUT/nodyn.o" \
  || fail "clang could not compile nodyn.c"
x86_64-elf-ld -T "$SCRIPT_DIR/nodyn.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/nodyn.elf" "$OUT/nodyn.o" \
  || fail "x86_64-elf-ld could not link nodyn.elf"
[[ -s "$OUT/nodyn.elf" ]] || fail "linker reported success but produced no nodyn.elf"

clang "${CFLAGS[@]}" "$SCRIPT_DIR/ld.c" -o "$OUT/ld.o" \
  || fail "clang could not compile ld.c"
x86_64-elf-ld -T "$SCRIPT_DIR/ld.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/ld.so" "$OUT/ld.o" \
  || fail "x86_64-elf-ld could not link ld.so"
[[ -s "$OUT/ld.so" ]] || fail "linker reported success but produced no ld.so"

x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "INTERP" \
  || fail "plat.elf has no PT_INTERP"
x86_64-elf-readelf -lW "$OUT/plat.elf" | grep -q "DYNAMIC" \
  || fail "plat.elf has no PT_DYNAMIC"
x86_64-elf-readelf -lW "$OUT/plat.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "plat.elf has a W+X segment"
x86_64-elf-readelf -h "$OUT/plat.elf" | grep -q "EXEC" \
  || fail "plat.elf is not ET_EXEC"

x86_64-elf-readelf -lW "$OUT/nodyn.elf" | grep -q "INTERP" \
  || fail "nodyn.elf has no PT_INTERP"
x86_64-elf-readelf -lW "$OUT/nodyn.elf" | grep -q "DYNAMIC" \
  && fail "nodyn.elf has PT_DYNAMIC — that image is the no-DYNAMIC path"
x86_64-elf-readelf -lW "$OUT/nodyn.elf" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "nodyn.elf has a W+X segment"

x86_64-elf-readelf -lW "$OUT/ld.so" | grep -q "INTERP" \
  && fail "ld.so has a PT_INTERP"
x86_64-elf-readelf -lW "$OUT/ld.so" | grep -q "DYNAMIC" \
  && fail "ld.so has PT_DYNAMIC — must not be glibc"
x86_64-elf-readelf -lW "$OUT/ld.so" | awk '$1=="LOAD"' | grep -q "RWE" \
  && fail "ld.so has a W+X segment"

INTERP_PATH=$(x86_64-elf-readelf -p .interp "$OUT/plat.elf" 2>/dev/null \
  | awk '/LD\.SO/{print $3; exit}')
[[ "$INTERP_PATH" == "LD.SO" ]] \
  || fail "plat.elf PT_INTERP is ${INTERP_PATH:-empty}, expected LD.SO"

python3 - "$OUT/plat.elf" <<'PY' || fail "plat.elf reloc_word is not zero in the file, or RELA is missing"
import struct, sys

data = open(sys.argv[1], "rb").read()
if data[:4] != b"\x7fELF":
    raise SystemExit("not ELF")
e_phoff = struct.unpack_from("<Q", data, 32)[0]
e_phentsize = struct.unpack_from("<H", data, 54)[0]
e_phnum = struct.unpack_from("<H", data, 56)[0]
dyn_va = None
loads = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
        struct.unpack_from("<IIQQQQQQ", data, off)
    if p_type == 1:
        loads.append((p_vaddr, p_offset, p_filesz))
    if p_type == 2:
        dyn_va = p_vaddr
if dyn_va is None:
    raise SystemExit("no PT_DYNAMIC")

def va_to_off(va):
    for vaddr, offset, filesz in loads:
        if vaddr <= va < vaddr + filesz:
            return offset + (va - vaddr)
    return None

dyn_off = va_to_off(dyn_va)
if dyn_off is None:
    raise SystemExit("DYNAMIC not in a LOAD")
rela = relasz = relaent = 24
i = dyn_off
while i + 16 <= len(data):
    tag, val = struct.unpack_from("<QQ", data, i)
    if tag == 0:
        break
    if tag == 7:
        rela = val
    if tag == 8:
        relasz = val
    if tag == 9:
        relaent = val
    i += 16
if relasz < 24 or relaent != 24:
    raise SystemExit("no RELA")
rela_off = va_to_off(rela)
if rela_off is None:
    raise SystemExit("RELA not in a LOAD")
r_offset, r_info, r_addend = struct.unpack_from("<QQQ", data, rela_off)
if (r_info & 0xFFFFFFFF) != 1:
    raise SystemExit("first RELA is not R_X86_64_64")
if (r_info >> 32) != 1:
    raise SystemExit("first RELA is not symbol 1")
word_off = va_to_off(r_offset)
if word_off is None:
    raise SystemExit("reloc target not in a LOAD")
word = struct.unpack_from("<Q", data, word_off)[0]
if word != 0:
    raise SystemExit("reloc_word in the file is 0x%X, not 0" % word)
print("reloc: R_X86_64_64 at 0x%X addend 0 (file word 0)" % r_offset)
PY

strings -a "$OUT/ld.so" | grep -q 'INTERP MAP' \
  || fail "ld.so lost INTERP MAP"
strings -a "$OUT/ld.so" | grep -q 'RELA OK' \
  || fail "ld.so lost RELA OK"
strings -a "$OUT/plat.elf" | grep -q 'DYN LINE' \
  || fail "plat.elf lost DYN LINE"
strings -a "$OUT/ld.so" | grep -q 'DYN LINE' \
  && fail "ld.so contains DYN LINE — derived write must come from the dyn"
strings -a "$OUT/plat.elf" | grep -q 'INTERP MAP' \
  && fail "plat.elf contains INTERP MAP — interp write must come from ld.so"
strings -a "$OUT/plat.elf" | grep -q 'RELA OK' \
  && fail "plat.elf contains RELA OK — apply write must come from ld.so"
strings -a "$OUT/nodyn.elf" | grep -q 'NOD LINE' \
  || fail "nodyn.elf lost NOD LINE"
strings -a "$OUT/ld.so" | grep -q 'NOD LINE' \
  && fail "ld.so contains NOD LINE"
# SIG lives in plat.elf's dynsym. LD.SO must not hardcode it.
python3 - "$OUT/ld.so" <<'PY' || fail "ld.so contains SIG — RELA would be vacuous"
import sys
data = open(sys.argv[1], "rb").read()
if b"\x01\x00\xde\xc0\x00\x00\x27\xa1" in data:
    raise SystemExit("SIG bytes in ld.so")
if b"A1270000C0DE0001" in data:
    raise SystemExit("SIG hex in ld.so")
PY

PBYTES=$(wc -c <"$OUT/plat.elf" | tr -d ' ')
NBYTES=$(wc -c <"$OUT/nodyn.elf" | tr -d ' ')
LBYTES=$(wc -c <"$OUT/ld.so" | tr -d ' ')
[[ "$PBYTES" -le 65536 ]] || fail "plat.elf is $PBYTES bytes — cap is 64 KiB"
[[ "$NBYTES" -le 65536 ]] || fail "nodyn.elf is $NBYTES bytes — cap is 64 KiB"
[[ "$LBYTES" -le 65536 ]] || fail "ld.so is $LBYTES bytes — cap is 64 KiB"
[[ "$LBYTES" -le 8192 ]] || fail "ld.so is $LBYTES bytes — a tiny loader, not glibc"

echo "build-progs: PASS — plat.elf $PBYTES (PT_INTERP+PT_DYNAMIC RELA), nodyn.elf $NBYTES, ld.so $LBYTES"
exit 0
