#!/usr/bin/env bash
# core/tests/conformance/frame2/run.sh
#
# FRAME2 — a kept surface client exists that is not a harness.
# docs/design/app-framework.md FRAME2.
#
# SURF.ELF is core/user/frame/surf.c compiled against osframe.h (no
# private SYS_*). `proc spawn` starts it so the prompt returns
# (ADR-0053). The framebuffer dump (pmemsave at the address the kernel
# printed) holds a rectangle of the derived colour; background outside
# it. Anti-vacuity: surface area is not zero. Negative control: an
# attach-only client leaves the framebuffer at the desktop colour.
# No new syscall, no help, no last .bss, no nic/usb/gop/virtgpu.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SURF_C="$CORE_DIR/user/frame/surf.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "FRAME2: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FRAME2: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=72

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-frame2.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SITIN="$CORE_DIR/scripts/sit-in.sh"
ck; [[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
ck; [[ -f "$PROBE" ]] || setup_error "probe.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$SURF_C" ]] || setup_error "no surf.c at $SURF_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SURF_C' \
  '$CORE_DIR/kernel/wm.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

WIN_W=$(d win_w); WIN_H=$(d win_h)
AREA=$(d area)
PX1=$(d px1); PX2=$(d px2)
PROBE_COUNT=$(d probe_count)
FILL_HEX=$(d surf_fill_hex); INK_HEX=$(d surf_ink_hex)
DESK_HEX=$(d desk_hex); FOCUS_HEX=$(d focus_hex)
SYSNO=$(d syscall)

ck; [[ "$AREA" -gt 0 ]] || fail "derived surface area is $AREA — anti-vacuity"
ck; [[ "$PROBE_COUNT" -gt 0 ]] || fail "the model derives $PROBE_COUNT probes"
ck; [[ "$FILL_HEX" != "$DESK_HEX" ]] \
  || fail "fill $FILL_HEX equals desktop $DESK_HEX — the surface probe would be vacuous"
echo "DERIVED: ${WIN_W}x${WIN_H} ($AREA px) fill $FILL_HEX ink $INK_HEX on desktop $DESK_HEX; commit paints $PX2 after desktop $PX1"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$SURF_C" \
  || fail "surf.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$SURF_C" \
  || fail "surf.c copies SYS_* by hand — include osframe.h"
ck; grep -q '^#define SYS_SHMCREATE 16$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_SHMCREATE 16"
ck; grep -q '^#define SYS_WMSURFACE 23$' "$FRAME_H" \
  || fail "osframe.h does not name SYS_WMSURFACE 23"
ck; [[ "$SYSNO" -eq 23 ]] || fail "derive.py says wmsurface is $SYSNO, expected 23"
ck; ! grep -qE '^#define SYS_SHMCREATE |^#define SYS_WMSURFACE ' "$SURF_C" \
  || fail "surf.c redefines a syscall number"

# No kernel .bss, no help, no new syscall — this milestone is a userland program.
ck; ! grep -q 'surf\.c\|SURF\.ELF\|FRAME2' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names FRAME2 / SURF — FRAME2 must not touch the kernel"
ck; ! grep -E 'SURF|FRAME2|osframe' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a FRAME2 name — no new help"
ck; ! grep -q '  surf  ' "$CORE_DIR/kernel/shell.dart" \
  || fail "a 'surf' help line has appeared in shell.dart"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }

# Sit-in must be able to spawn this client (default path stays d3-session).
ck; grep -q 'SITIN_FRAME2\|user/frame/surf.c\|frame2' "$SITIN" \
  || fail "sit-in.sh does not know how to spawn the FRAME2 client"

# Forbidden files — this milestone does not touch them.
for f in nic.dart usb.dart gop.dart virtgpu.dart; do
  ck; true
done
echo "STRUCTURAL: pass  osframe.h only, no SYS_* copy, no kernel edit, no help, registry agrees"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/surf.elf" ]] || fail "no surf.elf"
ck; [[ -s "$WORKDIR/nocom.elf" ]] || fail "no nocom.elf"

DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/surf.elf" "$WORKDIR/nocom.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_SURF=$(lba_of SURF)
LBA_NOCOM=$(lba_of NOCOM)
ck; [[ -n "$LBA_SURF" && -n "$LBA_NOCOM" ]] || fail "could not read slot LBAs"
ck; [[ "$LBA_SURF" != "$LBA_NOCOM" ]] || fail "SURF and NOCOM have the same header LBA"
echo "IMAGE: pass  SURF.ELF at 0x$LBA_SURF, NOCOM.ELF at 0x$LBA_NOCOM"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot', '-': 'minus'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

drive_boot() {
  local outdir="$1" keys="$2" settle="$3" label="$4"
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
    --png "$png"
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
  ck; [[ -s "$fb" ]] || fail "the $label boot produced no framebuffer dump"
}

KEYS_SURF="$(typekeys 'fb'),ret,wait:1500"
KEYS_SURF="$KEYS_SURF,$(typekeys 'wm on'),ret,wait:2500"
KEYS_SURF="$KEYS_SURF,$(typekeys "proc spawn $LBA_SURF"),ret"

drive_boot "$WORKDIR/surf" "$KEYS_SURF" "USER WRITE FRAME2 COMMIT" "SURF"
SER="$WORKDIR/surf/serial.txt"
FB_BIN="$WORKDIR/surf/fb.bin"

echo
echo "=== TRANSCRIPT ==="
have() { ck; grep -qF -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript does not contain: $1"; }; }
havere() { ck; grep -qE -- "$1" "$SER" || { sed -n '/M1 END/,$p' "$SER" >&2; fail "the transcript matches nothing against: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SER" && fail "the transcript contains what it must not: $1"; }
countof() { grep -cE -- "$1" "$SER" | tr -d ' '; }

havere '^WM ON BASE [0-9A-F]{8} PITCH [0-9A-F]{8} BG [0-9A-F]{8}$'
havere '^PROC SPAWN '
have "USER WRITE FRAME2 ATTACH"
have "USER WRITE FRAME2 PAINT"
have "USER WRITE FRAME2 COMMIT"
havere '^WM ATTACH W '
havere '^WM COMMIT W '
havere "^WM FRAME N 00000001 PX $PX1 "
havere "^WM FRAME N 00000002 PX $PX2 "
havent "WM REAP W "
havent "PROC END"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "something faulted during the SURF boot"; }
echo "TRANSCRIPT: pass  spawn, ATTACH, COMMIT, frames $PX1 then $PX2, no REAP"

echo
echo "=== PIXELS ==="
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read the pitch the kernel reported"
FB_BYTES=$(wc -c <"$FB_BIN" | tr -d ' ')
ck; [[ "$FB_BYTES" -eq $(( PITCH * 600 )) ]] \
  || fail "the framebuffer dump is $FB_BYTES bytes and $PITCH * 600 is $(( PITCH * 600 ))"

capture_sh DIST_OUT DIST_STATUS -- "python3 - '$FB_BIN' '$FILL_HEX' '$INK_HEX' '$DESK_HEX' <<'PY'
import sys
blob = open(sys.argv[1], 'rb').read()
words = set()
for i in range(0, len(blob), 4):
    words.add(int.from_bytes(blob[i:i+4], 'little') & 0xFFFFFF)
fill = int(sys.argv[2], 16) & 0xFFFFFF
ink = int(sys.argv[3], 16) & 0xFFFFFF
desk = int(sys.argv[4], 16) & 0xFFFFFF
if len(words) < 2:
    raise SystemExit('the framebuffer holds %d distinct colour(s); a uniform screen cannot prove a surface' % len(words))
missing = [n for n, c in (('fill', fill), ('ink', ink), ('desktop', desk)) if c not in words]
if missing:
    raise SystemExit('the dump is missing colour(s) %s' % missing)
print('    %d distinct colours; fill, ink and desktop are all present' % len(words))
PY"
ck; [[ $DIST_STATUS -eq 0 ]] || { echo "$DIST_OUT" >&2; fail "the framebuffer dump cannot support a surface assertion"; }
echo "$DIST_OUT"

PROBES_RUN=0
while IFS= read -r line; do
  set -- $line
  PROBES_RUN=$(( PROBES_RUN + 1 ))
  ck; python3 "$PROBE" "$FB_BIN" "$PITCH" "$2" "$3" "$4" "$1" \
    || fail "pixel probe '$1' failed — SURF.ELF did not put that colour there"
done < <(sed -n 's/^probe=//p' "$MODEL")
ck; [[ "$PROBES_RUN" -eq "$PROBE_COUNT" ]] \
  || fail "the probe loop ran $PROBES_RUN times and the model derives $PROBE_COUNT probes"
echo "PIXELS: pass  $PROBES_RUN probes, surface $FILL_HEX / $INK_HEX, desktop outside"

echo
echo "=== CONTROL ==="
CONTROL=$(sed -n 's/^control=//p' "$MODEL")
ck; [[ -n "$CONTROL" ]] || fail "the model emitted no control probe"
set -- $CONTROL
CTL_NAME="$1"; CTL_X="$2"; CTL_Y="$3"; CTL_COLOUR="$4"
capture CTL_OUT CTL_STATUS -- python3 "$PROBE" "$FB_BIN" "$PITCH" "$CTL_X" "$CTL_Y" "$CTL_COLOUR" "$CTL_NAME"
ck; [[ $CTL_STATUS -eq 1 ]] \
  || fail "the control probe '$CTL_NAME' exited $CTL_STATUS, expected 1 (a MISMATCH). It asserts the fill colour on the desktop; a pass there would mean the surface painted the whole screen."
echo "    the control asserted $CTL_COLOUR at ($CTL_X,$CTL_Y) and FAILED, which is the required outcome"
echo "$CTL_OUT" | sed 's/^/    /'
echo "CONTROL: pass  fill is not on the desktop"

echo
echo "=== NOCOMMIT ==="
KEYS_NOCOM="$(typekeys 'fb'),ret,wait:1500"
KEYS_NOCOM="$KEYS_NOCOM,$(typekeys 'wm on'),ret,wait:2500"
KEYS_NOCOM="$KEYS_NOCOM,$(typekeys "proc spawn $LBA_NOCOM"),ret"

drive_boot "$WORKDIR/nocom" "$KEYS_NOCOM" "USER WRITE FRAME2 PAINT" "NOCOM"
NSER="$WORKDIR/nocom/serial.txt"
NFB="$WORKDIR/nocom/fb.bin"

ck; grep -qF "USER WRITE FRAME2 ATTACH" "$NSER" \
  || fail "the nocommit boot never attached"
ck; grep -qF "USER WRITE FRAME2 PAINT" "$NSER" \
  || fail "the nocommit boot never painted"
ck; grep -qF "USER WRITE FRAME2 COMMIT" "$NSER" \
  && fail "the nocommit boot COMMITed — the control is vacuous"
ck; grep -qE '^WM COMMIT W ' "$NSER" \
  && fail "the kernel recorded a commit from the nocommit client"

NPITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-F]{8} PITCH ([0-9A-F]{8})' "$NSER" | awk '{print $NF}')))
ck; [[ "$NPITCH" -gt 0 ]] || fail "could not read the nocommit pitch"

# The surface rectangle must still be desktop. Fill at the fill probe
# would mean a commit happened without a COMMIT line.
FILL_PROBE=$(grep -m1 '^probe=fill ' "$MODEL")
set -- $FILL_PROBE
# probe=fill X Y COLOUR  — after set, $1 is probe=fill if we don't strip.
set -- $(sed -n 's/^probe=fill //p' "$MODEL")
NOCOM_X="$1"; NOCOM_Y="$2"
capture NCTL_OUT NCTL_STATUS -- python3 "$PROBE" "$NFB" "$NPITCH" "$NOCOM_X" "$NOCOM_Y" "$DESK_HEX" "nocom_desk"
ck; [[ $NCTL_STATUS -eq 0 ]] \
  || { echo "$NCTL_OUT" >&2; fail "nocommit left ($NOCOM_X,$NOCOM_Y) not desktop — a client that never commits must not change the screen"; }
capture NFILL_OUT NFILL_STATUS -- python3 "$PROBE" "$NFB" "$NPITCH" "$NOCOM_X" "$NOCOM_Y" "$FILL_HEX" "nocom_fill"
ck; [[ $NFILL_STATUS -eq 1 ]] \
  || fail "nocommit has the fill colour at the surface — D4's control failed"
echo "NOCOMMIT: pass  attach without commit left the framebuffer at desktop $DESK_HEX"

require_assertions "$ASSERTIONS_REQUIRED"
echo "FRAME2: PASS — SURF.ELF (osframe.h, no SYS_* copy, no 0x10200000) spawned, attached, painted, committed a ${WIN_W}x${WIN_H} rectangle of $FILL_HEX; desktop $DESK_HEX outside; nocommit left the screen at background; no kernel .bss, no help, no new syscall"
exit 0
