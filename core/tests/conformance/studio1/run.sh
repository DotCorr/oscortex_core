#!/usr/bin/env bash
# core/tests/conformance/studio1/run.sh
#
# STUDIO1 listing — a FRAME surface that lists APPS.TXT catalog names.
# docs/design/osxstudio.md NEXT. Not an IDE, not a builder, not opendir.
#
# STUDIO.ELF (core/user/frame/studio.c, osframe.h) is started with
# `proc spawn`. It opens the planted APPS.TXT, reads the names, writes
# them to COM1, and paints a colour strip if the compositor is on.
# The host derive.py knows the planted bytes; the capture must contain
# APP1.ELF. Negative: a catalog truncated to APP2.ELF must not print
# APP1.ELF. No new syscall, no kernel .bss, no help line.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
STUDIO_C="$CORE_DIR/user/frame/studio.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "STUDIO1: FAIL — $1" >&2; exit 1; }
setup_error() { echo "STUDIO1: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

# Listing does not call osgfx Skia or osmedia. Same switches as studio2b.
export OSMEDIA_FFMPEG="${OSMEDIA_FFMPEG:-0}"
export OSGFX_SKIA="${OSGFX_SKIA:-0}"
export OSGFX_CRT="${OSGFX_CRT:-0}"

# Floor is set after the first green run. A drop below it is the failure.
ASSERTIONS_REQUIRED=62

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-studio1.XXXXXX")" \
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
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"
ck; [[ -f "$STUDIO_C" ]] || setup_error "no studio.c at $STUDIO_C"
ck; [[ -f "$FRAME_H" ]] || setup_error "no osframe.h at $FRAME_H"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
ck; cp "$KERNEL_ELF" "$WORKDIR/kernel.elf" \
  || fail "could not snapshot kernel.elf"
KERNEL_ELF="$WORKDIR/kernel.elf"

echo
echo "=== STRUCTURAL ==="
ck; grep -q '#include "osframe.h"' "$STUDIO_C" \
  || fail "studio.c does not include osframe.h"
ck; ! grep -qE '^#define SYS_' "$STUDIO_C" \
  || fail "studio.c copies SYS_* by hand — include osframe.h"
ck; grep -q 'APPS.TXT' "$STUDIO_C" \
  || fail "studio.c does not bake APPS.TXT"
ck; ! grep -qE 'APP1\.ELF|APP2\.ELF' "$STUDIO_C" \
  || fail "studio.c hardcodes a catalog name"
ck; ! grep -qiE 'studio\.c|STUDIO\.ELF|STUDIO1|osxstudio' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names STUDIO — the listing must not touch the kernel"
ck; ! grep -E 'STUDIO|osxstudio|APPS\.TXT' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a STUDIO name — no new help"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "STRUCTURAL: pass  osframe.h only, APPS.TXT baked, no catalog literal, no kernel edit"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/studio.elf" ]] || fail "no studio.elf"

DISK_IMG="$WORKDIR/studio1.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" "$WORKDIR/studio.elf" \
  || fail "make-image.py could not write the volume"
TRUNC_IMG="$WORKDIR/studio1-trunc.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$TRUNC_IMG" "$WORKDIR/studio.elf" \
  --variant=trunc \
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
  ck; [[ -f "$MOUNTPOINT/STUDIO.ELF" ]] || fail "mounted volume has no STUDIO.ELF"
  ck; [[ -f "$MOUNTPOINT/APPS.TXT" ]] || fail "mounted volume has no APPS.TXT"
  ck; cmp -s "$MOUNTPOINT/STUDIO.ELF" "$WORKDIR/studio.elf" \
    || fail "macOS reads STUDIO.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APPS.TXT" "$DISK_IMG.apps" \
    || fail "macOS reads APPS.TXT differently from the planted catalog"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver reads STUDIO.ELF and APPS.TXT"
fi

echo
echo "=== DERIVE ==="
DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG.apps" > "$DERIVED" \
  || fail "derive.py could not derive the full-catalog expectations"
TRUNC_DERIVED="$WORKDIR/derived-trunc.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$TRUNC_IMG.apps" > "$TRUNC_DERIVED" \
  || fail "derive.py could not derive the truncated expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
td() { grep -m1 "^$1=" "$TRUNC_DERIVED" | cut -d= -f2-; }
ck; [[ "$(d catalog_lines)" -eq 2 ]] || fail "the full catalog is not two names"
ck; [[ "$(td catalog_lines)" -eq 1 ]] || fail "the truncated catalog is not one name"
ck; [[ "$(d has_app1)" -eq 1 ]] || fail "the full catalog does not list APP1.ELF"
ck; [[ "$(td has_app1)" -eq 0 ]] || fail "the truncated catalog still lists APP1.ELF"
ck; [[ "$(d token_0)" == "APP1.ELF" ]] || fail "first planted name is not APP1.ELF"
echo "DERIVED: $(d token_0) / $(d token_1); trunc $(td token_0)"

SHA_BEFORE=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)

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
  run_status drive_status -- python3 - "$port" "$ser" "$keys" <<'PY'
import json, os, socket, sys, time

port, serial, keys = int(sys.argv[1]), sys.argv[2], sys.argv[3]

class Qmp:
    def __init__(self, port):
        deadline = time.time() + 20
        last = None
        while time.time() < deadline:
            try:
                self.s = socket.create_connection(("127.0.0.1", port), timeout=2)
                self.f = self.s.makefile("rw", encoding="utf-8")
                hello = json.loads(self.f.readline())
                self.cmd("qmp_capabilities")
                print("STUDIO1: QEMU", hello.get("QMP", {}).get("version", {}))
                return
            except OSError as e:
                last = e
                time.sleep(0.2)
        raise SystemExit("could not connect to QMP: %s" % last)

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    raise SystemExit("QMP %s: %s" % (execute, msg["error"]))
                return msg["return"]

def count_marker(path, marker):
    if not os.path.exists(path):
        return 0
    return open(path, "rb").read().count(marker.encode("latin-1"))

def wait_marker(path, marker, timeout=25, at_least=1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if count_marker(path, marker) >= at_least:
            return True
        time.sleep(0.1)
    return False

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.5)
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        if not wait_marker(serial, marker, timeout=20):
            raise SystemExit("never saw %s" % marker)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(0.4)
q.cmd("quit")
PY
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial (tail) ---" >&2
    tail -80 "$ser" >&2
    fail "session driver exited $drive_status for the $label boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status on the $label boot"
  fi
  ck; [[ -s "$ser" ]] || fail "the $label boot captured no serial"
}

echo
echo "=== BOOT A — spawn STUDIO.ELF, list the planted catalog ==="
# READY yielders print PREEMPT forever; wait for the list marker, then quit.
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn studio.elf'),ret,until:USER WRITE STUDIO1 LIST,wait:400"

drive_session "$WORKDIR/main" "$KEYS" "main" "$DISK_IMG"
SERIAL="$WORKDIR/main/serial.txt"

echo
echo "=== BOOT B — truncated catalog must not invent APP1.ELF ==="
drive_session "$WORKDIR/trunc" "$KEYS" "trunc" "$TRUNC_IMG"
TSER="$WORKDIR/trunc/serial.txt"

echo
echo "=== ASSERT ==="
have() { ck; grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the transcript does not contain: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SERIAL" && fail "the transcript contains what it must not: $1"; }

have "$(d name_0)"
have "$(d name_1)"
have "$(d names_line)"
have "$(d list_line)"
have "$(d token_0)"
have "PROC SPAWN"
have "ELF FILE"
havent "STUDIO1 OPEN REFUSED"
havent "PROC END"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SERIAL" \
  || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "something faulted during the main boot"; }

ck; grep -qF -- "$(td name_0)" "$TSER" \
  || { sed -n '/M1 END/,$p' "$TSER" >&2; fail "the truncated boot did not print its planted name"; }
ck; grep -qF -- "APP1.ELF" "$TSER" \
  && fail "the truncated boot printed APP1.ELF — the listing did not come from APPS.TXT"
ck; grep -qF -- "$(d name_0)" "$TSER" \
  && fail "the truncated boot printed the full-catalog APP1 line"
ck; grep -qF -- "$(d names_line)" "$TSER" \
  && fail "the truncated boot printed the full-catalog NAMES line"

SHA_AFTER=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)
ck; [[ "$SHA_BEFORE" == "$SHA_AFTER" ]] \
  || fail "the main boot CHANGED the volume ($SHA_BEFORE -> $SHA_AFTER)"
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK2_STATUS -eq 0 ]] || fail "fsck_msdos rejected the volume after the boot"
echo "CHECK: pass  APP1.ELF listed from APPS.TXT; trunc did not invent it; volume unchanged"

require_assertions "$ASSERTIONS_REQUIRED"
echo "STUDIO1: PASS — STUDIO.ELF opened planted APPS.TXT, wrote APP1.ELF and APP2.ELF to COM1, listed $(d catalog_lines) names; a one-name truncate did not print APP1.ELF; volume unchanged; no kernel .bss, no help, no new syscall. This is a listing surface, not an editor and not a builder."
exit 0
