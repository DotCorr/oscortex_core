#!/usr/bin/env bash
# core/tests/conformance/nvm-root/run.sh
#
# NVM-root — NVMe and AHCI are equal fatDiskRead roots (ADR-0137).
# docs/decisions/0137-storage-class-is-the-fat-root.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# One derived PROG.ELF is written onto a FAT16 volume. The same image
# is attached once as QEMU `-device nvme` and once as `-device ahci`
# + ide-hd on ahci.0 (if=none, no PIIX3 disk). `ls` then `run prog.elf`
# must list that name and print the planted write + exit on BOTH
# backends. Those sectors move through fatDiskRead: NVMe via
# nvmeIoRead, AHCI via ahciIoRead. This boot has no IDE, so PIO
# cannot produce the plant.
#
# The file's cluster chain has a hole (nvm6 make-image.py). A reader
# that walks LBA+1, or that still reads A1/NVM3's LBA 7, cannot
# assemble a runnable ELF.
#
# Anti-vacuity: info pci on the NVMe boot must contain Class 0108;
# on the AHCI boot, Class 0106. Not a laptop vendor:device. The plant
# must not appear in elf/fat/nvme/ahci.dart. fatDiskRead must name
# nvmeIoRead, ahciIoRead, and ataReadInto. FAT NVME / FAT AHCI must
# print on the matching boot only.
#
# Negative: plain `-M pc` (no NVMe, no AHCI, no IDE) prints FS ERR 01
# and no FAT NVME / FAT AHCI / plant. NVMe off → no FAT NVME on the
# AHCI boot. AHCI off → no FAT AHCI on the NVMe boot.
#
# Coexistence: nvm0–nvm6 and A0/A1 stay the proofs they were.
# m6-disk / m14-fat stay on ATA PIO. No new syscall. 11 is fdwait.
# Not in help. No usb-kbd.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

fail() { echo "NVM-root: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NVM-root: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=66

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld \
            x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-nvm-root.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
NVME_SRC="$CORE_DIR/kernel/nvme.dart"
FAT_SRC="$CORE_DIR/kernel/fat.dart"
ELF_SRC="$CORE_DIR/kernel/elf.dart"
AHCI_SRC="$CORE_DIR/kernel/ahci.dart"
NVM6="$CORE_DIR/tests/conformance/nvm6"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
[[ -f "$NVME_SRC" ]] || setup_error "nvme.dart not found"
[[ -f "$FAT_SRC" ]] || setup_error "fat.dart not found"
[[ -f "$ELF_SRC" ]] || setup_error "elf.dart not found"
[[ -f "$AHCI_SRC" ]] || setup_error "ahci.dart not found"
[[ -f "$NVM6/build-prog.sh" ]] || setup_error "nvm6/build-prog.sh not found"
[[ -f "$NVM6/make-image.py" ]] || setup_error "nvm6/make-image.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

ck; grep -q "^part of 'kmain.dart';$" "$AHCI_SRC" \
  || fail "ahci.dart is not a part of kmain.dart"
ck; grep -q "^part 'ahci.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'ahci.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'ahci.dart';" ]] \
  || fail "part 'ahci.dart' is last in kmain.dart — D7 owns that position"
ck; [[ "$LAST_PART" != "part 'nvme.dart';" ]] \
  || fail "part 'nvme.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss$|final Bss ' "$AHCI_SRC" \
  || fail "ahci.dart declares a Bss — NVM-root takes the list from allocFrame"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — NVM-root added a help line"
ck; ! grep -q 'nvme' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM-root added an nvme syscall — the criterion forbids one"
ck; ! grep -q 'ahci' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "NVM-root added an ahci syscall — the criterion forbids one"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"

ck; grep -q 'u64 ahciIoRead(' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciIoRead — FAT would stay on ATA when NVMe is off"
ck; grep -q 'u64 ahciIoWrite(' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciIoWrite"
ck; grep -q 'u64 ahciIoSetup()' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciIoSetup"
ck; grep -q 'void ahciBuildIo(' "$AHCI_SRC" \
  || fail "ahci.dart has no ahciBuildIo — FAT would be stuck on LBA 7"
ck; grep -q 'ahciOpcWriteExt = 0x35' "$AHCI_SRC" \
  || fail "ahci.dart does not name WRITE DMA EXT 0x35"
ck; grep -q 'ahciClassStorage' "$AHCI_SRC" \
  || fail "ahci.dart lost the storage class constant"
ck; grep -q 'ahciSubclassSata' "$AHCI_SRC" \
  || fail "ahci.dart lost subclass 0x06"
ck; grep -q 'ahciProgIfAhci' "$AHCI_SRC" \
  || fail "ahci.dart lost prog-IF 0x01"
ck; grep -q 'nvmeClassStorage' "$NVME_SRC" \
  || fail "nvme.dart lost its class constant — the pick would be a SKU list"
ck; ! grep -qE 'ataReadInto|ataWriteFrom|ataSelect' "$AHCI_SRC" \
  || fail "ahci.dart calls ATA PIO — IDE is m6-disk's path"
ck; ! grep -qE 'nvmeFind|nvmeRead|nvmeWrite|nvmeIdentify|nvmeReport|nvmeIo' "$AHCI_SRC" \
  || fail "ahci.dart calls NVMe — the backends must stay separate arms"

ck; grep -q 'ahciFind()' "$FAT_SRC" \
  || fail "fatDiskPick does not call ahciFind — AHCI would not be a root"
ck; grep -q 'ahciIoSetup()' "$FAT_SRC" \
  || fail "fatDiskPick does not call ahciIoSetup"
ck; grep -q 'nvmeFind()' "$FAT_SRC" \
  || fail "fatDiskPick does not call nvmeFind"
ck; grep -q 'nvmeIoSetup()' "$FAT_SRC" \
  || fail "fatDiskPick does not call nvmeIoSetup"
ck; grep -q 'ahciIoRead' "$FAT_SRC" \
  || fail "fat.dart does not call ahciIoRead"
ck; grep -q 'nvmeIoRead' "$FAT_SRC" \
  || fail "fat.dart does not call nvmeIoRead"
ck; grep -q 'ataReadInto' "$FAT_SRC" \
  || fail "fat.dart no longer names ataReadInto — the ATA fallback is gone"
ck; grep -q 'return fatDiskRead(lba, dst);' "$ELF_SRC" \
  || fail "elfDiskRead is not fatDiskRead — the loader left the ABI"
ck; grep -q 'const int fatStoreBytes = 1824;' "$FAT_SRC" \
  || fail "fat_store is no longer 1824"
ck; grep -q 'const int fatDevAhci = 3;' "$FAT_SRC" \
  || fail "fatDevAhci is missing"
ck; grep -q 'const int fatMetaNvme = 31;' "$FAT_SRC" \
  || fail "fatMetaNvme is not spare word 31"

ck; python3 - "$FAT_SRC" <<'PY' || fail "fatDiskRead is not the three-arm class door"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 fatDiskRead\(u64 lba, u64 dst\) \{(.*)", src, re.S)
if not m:
    print("fatDiskRead is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nu64 ")[0]
need = (
    "nvmeIoRead(fatMeta(u64(fatMetaNvme)), lba, dst)",
    "ahciIoRead(fatMeta(u64(fatMetaNvme)), lba, dst)",
    "ataReadInto(lba, dst)",
    "fatDiskPick()",
)
for n in need:
    if n not in body:
        print("fatDiskRead missing %s" % n, file=sys.stderr)
        sys.exit(1)
PY

ck; python3 - "$FAT_SRC" <<'PY' || fail "fatDiskPick is not class-first"
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"u64 fatDiskPick\(\) \{(.*)", src, re.S)
if not m:
    print("fatDiskPick is missing", file=sys.stderr); sys.exit(1)
body = m.group(1).split("\n@bare")[0].split("\nu64 ")[0]
nv = body.find("nvmeFind()")
ah = body.find("ahciFind()")
if nv < 0 or ah < 0:
    print("fatDiskPick does not name both finds", file=sys.stderr); sys.exit(1)
if nv > ah:
    print("fatDiskPick looks at AHCI before NVMe — nvm5/nvm6 would flip", file=sys.stderr)
    sys.exit(1)
if "ahciIoSetup()" not in body or "nvmeIoSetup()" not in body:
    print("fatDiskPick does not set up both DMA sessions", file=sys.stderr)
    sys.exit(1)
PY

# Class is the match. A laptop vendor:device in the pick is a SKU.
ck; python3 - "$FAT_SRC" "$AHCI_SRC" "$NVME_SRC" <<'PY' || fail "pick is a SKU list, not class"
import sys
src = open(sys.argv[1]).read() + open(sys.argv[2]).read() + open(sys.argv[3]).read()
# Dell / OEM PCI identities must not be the pick. QEMU stand-ins
# already in A0/NVM0 (8086:2922, 1B36:0001, 1B36:0010) stay probes.
banned = ("0x1028", "0x1002", "DELL", "Ryzen", "Pro 14")
for b in banned:
    if b in src:
        print("storage pick names %r — class, not a SKU" % b, file=sys.stderr)
        sys.exit(1)
PY

FAT_STORE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="fatStore"{print $3+0; exit}')
ck; [[ "$FAT_STORE" -eq 1824 ]] || fail "fatStore is ${FAT_STORE:-missing} bytes, expected 1824"

BSS_AHCI=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /ahci/ {print $6}')
ck; [[ -z "$BSS_AHCI" ]] \
  || fail "kmain.o .bss contains $BSS_AHCI — NVM-root was not supposed to donate storage"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
EV_SIZE=$(bssfield wmeventStore 3)
EV_OFF=$(bssfield wmeventStore 2)
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
ck; [[ -n "$EV_OFF" ]] || fail "wmeventStore has no .bss offset in kmain.o"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss — NVM-root stole D7's slot"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"

capture_sh VERIFY_OUT VERIFY_STATUS -- 'cd "$CORE_DIR" && bash scripts/verify-freestanding.sh build/kmain.o'
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  fatDiskRead names NVMe+AHCI+ATA; class-first pick; no SKU; fat_store 1824; no new .bss; no help; no syscall"

echo
echo "=== DERIVE ==="
python3 - "$WORKDIR" "$ELF_SRC" "$NVME_SRC" "$FAT_SRC" "$AHCI_SRC" <<'PY' || setup_error "could not derive plant"
import os, sys
wd = sys.argv[1]
src = "".join(open(p, encoding="utf-8").read() for p in sys.argv[2:])
magic = os.urandom(16)
if magic == bytes(16):
    sys.exit("plant is all zeros")
hexmagic = magic.hex().upper()
if hexmagic.lower() in src.lower() or hexmagic in src:
    sys.exit("planted magic already appears in kernel sources")
exit_code = int.from_bytes(magic[:4], "big")
if exit_code == 0:
    sys.exit("derived exit is zero — vacuous")
open(os.path.join(wd, "plant.hex"), "w").write(hexmagic)
open(os.path.join(wd, "plant.exit"), "w").write("%08X" % exit_code)
print("DERIVE: MAGIC=%s EXIT=%08X" % (hexmagic, exit_code))
PY
ck; [[ -f "$WORKDIR/plant.hex" ]] || fail "no plant.hex after derive"
MAGIC=$(tr -d '\n' < "$WORKDIR/plant.hex")
EXIT_HEX=$(tr -d '\n' < "$WORKDIR/plant.exit")
ck; [[ ${#MAGIC} -eq 32 ]] || fail "plant is ${#MAGIC} hex chars, want 32"
ck; ! grep -Fqi "$MAGIC" "$ELF_SRC" || fail "plant appears in elf.dart"
ck; ! grep -Fqi "$MAGIC" "$NVME_SRC" || fail "plant appears in nvme.dart"
ck; ! grep -Fqi "$MAGIC" "$FAT_SRC" || fail "plant appears in fat.dart"
ck; ! grep -Fqi "$MAGIC" "$AHCI_SRC" || fail "plant appears in ahci.dart"

echo
echo "=== PROGRAM ==="
capture BUILD_P BP_STATUS -- bash "$NVM6/build-prog.sh" "$WORKDIR" prog "$MAGIC" "$EXIT_HEX"
echo "$BUILD_P"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-prog.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/prog.elf" ]] || fail "no prog.elf"
python3 "$NVM6/make-image.py" "$WORKDIR/plant.img" "$WORKDIR/prog.elf" \
  || fail "make-image.py could not write the volume"
ck; [[ -s "$WORKDIR/plant.img" ]] || fail "no plant.img"
ck; python3 - "$WORKDIR/plant.meta" <<'PY' || fail "image chain has no hole or landed on LBA 7"
import sys
meta = open(sys.argv[1]).read()
if "clus20_lba=7" in meta or "clus2_lba=7" in meta:
    print("a file cluster landed on LBA 7", file=sys.stderr); sys.exit(1)
if "data_start=" not in meta:
    print("missing data_start", file=sys.stderr); sys.exit(1)
PY

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys "ls"),ret,wait:1500,$(typekeys "run prog.elf"),ret,wait:8000"

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
echo "=== BOOT nvme (class 01/08/02) ==="
drive_session "$WORKDIR/nvme" "nvme" \
  -drive "file=$WORKDIR/plant.img,if=none,id=nvme0,format=raw,cache=writeback" \
  -device nvme,serial=nvmroot,drive=nvme0
echo
echo "=== BOOT ahci (class 01/06/01) ==="
drive_session "$WORKDIR/ahci" "ahci" \
  -drive "file=$WORKDIR/plant.img,if=none,id=ahci0,format=raw" \
  -device ahci,id=ahci \
  -device ide-hd,drive=ahci0,bus=ahci.0
echo
echo "=== BOOT default pc (both backends off) ==="
drive_session "$WORKDIR/none" "no-disk"

echo
echo "=== CRITERION ==="

check_run() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY' || return 1
import re, sys

serial = open(sys.argv[1], "rb").read()
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic = open(sys.argv[3], "r").read().strip().upper()
exit_hex = open(sys.argv[4], "r").read().strip().upper()
want_tag = sys.argv[5]
want_class = sys.argv[6]
fails = []
text = serial.decode("latin-1")

# QEMU 11's human `info pci` does not print PCI class 0108/0106.
# Anti-vacuity is the stand-in device line; the kernel pick remains
# class (nvmeFind / ahciFind). Not a Dell SKU.
if want_class == "0108":
    if not re.search(r"1b36:0010", info, re.I):
        fails.append("info pci has no 1b36:0010 — NVMe stand-in missing")
elif want_class == "0106":
    if not re.search(r"SATA controller:.*8086:2922", info, re.I):
        fails.append("info pci has no SATA 8086:2922 — AHCI stand-in missing")
else:
    fails.append("harness want_class %r is not 0108/0106" % want_class)
if magic == "0" * 32 or not magic:
    fails.append("planted magic is empty or all zeros — vacuous")

if want_tag not in text.splitlines() and (want_tag + "\n").encode("ascii") not in serial:
    fails.append("positive boot did not print %s — the other backend would also be silent" % want_tag)
other = "FAT AHCI" if want_tag == "FAT NVME" else "FAT NVME"
if other in text.splitlines() or (other + "\n").encode("ascii") in serial:
    fails.append("positive boot printed %s — that backend was off" % other)

if "FS ENT 00 NAME PROG    .ELF" not in text and "NAME PROG    .ELF" not in text:
    fails.append("ls did not list PROG.ELF — FAT list missed the plant")
if "FS OPEN PROG    .ELF" not in text and "FS OPEN PROG" not in text:
    fails.append("run did not open PROG.ELF")
if "ELF FILE PROG    .ELF" not in text and "ELF FILE PROG" not in text:
    fails.append("run did not print ELF FILE — the loader never took the named path")

want_write = "USER WRITE NVM6 " + magic
if want_write not in text:
    extra = [ln for ln in text.splitlines() if ln.startswith("USER WRITE ") or ln.startswith("ELF ") or ln.startswith("FS ") or ln.startswith("FAT ")]
    fails.append("missing %r" % want_write)
    if extra:
        fails.append("related lines: %r" % extra[:24])

want_exit = "USER EXIT CODE " + exit_hex.rjust(16, "0")
hits = [ln for ln in text.splitlines() if ln.startswith("USER EXIT CODE ")]
if not any(ln.startswith(want_exit) for ln in hits):
    fails.append("missing %s... (got %r)" % (want_exit, hits[-3:] if hits else []))

if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
print("    %s  listed PROG.ELF  USER WRITE NVM6 %s  EXIT %s" % (want_tag, magic, exit_hex.rjust(16, "0")))
PY
}

ck; check_run "$WORKDIR/nvme/serial.txt" "$WORKDIR/nvme/info-pci.txt" \
    "$WORKDIR/plant.hex" "$WORKDIR/plant.exit" "FAT NVME" "0108" \
  || fail "NVMe boot did not satisfy NVM-root"
echo "ASSERT: pass  NVMe class 01/08/02 lists and runs the planted ELF"

ck; check_run "$WORKDIR/ahci/serial.txt" "$WORKDIR/ahci/info-pci.txt" \
    "$WORKDIR/plant.hex" "$WORKDIR/plant.exit" "FAT AHCI" "0106" \
  || fail "AHCI boot did not satisfy NVM-root"
echo "ASSERT: pass  AHCI class 01/06/01 lists and runs the same planted ELF"

ck; python3 - "$WORKDIR/nvme/serial.txt" "$WORKDIR/ahci/serial.txt" \
    "$WORKDIR/plant.hex" "$WORKDIR/plant.exit" <<'PY' || fail "the two backends did not print the same plant"
import sys
nv = open(sys.argv[1], encoding="latin-1").read()
ah = open(sys.argv[2], encoding="latin-1").read()
magic = open(sys.argv[3]).read().strip().upper()
exit_hex = open(sys.argv[4]).read().strip().upper()
line = "USER WRITE NVM6 " + magic
ex = "USER EXIT CODE " + exit_hex.rjust(16, "0")
fails = []
if line not in nv or line not in ah:
    fails.append("backends disagree on the write plant")
if not any(ln.startswith(ex) for ln in nv.splitlines()) or not any(ln.startswith(ex) for ln in ah.splitlines()):
    fails.append("backends disagree on the exit plant")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  NVMe and AHCI printed the same derived write and exit"

ck; python3 - "$WORKDIR/none/serial.txt" "$WORKDIR/none/info-pci.txt" \
    "$WORKDIR/plant.hex" <<'PY' || fail "negative control did not hold"
import re, sys
serial = open(sys.argv[1], "rb").read()
info = open(sys.argv[2], "r", encoding="utf-8", errors="replace").read()
magic = open(sys.argv[3]).read().strip().upper()
text = serial.decode("latin-1")
fails = []
if re.search(r"Class\s+0108", info, re.I):
    fails.append("negative boot's info pci still has Class 0108")
if re.search(r"Class\s+0106", info, re.I):
    fails.append("negative boot's info pci still has Class 0106")
if b"FAT NVME" in serial:
    fails.append("negative boot printed FAT NVME — NVMe was off")
if b"FAT AHCI" in serial:
    fails.append("negative boot printed FAT AHCI — AHCI was off")
if "FS ERR 01" not in text:
    fails.append("negative boot did not print FS ERR 01 (boot sector unreadable)")
if "ELF FILE" in text:
    fails.append("negative boot printed ELF FILE — a load happened with no disk")
if "NAME PROG    .ELF" in text:
    fails.append("negative boot listed PROG.ELF with no disk")
writes = [ln for ln in text.splitlines() if ln.startswith("USER WRITE NVM6")]
if writes:
    fails.append("negative boot printed a program write: %r" % writes)
if magic in text:
    fails.append("negative boot serial contains the plant — that is a canned constant")
if fails:
    for f in fails:
        print("    - " + f, file=sys.stderr)
    sys.exit(1)
PY
echo "ASSERT: pass  both backends off → FS ERR 01; no FAT NVME / FAT AHCI / plant"

require_assertions "$ASSERTIONS_REQUIRED"
echo "NVM-root: PASS — same planted ELF lists and runs through NVMe class 01/08/02 and AHCI class 01/06/01; either backend off misses; ATA fallback stays for machines with neither"
exit 0
