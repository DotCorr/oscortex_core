#!/usr/bin/env bash
# core/tests/conformance/de-studio/run.sh
#
# DE Studio — listing is not the product. STUDIO.ELF exhibits planted
# catalog names that open on the volume, a derived key spawn(26)s one,
# and hidden `go NAME` is the idle-line Spotlight (ADR-0099). Not a
# builder, not live-edit, not a guest Dart SDK, not WM chrome.
#
# Reuses studio2's image and APP1.ELF. Three boots:
#   A — proc spawn studio.elf, derived key → APP1 HEAP
#   B — go app1.elf (no studio, no start-menu) → APP1 HEAP
#   C — no key, no go → APP1 does not start
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
STUDIO_C="$CORE_DIR/user/frame/studio.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"
STUDIO2="$SCRIPT_DIR/../studio2"

fail() { echo "DE-STUDIO: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-STUDIO: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

# DE exhibit does not call osgfx Skia or osmedia. Same switches as studio2b.
export OSMEDIA_FFMPEG="${OSMEDIA_FFMPEG:-0}"
export OSGFX_SKIA="${OSGFX_SKIA:-0}"
export OSGFX_CRT="${OSGFX_CRT:-0}"

# Floor is set after the first green run. A drop below it is the failure.
ASSERTIONS_REQUIRED=97

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-studio.XXXXXX")" \
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
ck; [[ -f "$STUDIO2/build-progs.sh" ]] || setup_error "no studio2/build-progs.sh"
ck; [[ -f "$STUDIO2/make-image.py" ]] || setup_error "no studio2/make-image.py"

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
ck; grep -q 'SYS_SPAWN' "$STUDIO_C" \
  || fail "studio.c never calls SYS_SPAWN"
ck; grep -q 'STUDIO2 HAVE' "$STUDIO_C" \
  || fail "studio.c never exhibits names that open on the volume"
ck; grep -q 'SYS_SPAWN 26' "$FRAME_H" \
  || fail "osframe.h does not name SYS_SPAWN 26"
ck; grep -q 'APPS.TXT' "$STUDIO_C" \
  || fail "studio.c does not bake APPS.TXT"
ck; ! grep -qE 'APP1\.ELF|APP2\.ELF' "$STUDIO_C" \
  || fail "studio.c hardcodes a catalog name"
ck; grep -q 'procCmdGoSp' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no hidden go prefix"
ck; grep -q 'shellGoArgs' "$CORE_DIR/kernel/proc.dart" \
  || fail "proc.dart has no shellGoArgs"
ck; grep -q 'shellGoArgs' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart does not dispatch go"
ck; ! grep -q 'go <' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a go help string — leave it out of help"
ck; ! grep -q 'proc spawn' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a proc spawn help string — leave it out of help"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — help moved"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — stolen last place"
ck; ! grep -n 'shellGoArgs' -A20 "$CORE_DIR/kernel/proc.dart" \
  | grep -q '@bss' \
  || fail "go donated .bss"
ck; ! grep -qiE 'studio\.c|STUDIO\.ELF|STUDIO1|STUDIO2|osxstudio' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names STUDIO — go is generic, not a studio hook"
ck; ! grep -E 'STUDIO|osxstudio|APPS\.TXT' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell.dart grew a STUDIO name — no new help"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "$REG_OUT"
echo "STRUCTURAL: pass  go hidden, spawn 26, help 2511, last .bss wmeventStore"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$STUDIO2/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "studio2/build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/studio.elf" ]] || fail "no studio.elf"
ck; [[ -s "$WORKDIR/app1.elf" ]] || fail "no app1.elf"

DISK_IMG="$WORKDIR/de-studio.img"
ck; python3 "$STUDIO2/make-image.py" "$DISK_IMG" \
  "$WORKDIR/studio.elf" "$WORKDIR/app1.elf" \
  || fail "make-image.py could not write the volume"

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
  ck; [[ -f "$MOUNTPOINT/APP1.ELF" ]] || fail "mounted volume has no APP1.ELF"
  ck; [[ -f "$MOUNTPOINT/APPS.TXT" ]] || fail "mounted volume has no APPS.TXT"
  ck; cmp -s "$MOUNTPOINT/STUDIO.ELF" "$WORKDIR/studio.elf" \
    || fail "macOS reads STUDIO.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APP1.ELF" "$WORKDIR/app1.elf" \
    || fail "macOS reads APP1.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APPS.TXT" "$DISK_IMG.apps" \
    || fail "macOS reads APPS.TXT differently from the planted catalog"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver reads STUDIO.ELF, APP1.ELF, APPS.TXT"
fi

echo
echo "=== DERIVE ==="
DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG.apps" "$STUDIO_C" > "$DERIVED" \
  || fail "derive.py could not derive expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
ck; [[ "$(d catalog_lines)" -eq 1 ]] || fail "the catalog is not one name"
ck; [[ "$(d token_0)" == "APP1.ELF" ]] || fail "first planted name is not APP1.ELF"
ck; [[ "$(d has_app1)" -eq 1 ]] || fail "the catalog does not list APP1.ELF"
ck; [[ "$(d go_token)" == "APP1.ELF" ]] || fail "go token is not the planted name"
echo "DERIVED: $(d token_0) key=$(d key_qcode) go=$(d go_cmd)"

SHA_BEFORE=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  local disk="$outdir/disk.img"
  : >"$ser"
  ck; cp "$DISK_IMG" "$disk" || fail "could not copy the planted volume for the $label boot"
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
    -drive "file=$disk,format=raw,if=ide,index=0,media=disk" \
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
                print("DE-STUDIO: QEMU", hello.get("QMP", {}).get("version", {}))
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
        if not wait_marker(serial, marker, timeout=25):
            raise SystemExit("never saw %s" % marker)
        continue
    if item.startswith("rel:"):
        parts = item.split(":")
        dx, dy = int(parts[1]), int(parts[2])
        events = []
        if dx:
            events.append({"type": "rel", "data": {"axis": "x", "value": dx}})
        if dy:
            events.append({"type": "rel", "data": {"axis": "y", "value": dy}})
        if events:
            q.cmd("input-send-event", events=events)
        time.sleep(0.05)
        continue
    if item.startswith("btn:"):
        parts = item.split(":")
        q.cmd("input-send-event", events=[
            {"type": "btn",
             "data": {"button": parts[1], "down": parts[2] == "down"}}])
        time.sleep(0.05)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(0.8)
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
echo "=== BOOT A — Studio exhibits planted names and launches APP1 ==="
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn studio.elf'),ret,until:USER WRITE STUDIO2 READY,wait:400"
KEYS="$KEYS,$(d rels_hit),wait:200,btn:left:down,wait:200,btn:left:up,wait:400"
KEYS="$KEYS,$(d key_qcode),until:USER WRITE APPS1 APP1 HEAP 1,wait:600"

drive_session "$WORKDIR/studio" "$KEYS" "studio"
SSER="$WORKDIR/studio/serial.txt"

echo
echo "=== BOOT B — hidden go NAME, no Studio, no start-menu ==="
GO_KEYS="$(typekeys "$(d go_cmd)"),ret,until:USER WRITE APPS1 APP1 HEAP 1,wait:600"

drive_session "$WORKDIR/go" "$GO_KEYS" "go"
GSER="$WORKDIR/go/serial.txt"

echo
echo "=== BOOT C — no key, no go, APP1 must not start ==="
NEG_KEYS="$(typekeys 'fb'),ret,wait:1500"
NEG_KEYS="$NEG_KEYS,$(typekeys 'wm on'),ret,wait:2500"
NEG_KEYS="$NEG_KEYS,$(typekeys 'proc spawn studio.elf'),ret,until:USER WRITE STUDIO2 READY,wait:2500"

drive_session "$WORKDIR/neg" "$NEG_KEYS" "neg"
NSER="$WORKDIR/neg/serial.txt"

echo
echo "=== ASSERT ==="
have() { ck; grep -qF -- "$1" "$SSER" || { sed -n '/M1 END/,$p' "$SSER" >&2; fail "the studio boot does not contain: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SSER" && fail "the studio boot contains what it must not: $1"; }
gohave() { ck; grep -qF -- "$1" "$GSER" || { sed -n '/M1 END/,$p' "$GSER" >&2; fail "the go boot does not contain: $1"; }; }
gohavent() { ck; grep -qF -- "$1" "$GSER" && fail "the go boot contains what it must not: $1"; }

have "$(d name_0)"
have "$(d have_line)"
have "$(d list_line)"
have "$(d ready_line)"
have "$(d launch_line)"
have "$(d ok_prefix)"
have "$(d app1_hello)"
have "$(d app1_heap)"
have "PROC SPAWN"
have "ELF FILE"
havent "STUDIO1 OPEN REFUSED"
havent "STUDIO2 REFUSED"
havent "$(d app1_heap_fail)"
havent "PROC END"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SSER" \
  || { sed -n '/M1 END/,$p' "$SSER" >&2; fail "something faulted during the studio boot"; }

gohave "$(d go_line)"
gohave "$(d app1_hello)"
gohave "$(d app1_heap)"
gohave "PROC SPAWN"
gohave "ELF FILE"
gohavent "STUDIO2 LAUNCH"
gohavent "$(d app1_heap_fail)"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$GSER" \
  || { sed -n '/M1 END/,$p' "$GSER" >&2; fail "something faulted during the go boot"; }

ck; grep -qF -- "$(d ready_line)" "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the negative boot did not reach STUDIO2 READY"; }
ck; grep -qF -- "$(d have_line)" "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the negative boot did not exhibit HAVE"; }
ck; grep -qF -- "$(d app1_heap)" "$NSER" \
  && fail "the negative boot started APP1 without a key or go"
ck; grep -qF -- "$(d launch_line)" "$NSER" \
  && fail "the negative boot launched without a key"
ck; grep -qF -- "$(d go_line)" "$NSER" \
  && fail "the negative boot printed GO without a go command"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "something faulted during the negative boot"; }

SHA_AFTER=$(shasum -a 256 "$DISK_IMG" | cut -d' ' -f1)
ck; [[ "$SHA_BEFORE" == "$SHA_AFTER" ]] \
  || fail "the boots CHANGED the volume ($SHA_BEFORE -> $SHA_AFTER)"
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK2_STATUS -eq 0 ]] || fail "fsck_msdos rejected the volume after the boots"
echo "CHECK: pass  Studio exhibited and launched APP1; go launched APP1; no-key stayed listed"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-STUDIO: PASS — STUDIO.ELF listed planted APPS.TXT, exhibited HAVE for the name that opens on the volume, derived key launched APP1.ELF (HEAP 1); hidden go app1.elf did the same without Studio or start-menu chrome; no key/go did not start APP1. Launcher/exhibit, not a builder. spawn is 26; go is not a new syscall; help 2511; last .bss wmeventStore."
exit 0
