#!/usr/bin/env bash
# core/tests/conformance/de-browse/build-progs.sh
#
# Builds BROWSE.ELF (data: PAGE) and NONE.ELF (--no-init) against
# osframe.h + oschrome_guest.c + official linux64 cef_initialize.
# The address of the surface comes from wmsurface(WM_OP_ATTACH).
#
# Usage: build-progs.sh <outdir> <kerneldir>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_DIR="$CORE_DIR/user/frame"
CHROME_DIR="$CORE_DIR/plat/chrome"
SRC="$FRAME_DIR/browse.c"
GUEST="$CHROME_DIR/oschrome_guest.c"
CEF_C="$CHROME_DIR/oschrome_cef.c"
EXTRACT="$CORE_DIR/scripts/extract-cef-guest.sh"

fail() { echo "build-progs: FAIL — $1" >&2; exit 1; }
setup_error() { echo "build-progs: FAIL — $1" >&2; exit 2; }

OUT="${1:-}"
KERNEL_DIR="${2:-}"
[[ -n "$OUT" ]] || setup_error "usage: build-progs.sh <outdir> <kerneldir>"
[[ -d "$KERNEL_DIR" ]] || setup_error "no kernel sources at $KERNEL_DIR"
[[ -f "$SRC" ]] || setup_error "no browse.c at $SRC"
[[ -f "$GUEST" ]] || setup_error "no oschrome_guest.c at $GUEST"
[[ -f "$CEF_C" ]] || setup_error "no oschrome_cef.c at $CEF_C"
[[ -f "$EXTRACT" ]] || setup_error "no extract-cef-guest.sh at $EXTRACT"
[[ -f "$FRAME_DIR/osframe.h" ]] || setup_error "no osframe.h at $FRAME_DIR"
[[ -f "$CHROME_DIR/oschrome.h" ]] || setup_error "no oschrome.h at $CHROME_DIR"
mkdir -p "$OUT" || setup_error "could not create $OUT"

for tool in clang x86_64-elf-ld x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-nm python3; do
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
  -I"$FRAME_DIR"
  -I"$CHROME_DIR"
)

bash "$EXTRACT" "$OUT/cef_initialize" \
  || fail "extract-cef-guest.sh could not produce official cef_initialize.o"
[[ -s "$OUT/cef_initialize.o" ]] || fail "no official cef_initialize.o"

clang "${CFLAGS[@]}" "$GUEST" -o "$OUT/oschrome_guest.o" \
  || fail "clang could not compile oschrome_guest.c"
clang "${CFLAGS[@]}" "$CEF_C" -o "$OUT/oschrome_cef.o" \
  || fail "clang could not compile oschrome_cef.c"
clang "${CFLAGS[@]}" "$SRC" -o "$OUT/browse.o" \
  || fail "clang could not compile browse.c"
clang "${CFLAGS[@]}" -DBROWSE_NO_INIT "$SRC" -o "$OUT/none.o" \
  || fail "clang could not compile browse.c -DBROWSE_NO_INIT"

x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/browse.elf" "$OUT/browse.o" "$OUT/oschrome_guest.o" \
     "$OUT/oschrome_cef.o" "$OUT/cef_initialize.o" \
  || fail "x86_64-elf-ld could not link browse.elf"
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/none.elf" "$OUT/none.o" "$OUT/oschrome_guest.o" \
     "$OUT/oschrome_cef.o" "$OUT/cef_initialize.o" \
  || fail "x86_64-elf-ld could not link none.elf"
[[ -s "$OUT/browse.elf" ]] || fail "linker reported success but produced no browse.elf"
[[ -s "$OUT/none.elf" ]] || fail "linker reported success but produced no none.elf"

# Anti-vacuity: browse.o without oschrome_guest.o cannot resolve the ABI.
if x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
     -o "$OUT/browse-nosym.elf" "$OUT/browse.o" 2>"$OUT/browse-nosym.err"; then
  fail "browse.o linked without oschrome_guest.o — the client does not call the ABI"
fi
rm -f "$OUT/browse-nosym.elf"

# Anti-vacuity: stub-only (guest painter, no official CEF object) has
# no cef_ symbol. The rgb parser alone is not Chromium.
x86_64-elf-ld -T "$SCRIPT_DIR/prog.ld" -z max-page-size=0x1000 --build-id=none \
  -o "$OUT/browse-stub.elf" "$OUT/browse.o" "$OUT/oschrome_guest.o" \
  || fail "stub-only browse+guest failed to link"
STUB_NM="$(x86_64-elf-nm "$OUT/browse-stub.elf")"
if echo "$STUB_NM" | grep -E 'cef_|CefInitialize|cef_initialize' >/dev/null; then
  fail "stub-only browse.elf has a cef_ symbol — official extract was not required"
fi
rm -f "$OUT/browse-stub.elf"

python3 - "$OUT/browse.elf" "$OUT/none.elf" "$SRC" "$GUEST" "$KERNEL_DIR/vm.dart" "$CEF_C" <<'PY' \
  || fail "the program that was built is not the one this harness needs"
import re, subprocess, sys

elf, none, src, guest, vmdart, cefc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
text = open(src).read()
gtext = open(guest).read()
fails = []

if '#include "osframe.h"' not in text:
    fails.append("browse.c does not include osframe.h")
if '#include "oschrome.h"' not in text:
    fails.append("browse.c does not include oschrome.h")
if "oslibc.h" in text:
    fails.append("browse.c includes oslibc.h — BROWSE numbers live in osframe.h")
hand = re.findall(r"^#define\s+SYS_[A-Z0-9_]+\s+\d+", text, re.M)
if hand:
    fails.append("browse.c copies SYS_* by hand: %s" % hand)
if "SYS_FDWAIT" in text:
    fails.append("browse.c names SYS_FDWAIT — 11 stays reserved")
if "oschrome_load_url" not in text:
    fails.append("browse.c does not call oschrome_load_url")
if "oschrome_default_data_url" not in text:
    fails.append("browse.c does not load the default data: URL")
if "oschrome_pixel" not in text:
    fails.append("browse.c does not read oschrome_pixel")
if "parse_rgb" not in gtext:
    fails.append("oschrome_guest.c has no parse_rgb — a PAGE fill that ignores the URL")
if "rgb(" not in gtext:
    fails.append("oschrome_guest.c does not look for rgb(")
if "CefInitialize" in gtext:
    fails.append("oschrome_guest.c names CefInitialize — that is the Mac .mm")
if "cef_initialize" in gtext:
    fails.append("oschrome_guest.c defines or names cef_initialize — that is the official extract")
ctext = open(cefc).read()
if "int cef_initialize" in ctext and "{" in ctext.split("int cef_initialize", 1)[1].split(";")[0]:
    fails.append("oschrome_cef.c defines cef_initialize — official extract must own the body")
if "cef_initialize" not in ctext:
    fails.append("oschrome_cef.c does not reference cef_initialize")
if re.search(r"guest OS", text, re.I) or re.search(r"guest OS", gtext, re.I):
    fails.append("browse/oschrome_guest says guest OS")
if re.search(r"Flutter", text, re.I):
    fails.append("browse.c names Flutter")

def syscall_nums(path):
    dis = subprocess.run(["x86_64-elf-objdump", "-d", path],
                         capture_output=True, text=True).stdout
    nums = set()
    prev_imm = None
    for line in dis.splitlines():
        m = re.search(r"mov\s+\$0x([0-9a-f]+),%eax", line)
        if m:
            prev_imm = int(m.group(1), 16)
        if re.search(r"xor\s+%eax,%eax", line):
            prev_imm = 0
        if "int" in line and "$0x80" in line:
            if prev_imm is None:
                fails.append("%s: int $0x80 with no load of %%eax" % path)
            else:
                nums.add(prev_imm)
    return nums, dis

want = {0, 1, 3, 16, 23, 24, 25}
nums, dis = syscall_nums(elf)
extra = nums - want
missing = want - nums
if extra:
    fails.append("BROWSE issues unexpected syscall(s) %s" % sorted(extra))
if missing:
    fails.append("BROWSE is missing syscall(s) %s — need exit/write/yield/"
                 "shmcreate/wmsurface/kbdevent/wmevent" % sorted(missing))
if 11 in nums:
    fails.append("BROWSE issues syscall 11 — fdwait is reserved")

nm = subprocess.run(["x86_64-elf-nm", elf], capture_output=True, text=True).stdout
if "oschrome_backend_chromium" not in nm:
    fails.append("browse.elf has no oschrome_backend_chromium")
if "oschrome_load_url" not in nm:
    fails.append("browse.elf has no oschrome_load_url")
if "cef_initialize" not in nm:
    fails.append("browse.elf has no cef_initialize — official linux64 CEF was not linked")
if not re.search(r"\b[Tt]\s+cef_initialize\b", nm):
    fails.append("browse.elf cef_initialize is not a defined text symbol")
nmn = subprocess.run(["x86_64-elf-nm", none], capture_output=True, text=True).stdout
if "oschrome_backend_chromium" not in nmn:
    fails.append("none.elf has no oschrome_backend_chromium — no-init must stay linked")
if "cef_initialize" not in nmn:
    fails.append("none.elf dropped cef_initialize")

code = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
code = re.sub(r"//[^\n]*", " ", code)
vm = open(vmdart).read()
mb = re.search(r"const int vmShmBase = (0x[0-9A-Fa-f]+);", vm)
if not mb:
    fails.append("could not read vmShmBase out of vm.dart")
else:
    base = int(mb.group(1), 16)
    lits = re.findall(r"0[xX]([0-9A-Fa-f]+)", code)
    if any(int(l, 16) == base for l in lits):
        fails.append("browse.c contains the literal 0x%X — vmShmBase" % base)

for name in ("SYS_YIELD", "SYS_KBDEVENT", "SYS_WMEVENT", "SYS_WMSURFACE"):
    if name not in text:
        fails.append("browse.c has no %s" % name)
if "for (;;)" not in text and "for(;;)" not in text:
    fails.append("browse.c has no forever loop")
if "volatile" not in text:
    fails.append("browse.c has no volatile")
if "volatile u32 *p" not in text:
    fails.append("the paint pointer is not volatile")

rel = subprocess.run(["x86_64-elf-readelf", "-rW", elf],
                     capture_output=True, text=True).stdout
if "R_X86_64" in rel:
    fails.append("browse.elf carries dynamic relocations")

hdr = subprocess.run(["x86_64-elf-readelf", "-lW", elf],
                     capture_output=True, text=True).stdout
if "INTERP" in hdr:
    fails.append("browse.elf has a PT_INTERP")
if re.search(r"LOAD.*RWE", hdr):
    fails.append("browse.elf has a W+X segment")
loads = re.findall(
    r"LOAD\s+0x[0-9a-f]+ 0x([0-9a-f]+) 0x[0-9a-f]+ 0x([0-9a-f]+) 0x([0-9a-f]+) (R E|RW )",
    hdr)
if len(loads) != 2:
    fails.append("expected exactly two PT_LOAD segments, found %d" % len(loads))
else:
    (rxva, rxf, rxm, rxfl), (rwva, rwf, rwm, rwfl) = loads
    if rxfl.strip() != "R E":
        fails.append("the first PT_LOAD is %r, expected R E" % rxfl)
    if rwfl.strip() != "RW":
        fails.append("the second PT_LOAD is %r, expected RW" % rwfl)
    if int(rwf, 16) == 0:
        fails.append("the RW segment has p_filesz 0 — .data was optimised away")
    if int(rwm, 16) <= int(rwf, 16):
        fails.append("the RW segment has no zero tail (p_memsz %s <= p_filesz %s)"
                     % (rwm, rwf))

nbytes = __import__("os").path.getsize(elf)
if nbytes > 65536:
    fails.append("browse.elf is %d bytes; elfImageMax is 65536" % nbytes)
n2 = __import__("os").path.getsize(none)
if n2 > 65536:
    fails.append("none.elf is %d bytes; elfImageMax is 65536" % n2)

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("build-progs: PASS — browse.elf (%d bytes) none.elf (%d bytes) "
      "oschrome_backend_chromium + cef_initialize, syscalls %s"
      % (nbytes, n2, sorted(nums)))
PY
