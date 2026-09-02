#!/usr/bin/env bash
# core/tests/conformance/frame1/run.sh
#
# FRAME1 — the ABI is written down once, and a copy of it boots.
# docs/design/app-framework.md FRAME1.
#
# Host header core/user/frame/osframe.h names the allocated syscalls a
# FRAME client needs. The same bytes are planted as FRAME.H on a FAT16
# volume. ABITST.ELF opens that file, reads it in 512-byte strides, and
# prints a magic/version plus an FNV derive.py computed from the planted
# bytes. No new syscall, no kernel .bss, no help line.
#
# Anti-vacuity: FRAME.H is longer than 512 bytes and names at least two
# distinct syscall rows.
# Negative control: a volume whose FRAME.H was truncated by one SYS_ row
# prints a different checksum.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "FRAME1: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FRAME1: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Floor is set after the first green run.
ASSERTIONS_REQUIRED=56

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-frame1.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
MOUNTPOINT="$WORKDIR/mnt"
ATTACHED=""
cleanup() {
  [[ -n "$ATTACHED" ]] && hdiutil detach "$ATTACHED" -force >/dev/null 2>&1
  [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"

echo "=== BUILD ==="
capture BUILD_OUT BUILD_STATUS -- bash "$CORE_DIR/scripts/build-kernel.sh"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
echo "$REG_OUT"
ck; [[ $REG_STATUS -eq 0 ]] || fail "verify-syscall-registry.sh exited $REG_STATUS"

# The four names oslibc.h must not grow. FRAME keeps them.
for name in SYS_MOUSE SYS_WMSURFACE SYS_KBDEVENT SYS_WMEVENT; do
  ck; grep -q "^#define $name " "$FRAME_H" \
    || fail "osframe.h does not define $name"
  ck; grep -q "^#define $name " "$CORE_DIR/user/libc/oslibc.h" \
    && fail "oslibc.h grew $name — leave it in osframe.h only"
done

FRAME_BYTES=$(wc -c <"$FRAME_H" | tr -d ' ')
ck; [[ "$FRAME_BYTES" -gt 512 ]] \
  || fail "osframe.h is $FRAME_BYTES bytes; FRAME1 needs more than one 512-byte read"
SYS_ROWS=$(grep -cE '^#define SYS_[A-Z0-9_]+ [0-9]+$' "$FRAME_H" || true)
ck; [[ "$SYS_ROWS" -ge 2 ]] \
  || fail "osframe.h names $SYS_ROWS SYS_* rows; need at least two"

# No kernel .bss, no help, no new syscall — this milestone is host files.
# NO KERNEL *CODE* NAMES osframe.h. Comments are stripped first, and that is not
# a loophole: proc.dart's only mention of `osframe.h` today is a doc comment explaining
# which header the userland side of a syscall lives in --- prose, not reach. A check that fires on a
# sentence describing the rule cannot distinguish it from a violation of the
# rule, so it is asked of code -- and of directives under any spelling, which
# the raw grep could not see separately at all.
capture_sh PURITY_OUT PURITY_STATUS -- "python3 - '$CORE_DIR/kernel' <<'PY'
import pathlib, re, sys
NAMES = ['osframe']
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).rglob('*.dart')):
    src = re.sub(r'/[*].*?[*]/', '', f.read_text(), flags=re.S)
    for n, line in enumerate(src.split('\n'), 1):
        code = line.split('//', 1)[0]
        for name in NAMES:
            if name in code:
                bad.append('%s:%d: %s' % (f.name, n, code.strip()))
            if re.search(r'(import|include|part)\\b.*' + re.escape(name), line):
                bad.append('%s:%d: names it in a directive: %s'
                           % (f.name, n, line.strip()))
if bad:
    raise SystemExit('\n'.join(bad))
print('    (no kernel source names osframe outside a doc comment)')
PY"
ck; [[ $PURITY_STATUS -eq 0 ]] || { echo "$PURITY_OUT" >&2; fail "kernel CODE names osframe.h — it must not touch the kernel: $PURITY_OUT"; }
ck; ! grep -E 'frame\.h|osframe|FRAME1' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a FRAME name — no new help"

echo "STRUCTURAL: pass  osframe.h $FRAME_BYTES bytes, $SYS_ROWS SYS_* rows, registry agrees, no kernel edit"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"

DISK_IMG="$WORKDIR/frame1.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/abitst.elf" "$FRAME_H" \
  || fail "make-image.py could not write the volume"
TRUNC_IMG="$WORKDIR/frame1-trunc.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$TRUNC_IMG" \
  "$WORKDIR/abitst.elf" "$FRAME_H" --variant=trunc \
  || fail "make-image.py could not write the truncated volume"

command -v fsck_msdos >/dev/null 2>&1 || FSCK=/sbin/fsck_msdos
FSCK="${FSCK:-fsck_msdos}"
ck; [[ -x "$FSCK" ]] || command -v "$FSCK" >/dev/null 2>&1 \
  || setup_error "fsck_msdos not found"
capture FSCK_OUT FSCK_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK_STATUS -eq 0 ]] || { echo "$FSCK_OUT" >&2; fail "fsck_msdos rejected the image"; }
echo "IMAGE: pass  fsck_msdos accepts the volume"

if command -v hdiutil >/dev/null 2>&1; then
  mkdir -p "$MOUNTPOINT"
  capture ATTACH_OUT ATTACH_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
  ck; [[ $ATTACH_STATUS -eq 0 ]] \
    || { echo "$ATTACH_OUT" >&2; fail "hdiutil could not mount the image"; }
  ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH_OUT")"
  ck; [[ -f "$MOUNTPOINT/FRAME.H" ]] || fail "mounted volume has no FRAME.H"
  ck; [[ -f "$MOUNTPOINT/ABITST.ELF" ]] || fail "mounted volume has no ABITST.ELF"
  ck; cmp -s "$MOUNTPOINT/FRAME.H" "$FRAME_H" \
    || fail "macOS reads FRAME.H differently from osframe.h"
  ck; cmp -s "$MOUNTPOINT/ABITST.ELF" "$WORKDIR/abitst.elf" \
    || fail "macOS reads ABITST.ELF differently"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver reads FRAME.H and ABITST.ELF back"
fi

echo
echo "=== DERIVE ==="
DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$FRAME_H" "$DISK_IMG.frame" > "$DERIVED" \
  || fail "derive.py could not derive the full-table expectations"
TRUNC_DERIVED="$WORKDIR/derived-trunc.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$FRAME_H" "$TRUNC_IMG.frame" > "$TRUNC_DERIVED" \
  || fail "derive.py could not derive the truncated expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
td() { grep -m1 "^$1=" "$TRUNC_DERIVED" | cut -d= -f2-; }
ck; [[ "$(d planted_is_full)" -eq 1 ]] || fail "the main plant is not byte-identical to osframe.h"
ck; [[ "$(td planted_is_full)" -eq 0 ]] || fail "the truncated plant is still the full header"
ck; [[ "$(d fnv)" != "$(td fnv)" ]] \
  || fail "truncating one SYS_ row did not change the FNV — the control is vacuous"
ck; [[ "$(d len)" -gt 512 ]] || fail "planted FRAME.H is $(d len) bytes, not >512"
echo "DERIVED: FRAME.H $(d len) bytes FNV $(d fnv_hex); trunc FNV $(td fnv_hex)"

SHA_BEFORE=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3" img="$4"
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
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -drive "file=$img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" \
    --wait-for 'M1 END\n' --png "$outdir/shot.png" --screen-text "$outdir/screen.txt" \
    --keys "$keys"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
}

KEYS="$(typekeys "run abitst.elf"),ret,wait:8000"
drive_session "$WORKDIR/main" "$KEYS" "main" "$DISK_IMG"
SERIAL="$WORKDIR/main/serial.txt"
ck; [[ -s "$SERIAL" ]] || fail "the main boot captured no serial"

have() { ck; grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

have "$(d line)"
have "$(printf "ELF DONE EXIT %016X" "$(d exit)")"
havent "$(td fnv_hex)"
echo "CHECK: pass  ABITST.ELF printed $(d line) and exited $(printf %02X "$(d exit)")"

SHA_AFTER=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)
ck; [[ "$SHA_BEFORE" == "$SHA_AFTER" ]] \
  || fail "the main boot CHANGED the volume ($SHA_BEFORE -> $SHA_AFTER)"
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK2_STATUS -eq 0 ]] || fail "fsck_msdos rejected the volume after the boot"
echo "CHECK: pass  volume unchanged after the boot — sha256 $SHA_AFTER"

drive_session "$WORKDIR/trunc" "$KEYS" "trunc" "$TRUNC_IMG"
TSER="$WORKDIR/trunc/serial.txt"
ck; grep -qF -- "$(td line)" "$TSER" \
  || { sed -n '/M1 END/,$p' "$TSER" >&2; fail "the truncated boot did not print its own derived line"; }
ck; grep -qF -- "$(d line)" "$TSER" \
  && fail "the truncated boot printed the FULL-table line — the checksum did not fail"
ck; grep -qF -- "$(d fnv_hex)" "$TSER" \
  && fail "the truncated boot still produced the full-table FNV"
echo "CHECK: pass  truncated FRAME.H printed $(td fnv_hex) and not $(d fnv_hex)"

require_assertions "$ASSERTIONS_REQUIRED"
echo "FRAME1: PASS — host header $FRAME_H ($FRAME_BYTES bytes, $SYS_ROWS SYS_* rows) planted as FRAME.H; ABITST.ELF opened it, read it in 512-byte strides, printed magic $(d magic_hex) version $(d version) FNV $(d fnv_hex); a one-row truncate produced $(td fnv_hex); volume unchanged; no kernel .bss, no help, no new syscall"
exit 0
