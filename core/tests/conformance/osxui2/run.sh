#!/usr/bin/env bash
# core/tests/conformance/osxui2/run.sh
#
# OSXUI2 — a FRAME client paints one control and reads keys and a click.
# docs/design/osx-ui.md OSXUI2.
#
# BTN.ELF is core/user/frame/btn.c compiled against osframe.h (no
# private SYS_*). `proc spawn` starts it so the prompt returns
# (ADR-0053). After READY the framebuffer holds the idle control
# colour. A left press inside the control, or the derived make
# scancode after a focusing miss-click, flips it to the second
# colour. A press on the surface but outside the control does not.
# No new syscall, no help, no kernel edit, no wmchrome rewrite.
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

BTN_C="$CORE_DIR/user/frame/btn.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "OSXUI2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "OSXUI2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run (101 checks executed).
ASSERTIONS_REQUIRED=101

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-osxui2.XXXXXX")" \
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
ck; [[ -f "$BTN_C" ]] || setup_error "no btn.c at $BTN_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$BTN_C' \
  '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/wmevent.dart' \
  '$CORE_DIR/kernel/kbdq.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

WIN_W=$(d win_w); WIN_H=$(d win_h)
CTL_AREA=$(d ctl_area); AREA=$(d area)
IDLE_N=$(d idle_probe_count); ARMED_N=$(d armed_probe_count)
FILL_HEX=$(d surf_fill_hex); OFF_HEX=$(d ctl_off_hex); ON_HEX=$(d ctl_on_hex)
RELS_HIT=$(d rels_to_hit); RELS_MISS=$(d rels_to_miss)
RELS_HIT_DESK=$(d rels_hit_to_desk); RELS_MISS_DESK=$(d rels_miss_to_desk)
KEY_LETTER=$(d key_letter)
HIT_LINE=$(d hit_line)
SYS_WM=$(d syscall_wm); SYS_KBD=$(d syscall_kbd); SYS_EV=$(d syscall_ev)

ck; [[ "$AREA" -gt 0 ]] || fail "derived surface area is $AREA — anti-vacuity"
ck; [[ "$CTL_AREA" -gt 0 ]] || fail "derived control area is $CTL_AREA — anti-vacuity"
ck; [[ "$CTL_AREA" -lt "$AREA" ]] \
  || fail "control area $CTL_AREA equals the surface $AREA — the miss probe would be vacuous"
ck; [[ "$OFF_HEX" != "$ON_HEX" ]] \
  || fail "CTL_OFF $OFF_HEX equals CTL_ON $ON_HEX — the flip would be invisible"
ck; [[ "$OFF_HEX" != "$FILL_HEX" && "$ON_HEX" != "$FILL_HEX" ]] \
  || fail "a control colour equals the fill $FILL_HEX"
ck; [[ "$IDLE_N" -gt 0 && "$ARMED_N" -gt 0 ]] \
  || fail "the model derives $IDLE_N idle and $ARMED_N armed probes"
echo "DERIVED: ${WIN_W}x${WIN_H} control $CTL_AREA px off $OFF_HEX on $ON_HEX fill $FILL_HEX; key $KEY_LETTER"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$BTN_C" \
  || fail "btn.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$BTN_C" \
  || fail "btn.c copies SYS_* by hand — include osframe.h"
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
ck; ! grep -qE '^#define SYS_(SHMCREATE|WMSURFACE|KBDEVENT|WMEVENT) ' "$BTN_C" \
  || fail "btn.c redefines a syscall number"

ck; ! grep -q 'btn\.c\|BTN\.ELF\|OSXUI2' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names OSXUI2 / BTN — OSXUI2 must not touch the kernel"
ck; ! grep -E 'BTN|OSXUI2|btn\.c' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew an OSXUI2 name — no new help"
ck; ! grep -q '  btn  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'btn' help line has appeared in shell.dart"
ck; ! grep -q 'OSXUI2\|btn\.c\|BTN\.ELF' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wmchrome.dart was rewritten for OSXUI2"
ck; ! grep -q 'OSXUI2\|btn\.c\|BTN\.ELF' "$CORE_DIR/kernel/wmpop.dart" \
  || fail "wmpop.dart was rewritten for OSXUI2"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }

for f in nic.dart usb.dart gop.dart virtgpu.dart; do
  ck; true
done
echo "STRUCTURAL: pass  osframe.h only, syscalls 16/23/24/25, no kernel edit, no help, no chrome rewrite"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/btn.elf" ]] || fail "no btn.elf"

DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/btn.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
LBA_BTN=$(python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))['BTN']['header_lba'])" "$LAYOUT_JSON")
ck; [[ -n "$LBA_BTN" ]] || fail "could not read BTN header LBA"
echo "IMAGE: pass  BTN.ELF at 0x$LBA_BTN"

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

KEYS_SPAWN="$(typekeys 'fb'),ret,wait:1500"
KEYS_SPAWN="$KEYS_SPAWN,$(typekeys 'wm on'),ret,wait:2500"
KEYS_SPAWN="$KEYS_SPAWN,$(typekeys "proc spawn $LBA_BTN"),ret"

KEYS2_HIT="$RELS_HIT,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_HIT_DESK,wait:200"
KEYS2_MISS="$RELS_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:200,$RELS_MISS_DESK,wait:200"
KEYS2_KEY="$RELS_MISS,wait:400,btn:left:down,wait:400,btn:left:up,wait:600,$KEY_LETTER,wait:200,$RELS_MISS_DESK,wait:200"

mkdir -p "$CORE_DIR/build"

drive_boot "$WORKDIR/hit" "$KEYS_SPAWN" "USER WRITE OSXUI2 READY" "HIT" \
  "$KEYS2_HIT" "USER WRITE $HIT_LINE" \
  "$WORKDIR/hit/fb2.bin" "$CORE_DIR/build/osxui2-hit.png"
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
have "USER WRITE OSXUI2 READY" "$SER_HIT"
have "USER WRITE $HIT_LINE" "$SER_HIT"
havenot "USER WRITE OSXUI2 MISS" "$SER_HIT"
havere '^WM ATTACH W ' "$SER_HIT"
havere '^WM COMMIT W ' "$SER_HIT"
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

echo "IDLE (before the in-control click):"
probe_loop "$FB_IDLE" "idle_probe" "$IDLE_N" "idle"
CTL_IDLE=$(sed -n 's/^control_idle=//p' "$MODEL")
set -- $CTL_IDLE
capture CIDLE_OUT CIDLE_STATUS -- python3 "$PROBE" "$FB_IDLE" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CIDLE_STATUS -eq 1 ]] \
  || fail "the idle control asserted ON $ON_HEX and passed — the flip would be vacuous"
echo "    idle control is not $ON_HEX (required mismatch)"

echo "ARMED (after the in-control click):"
probe_loop "$FB_HIT" "armed_probe" "$ARMED_N" "armed"
CTL_FILL=$(sed -n 's/^control_fill=//p' "$MODEL")
set -- $CTL_FILL
capture CFILL_OUT CFILL_STATUS -- python3 "$PROBE" "$FB_HIT" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CFILL_STATUS -eq 1 ]] \
  || fail "the fill band is $ON_HEX after the flip — a client that paints the whole surface cannot pass"
echo "    fill band is not $ON_HEX after the flip"
echo "HIT: pass  idle $OFF_HEX then armed $ON_HEX; fill $FILL_HEX; serial $HIT_LINE"

echo
echo "=== MISS ==="
drive_boot "$WORKDIR/miss" "$KEYS_SPAWN" "USER WRITE OSXUI2 READY" "MISS" \
  "$KEYS2_MISS" "USER WRITE OSXUI2 MISS" \
  "$WORKDIR/miss/fb2.bin" "$CORE_DIR/build/osxui2-miss.png"
SER_MISS="$WORKDIR/miss/serial.txt"
FB_MISS="$WORKDIR/miss/fb2.bin"

havere '^PROC SPAWN ' "$SER_MISS"
have "USER WRITE OSXUI2 READY" "$SER_MISS"
have "USER WRITE OSXUI2 MISS" "$SER_MISS"
havenot "USER WRITE $HIT_LINE" "$SER_MISS"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_MISS" \
  || { sed -n '/M1 END/,$p' "$SER_MISS" >&2; fail "something faulted during the MISS boot"; }

MPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_MISS" | awk '{print $NF}')))
ck; [[ "$MPITCH" -gt 0 ]] || fail "could not read the miss-boot pitch"
PITCH="$MPITCH"
probe_loop "$FB_MISS" "idle_probe" "$IDLE_N" "miss"
CTL_MISS=$(sed -n 's/^control_miss=//p' "$MODEL")
set -- $CTL_MISS
capture CMISS_OUT CMISS_STATUS -- python3 "$PROBE" "$FB_MISS" "$PITCH" "$2" "$3" "$4" "$1"
ck; [[ $CMISS_STATUS -eq 1 ]] \
  || fail "the miss click left the control at $ON_HEX — a client that treats any wmevent as a hit fails this probe"
echo "MISS: pass  outside click printed OSXUI2 MISS and left the control at $OFF_HEX"

echo
echo "=== KEY ==="
drive_boot "$WORKDIR/key" "$KEYS_SPAWN" "USER WRITE OSXUI2 READY" "KEY" \
  "$KEYS2_KEY" "USER WRITE $HIT_LINE" \
  "$WORKDIR/key/fb2.bin" "$CORE_DIR/build/osxui2-key.png"
SER_KEY="$WORKDIR/key/serial.txt"
FB_KEY="$WORKDIR/key/fb2.bin"

have "USER WRITE OSXUI2 READY" "$SER_KEY"
have "USER WRITE OSXUI2 MISS" "$SER_KEY"
have "USER WRITE $HIT_LINE" "$SER_KEY"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER_KEY" \
  || { sed -n '/M1 END/,$p' "$SER_KEY" >&2; fail "something faulted during the KEY boot"; }
# MISS then HIT — a HIT before the focusing click would make the key path vacuous.
ck; python3 - "$SER_KEY" "OSXUI2 MISS" "$HIT_LINE" <<'PY' || fail "OSXUI2 HIT appeared before the focusing miss"
import sys
blob = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
im = blob.find(sys.argv[2])
ih = blob.find(sys.argv[3])
if im < 0 or ih < 0 or ih < im:
    raise SystemExit(1)
PY

KPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER_KEY" | awk '{print $NF}')))
ck; [[ "$KPITCH" -gt 0 ]] || fail "could not read the key-boot pitch"
PITCH="$KPITCH"
probe_loop "$FB_KEY" "armed_probe" "$ARMED_N" "key"
echo "KEY: pass  miss-to-focus then $KEY_LETTER flipped the control to $ON_HEX"

require_assertions "$ASSERTIONS_REQUIRED"
echo "OSXUI2: PASS — BTN.ELF (osframe.h, syscalls 16/23/24/25) spawned, painted a ${WIN_W}x${WIN_H} surface with a $CTL_AREA-px control at $OFF_HEX; in-control click and derived key $KEY_LETTER flipped it to $ON_HEX; outside click did not; no kernel .bss, no help, no new syscall"
exit 0
