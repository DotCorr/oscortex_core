#!/usr/bin/env bash
# core/tests/conformance/p4-bios/run.sh
#
# PORT4 — QEMU SeaBIOS + Limine hybrid ISO loads our Multiboot1 kernel
# without OVMF and without `-kernel`. docs/design/portable-hardware.md
# PORT note, ADR-0072.
#
# Binary: qemu-system-x86_64 -cdrom hybrid.iso (QEMU's built-in SeaBIOS).
# No -bios, no pflash, no -kernel. Serial first line is the existing M0
# banner (derived, not a new string). After M1 END, `fb` prints an
# ADR-0064 winner (GOP / BAR / NONE). GOP is not *required* on BIOS
# (VGA/Bochs fallback is the point).
#
# Negative: the same kernel.elf under `-kernel` still prints
# OSCORTEX M0 OK (m0-boot's first-line contract).
# This harness does not replace p2-gop (UEFI GOP stays that file).
#
# Not a metal BIOS boot. Not a GOP requirement. No kernel .bss, no help.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "P4-bios: FAIL — $1" >&2; exit 1; }
setup_error() { echo "P4-bios: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Derived from a run, not counted by hand.
ASSERTIONS_REQUIRED=34

command -v qemu-system-x86_64 >/dev/null 2>&1 || setup_error "qemu-system-x86_64 not found on PATH (brew install qemu)"
command -v python3 >/dev/null 2>&1 || setup_error "python3 not found on PATH"
command -v xorriso >/dev/null 2>&1 || setup_error "xorriso not found on PATH (brew install xorriso)"
command -v limine >/dev/null 2>&1 || setup_error "limine not found on PATH (brew install limine)"
command -v x86_64-elf-readelf >/dev/null 2>&1 || setup_error "x86_64-elf-readelf not found on PATH"
command -v x86_64-elf-objdump >/dev/null 2>&1 || setup_error "x86_64-elf-objdump not found on PATH"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-p4-bios.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ===========================================================================
# Step 1 — build the same kernel.elf the Multiboot harnesses use.
# ===========================================================================
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

# ===========================================================================
# Step 2 — structural. No kernel code is this milestone; the ISO is.
# ===========================================================================
echo
echo "=== STRUCTURAL ==="

ck; grep -q 'limine bios-install' "$CORE_DIR/scripts/build-uefi-image.sh" \
  || fail "build-uefi-image.sh does not run limine bios-install — the ISO is not a hybrid"
ck; grep -q 'limine-bios.sys' "$CORE_DIR/scripts/build-uefi-image.sh" \
  || fail "build-uefi-image.sh does not mention limine-bios.sys"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — PORT added a help line"

ck; ! grep -q 'bios\|seabios\|limine' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "PORT added a syscall — the criterion forbids one"

# Multiboot1 header still present — BIOS is a second *loader*, not a
# second container. Same magic + flags 7 the UEFI path kept.
HDR=$(x86_64-elf-objdump -s -j .multiboot "$KERNEL_ELF" | awk '/100000/{print $2,$3,$4; exit}')
ck; [[ "$HDR" == "02b0ad1b 07000000 f74f52e4" ]] \
  || fail "Multiboot1 header is $HDR, expected 02b0ad1b 07000000 f74f52e4 (magic + flags 7 + checksum)"

LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — D7 lost last place"

capture_sh VERIFY_OUT VERIFY_STATUS -- "OSCORTEX_ALLOWLIST='$CORE_DIR/tools/bare-symbol-allowlist.txt' bash '$CORE_DIR/scripts/verify-freestanding.sh' '$KERNEL_ELF'"
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  hybrid recipe has bios-install; VIDEO header intact; no help, no syscall; wmeventStore last"

# ===========================================================================
# Step 3 — hybrid ISO (same builder p2-gop uses).
# ===========================================================================
echo
echo "=== ISO ==="
capture_sh ISO_OUT ISO_STATUS -- "bash '$CORE_DIR/scripts/build-uefi-image.sh' '$KERNEL_ELF' '$WORKDIR/hybrid.iso'"
echo "$ISO_OUT"
ck; [[ $ISO_STATUS -eq 0 ]] || fail "build-uefi-image.sh exited $ISO_STATUS"
ck; [[ -f "$WORKDIR/hybrid.iso" ]] || fail "no hybrid.iso"

ck; xorriso -indev "$WORKDIR/hybrid.iso" -find / -name kernel.elf -- 2>/dev/null | grep -q kernel.elf \
  || fail "hybrid.iso does not contain kernel.elf"
ck; xorriso -indev "$WORKDIR/hybrid.iso" -find / -name limine-bios.sys -- 2>/dev/null | grep -q limine-bios.sys \
  || fail "hybrid.iso does not contain limine-bios.sys — SeaBIOS stage 2 would be missing"
ck; xorriso -indev "$WORKDIR/hybrid.iso" -find / -name limine-bios-cd.bin -- 2>/dev/null | grep -q limine-bios-cd.bin \
  || fail "hybrid.iso does not contain limine-bios-cd.bin — El Torito BIOS boot would be missing"
ck; xorriso -indev "$WORKDIR/hybrid.iso" -find / -name BOOTX64.EFI -- 2>/dev/null | grep -q BOOTX64.EFI \
  || fail "hybrid.iso lost BOOTX64.EFI — the UEFI path would break"

# ===========================================================================
# Step 4 — two boots.
# ===========================================================================

drive_bios() {
  local outdir="$1"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  # NOTE: no -kernel, no -bios, no pflash. QEMU's SeaBIOS + the ISO.
  # One argv word per line so a workdir named p4-bios cannot satisfy
  # `grep -bios` by accident (the path is a later line).
  printf '%s\n' \
    "qemu-system-x86_64" \
    "-cdrom" \
    "$WORKDIR/hybrid.iso" \
    "-m" \
    "128M" \
    >"$outdir/qemu.argv"
  timeout 60 qemu-system-x86_64 \
    -cdrom "$WORKDIR/hybrid.iso" \
    -m 128M \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for $'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --keys "f,b,ret,wait:800"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status on the BIOS boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "BIOS qemu exited $qemu_status unexpectedly"
  fi
  ck; grep -qx -- '-cdrom' "$outdir/qemu.argv" \
    || fail "BIOS argv was not recorded (would make the no--kernel check vacuous)"
  ck; ! grep -qx -- '-kernel' "$outdir/qemu.argv" \
    || fail "the BIOS qemu argv contains -kernel — PORT4 forbids QEMU's Multiboot loader"
  ck; ! grep -qx -- '-bios' "$outdir/qemu.argv" \
    || fail "the BIOS qemu argv contains -bios — that is not SeaBIOS-default"
  ck; ! grep -qx -- 'pflash' "$outdir/qemu.argv" \
    || fail "the BIOS qemu argv has pflash — that is an OVMF boot"
  ck; ! grep -qiE 'ovmf|edk2' "$outdir/qemu.argv" \
    || fail "the BIOS qemu argv names OVMF/edk2 — PORT4 is SeaBIOS"
}

drive_multiboot() {
  local outdir="$1"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 20 qemu-system-x86_64 \
    -kernel "$KERNEL_ELF" \
    -m 128M \
    -serial "file:$ser" \
    -display none \
    -no-reboot \
    -qmp "tcp:127.0.0.1:$port,server,nowait" \
    >"$outdir/qemu.log" 2>&1 &
  local qemu_pid=$!
  local drive_status
  run_status drive_status -- python3 "$DRIVER" \
    --port "$port" --serial "$ser" --wait-for $'M1 END\n' \
    --png "$outdir/screen.png" --screen-text "$outdir/screen.txt" \
    --keys "f,b,ret,wait:400"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status on the Multiboot boot"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "Multiboot qemu exited $qemu_status unexpectedly"
  fi
}

echo
echo "=== BOOT BIOS (SeaBIOS + Limine hybrid, no -kernel, no OVMF) ==="
echo "Limine    $(limine --print-datadir) ($(limine version | head -1))"
drive_bios "$WORKDIR/bios"

echo
echo "=== BOOT Multiboot -kernel (negative) ==="
drive_multiboot "$WORKDIR/mb"

# ===========================================================================
# Step 5 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

BIOS_SER="$WORKDIR/bios/serial.txt"
MB_SER="$WORKDIR/mb/serial.txt"

ck; [[ -s "$BIOS_SER" ]] || fail "BIOS serial file is empty — SeaBIOS never ran (or serial was not attached)"

# Serial derived: the first line is the existing M0 banner, byte-exact,
# same contract as m0-boot/run.sh. Not a new string this harness invented.
EXPECTED="$WORKDIR/expected.txt"
printf 'OSCORTEX M0 OK\n' >"$EXPECTED"
EXPECTED_BYTES=$(wc -c <"$EXPECTED" | tr -d ' ')
head -c "$EXPECTED_BYTES" "$BIOS_SER" >"$WORKDIR/first_line.txt"
ck; cmp -s "$WORKDIR/first_line.txt" "$EXPECTED" \
  || { echo "--- BIOS serial first bytes ---" >&2; xxd "$WORKDIR/first_line.txt" >&2; \
       fail "BIOS first $EXPECTED_BYTES serial bytes are not OSCORTEX M0 OK — Limine did not reach kmain"; }

ck; grep -q 'M1 END' "$BIOS_SER" \
  || fail "BIOS serial has no M1 END — the kernel did not finish the M1 boot"

# Scanout: VGA/Bochs fallback is the point. Do not *require* GOP.
# Limine-on-BIOS may fill the Multiboot VIDEO tag from VBE (this host
# printed FB GOP 1024x768 at the Bochs BAR). Accept any ADR-0064 winner.
FB_LINE=$(grep -E '^FB (BAR |NONE|GOP )' "$BIOS_SER" | head -1)
ck; if [[ -n "$FB_LINE" ]]; then
  echo "ASSERT: pass  BIOS fb printed: $FB_LINE"
else
  echo "--- BIOS serial ---" >&2
  cat -v "$BIOS_SER" >&2
  fail "BIOS fb printed no FB GOP / FB BAR / FB NONE — fb never ran or hung"
fi
# M1 always prints `M1 FAULT 06` (deliberate #UD). A page fault from
# `fb` is `FAULT 0E` plus `PF CR2`, and it appears AFTER `M1 END`.
ck; python3 - "$BIOS_SER" <<'PY' || fail "BIOS boot took a page fault after fb"
import sys
text = open(sys.argv[1], "r", encoding="latin-1").read()
i = text.find("M1 END")
tail = text[i:] if i >= 0 else text
if "\nFAULT 0E" in tail or "\nPF CR2" in tail or tail.startswith("FAULT 0E") or tail.startswith("PF CR2"):
    sys.stderr.write("--- BIOS serial (tail) ---\n%s\n" % tail[-800:])
    sys.exit(1)
PY

# Negative: -kernel is still the M0 first-line contract.
ck; grep -q 'OSCORTEX M0 OK' "$MB_SER" \
  || fail "Multiboot serial has no OSCORTEX M0 OK — PORT4 broke -kernel"
ck; grep -q 'M1 END' "$MB_SER" \
  || fail "Multiboot serial has no M1 END"
ck; grep -q 'FB BAR FD000000 MODE 0320x0258x20 OK' "$MB_SER" \
  || { echo "--- Multiboot serial ---" >&2; cat -v "$MB_SER" >&2; \
       fail "Multiboot fb did not print the Bochs MODE 0320x0258x20 line"; }
echo "ASSERT: pass  -kernel still OSCORTEX M0 OK + Bochs 800x600"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "P4-bios: PASS — SeaBIOS+Limine loaded kernel.elf from -cdrom without -kernel and without OVMF; serial first line OSCORTEX M0 OK; M1 END; fb printed an ADR-0064 winner; -kernel still Bochs; no new .bss"
exit 0
