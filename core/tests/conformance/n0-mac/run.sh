#!/usr/bin/env bash
# core/tests/conformance/n0-mac/run.sh
#
# N0 — the kernel finds the e1000 and reads its MAC address.
# docs/design/net-stack.md §9 N0, ADR-0058.
#
# Binary: the harness types a MAC on the QEMU command line
# (`-nic user,model=e1000,mac=...,romfile=`) and requires the kernel's
# printed `NIC MAC` line to equal that string, byte for byte. The
# expectation comes from outside the kernel. `romfile=` is mandatory:
# without it the option ROM's DHCP contaminates later pcaps.
#
# Negative control: `-nic none` prints `NIC NONE` and no MAC line.
# Anti-vacuity: the expected MAC must be non-empty.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "N0-mac: FAIL — $1" >&2; exit 1; }
setup_error() { echo "N0-mac: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=29

for tool in qemu-system-x86_64 python3 x86_64-elf-objdump x86_64-elf-readelf \
            x86_64-elf-objcopy llvm-nm; do
  ck; command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

# Derived here, typed onto the QEMU line, compared against the capture.
# It must not appear in the kernel: the harness is the only place this
# string is a constant.
# Chosen here, typed onto the QEMU line, compared against the capture.
# Not QEMU's default 52:54:00:12:34:56, and not a string that appears
# in the kernel. The design's example 52:54:00:AB:CD:EF is the same idea.
MAC="52:54:00:AB:CD:EF"
ck; [[ -n "$MAC" ]] || fail "the expected MAC is empty — the comparison would be vacuous"
ck; [[ "$MAC" == *:*:*:*:*:* ]] || fail "the derived MAC $MAC is not six colon-separated octets"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
ck; [[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
ck; [[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-n0-mac.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== STRUCTURAL ==="

# The MAC the harness typed must not be sitting in the kernel. A kernel
# that printed a constant would pass one boot and fail a second with a
# different mac=; this check catches the constant before the first boot.
MAC_COMPACT="${MAC//:/}"
ck; ! grep -Fqi "$MAC" "$CORE_DIR/kernel/nic.dart" "$CORE_DIR/kernel/pci.dart" \
  || fail "the derived MAC $MAC appears in the kernel — the expectation would not be coming from outside"
ck; ! grep -Fqi "$MAC_COMPACT" "$CORE_DIR/kernel/nic.dart" \
  || fail "the compact form $MAC_COMPACT appears in nic.dart"

# ZERO new .bss: nic.dart donates nothing, so D7 stays last.
ck; ! grep -q 'Bss(' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart declares a Bss — N0 was supposed to print from locals"
ck; grep -q "part 'nic.dart';" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not name nic.dart"
# nic.dart is after kbdq and before wmevent: D7 keeps last place.
PART_ORDER=$(awk "/part '/{print}" "$CORE_DIR/kernel/kmain.dart" | tr -d "'")
echo "$PART_ORDER" | awk '
  /part kbdq.dart/ { k=NR }
  /part nic.dart/  { n=NR }
  /part wmevent.dart/ { w=NR }
  END {
    if (!k || !n || !w) { print "missing"; exit 1 }
    if (!(k<n && n<w)) { print "order " k " " n " " w; exit 1 }
    print "ok"
  }' >/dev/null \
  || fail "nic.dart is not between kbdq.dart and wmevent.dart — D7 would lose last place"

# N0's MAC print does not write a port. pciWrite32 exists for G1/N1
# (BME); nicReport still does not call it.
ck; ! grep -n '^[^/]*port_outl' "$CORE_DIR/kernel/nic.dart" \
  || fail "nic.dart writes a port — N0's MAC print is a read"
ck; grep -q 'void pciWrite32' "$CORE_DIR/kernel/pci.dart" \
  || fail "pciWrite32 is gone — G1 and N1 need the write path"

# Not in help.
ck; ! grep -E 'nic|net' "$CORE_DIR/kernel/shell.dart" | grep -q 'shellStrHelp' \
  || fail "nic or net was added to help"

ck; grep -q 'pciFindByClass' "$CORE_DIR/kernel/pci.dart" \
  || fail "pci.dart has no pciFindByClass"
ck; grep -q 'pciReadBar' "$CORE_DIR/kernel/pci.dart" \
  || fail "pci.dart has no pciReadBar"
ck; grep -q 'romfile=' "$SCRIPT_DIR/run.sh" \
  || fail "this harness does not pass romfile= — later pcap assertions would be vacuous"

echo "STRUCTURAL: pass  no .bss, part order, nicReport is a read, MAC not in the kernel, not in help"

boot_nic() {
  local label="$1"
  shift
  mkdir -p "$WORKDIR/$label"
  local ser="$WORKDIR/$label/serial.txt"
  local png="$WORKDIR/$label/shot.png"
  local screen="$WORKDIR/$label/screen.txt"
  : >"$ser"
  local port
  port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 120 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -cpu qemu64 \
    -vga std \
    -display none \
    -no-reboot \
    -serial "file:$ser" \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    "$@" \
    >"$WORKDIR/$label/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$ser" \
    --wait-for 'M1 END\n' --png "$png" --screen-text "$screen" \
    --keys "n,i,c,ret"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$WORKDIR/$label/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status on the $label boot"
  fi
  cp "$ser" "$CORE_DIR/build/n0-mac-$label-serial.txt"
}

echo
echo "=== BOOT (mac=$MAC, romfile=) ==="
# romfile= is empty on purpose: the option ROM's DHCP is seven frames the
# kernel did not send (net-stack.md §0.2 fact 8).
# -nic …,romfile= is rejected by this QEMU ("Invalid parameter 'romfile'").
# The measured form (net-e1000.md §7.2) is -netdev + -device with romfile=
# on the device. -net none drops the default NIC so we have exactly one.
boot_nic present \
  -net none \
  -netdev user,id=n0 \
  -device "e1000,netdev=n0,mac=$MAC,romfile="
SER="$WORKDIR/present/serial.txt"

echo
echo "=== ASSERT (derived MAC) ==="
ck; grep -q "NIC MAC $MAC" "$SER" \
  || { echo "--- serial ---" >&2; cat -v "$SER" >&2; \
       fail "the capture does not contain NIC MAC $MAC — the kernel did not print the MAC the harness typed"; }
MAC_LINES=$(grep -c '^NIC MAC ' "$SER" || true)
ck; [[ "$MAC_LINES" -eq 1 ]] \
  || fail "the capture has $MAC_LINES NIC MAC lines, want exactly 1"
ck; ! grep -q 'NIC NONE' "$SER" \
  || fail "the present boot printed NIC NONE"
echo "ASSERT: pass  printed MAC equals the mac= string this harness typed ($MAC)"

echo
echo "=== BOOT (negative: -nic none) ==="
boot_nic absent -nic none
SER_NONE="$WORKDIR/absent/serial.txt"

ck; grep -q 'NIC NONE' "$SER_NONE" \
  || { echo "--- serial ---" >&2; cat -v "$SER_NONE" >&2; \
       fail "the -nic none boot did not print NIC NONE"; }
ck; ! grep -q 'NIC MAC ' "$SER_NONE" \
  || fail "the -nic none boot printed a NIC MAC line — the device was supposed to be gone"
echo "ASSERT: pass  -nic none prints NIC NONE and no MAC line"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "N0-mac: PASS — kernel MAC equals the mac= this harness typed ($MAC); -nic none prints NONE; romfile=; no new .bss"
exit 0
