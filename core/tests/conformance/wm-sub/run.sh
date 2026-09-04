#!/usr/bin/env bash
# core/tests/conformance/wm-sub/run.sh — ADR-0184 subsurfaces.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"
fail() { echo "WM-sub: FAIL — $1" >&2; exit 1; }
setup_error() { echo "WM-sub: FAIL — $1" >&2; exit 2; }
source "$SCRIPT_DIR/../_lib/harness.sh"
export OSGFX_SKIA=0 OSGFX_CRT=0 OSMEDIA_FFMPEG=0
ASSERTIONS_REQUIRED=24

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-wm-sub.XXXXXX")" || setup_error "mktemp"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
trap 'rm -rf "$WORKDIR"' EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build failed"

echo "=== STRUCTURAL ==="
ck; grep -q 'wmOpSub = 5' "$CORE_DIR/kernel/wmext.dart" || fail "wmOpSub missing"
ck; grep -q 'wmAbsX' "$CORE_DIR/kernel/wmext.dart" || fail "wmAbsX missing"
STORE=$(awk '/^const int wmStoreBytes = /{print $5}' "$CORE_DIR/kernel/wm.dart" | tr -d ';')
ck; [[ "$STORE" -eq 1472 ]] || fail "wmStoreBytes $STORE"
ck; grep -E '^\| 11 \|' "$CORE_DIR/docs/syscall-registry.md" | grep -q fdwait || fail "fdwait"
echo "STRUCTURAL: pass"

echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs"
# single elf image
python3 - "$WORKDIR/sub.img" "$WORKDIR/prog.elf" <<'PY' || fail "image"
import struct, sys
SECTOR=512; SPC=2; RES=1; NF=2; FS=20; RE=512; DS=10000
RS=(RE*32)//SECTOR; FAT_START=RES; ROOT=RES+NF*FS; DATA=ROOT+RS
TOT=DATA+DS; CB=SPC*SECTOR; MEDIA=0xF8; EOC=0xFFFF
out, elfp = sys.argv[1], sys.argv[2]
blob=open(elfp,"rb").read()
need=max(1,(len(blob)+CB-1)//CB)
chain=list(range(2,2+need))
img=bytearray()
for s in range(TOT):
    b=bytearray((31*s+7*i+0x21)&0xFF for i in range(SECTOR))
    img+=b
b=bytearray(SECTOR); b[0:3]=b"\xEB\x3C\x90"; b[3:11]=b"OSCORTEX"
struct.pack_into("<H",b,11,SECTOR); b[13]=SPC; struct.pack_into("<H",b,14,RES)
b[16]=NF; struct.pack_into("<H",b,17,RE); struct.pack_into("<H",b,19,TOT)
b[21]=MEDIA; struct.pack_into("<H",b,22,FS); struct.pack_into("<H",b,24,63)
struct.pack_into("<H",b,26,16); b[36]=0x80; b[38]=0x29
struct.pack_into("<I",b,39,0x05C0FFEE); b[43:54]=b"OSCORTEX   "; b[54:62]=b"FAT16   "
b[510:512]=b"\x55\xAA"; img[0:SECTOR]=b
fat=bytearray(FS*SECTOR); struct.pack_into("<H",fat,0,0xFF00|MEDIA); struct.pack_into("<H",fat,2,EOC)
for i,cl in enumerate(chain):
    struct.pack_into("<H",fat,cl*2, chain[i+1] if i+1<len(chain) else EOC)
for n in range(NF):
    at=(FAT_START+n*FS)*SECTOR; img[at:at+len(fat)]=fat
root=bytearray(); e=bytearray(32); e[0:11]=b"OSCORTEX   "; e[11]=0x08; root+=e
e=bytearray(32); e[0:11]=b"PROG    ELF"; e[11]=0x20
struct.pack_into("<H",e,26,chain[0]); struct.pack_into("<I",e,28,len(blob)); root+=e
root+=b"\x00"*(RE*32-len(root)); img[ROOT*SECTOR:(ROOT+RS)*SECTOR]=root
def cat(cl): return (DATA+(cl-2)*SPC)*SECTOR
for i,cl in enumerate(chain):
    piece=blob[i*CB:(i+1)*CB].ljust(CB,b"\0"); img[cat(cl):cat(cl)+CB]=piece
open(out,"wb").write(img); print("image ok", len(img))
PY

PAR_FILL=0x00C03828
CH_FILL=0x001878A8
# after move: parent (200,100), child abs (216,116); centers
CX=$((216 + 16)); CY=$((116 + 16))
PX=210; PY=110
OLDX=$((116 + 16)); OLDY=$((116 + 16))

typekeys() { python3 -c "import sys; print(','.join({' ':'spc','.':'dot'}.get(c,c.lower()) for c in sys.argv[1]))" "$1"; }
KEYS="$(typekeys 'fb'),ret,wait:1500,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn PROG.ELF'),ret,wait:5000"

echo "=== BOOT ==="
SER="$WORKDIR/serial.txt"; FB="$WORKDIR/fb.bin"; : >"$SER"
port=$(python3 "$PICKER") || fail "port"
timeout 180 qemu-system-x86_64 -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
  -serial "file:$SER" -display none -no-reboot \
  -drive "file=$WORKDIR/sub.img,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" >"$WORKDIR/qemu.log" 2>&1 &
qid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --keys "$KEYS" --settle-for 'WM SUB MOVED' --settle-timeout 40 \
  --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' --fb-out "$FB" --png "$WORKDIR/shot.png"
kill "$qid" 2>/dev/null || true
await qemu_status "$qid"
ck; [[ $drive_status -eq 0 ]] || { tail -80 "$SER" >&2; fail "drive $drive_status"; }
cp "$SER" "$CORE_DIR/build/wm-sub-serial.txt"
PITCH=$(grep -m1 -oE 'WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8}' "$SER" | awk '{print $NF}')
PITCH=$((16#$PITCH))

echo "=== ASSERT ==="
ck; grep -qF 'WM SUB MOVED' "$SER" || fail "no WM SUB MOVED"
ck; grep -qE '^WM SUB W ' "$SER" || fail "no WM SUB"
ck; grep -qE '^WM MOVE W ' "$SER" || fail "no WM MOVE"
ck; python3 "$PROBE" "$FB" "$PITCH" "$CX" "$CY" "$(printf '%08X' $CH_FILL)" child \
  || fail "child pixel at ($CX,$CY) after parent move"
ck; python3 "$PROBE" "$FB" "$PITCH" "$PX" "$PY" "$(printf '%08X' $PAR_FILL)" parent \
  || fail "parent pixel"
# old child location must not still be child fill
if python3 "$PROBE" "$FB" "$PITCH" "$OLDX" "$OLDY" "$(printf '%08X' $CH_FILL)" old 2>/dev/null; then
  fail "child fill still at old abs ($OLDX,$OLDY)"
fi
ck; true
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" || fail "fault"
echo "WM-sub: PASS — child followed parent move"
exit 0
