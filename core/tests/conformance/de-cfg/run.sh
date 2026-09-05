#!/usr/bin/env bash
# core/tests/conformance/de-cfg/run.sh
#
# ADR-0142 — under `wm de`, a client pops configure / enter / leave
# through syscall 25 when attach, resize, or focus happens. Without
# `wm de` the compositor still attaches and the client pops NONE.
# No new syscall. 11 is fdwait. No help line.
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

fail() { echo "DE-cfg: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-cfg: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor pinned on the first green run.
ASSERTIONS_REQUIRED=42

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-cfg.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/d2-compositor/comp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
SITIN="$CORE_DIR/scripts/sit-in.sh"
[[ -f "$DRIVER" ]] || setup_error "comp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 OSGFX_CRT=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
DISK_IMG="$WORKDIR/de-cfg.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/win.elf" \
  || fail "make-image.py could not write the volume"
if command -v fsck_msdos >/dev/null 2>&1 || [[ -x /sbin/fsck_msdos ]]; then
  FSCK="${FSCK:-fsck_msdos}"
  [[ -x /sbin/fsck_msdos ]] && FSCK=/sbin/fsck_msdos
  capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
  ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
else
  ck; true
fi
echo "IMAGE: pass  WIN.ELF"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' \
  '$CORE_DIR/kernel/wmde.dart' \
  '$CORE_DIR/kernel/wmchrome.dart' \
  '$CORE_DIR/kernel/wm.dart' \
  '$CORE_DIR/kernel/wmevent.dart' \
  '$SCRIPT_DIR/win.c' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

SYSNO=$(d sysno)
STORE=$(d store)
ATTACH_LINE=$(d attach_line)
RESIZE_LINE=$(d resize_line)
WRONG_LINE=$(d wrong_line)
RELS_SE=$(d rels_se_drag)
RELS_DESK=$(d rels_desk)
NEW_W=$(d new_w)
WIN_W=$(d win_w)
TYPE_CFG=$(d type_configure)
TYPE_ENTER=$(d type_enter)
TYPE_LEAVE=$(d type_leave)

ck; [[ -n "$ATTACH_LINE" && -n "$RESIZE_LINE" && -n "$RELS_SE" ]] \
  || fail "derive.py omitted configure geometry"
ck; [[ "$ATTACH_LINE" != "$RESIZE_LINE" ]] \
  || fail "attach and resize configure lines match — resize would be vacuous"
ck; [[ "$ATTACH_LINE" != "$WRONG_LINE" ]] \
  || fail "wrong-geom line equals attach — the negative control is vacuous"
ck; [[ "$NEW_W" -ne "$WIN_W" ]] \
  || fail "derived resize is zero — the assertion would be vacuous"
echo "DERIVED: attach '$ATTACH_LINE' resize '$RESIZE_LINE'"

echo
echo "=== STRUCTURAL ==="
ck; grep -q 'wmeventTypeConfigure' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "wmevent.dart has no configure type"
ck; grep -q 'wmeventEnqueueConfigure' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "wmevent.dart has no wmeventEnqueueConfigure"
ck; grep -q 'wmeventEnqueueEnter' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "wmevent.dart has no wmeventEnqueueEnter"
ck; grep -q 'wmeventEnqueueLeave' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "wmevent.dart has no wmeventEnqueueLeave"
ck; grep -q 'wmeventEnqueueConfigure' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmAttach / resize / move do not call wmeventEnqueueConfigure"
ck; grep -q 'wmFocusTo' "$CORE_DIR/kernel/wm.dart" \
  || fail "wm.dart has no wmFocusTo"
ck; grep -q 'wmDeOn' "$CORE_DIR/kernel/wmevent.dart" \
  || fail "configure is not gated on wm de"
ck; [[ "$TYPE_CFG" -eq 2 && "$TYPE_ENTER" -eq 3 && "$TYPE_LEAVE" -eq 4 ]] \
  || fail "types are not configure=2 enter=3 leave=4"
ck; [[ "$SYSNO" -eq 25 ]] || fail "wmevent syscall is $SYSNO, expected 25"
ck; ! grep -qE 'const int \w+SysNo = 11;' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel file claimed syscall 11"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
ck; [[ -f "$CORE_DIR/docs/decisions/0142-configure-reaches-the-client.md" ]] \
  || fail "ADR-0142 is missing"
ck; grep -q "typekeys 'wm de'" "$SITIN" \
  || fail "sit-in.sh does not type wm de"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
ck; [[ "$STORE" -eq 1920 ]] || fail "wmeventStoreBytes is $STORE, expected 1920"
ck; ! grep -qE 'const int \w+SysNo' "$CORE_DIR/kernel/wmde.dart" \
  || fail "wmde.dart allocated a syscall number"
capture_sh HELP_OUT HELP_STATUS -- "python3 - '$CORE_DIR/kernel/shell.dart' <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'final List<u8> shellStrHelp = const \[(.*?)\];', src, re.S)
if not m:
    raise SystemExit('no shellStrHelp')
blob = bytes(int(x, 16) for x in re.findall(r'u8\(0x([0-9A-Fa-f]{2})\)', m.group(1)))
if b'configure' in blob.lower() or b'de-cfg' in blob.lower() or b'wmevent' in blob.lower():
    raise SystemExit('de-cfg appeared inside shellStrHelp')
print('    shellStrHelp has no de-cfg line')
PY"
ck; [[ $HELP_STATUS -eq 0 ]] || { echo "$HELP_OUT" >&2; fail "de-cfg appeared in help (GAP-0304)"; }
echo "$HELP_OUT"
echo "STRUCTURAL: pass  configure/enter/leave on wmevent 25, 11 fdwait, gated on wm de"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower())
               for c in sys.argv[1]))
" "$1"; }

de_boot() {
  local name="$1" keys="$2" settle="$3" keys2="${4:-}" settle2="${5:-}"
  local dir="$WORKDIR/$name"
  mkdir -p "$dir"
  local ser="$dir/serial.txt"
  local fb1="$dir/fb.bin"
  local png1="$dir/shot.png"
  : >"$ser"
  local attempt=0 drive_status=1 qemu_status=0
  while :; do
    attempt=$(( attempt + 1 ))
    local port
    port=$(python3 "$PICKER") || fail "pick-port.py could not find a free port"
    : >"$ser"
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
      >"$dir/qemu.log" 2>&1 &
    local qemu_pid=$!
    local extra=()
    [[ -n "$keys2" ]] && extra+=(--keys2 "$keys2")
    [[ -n "$settle2" ]] && extra+=(--settle2-for "$settle2")
    run_status drive_status -- python3 "$DRIVER" \
      --port "$port" \
      --serial "$ser" \
      --wait-for 'M1 END\n' \
      --keys "$keys" \
      --settle-for "$settle" \
      --settle-timeout 60 \
      --fb-from 'WM ON BASE ([0-9A-F]{8}) PITCH ([0-9A-F]{8})' \
      --fb-out "$fb1" \
      --png "$png1" \
      "${extra[@]}"
    await qemu_status "$qemu_pid"
    if [[ $drive_status -ne 0 ]] && grep -q "Address already in use" "$dir/qemu.log" \
       && [[ $attempt -lt 5 ]]; then
      echo "    (port $port was taken; retrying — attempt $attempt)"
      continue
    fi
    break
  done
  if [[ $drive_status -ne 0 ]]; then
    cat "$dir/qemu.log" >&2
    echo "--- serial captured so far ---" >&2
    sed -n '/M1 END/,$p' "$ser" >&2
    fail "$name: comp-drive.py exited $drive_status"
  fi
  if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$dir/qemu.log" >&2
    fail "$name: qemu exited $qemu_status"
  fi
  [[ -s "$ser" ]] || fail "$name: no serial"
  DE_SER="$ser"
}

have() { grep -qF -- "$1" "$DE_SER" || { sed -n '/M1 END/,$p' "$DE_SER" >&2; fail "$2"; }; }
havenot() { ! grep -qF -- "$1" "$DE_SER" || { sed -n '/M1 END/,$p' "$DE_SER" >&2; fail "$2"; }; }
havere() { grep -qE -- "$1" "$DE_SER" || { sed -n '/M1 END/,$p' "$DE_SER" >&2; fail "$2"; }; }

echo
echo "=== BOOT DE (attach + resize + leave) ==="
DE_KEYS="$(typekeys 'fb'),ret,wait:1500"
DE_KEYS="$DE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
DE_KEYS="$DE_KEYS,$(typekeys 'wm de'),ret,wait:800"
DE_KEYS="$DE_KEYS,$(typekeys 'proc spawn WIN.ELF'),ret,wait:400"
de_boot live "$DE_KEYS" "DE CFG CONFIGURE" "$RELS_SE,wait:400,$RELS_DESK" "DE CFG LEAVE"
ck; havere '^WM DE ON' "WM DE ON did not appear"
ck; have "DE CFG COMMIT" "WIN.ELF did not commit"
ck; have "$ATTACH_LINE" "client did not pop the derived attach configure"
ck; have "$RESIZE_LINE" "client did not pop the derived resize configure"
ck; have "DE CFG ENTER" "client did not pop enter on focus"
ck; have "DE CFG LEAVE" "client did not pop leave on the desktop click"
ck; havenot "$WRONG_LINE" "client printed the wrong-geom configure"
ck; havere '^WM ATTACH' "compositor did not attach — the client line would be a lie"
ck; havere '^WM RESIZE W ' "SE drag did not print WM RESIZE"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" \
  || fail "de boot faulted"
echo "LIVE: pass  client popped attach configure, resize configure, enter, leave"

echo
echo "=== BOOT NO-DE (anti-vacuity) ==="
NODE_KEYS="$(typekeys 'fb'),ret,wait:1500"
NODE_KEYS="$NODE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
NODE_KEYS="$NODE_KEYS,$(typekeys 'proc spawn WIN.ELF'),ret,wait:400"
de_boot node "$NODE_KEYS" "DE CFG NONE"
ck; have "DE CFG COMMIT" "no-de WIN.ELF did not commit"
ck; have "DE CFG NONE" "no-de client did not pop empty — configure leaked without wm de"
ck; havenot "$ATTACH_LINE" "no-de client saw attach configure — send is not gated"
ck; havenot "DE CFG ENTER" "no-de client saw enter"
ck; havenot "DE CFG LEAVE" "no-de client saw leave"
ck; havere '^WM ATTACH' "no-de compositor did not attach — NONE would be vacuous"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$DE_SER" \
  || fail "no-de boot faulted"
echo "ANTI-VACUITY: pass  compositor attached; client popped NONE without wm de"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "DE-cfg: PASS ($ASSERTIONS checks) — client popped configure/enter/leave under wm de; no send → NONE"
exit 0
