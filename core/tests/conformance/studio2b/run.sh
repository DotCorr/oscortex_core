#!/usr/bin/env bash
# core/tests/conformance/studio2b/run.sh
#
# STUDIO2b persist — STUDIO.ELF remembers the last launched catalog name
# across a second start. docs/design/osxstudio.md. Listing is STUDIO1;
# launch is STUDIO2; this is data-only persist of SEL.DAT. Not a
# compiler, not a builder, not live-edit, not a guest Dart SDK.
#
# Boot A: proc spawn studio.elf, derived key selects APP1. Host reads
# SEL.DAT as the derived u32. Boot B (same volume): second Studio start
# exhibits that name selected. Anti-vacuity: APP2 is planted and must
# not appear selected. Negative: no key → no SEL.DAT, no SEL exhibit.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
STUDIO_C="$CORE_DIR/user/frame/studio.c"
FRAME_H="$CORE_DIR/user/frame/osframe.h"

fail() { echo "STUDIO2B: FAIL — $1" >&2; exit 1; }
setup_error() { echo "STUDIO2B: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

# Studio persist does not call osgfx Skia or osmedia. The 12MiB CRT
# heap blows vmFineBytes (4 MiB) and vmInit refuses every spawn.
# Same switches as files-fm / de-set2 / de-browse.
export OSMEDIA_FFMPEG="${OSMEDIA_FFMPEG:-0}"
export OSGFX_SKIA="${OSGFX_SKIA:-0}"
export OSGFX_CRT="${OSGFX_CRT:-0}"

# Floor is set after the first green run. A drop below it is the failure.
ASSERTIONS_REQUIRED=111

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-readelf \
            x86_64-elf-objdump; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

ck; WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-studio2b.XXXXXX")" \
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
# A sibling harness may rebuild build/kernel.elf with the 12MiB CRT
# while we are in QEMU. Pin the slim image we just produced.
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
ck; grep -q 'SYS_FDWRITE' "$STUDIO_C" \
  || fail "studio.c never calls SYS_FDWRITE"
ck; grep -q 'SEL.DAT' "$STUDIO_C" \
  || fail "studio.c does not name SEL.DAT"
ck; grep -q 'SEL_BYTES' "$STUDIO_C" \
  || fail "studio.c does not name SEL_BYTES"
ck; grep -q 'SYS_SPAWN 26' "$FRAME_H" \
  || fail "osframe.h does not name SYS_SPAWN 26"
ck; grep -q 'APPS.TXT' "$STUDIO_C" \
  || fail "studio.c does not bake APPS.TXT"
ck; ! grep -qE 'APP1\.ELF|APP2\.ELF' "$STUDIO_C" \
  || fail "studio.c hardcodes a catalog name"
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
ck; ! grep -qiE 'studio\.c|STUDIO\.ELF|STUDIO1|STUDIO2|osxstudio|SEL\.DAT' "$CORE_DIR/kernel/"*.dart \
  || fail "a kernel .dart names STUDIO / SEL.DAT — persist is userland"
capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh'"
ck; [[ $REG_STATUS -eq 0 ]] || { echo "$REG_OUT" >&2; fail "verify-syscall-registry.sh exited $REG_STATUS"; }
echo "$REG_OUT"
echo "STRUCTURAL: pass  SEL.DAT userland, spawn 26, help 2511, last .bss wmeventStore"

echo
echo "=== PROGRAMS ==="
capture BUILD_PROGS_OUT BP_STATUS -- bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR"
echo "$BUILD_PROGS_OUT"
ck; [[ $BP_STATUS -eq 0 ]] || fail "build-progs.sh exited $BP_STATUS"
ck; [[ -s "$WORKDIR/studio.elf" ]] || fail "no studio.elf"
ck; [[ -s "$WORKDIR/app1.elf" ]] || fail "no app1.elf"
ck; [[ -s "$WORKDIR/app2.elf" ]] || fail "no app2.elf"

DISK_IMG="$WORKDIR/studio2b.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/studio.elf" "$WORKDIR/app1.elf" "$WORKDIR/app2.elf" \
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
  ck; [[ -f "$MOUNTPOINT/APP2.ELF" ]] || fail "mounted volume has no APP2.ELF"
  ck; [[ -f "$MOUNTPOINT/APPS.TXT" ]] || fail "mounted volume has no APPS.TXT"
  ck; [[ ! -e "$MOUNTPOINT/SEL.DAT" ]] \
    || fail "SEL.DAT is already on the as-built volume — the guest creating it would prove nothing"
  ck; cmp -s "$MOUNTPOINT/STUDIO.ELF" "$WORKDIR/studio.elf" \
    || fail "macOS reads STUDIO.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APP1.ELF" "$WORKDIR/app1.elf" \
    || fail "macOS reads APP1.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APP2.ELF" "$WORKDIR/app2.elf" \
    || fail "macOS reads APP2.ELF differently"
  ck; cmp -s "$MOUNTPOINT/APPS.TXT" "$DISK_IMG.apps" \
    || fail "macOS reads APPS.TXT differently from the planted catalog"
  hdiutil detach "$ATTACHED" >/dev/null 2>&1
  ATTACHED=""
  echo "IMAGE: pass  macOS msdos driver reads STUDIO.ELF, APP1.ELF, APP2.ELF, APPS.TXT; no SEL.DAT"
fi

echo
echo "=== DERIVE ==="
DERIVED="$WORKDIR/derived.txt"
ck; python3 "$SCRIPT_DIR/derive.py" "$DISK_IMG.apps" "$STUDIO_C" > "$DERIVED" \
  || fail "derive.py could not derive expectations"
d() { grep -m1 "^$1=" "$DERIVED" | cut -d= -f2-; }
ck; [[ "$(d catalog_lines)" -eq 2 ]] || fail "the catalog is not two names"
ck; [[ "$(d token_0)" == "APP1.ELF" ]] || fail "first planted name is not APP1.ELF"
ck; [[ "$(d token_1)" == "APP2.ELF" ]] || fail "second planted name is not APP2.ELF"
ck; [[ "$(d persist_bytes)" -eq 4 ]] || fail "persist_bytes is $(d persist_bytes), expected 4"
ck; [[ "$(d sizeof_buf)" -ne "$(d persist_bytes)" ]] \
  || fail "sizeof-buf equals persist_bytes — the write-length control is vacuous"
ck; [[ "$(d sel_file)" == "SEL.DAT" ]] || fail "sel file is $(d sel_file), expected SEL.DAT"
ck; [[ "$(d sel_word)" -eq 0 ]] || fail "derived sel_word is not row 0"
ck; [[ "$(d has_app1)" -eq 1 ]] || fail "the catalog does not list APP1.ELF"
ck; [[ "$(d has_app2)" -eq 1 ]] || fail "the catalog does not list APP2.ELF"
echo "DERIVED: $(d token_0) vs $(d token_1) key=$(d key_qcode) sel_word=$(d sel_word) persist=$(d persist_bytes)"

typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

drive_session() {
  local outdir="$1" keys="$2" label="$3" disk="$4"
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
                print("STUDIO2B: QEMU", hello.get("QMP", {}).get("version", {}))
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
echo "=== BOOT A — spawn STUDIO.ELF, derived key selects APP1 ==="
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'proc spawn studio.elf'),ret,until:USER WRITE STUDIO2 READY,wait:400"
KEYS="$KEYS,$(d rels_hit),wait:200,btn:left:down,wait:200,btn:left:up,wait:400"
KEYS="$KEYS,$(d key_qcode),until:USER WRITE APPS1 APP1 HEAP 1,wait:800"

drive_session "$WORKDIR/main" "$KEYS" "main" "$DISK_IMG"
SERIAL="$WORKDIR/main/serial.txt"

echo
echo "=== PERSIST (host read-back) ==="
capture FSCK2_OUT FSCK2_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK2_STATUS -eq 0 ]] \
  || { echo "$FSCK2_OUT" >&2; fail "fsck_msdos rejected the volume after the guest wrote"; }
mkdir -p "$MOUNTPOINT"
capture ATTACH2_OUT ATTACH2_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
  -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DISK_IMG"
ck; [[ $ATTACH2_STATUS -eq 0 ]] \
  || { echo "$ATTACH2_OUT" >&2; fail "hdiutil could not mount the image the guest wrote"; }
ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH2_OUT")"
ck; [[ -f "$MOUNTPOINT/$(d sel_file)" ]] || fail "the mounted volume has no $(d sel_file)"
SEL_PATH="$WORKDIR/sel.dat"
cp "$MOUNTPOINT/$(d sel_file)" "$SEL_PATH" || fail "could not copy $(d sel_file) off the volume"
hdiutil detach "$ATTACHED" >/dev/null 2>&1
ATTACHED=""

SEL_N=$(wc -c <"$SEL_PATH" | tr -d ' ')
ck; [[ "$SEL_N" -eq "$(d persist_bytes)" ]] \
  || fail "$(d sel_file) is $SEL_N bytes, expected $(d persist_bytes) — a sizeof(buf) write would be $(d sizeof_buf)"
capture_sh TH_OUT TH_STATUS -- "python3 - '$SEL_PATH' '$(d sel_word)' '$(d persist_bytes)' <<'PY'
import sys
blob = open(sys.argv[1], 'rb').read()
want = int(sys.argv[2])
n = int(sys.argv[3])
if len(blob) != n:
    raise SystemExit('%s is %d bytes, expected %d' % (sys.argv[1], len(blob), n))
got = int.from_bytes(blob[:4], 'little')
if got != want:
    raise SystemExit('SEL.DAT is %d, expected row %d' % (got, want))
print('    SEL.DAT %d bytes = %d (row 0 / APP1)' % (n, got))
PY"
ck; [[ $TH_STATUS -eq 0 ]] || { echo "$TH_OUT" >&2; fail "SEL.DAT does not hold the derived row"; }
echo "$TH_OUT"
echo "PERSIST: pass  $(d sel_file) is $(d persist_bytes) bytes of row $(d sel_word), fsck_msdos clean"

echo
echo "=== BOOT B — second Studio start, exhibit the persisted name ==="
RE_KEYS="$(typekeys 'fb'),ret,wait:1500"
RE_KEYS="$RE_KEYS,$(typekeys 'wm on'),ret,wait:2500"
RE_KEYS="$RE_KEYS,$(typekeys 'proc spawn studio.elf'),ret,until:USER WRITE STUDIO2 SEL,wait:800"

drive_session "$WORKDIR/again" "$RE_KEYS" "again" "$DISK_IMG"
ASER="$WORKDIR/again/serial.txt"

echo
echo "=== BOOT C — no key, no SEL.DAT on a fresh volume ==="
NEG_IMG="$WORKDIR/neg.img"
ck; python3 "$SCRIPT_DIR/make-image.py" "$NEG_IMG" \
  "$WORKDIR/studio.elf" "$WORKDIR/app1.elf" "$WORKDIR/app2.elf" \
  || fail "make-image.py could not write the negative volume"
NEG_KEYS="$(typekeys 'fb'),ret,wait:1500"
NEG_KEYS="$NEG_KEYS,$(typekeys 'wm on'),ret,wait:2500"
NEG_KEYS="$NEG_KEYS,$(typekeys 'proc spawn studio.elf'),ret,until:USER WRITE STUDIO2 READY,wait:2500"

drive_session "$WORKDIR/neg" "$NEG_KEYS" "neg" "$NEG_IMG"
NSER="$WORKDIR/neg/serial.txt"

echo
echo "=== ASSERT ==="
have() { ck; grep -qF -- "$1" "$SERIAL" || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "the first boot does not contain: $1"; }; }
havent() { ck; grep -qF -- "$1" "$SERIAL" && fail "the first boot contains what it must not: $1"; }
ahave() { ck; grep -qF -- "$1" "$ASER" || { sed -n '/M1 END/,$p' "$ASER" >&2; fail "the second Studio start does not contain: $1"; }; }
ahavent() { ck; grep -qF -- "$1" "$ASER" && fail "the second Studio start contains what it must not: $1"; }

have "$(d name_0)"
have "$(d name_1)"
have "$(d list_line)"
have "$(d ready_line)"
have "$(d launch_line)"
have "$(d save_line)"
have "$(d ok_prefix)"
have "$(d app1_hello)"
have "$(d app1_heap)"
have "PROC SPAWN"
have "ELF FILE"
havent "$(d sel_line)"
havent "$(d other_sel)"
havent "STUDIO1 OPEN REFUSED"
havent "STUDIO2 REFUSED"
havent "$(d app1_heap_fail)"
havent "$(d app2_heap)"
havent "PROC END"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SERIAL" \
  || { sed -n '/M1 END/,$p' "$SERIAL" >&2; fail "something faulted during the first boot"; }

ahave "$(d ready_line)"
ahave "$(d sel_line)"
ahave "$(d name_0)"
ahave "$(d name_1)"
ahavent "$(d other_sel)"
ahavent "$(d launch_line)"
ahavent "$(d app1_heap)"
ahavent "$(d app2_heap)"
ahavent "$(d save_line)"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$ASER" \
  || { sed -n '/M1 END/,$p' "$ASER" >&2; fail "something faulted during the second Studio start"; }

ck; grep -qF -- "$(d ready_line)" "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "the negative boot did not reach STUDIO2 READY"; }
ck; grep -qF -- "$(d sel_line)" "$NSER" \
  && fail "the negative boot exhibited a selection without a prior persist"
ck; grep -qF -- "$(d other_sel)" "$NSER" \
  && fail "the negative boot exhibited the other plant as selected"
ck; grep -qF -- "$(d save_line)" "$NSER" \
  && fail "the negative boot persisted without a key"
ck; grep -qF -- "$(d app1_heap)" "$NSER" \
  && fail "the negative boot started APP1 without a key"
ck; grep -qF -- "$(d launch_line)" "$NSER" \
  && fail "the negative boot launched without a key"
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$NSER" \
  || { sed -n '/M1 END/,$p' "$NSER" >&2; fail "something faulted during the negative boot"; }

mkdir -p "$MOUNTPOINT"
capture ATTACH3_OUT ATTACH3_STATUS -- hdiutil attach -imagekey diskimage-class=CRawDiskImage \
  -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$NEG_IMG"
ck; [[ $ATTACH3_STATUS -eq 0 ]] \
  || { echo "$ATTACH3_OUT" >&2; fail "hdiutil could not mount the negative image"; }
ATTACHED="$(awk '/dev\/disk/ {print $1; exit}' <<<"$ATTACH3_OUT")"
ck; [[ ! -e "$MOUNTPOINT/$(d sel_file)" ]] \
  || fail "the negative boot created $(d sel_file) — persist without a key is vacuous"
hdiutil detach "$ATTACHED" >/dev/null 2>&1
ATTACHED=""

capture FSCK3_OUT FSCK3_STATUS -- "$FSCK" -n "$DISK_IMG"
ck; [[ $FSCK3_STATUS -eq 0 ]] || fail "fsck_msdos rejected the persisted volume"
echo "CHECK: pass  APP1 selected and persisted; second start exhibited that name; APP2 not selected"

require_assertions "$ASSERTIONS_REQUIRED"
echo "STUDIO2B: PASS — STUDIO.ELF selected APP1.ELF, wrote SEL.DAT as the derived u32, and a second Studio start exhibited that name selected. APP2.ELF was planted and did not appear selected. No key did not persist. Destroy-on-save, not atomic, not a builder, not emit."
exit 0
