#!/usr/bin/env bash
# core/tests/conformance/osxui3/run.sh
#
# OSXUI3 — a second surface is a client-owned menu.
# docs/design/osx-ui.md OSXUI3.
#
# MENU.ELF is core/user/frame/menu.c compiled against osframe.h (no
# private SYS_*). `proc spawn` starts it so the prompt returns
# (ADR-0053). One client, two shm regions / two window slots. A click
# or the derived key opens a second surface. A click on a menu band
# flips that band. A click on the main surface leaves the menu colour
# unchanged and is reported as OSXUI3 MAIN. Attach-without-commit
# leaves the menu rectangle at desktop. No new syscall, no help.
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

MENU_C="$CORE_DIR/user/frame/menu.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "OSXUI3: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OSXUI3: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run (120 checks executed).
ASSERTIONS_REQUIRED=120

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-osxui3.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
ck; [[ -f "$PROBE" ]] || setup_error "probe.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$MENU_C" ]] || setup_error "no menu.c at $MENU_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$MENU_C' \
  '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/wmevent.dart' \
  '$CORE_DIR/kernel/kbdq.dart' '$CORE_DIR/kernel/shm.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

WIN_W=$(d win_w); WIN_H=$(d win_h)
MENU_W=$(d menu_w); MENU_H=$(d menu_h)
MENU_AREA=$(d menu_area); AREA=$(d area)
IDLE_N=$(d idle_probe_count); OPEN_N=$(d open_probe_count)
ARMED_N=$(d armed_probe_count); MISS_N=$(d miss_probe_count)
FILL_HEX=$(d surf_fill_hex); MENU_HEX=$(d menu_fill_hex)
OFF_HEX=$(d band_off_hex); ON_HEX=$(d band_on_hex); DESK_HEX=$(d desk_hex)
RELS_OPEN=$(d rels_to_open); RELS_MISS=$(d rels_to_miss)
RELS_OPEN_BAND=$(d rels_open_to_band); RELS_OPEN_MISS=$(d rels_open_to_miss)
RELS_BAND_PARK=$(d rels_band_to_park); RELS_MISS_PARK=$(d rels_miss_to_park)
RELS_OPEN_PARK=$(d rels_open_to_park)
KEY_LETTER=$(d key_letter)
OPEN_LINE=$(d open_line); BAND_LINE=$(d band_line)
SYS_WM=$(d syscall_wm); SYS_KBD=$(d syscall_kbd); SYS_EV=$(d syscall_ev)
SHM_MAX=$(d shm_max); WM_MAX=$(d wm_max)

ck; [[ "$AREA" -gt 0 ]] || fail "derived main area is $AREA — anti-vacuity"
ck; [[ "$MENU_AREA" -gt 0 ]] || fail "derived menu area is $MENU_AREA — anti-vacuity"
ck; [[ "$MENU_AREA" -ne "$AREA" ]] \
  || fail "menu area $MENU_AREA equals the main surface $AREA"
ck; [[ "$OFF_HEX" != "$ON_HEX" ]] \
  || fail "BAND_OFF $OFF_HEX equals BAND_ON $ON_HEX — the flip would be invisible"
ck; [[ "$MENU_HEX" != "$FILL_HEX" ]] \
  || fail "menu fill equals main fill — the two surfaces would be the same colour"
ck; [[ "$SHM_MAX" -ge 2 ]] || fail "shmMax is $SHM_MAX, OSXUI3 needs two regions"
ck; [[ "$WM_MAX" -ge 2 ]] || fail "wmMaxWindows is $WM_MAX, expected >= 2"
ck; [[ "$IDLE_N" -gt 0 && "$OPEN_N" -gt 0 && "$ARMED_N" -gt 0 ]] \
  || fail "the model derives $IDLE_N idle, $OPEN_N open, $ARMED_N armed probes"
echo "DERIVED: main ${WIN_W}x${WIN_H} menu ${MENU_W}x${MENU_H} ($MENU_AREA px) fill $MENU_HEX band $OFF_HEX->$ON_HEX; key $KEY_LETTER"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$MENU_C" \
  || fail "menu.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$MENU_C" \
  || fail "menu.c copies SYS_* by hand — include osframe.h"
ck; grep -q '^#define SYS_SHMCREATE 16$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_SHMCREATE 16"
ck; grep -q '^#define SYS_WMSURFACE 23$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_WMSURFACE 23"
ck; grep -q '^#define SYS_KBDEVENT 24$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_KBDEVENT 24"
ck; grep -q '^#define SYS_WMEVENT 25$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_WMEVENT 25"
ck; [[ "$SYS_WM" -eq 23 ]] || fail "derive.py says wmsurface is $SYS_WM, expected 23"
ck; [[ "$SYS_KBD" -eq 24 ]] || fail "derive.py says kbdevent is $SYS_KBD, expected 24"
ck; [[ "$SYS_EV" -eq 25 ]] || fail "derive.py says wmevent is $SYS_EV, expected 25"
ck; grep -q 'wmWindowOfRegion' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart has no wmWindowOfRegion — one client cannot commit a second surface"
ck; grep -q 'wmeventPopOwned' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "wmevent.dart has no wmeventPopOwned — one client cannot pop both rings"
ck; ! grep -qE 'menu\.c|MENU\.ELF|OSXUI3' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names OSXUI3 / MENU — the kit must not name the client"
ck; ! grep -E 'MENU|OSXUI3|menu\.c' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew an OSXUI3 name — no new help"
ck; ! grep -q '  menu  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'menu' help line has appeared in shell.dart"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  osframe.h only, syscalls 16/23/24/25, two windows per client, no help"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/menu.elf" ]] || fail "no menu.elf"
ck; [[ -s "$WORKDIR/nocom.elf" ]] || fail "no nocom.elf"

DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/menu.elf" \
  "$WORKDIR/nocom.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
LBA_MENU=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['MENU']['header_lba'])" "$LAYOUT_JSON")
LBA_NOCOM=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['NOCOM']['header_lba'])" "$LAYOUT_JSON")
ck; [[ -n "$LBA_MENU" && -n "$LBA_NOCOM" ]] || fail "could not read header LBAs"
echo "IMAGE: pass  MENU.ELF at 0x$LBA_MENU  NOCOM.ELF at 0x$LBA_NOCOM"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

drive_boot() {
  local outdir="$1" keys="$2" settle="$3" label="$4"
  local keys2="$5" settle2="$6" fb2="$7" png2="$8"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local fb="$outdir/fb.bin"
  local png="$outdir/shot.png"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 180 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local extra=()
  extra+=(--keys2 "$keys2")
  extra+=(--settle2-for "$settle2")
  extra+=(--fb-out2 "$fb2" --png2 "$png2")
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" \
    --serial "$ser" \
    --wait-for 'M1 END\n' \
    --keys "$keys" \
    --settle-for "$settle" \
    --settle-timeout 60 \
    --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
    --fb-out "$fb" \
    --png "$png" \
    ${extra[@]+"${extra[@]}"}
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "comp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
  ck; [[ -s "$fb" ]] || fail "the $label boot produced no first framebuffer dump"
  ck; [[ -s "$fb2" ]] || fail "the $label boot produced no second framebuffer dump"
}

KEYS_MENU="$(typekeys 'fb'),ret,wait:1500"
KEYS_MENU="$KEYS_MENU,$(typekeys 'wm on'),ret,wait:2500"
KEYS_MENU="$KEYS_MENU,$(typekeys "proc spawn $LBA_MENU"),ret"

KEYS_NOCOM="$(typekeys 'fb'),ret,wait:1500"
KEYS_NOCOM="$KEYS_NOCOM,$(typekeys 'wm on'),ret,wait:2500"
KEYS_NOCOM="$KEYS_NOCOM,$(typekeys "proc spawn $LBA_NOCOM"),ret"

KEYS2_HIT="$RELS_OPEN,wait:400,btn:left:down,wait:400,btn:left:up,wait:800"
KEYS2_HIT="$KEYS2_HIT,$RELS_OPEN_BAND,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_BAND_PARK,wait:200"

KEYS2_MISS="$RELS_OPEN,wait:400,btn:left:down,wait:400,btn:left:up,wait:800"
KEYS2_MISS="$KEYS2_MISS,$RELS_OPEN_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_MISS_PARK,wait:200"

KEYS2_KEY="$RELS_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:600,$KEY_LETTER,wait:400,$RELS_MISS_PARK,wait:200"

KEYS2_NOCOM="$RELS_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:600,$KEY_LETTER,wait:400,$RELS_MISS_PARK,wait:200"

mkdir -p "$CORE_DIR/build"

drive_boot "$WORKDIR/hit" "$KEYS_MENU" "USER WRITE OSXUI3 READY" "HIT" \
  "$KEYS2_HIT" "USER WRITE $BAND_LINE" \
  "$WORKDIR/hit/fb2.bin" "$CORE_DIR/build/osxui3-hit.png"
SER_HIT="$WORKDIR/hit/serial.txt"
FB_IDLE="$WORKDIR/hit/fb.bin"
FB_HIT="$WORKDIR/hit/fb2.bin"

echo
echo "=== HIT ==="
have() { ck; grep -qF -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript does not contain: $1"; }; }
havenot() { ck; grep -qF -- "$1" "$2" && fail "the transcript contains what it must not: $1"; }
havere() { ck; grep -qE -- "$1" "$2" || { sed -n '/M1 END/,$p' "$2" >&2; fail "the transcript matches nothing against: $1"; }; }

havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$' "$SER_HIT"
havere '^PROC SPAWN ' "$SER_HIT"
have "USER WRITE OSXUI3 READY" "$SER_HIT"
have "USER WRITE OSXUI3 ATTACH" "$SER_HIT"
have "USER WRITE $OPEN_LINE" "$SER_HIT"
have "USER WRITE $BAND_LINE" "$SER_HIT"
havenot "USER WRITE OSXUI3 MAIN" "$SER_HIT"
ATTACH_N=$(grep -cE '^WM ATTACH W ' "$SER_HIT" || true)
COMMIT_N=$(grep -cE '^WM COMMIT W ' "$SER_HIT" || true)
ck; [[ "$ATTACH_N" -eq 2 ]] || fail "HIT boot had $ATTACH_N attaches, expected 2 (main + menu)"
ck; [[ "$COMMIT_N" -ge 3 ]] || fail "HIT boot had $COMMIT_N commits, expected at least 3 (main, menu, band)"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_HIT" \
  || { sed -n '/M1 END/,$p' "$SER_HIT" >&2; fail "something faulted during the HIT boot"; }

PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_HIT" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"

probe_loop() {
  local fb="$1" prefix="$2" expect="$3" label="$4"
  local n=0
  while IFS= read -r line; do
    set -- $line
    n=$(( n + 1 ))
    ck; python3 "$PROBE" "$fb" "$PITCH" "$2" "$3" "$4" "$1" \
      || fail "pixel probe '$1' failed on the $label dump — expected $4"
  done < <(sed -n "s/^${prefix}=//p" "$MODEL")
  ck; [[ "$n" -eq "$expect" ]] \
    || fail "the $label probe loop ran $n times and the model derives $expect"
  echo "    $label: $n probes matched"
}

echo "IDLE (before the menu exists):"
probe_loop "$FB_IDLE" "idle_probe" "$IDLE_N" "idle"
CTL_IDLE=$(sed -n 's/^control_idle_menu=//p' "$MODEL")
set -- $CTL_IDLE
capture CIDLE_OUT CIDLE_STATUS -- python3 "$PROBE" "$FB_IDLE" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CIDLE_STATUS -eq 1 ]] \
  || fail "the idle menu rect already holds MENU_FILL — opening would be vacuous"
echo "    idle menu rect is not $MENU_HEX (required mismatch)"

echo "ARMED (after open + band click):"
probe_loop "$FB_HIT" "armed_probe" "$ARMED_N" "armed"
echo "HIT: pass  idle desktop at the menu rect; after click, menu $MENU_HEX and band $ON_HEX"

echo
echo "=== MISS ==="
drive_boot "$WORKDIR/miss" "$KEYS_MENU" "USER WRITE OSXUI3 READY" "MISS" \
  "$KEYS2_MISS" "USER WRITE OSXUI3 MAIN" \
  "$WORKDIR/miss/fb2.bin" "$CORE_DIR/build/osxui3-miss.png"
SER_MISS="$WORKDIR/miss/serial.txt"
FB_MISS="$WORKDIR/miss/fb2.bin"

have "USER WRITE OSXUI3 READY" "$SER_MISS"
have "USER WRITE $OPEN_LINE" "$SER_MISS"
have "USER WRITE OSXUI3 MAIN" "$SER_MISS"
havenot "USER WRITE $BAND_LINE" "$SER_MISS"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_MISS" \
  || { sed -n '/M1 END/,$p' "$SER_MISS" >&2; fail "something faulted during the MISS boot"; }
ck; python3 - "$SER_MISS" "$OPEN_LINE" "OSXUI3 MAIN" <<'PY' || fail "OSXUI3 MAIN appeared before the menu opened"
import sys
blob = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
io = blob.find(sys.argv[2])
im = blob.find(sys.argv[3])
if io < 0 or im < 0 or im < io:
    raise SystemExit(1)
PY

MPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_MISS" | awk '{print $NF}')))
ck; [[ "$MPITCH" -gt 0 ]] || fail "could not read the miss-boot pitch"
PITCH="$MPITCH"
probe_loop "$FB_MISS" "miss_probe" "$MISS_N" "miss"
CTL_MISS=$(sed -n 's/^control_miss_band=//p' "$MODEL")
set -- $CTL_MISS
capture CMISS_OUT CMISS_STATUS -- python3 "$PROBE" "$FB_MISS" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CMISS_STATUS -eq 1 ]] \
  || fail "the main-surface click left the band at $ON_HEX — a client that treats any wmevent as a band hit fails this probe"
echo "MISS: pass  main click printed OSXUI3 MAIN and left the band at $OFF_HEX"

echo
echo "=== KEY ==="
drive_boot "$WORKDIR/key" "$KEYS_MENU" "USER WRITE OSXUI3 READY" "KEY" \
  "$KEYS2_KEY" "USER WRITE $OPEN_LINE" \
  "$WORKDIR/key/fb2.bin" "$CORE_DIR/build/osxui3-key.png"
SER_KEY="$WORKDIR/key/serial.txt"
FB_KEY="$WORKDIR/key/fb2.bin"

have "USER WRITE OSXUI3 READY" "$SER_KEY"
have "USER WRITE OSXUI3 MAIN" "$SER_KEY"
have "USER WRITE $OPEN_LINE" "$SER_KEY"
havenot "USER WRITE $BAND_LINE" "$SER_KEY"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_KEY" \
  || { sed -n '/M1 END/,$p' "$SER_KEY" >&2; fail "something faulted during the KEY boot"; }
ck; python3 - "$SER_KEY" "OSXUI3 MAIN" "$OPEN_LINE" <<'PY' || fail "OSXUI3 OPEN appeared before the focusing miss"
import sys
blob = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
im = blob.find(sys.argv[2])
io = blob.find(sys.argv[3])
if im < 0 or io < 0 or io < im:
    raise SystemExit(1)
PY

KPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_KEY" | awk '{print $NF}')))
ck; [[ "$KPITCH" -gt 0 ]] || fail "could not read the key-boot pitch"
PITCH="$KPITCH"
probe_loop "$FB_KEY" "open_probe" "$OPEN_N" "key"
echo "KEY: pass  miss-to-focus then $KEY_LETTER opened the menu at $MENU_HEX"

echo
echo "=== NOCOMMIT ==="
drive_boot "$WORKDIR/nocom" "$KEYS_NOCOM" "USER WRITE OSXUI3 READY" "NOCOM" \
  "$KEYS2_NOCOM" "USER WRITE OSXUI3 ATTACH" \
  "$WORKDIR/nocom/fb2.bin" "$CORE_DIR/build/osxui3-nocom.png"
SER_NOCOM="$WORKDIR/nocom/serial.txt"
FB_NOCOM="$WORKDIR/nocom/fb2.bin"

have "USER WRITE OSXUI3 READY" "$SER_NOCOM"
have "USER WRITE OSXUI3 ATTACH" "$SER_NOCOM"
havenot "USER WRITE $OPEN_LINE" "$SER_NOCOM"
ck; grep -qE '^WM ATTACH W ' "$SER_NOCOM" \
  || fail "the nocommit boot never attached the menu"
# Main commits; the menu must not.
MENU_COMMITS=$(grep -cE '^WM COMMIT W 1 ' "$SER_NOCOM" || true)
ck; [[ "$MENU_COMMITS" -eq 0 ]] \
  || fail "the nocommit boot committed window 1 ($MENU_COMMITS times) — the control is vacuous"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_NOCOM" \
  || { sed -n '/M1 END/,$p' "$SER_NOCOM" >&2; fail "something faulted during the NOCOMMIT boot"; }

NPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_NOCOM" | awk '{print $NF}')))
ck; [[ "$NPITCH" -gt 0 ]] || fail "could not read the nocommit pitch"
PITCH="$NPITCH"
CTL_ND=$(sed -n 's/^control_nocom_desk=//p' "$MODEL")
set -- $CTL_ND
capture ND_OUT ND_STATUS -- python3 "$PROBE" "$FB_NOCOM" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $ND_STATUS -eq 0 ]] \
  || { echo "$ND_OUT" >&2; fail "nocommit left the menu rect not desktop — a client that never commits must not change those pixels"; }
CTL_NF=$(sed -n 's/^control_nocom_fill=//p' "$MODEL")
set -- $CTL_NF
capture NF_OUT NF_STATUS -- python3 "$PROBE" "$FB_NOCOM" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $NF_STATUS -eq 1 ]] \
  || fail "nocommit has MENU_FILL at the menu rect — D4's control failed"
echo "NOCOMMIT: pass  attach without commit left the menu rectangle at desktop $DESK_HEX"

require_assertions "$ASSERTIONS_REQUIRED"
echo "OSXUI3: PASS — MENU.ELF (osframe.h, syscalls 16/23/24/25) spawned one client, two attach/commit pairs; click and key $KEY_LETTER opened a ${MENU_W}x${MENU_H} menu at $MENU_HEX; band click flipped it to $ON_HEX; main click did not; nocommit left the menu rect at desktop; no help, no new syscall"
exit 0
