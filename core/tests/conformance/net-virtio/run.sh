#!/usr/bin/env bash
# core/tests/conformance/net-virtio/run.sh
#
# ADR-0145 — VirtIO-net is a second NIC class (not e1000).
# docs/decisions/0145-virtio-net-is-a-second-nic-class.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# QEMU attaches modern VirtIO-net
# (`-device virtio-net-pci-non-transitional,mac=<derived>` → 1af4:1041).
# Transitional `virtio-net-pci` is 1af4:1000 and is not this door.
# info pci has 1af4:1041. The MAC is not a kernel constant.
#
# Negative: plain `-M pc` (default e1000 only) prints NIC VIRTIO NONE
# and never the plant MAC from `nic virtio`. Bare `nic` still works
# on the e1000 when present (coexistence).
#
# Not TX/RX. Not Wi-Fi. Not OTA. No Graphite. No Dell SKU.
# Syscall 11 stays fdwait. Not in help.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "Net-virtio: FAIL — $1" >&2; exit 1; }
setup_error() { echo "Net-virtio: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=28

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-net-virtio.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"

echo
echo "=== STRUCTURAL ==="
ck; [[ -f "$CORE_DIR/kernel/virtnet.dart" ]] || fail "virtnet.dart missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/virtnet.dart" \
  || fail "virtnet.dart is not a part"
ck; grep -q "^part 'virtnet.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list virtnet.dart"
ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/virtnet.dart" \
  || fail "virtnet.dart donated .bss"
ck; grep -q 'virtnetDevice = 0x1041' "$CORE_DIR/kernel/virtnet.dart" \
  || fail "virtnet.dart lost device id 0x1041 — would be an e1000 relabel"
ck; ! grep -qE '0x100[Ee]|8086:100' "$CORE_DIR/kernel/virtnet.dart" \
  || fail "virtnet.dart names e1000 — second class must not be a SKU relabel"
ck; grep -q 'virtnetStrCmd' "$CORE_DIR/kernel/shell.dart" \
  || fail "shell does not dispatch nic virtio"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing}, expected 2511"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore"
echo "STRUCTURAL: pass  virtnet is no-@bss 1041 class door; not e1000; fdwait"

echo
echo "=== DERIVE ==="
python3 - "$WORKDIR" "$CORE_DIR/kernel/virtnet.dart" "$CORE_DIR/kernel/nic.dart" <<'PY' || setup_error "derive failed"
import os, random, sys
wd = sys.argv[1]
srcs = open(sys.argv[2]).read() + open(sys.argv[3]).read()
while True:
    mac = [random.randrange(256) for _ in range(6)]
    mac[0] = (mac[0] & 0xFE) | 0x02
    s = ":".join("%02x" % b for b in mac)
    if s.lower() not in srcs.lower() and "52:54:00" not in s:
        break
open(os.path.join(wd, "mac.txt"), "w").write(s)
print("DERIVE: MAC=%s" % s)
PY
MAC=$(tr -d '\n' <"$WORKDIR/mac.txt")
ck; [[ ${#MAC} -eq 17 ]] || fail "MAC length ${#MAC}"
ck; ! grep -Fqi "$MAC" "$CORE_DIR/kernel/virtnet.dart" || fail "plant in virtnet.dart"
ck; ! grep -Fqi "$MAC" "$CORE_DIR/kernel/nic.dart" || fail "plant in nic.dart"
MAC_UP=$(printf '%s' "$MAC" | tr 'a-f' 'A-F')
EXPECT="NIC VIRTIO ${MAC_UP}"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc'}.get(c, c.lower()) for c in sys.argv[1]))
" "$1"; }

drive() {
  local outdir="$1"
  shift
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port"
  timeout 90 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
    "$@" \
    -serial "file:$ser" -display none -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qp=$!
  local st
  run_status st -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for $'M1 END\n' \
    --png "$outdir/s.png" --screen-text "$outdir/s.txt" \
    --monitor-command 'info pci' --monitor-capture "$outdir/info-pci.txt" \
    --keys "$(typekeys 'nic virtio'),ret,wait:1500,$(typekeys nic),ret,wait:800"
  local qs
  await qs "$qp"
  ck; [[ $st -eq 0 ]] || { cat "$outdir/qemu.log" >&2; cat "$ser" >&2; fail "qmp-drive $outdir"; }
  ck; if [[ $qs -ne 0 && $qs -ne 124 ]]; then fail "qemu $qs $outdir"; fi
}

echo
echo "=== BOOT virtio-net ==="
drive "$WORKDIR/vnet" \
  -netdev "user,id=vn0" \
  -device "virtio-net-pci-non-transitional,netdev=vn0,mac=$MAC"

echo
echo "=== BOOT default pc (no virtio-net) ==="
drive "$WORKDIR/none"

echo
echo "=== CRITERION ==="
ck; grep -qi '1af4:1041' "$WORKDIR/vnet/info-pci.txt" \
  || fail "info pci has no 1af4:1041"
ck; grep -qF "$EXPECT" "$WORKDIR/vnet/serial.txt" \
  || { sed -n '/M1 END/,$p' "$WORKDIR/vnet/serial.txt" >&2; fail "missing $EXPECT"; }
ck; ! grep -q 'NIC VIRTIO NONE' "$WORKDIR/vnet/serial.txt" \
  || fail "positive boot printed NONE"
echo "ASSERT: pass  nic virtio printed planted MAC; 1af4:1041 present"

ck; ! grep -qi '1af4:1041' "$WORKDIR/none/info-pci.txt" \
  || fail "negative info pci still has virtio-net"
ck; grep -q 'NIC VIRTIO NONE' "$WORKDIR/none/serial.txt" \
  || fail "negative boot missing NIC VIRTIO NONE"
ck; ! grep -qF "$EXPECT" "$WORKDIR/none/serial.txt" \
  || fail "negative boot printed the plant"
# e1000 coexistence: on the no-virtio boot, bare `nic` still works.
ck; grep -qE '^NIC MAC ' "$WORKDIR/none/serial.txt" \
  || fail "bare nic lost the e1000 path on plain -M pc"
echo "ASSERT: pass  no virtio-net → NIC VIRTIO NONE; e1000 nic path intact"

require_assertions "$ASSERTIONS_REQUIRED"
echo "Net-virtio: PASS — VirtIO-net class 1AF4:1041 prints derived MAC; e1000 path untouched; absent device is NONE"
exit 0
