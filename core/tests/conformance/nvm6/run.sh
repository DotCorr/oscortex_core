#!/usr/bin/env bash
# core/tests/conformance/nvm6/run.sh
#
# NVM6 — a named ELF loads through the NVMe I/O pair.
# docs/decisions/0092-a-named-elf-loads-through-nvme.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# A derived program is written onto a FAT16 volume attached as QEMU
# `-device nvme` with no IDE drive. `run prog.elf` loads it and prints
# a write string and exit code the harness planted at test time. Those
# image sectors move through fatDiskRead → nvmeIoRead: this boot has
# no IDE, so a PIO fallback cannot produce the plant.
#
# The file's cluster chain has a hole. Cluster 2 holds the first
# sector; the rest start at cluster 20. A reader that walks LBA+1, or
# that still reads NVM3's LBA 7, cannot assemble a runnable ELF. A
# second image must print its own plant, not the first.
#
# Anti-vacuity: QEMU info pci on the positive boot must contain
# 1b36:0010. The plant must not appear in elf.dart, fat.dart or
# nvme.dart. elfDiskRead must call fatDiskRead. elfReadSectors must
# not call ataReadInto. FAT NVME must print. Derived write/exit are
# not a kernel constant.
#
# Negative control: the same kernel on plain `-M pc` (no NVMe, no
# IDE disk) prints FS ERR 01 and no FAT NVME / ELF FILE / USER WRITE
# NVM6. info pci must lack 1b36:0010. The plant must not appear.
#
# Coexistence: NVM6 does not take m10-elf / m11-proc / m14-fat off
# ATA PIO. Those machines have no NVMe, so fatDiskPick chooses ATA.
# nvm0–nvm5 and both AHCI harnesses stay the proofs they were.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "NVM6: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM6: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=68

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld \
            x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm6.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
NVME_SRC="$CORE_DIR/kernel/nvme.dart"
FAT_SRC="$CORE_DIR/kernel/fat.dart"
ELF_SRC="$CORE_DIR/kernel/elf.dart"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$NVME_SRC" ]] || setup_error "nvme.dart not found"
[[ -f "$FAT_SRC" ]] || setup_error "fat.dart not found"
[[ -f "$ELF_SRC" ]] || setup_error "elf.dart not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$NVME_SRC" ]] || fail "core/kernel/nvme.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$NVME_SRC" \
  || fail "nvme.dart is not a part of kmain.dart"
ck; grep -q "^part 'nvme.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'nvme.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'nvme.dart';" ]] \
  || fail "part 'nvme.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$NVME_SRC" \
  || fail "nvme.dart declares a Bss — NVM6 takes queues from allocFrame"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM6 added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM6 added a syscall — the criterion forbids one"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; grep -q '| 26 | `spawn`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 26 is no longer spawn"

ck; grep -q 'u64 elfDiskRead(' "$ELF_SRC" \
  || fail "elf.dart has no elfDiskRead — the loader would still call ATA only"
ck; grep -q 'return fatDiskRead(lba, dst);' "$ELF_SRC" \
  || fail "elfDiskRead does not call fatDiskRead — not the same pick as FAT"
ck; ! grep -q 'ataReadInto' "$ELF_SRC" \
  || fail "elf.dart still calls ataReadInto — image sectors would stay on PIO"
ck; grep -q 'elfDiskRead(lba, buf)' "$ELF_SRC" \
  || fail "elfReadHeader does not call elfDiskRead"
ck; grep -q 'elfDiskRead(lba, buf + (i << u64(elfSectorShift)))' "$ELF_SRC" \
  || fail "elfReadSectors does not call elfDiskRead"
ck; grep -q 'u64 fatDiskRead(' "$FAT_SRC" \
  || fail "fat.dart has no fatDiskRead"
ck; grep -q 'nvmeIoRead' "$FAT_SRC" \
  || fail "fat.dart does not call nvmeIoRead"
ck; grep -q 'ataReadInto' "$FAT_SRC" \
  || fail "fat.dart no longer names ataReadInto — the ATA fallback is gone"
ck; grep -q 'nvmeFind()' "$FAT_SRC" \
  || fail "fatDiskPick does not call nvmeFind"
ck; grep -q 'u64 nvmeIoRead(' "$NVME_SRC" \
  || fail "nvme.dart has no nvmeIoRead"
ck; ! grep -qE 'ataRead|ataWrite|ataSelect' "$NVME_SRC" \
  || fail "nvme.dart calls ATA — IDE is m6-disk's path"
ck; ! grep -qE 'nvmeFind|nvmeRead|nvmeWrite|nvmeIdentify|nvmeReport|nvmeIo' "$CORE_DIR/kernel/ahci.dart" \
  || fail "ahci.dart calls NVMe — NVM6 was not supposed to edit the AHCI path"
ck; grep -q 'const int fatStoreBytes = 1824;' "$FAT_SRC" \
  || fail "fat_store is no longer 1824 — NVM6 was not supposed to grow it"
ck; grep -q 'const int fatMetaDev = 30;' "$FAT_SRC" \
  || fail "fatMetaDev is not spare word 30"
ck; grep -q 'const int fatMetaNvme = 31;' "$FAT_SRC" \
  || fail "fatMetaNvme is not spare word 31"

ck; python3 - "$ELF_SRC" <<'PY' || fail "elfDiskRead is not the FAT pick"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 elfDiskRead\(u64 lba, u64 dst\) \{(.*)", src, re.S)
if not m:
    print("elfDiskRead is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nu64 ")[0]
if "fatDiskRead(lba, dst)" not in body:
    print("elfDiskRead does not return fatDiskRead(lba, dst)", file=sys.stderr)
    sys.exit(1)
if "ataReadInto" in body:
    print("elfDiskRead still names ataReadInto", file=sys.stderr)
    sys.exit(1)
PY

ck; python3 - "$ELF_SRC" <<'PY' || fail "elfReadSectors still has a private ATA path"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 elfReadSectors\(u64 from, u64 n, u64 buf\) \{(.*)", src, re.S)
if not m:
    print("elfReadSectors is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nu64 ")[0]
if "elfDiskRead" not in body:
    print("elfReadSectors does not call elfDiskRead", file=sys.stderr)
    sys.exit(1)
if "ataReadInto" in body:
    print("elfReadSectors still calls ataReadInto", file=sys.stderr)
    sys.exit(1)
PY

FAT_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="fatStore"{print $3+0; exit}')
ck; [[ "$FAT_STORE" -eq 1824 ]] || fail "fatStore is ${FAT_STORE:-missing} bytes, expected 1824"

BSS_NVME=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /nvme/ {print $6}')
ck; [[ -z "$BSS_NVME" ]] \
  || fail "kmain.o .bss contains $BSS_NVME — NVM6 was not supposed to donate storage"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
EV_SIZE=$(bsssize wmeventStore)
EV_OFF=$(bssoff wmeventStore)
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
ck; [[ -n "$EV_OFF" ]] || fail "wmeventStore has no .bss offset in kmain.o"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — NVM6 stole D7's slot"

LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  elfDiskRead is fatDiskRead; no ataReadInto in elf.dart; fat_store 1824; no new .bss; wmeventStore last; no help; no syscall"

echo
echo "=== DERIVE ==="
python3 - "$WORKDIR" "$ELF_SRC" "$NVME_SRC" "$FAT_SRC" <<'PY' || setup_error "could not derive plants"
import os, sys
wd, elf_src, nvme_src, fat_src = sys.argv[1:5]
src = open(elf_src, encoding="utf-8").read() + open(nvme_src, encoding="utf-8").read() + open(fat_src, encoding="utf-8").read()

def one(name):
    magic = os.urandom(16)
    if magic == bytes(16):
        sys.exit("plant is all zeros")
    hexmagic = magic.hex().upper()
    if hexmagic.lower() in src.lower() or hexmagic in src:
        sys.exit("planted magic already appears in elf/fat/nvme.dart")
    exit_code = int.from_bytes(magic[:4], "big")
    if exit_code == 0:
        sys.exit("derived exit is zero — vacuous")
    open(os.path.join(wd, name + ".hex"), "w").write(hexmagic)
    open(os.path.join(wd, name + ".exit"), "w").write("%08X" % exit_code)
    return hexmagic, exit_code

a, ae = one("plantA")
b, be = one("plantB")
if a == b:
    sys.exit("the two plants collided")
if ae == be:
    sys.exit("the two exit codes collided")
print("DERIVE: plant A MAGIC=%s EXIT=%08X" % (a, ae))
print("DERIVE: plant B MAGIC=%s EXIT=%08X" % (b, be))
PY
ck; [[ -f "$WORKDIR/plantA.hex" ]] || fail "no plantA.hex after derive"
ck; [[ -f "$WORKDIR/plantB.hex" ]] || fail "no plantB.hex after derive"
MAGIC_A=$(tr -d '\n' < "$WORKDIR/plantA.hex")
MAGIC_B=$(tr -d '\n' < "$WORKDIR/plantB.hex")
EXIT_A=$(tr -d '\n' < "$WORKDIR/plantA.exit")
EXIT_B=$(tr -d '\n' < "$WORKDIR/plantB.exit")
ck; [[ ${#MAGIC_A} -eq 32 ]] || fail "plant A is ${#MAGIC_A} hex chars, want 32"
ck; [[ ${#MAGIC_B} -eq 32 ]] || fail "plant B is ${#MAGIC_B} hex chars, want 32"
ck; [[ "$MAGIC_A" != "$MAGIC_B" ]] || fail "plant A equals plant B — wrong-image would be vacuous"
ck; [[ "$EXIT_A" != "$EXIT_B" ]] || fail "exit A equals exit B — wrong-image would be vacuous"
ck; ! grep -Fqi "$MAGIC_A" "$ELF_SRC" \
  || fail "plant A $MAGIC_A appears in elf.dart — the expectation would not be coming from outside"
ck; ! grep -Fqi "$MAGIC_B" "$ELF_SRC" \
  || fail "plant B $MAGIC_B appears in elf.dart"
ck; ! grep -Fqi "$MAGIC_A" "$NVME_SRC" \
  || fail "plant A appears in nvme.dart"
ck; ! grep -Fqi "$MAGIC_B" "$NVME_SRC" \
  || fail "plant B appears in nvme.dart"
ck; ! grep -Fqi "$MAGIC_A" "$FAT_SRC" \
  || fail "plant A appears in fat.dart"
ck; ! grep -Fqi "$MAGIC_B" "$FAT_SRC" \
  || fail "plant B appears in fat.dart"

echo
echo "=== PROGRAMS ==="
capture BUILD_A BA_STATUS -- bash "$SCRIPT_DIR/build-prog.sh" "$WORKDIR" progA "$MAGIC_A" "$EXIT_A"
echo "$BUILD_A"
ck; [[ $BA_STATUS -eq 0 ]] || fail "build-prog.sh progA exited $BA_STATUS"
capture BUILD_B BB_STATUS -- bash "$SCRIPT_DIR/build-prog.sh" "$WORKDIR" progB "$MAGIC_B" "$EXIT_B"
echo "$BUILD_B"
ck; [[ $BB_STATUS -eq 0 ]] || fail "build-prog.sh progB exited $BB_STATUS"
ck; [[ -s "$WORKDIR/progA.elf" ]] || fail "no progA.elf"
ck; [[ -s "$WORKDIR/progB.elf" ]] || fail "no progB.elf"
ck; ! cmp -s "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" \
  || fail "progA.elf and progB.elf are byte-identical — two names would be one program"

python3 "$SCRIPT_DIR/make-image.py" "$WORKDIR/plantA.img" "$WORKDIR/progA.elf" \
  || fail "make-image.py could not write plant A"
python3 "$SCRIPT_DIR/make-image.py" "$WORKDIR/plantB.img" "$WORKDIR/progB.elf" \
  || fail "make-image.py could not write plant B"
ck; [[ -s "$WORKDIR/plantA.img" ]] || fail "no plantA.img"
ck; [[ -s "$WORKDIR/plantB.img" ]] || fail "no plantB.img"
ck; ! cmp -s "$WORKDIR/plantA.img" "$WORKDIR/plantB.img" \
  || fail "the two images are byte-identical"

ck; python3 - "$WORKDIR/plantA.meta" "$WORKDIR/plantB.meta" <<'PY' || fail "image chain has no hole or landed on LBA 7"
import sys
for path in sys.argv[1:]:
    meta = open(path).read()
    if "clus20_lba=7" in meta or "clus2_lba=7" in meta:
        print("%s put a file cluster on LBA 7" % path, file=sys.stderr)
        sys.exit(1)
    if "data_start=" not in meta:
        print("%s missing data_start" % path, file=sys.stderr)
        sys.exit(1)
PY

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys "run prog.elf"),ret,wait:8000"

drive_session() {
  local outdir="$1" label="$2"
  shift 2
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    "$@" \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for 'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt" \
    --keys "$KEYS"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status unexpectedly on the $label boot"
  fi
}

echo
echo "=== BOOT nvme plant A ==="
drive_session "$WORKDIR/bootA" "plant-A" \
  -drive "file=$WORKDIR/plantA.img,if=none,id=nvme0,format=raw,cache=writeback" \
  -device nvme,serial=nvm6a,drive=nvme0
echo
echo "=== BOOT nvme plant B (wrong image vs A) ==="
drive_session "$WORKDIR/bootB" "plant-B" \
  -drive "file=$WORKDIR/plantB.img,if=none,id=nvme0,format=raw,cache=writeback" \
  -device nvme,serial=nvm6b,drive=nvme0
echo
echo "=== BOOT default pc (negative) ==="
drive_session "$WORKDIR/none" "no-nvme"

echo
echo "=== CRITERION ==="

check_run() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY' || return 1
import re, sys

serial = open(sys.argv[1], "rb").read()
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic = open(sys.argv[3], "r").read().strip().upper()
other = open(sys.argv[4], "r").read().strip().upper()
exit_hex = open(sys.argv[5], "r").read().strip().upper()
other_exit = open(sys.argv[6], "r").read().strip().upper()
fails = []

text = serial.decode("latin-1")
if not re.search(r"1b36:0010", info, re.I):
    fails.append("QEMU info pci has no 1b36:0010 — this is not an nvme boot")
if magic == "0" * 32 or not magic:
    fails.append("planted magic is empty or all zeros — vacuous")
if magic == other:
    fails.append("this plant equals the other image — wrong-image is vacuous")

if b"FAT NVME\n" not in serial and "FAT NVME" not in text.splitlines():
    fails.append("positive boot did not print FAT NVME — ATA would also be silent")
if "NVME NONE" in text.splitlines():
    fails.append("positive boot printed NVME NONE — the device was attached")

if "FS OPEN PROG    .ELF" not in text and "FS OPEN PROG" not in text:
    fails.append("positive boot did not open PROG.ELF: missing FS OPEN")
if "ELF FILE PROG    .ELF" not in text and "ELF FILE PROG" not in text:
    fails.append("positive boot did not print ELF FILE — the loader never took the named path")

want_write = "USER WRITE NVM6 " + magic
if want_write not in text:
    extra = [ln for ln in text.splitlines() if ln.startswith("USER WRITE ") or ln.startswith("ELF ") or ln.startswith("FS ") or ln.startswith("FAT ")]
    fails.append("missing %r" % want_write)
    if extra:
        fails.append("related lines: %r" % extra[:24])
if ("USER WRITE NVM6 " + other) in text:
    fails.append("serial contains the other image's write plant")

want_exit = "USER EXIT CODE " + exit_hex.rjust(16, "0")
hits = [ln for ln in text.splitlines() if ln.startswith("USER EXIT CODE ")]
if not any(ln.startswith(want_exit) for ln in hits):
    fails.append("missing %s... (got %r)" % (want_exit, hits[-3:] if hits else []))
if any(other_exit.rjust(16, "0") in ln for ln in hits):
    fails.append("exit code equals the other image's plant")

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    USER WRITE NVM6 %s and EXIT %s" % (magic, exit_hex.rjust(16, "0")))
PY
}

ck; check_run "$WORKDIR/bootA/serial.txt" "$WORKDIR/bootA/info-pci.txt" \
    "$WORKDIR/plantA.hex" "$WORKDIR/plantB.hex" \
    "$WORKDIR/plantA.exit" "$WORKDIR/plantB.exit" \
  || fail "plant-A boot did not satisfy NVM6"
echo "ASSERT: pass  plant A run prints derived write+exit through NVMe"

ck; check_run "$WORKDIR/bootB/serial.txt" "$WORKDIR/bootB/info-pci.txt" \
    "$WORKDIR/plantB.hex" "$WORKDIR/plantA.hex" \
    "$WORKDIR/plantB.exit" "$WORKDIR/plantA.exit" \
  || fail "plant-B boot did not satisfy NVM6 (wrong image vs A)"
echo "ASSERT: pass  plant B run equals image B and does not equal image A"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" \
    "$WORKDIR/plantA.hex" "$WORKDIR/plantB.hex" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read()
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic_a = open(sys.argv[3]).read().strip().upper()
magic_b = open(sys.argv[4]).read().strip().upper()
text = serial.decode("latin-1")
fails = []
if re.search(r"1b36:0010", info, re.I):
    fails.append("negative boot's info pci still has 1b36:0010 — this is not plain -M pc")
if b"FAT NVME" in serial:
    fails.append("negative boot printed FAT NVME — there is no NVMe")
if "FS ERR 01" not in text:
    fails.append("negative boot did not print FS ERR 01 (boot sector unreadable)")
if "ELF FILE" in text:
    fails.append("negative boot printed ELF FILE — a load happened with no disk")
writes = [ln for ln in text.splitlines() if ln.startswith("USER WRITE NVM6")]
if writes:
    fails.append("negative boot printed a program write: %r" % writes)
if magic_a in text or magic_b in text:
    fails.append("negative boot serial contains a plant — that is a canned constant")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  plain -M pc prints FS ERR 01 and no FAT NVME / no plant"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM6: PASS — run prog.elf on an NVMe FAT volume prints derived write+exit; a second image prints its own; plain -M pc is FS ERR 01; ATA fallback stays for machines with no NVMe"
exit 0
