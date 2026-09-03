#!/usr/bin/env bash
# core/tests/conformance/p2-gop/run.sh
#
# PORT1 + PORT2 — QEMU + OVMF + Limine loads our Multiboot1 kernel, and
# the kernel reads a GOP framebuffer without talking Bochs dispi.
# docs/design/portable-hardware.md §7, ADR-0060.
#
# PORT1 binary: the UEFI boot does NOT pass -kernel. Serial contains
# the existing M0 banner. QEMU exit 124 (hlt loop) is the derived
# termination, same as m0-boot.
# PORT2 binary: `fb` prints `FB GOP <w>x<h> <pitch> <addr>` whose
# width×height equal the resolution THIS harness wrote into limine.conf
# (1024×768, not the kernel's 800×600).
# Negative: the same kernel.elf under `-kernel` still prints
# `FB BAR … MODE 0320x0258x20 OK` and does not print `FB GOP`.
#
# This is not a Ryzen laptop boot. After the GOP line, the harness
# pmemsaves the aperture the kernel printed and requires a derived
# colour at a derived coordinate (outside the compiled-in 800x600).
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "P2-gop: FAIL — $1" >&2; exit 1; }
setup_error() { echo "P2-gop: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Derived from a run, not counted by hand. See m0-boot/run.sh.
ASSERTIONS_REQUIRED=50

# Geometry the harness asks Limine for. Not 800×600 (Bochs) and not
# 1280×800 (virtio-vga default). The kernel does not contain these
# numbers as a print constant; it reads them from the Multiboot tag.
GOP_W=1024
GOP_H=768
GOP_BPP=32
PITCH=$((GOP_W * GOP_BPP / 8))
# Marker the kernel derives from the loader geometry (gopMarkColor /
# gopMarkOrigin). Recomputed here from the same three numbers this
# harness wrote into limine.conf -- not from a kernel constant.
MARK_X=$((GOP_W - 32))
MARK_Y=$((GOP_H - 32))
MARK_COLOR=$(( ((GOP_W >> 4) << 16) | ((GOP_H >> 4) << 8) | 0xA5 ))
MARK_BYTES=$((GOP_H * PITCH))

ck; [[ "$GOP_W" -ne 800 ]] || fail "GOP_W is 800 — that is the Bochs mode, the comparison would be vacuous"
ck; [[ "$GOP_H" -ne 600 ]] || fail "GOP_H is 600 — that is the Bochs mode, the comparison would be vacuous"
ck; [[ "$GOP_W" -ne 1280 ]] || fail "GOP_W is 1280 — that is virtio-vga's default"

command -v qemu-system-x86_64 >/dev/null 2>&1 || setup_error "qemu-system-x86_64 not found on PATH (brew install qemu)"
command -v python3 >/dev/null 2>&1 || setup_error "python3 not found on PATH"
command -v xorriso >/dev/null 2>&1 || setup_error "xorriso not found on PATH (brew install xorriso)"
command -v limine >/dev/null 2>&1 || setup_error "limine not found on PATH (brew install limine)"
command -v x86_64-elf-readelf >/dev/null 2>&1 || setup_error "x86_64-elf-readelf not found on PATH"
command -v x86_64-elf-objdump >/dev/null 2>&1 || setup_error "x86_64-elf-objdump not found on PATH"

# ---------------------------------------------------------------------------
# OVMF. Homebrew qemu ships edk2-x86_64-code.fd (pflash CODE), not a
# combined OVMF.fd. `qemu-system-x86_64 -bios <CODE>` was measured to
# fail: "could not load PC BIOS". The working invocation is two pflash
# drives (CODE readonly + a writable copy of the VARS template).
# ---------------------------------------------------------------------------
find_ovmf_code() {
  local c
  for c in \
    "${OVMF_CODE:-}" \
    "${OVMF:-}" \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    /usr/local/share/qemu/edk2-x86_64-code.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd
  do
    if [[ -n "$c" && -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

find_ovmf_vars() {
  local c
  for c in \
    "${OVMF_VARS:-}" \
    /opt/homebrew/share/qemu/edk2-i386-vars.fd \
    /usr/local/share/qemu/edk2-i386-vars.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd
  do
    if [[ -n "$c" && -f "$c" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

OVMF_CODE_FILE="$(find_ovmf_code)" || setup_error \
  "OVMF CODE firmware not found. On this Mac: brew install qemu
  expected: /opt/homebrew/share/qemu/edk2-x86_64-code.fd
  QEMU 11 rejects -bios on that file (\"could not load PC BIOS\"); this
  harness uses pflash. Set OVMF_CODE / OVMF_VARS to override."
OVMF_VARS_FILE="$(find_ovmf_vars)" || setup_error \
  "OVMF VARS template not found (need a writable copy for pflash).
  On this Mac: brew install qemu
  expected: /opt/homebrew/share/qemu/edk2-i386-vars.fd
  Set OVMF_VARS to override."

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-p2-gop.XXXXXX")" || setup_error "mktemp failed"
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
# Step 2 — structural.
# ===========================================================================
echo
echo "=== STRUCTURAL ==="

ck; [[ -f "$CORE_DIR/kernel/gop.dart" ]] || fail "core/kernel/gop.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/gop.dart" \
  || fail "gop.dart is not a part of kmain.dart"
ck; grep -q "^part 'gop.dart';$" "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain.dart does not list part 'gop.dart'"

LAST_PART=$(awk "/^part '/{p=\$0} END{print p}" "$CORE_DIR/kernel/kmain.dart")
ck; [[ "$LAST_PART" != "part 'gop.dart';" ]] \
  || fail "part 'gop.dart' is last in kmain.dart — D7 owns that position"

ck; ! grep -qE '^@bss|final Bss ' "$CORE_DIR/kernel/gop.dart" \
  || fail "gop.dart declares donated .bss — PORT2 retains nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — PORT added a help line"

ck; ! grep -q 'gop\|uefi\|limine' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "PORT added a syscall — the criterion forbids one"

# Multiboot1 header still present, VIDEO bit set, not rewritten to UEFI-only.
HDR=$(x86_64-elf-objdump -s -j .multiboot "$KERNEL_ELF" | awk '/100000/{print $2,$3,$4; exit}')
ck; [[ "$HDR" == "02b0ad1b 07000000 f74f52e4" ]] \
  || fail "Multiboot1 header is $HDR, expected 02b0ad1b 07000000 f74f52e4 (magic + flags 7 + checksum)"

# No donated .bss from gop.
BSS_GOP=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6 ~ /gop/ {print $6}')
ck; [[ -z "$BSS_GOP" ]] \
  || fail "kmain.o .bss contains $BSS_GOP — PORT2 was not supposed to donate storage"

# wmevent is still last.
LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — D7 lost last place"

# The derived geometry must not be a constant the kernel prints.
ck; ! grep -F "$GOP_W" "$CORE_DIR/kernel/gop.dart" "$CORE_DIR/kernel/fb.dart" \
  || fail "GOP_W $GOP_W appears in the kernel — the expectation would not be coming from the loader"
ck; ! grep -nE 'port_outw|fbSetMode|fbFindVgaBar' "$CORE_DIR/kernel/gop.dart" | grep -vE '^\s*[0-9]+:\s*//' \
  || fail "gop.dart talks to Bochs dispi — PORT2 forbids that"

capture_sh VERIFY_OUT VERIFY_STATUS -- "OSCORTEX_ALLOWLIST='$CORE_DIR/tools/bare-symbol-allowlist.txt' bash '$CORE_DIR/scripts/verify-freestanding.sh' '$KERNEL_ELF'"
echo "$VERIFY_OUT"
ck; [[ $VERIFY_STATUS -eq 0 ]] || fail "verify-freestanding.sh failed"
echo "STRUCTURAL: pass  gop.dart is a silent no-@bss part, not last; VIDEO header intact; no help, no syscall, no dispi"

# ===========================================================================
# Step 3 — UEFI ISO. The harness writes limine.conf so W×H are derived.
# ===========================================================================
echo
echo "=== ISO ==="
cat > "$WORKDIR/limine.conf" <<EOF
timeout: 0

/oscortex
    protocol: multiboot
    path: boot():/boot/kernel.elf
    KERNEL_PATH: boot():/boot/kernel.elf
    resolution: ${GOP_W}x${GOP_H}x${GOP_BPP}
EOF

capture_sh ISO_OUT ISO_STATUS -- "LIMINE_CONF='$WORKDIR/limine.conf' bash '$CORE_DIR/scripts/build-uefi-image.sh' '$KERNEL_ELF' '$WORKDIR/uefi.iso'"
echo "$ISO_OUT"
ck; [[ $ISO_STATUS -eq 0 ]] || fail "build-uefi-image.sh exited $ISO_STATUS"
ck; [[ -f "$WORKDIR/uefi.iso" ]] || fail "no uefi.iso"

# The firmware volume must actually contain our kernel and Limine's EFI
# app, so a -kernel boot cannot satisfy PORT1 by accident.
ck; xorriso -indev "$WORKDIR/uefi.iso" -find / -name kernel.elf -- 2>/dev/null | grep -q kernel.elf \
  || fail "uefi.iso does not contain kernel.elf"
ck; xorriso -indev "$WORKDIR/uefi.iso" -find / -name BOOTX64.EFI -- 2>/dev/null | grep -q BOOTX64.EFI \
  || fail "uefi.iso does not contain BOOTX64.EFI"

cp "$OVMF_VARS_FILE" "$WORKDIR/OVMF_VARS.fd" || fail "could not copy OVMF VARS"

# ===========================================================================
# Step 4 — two boots.
# ===========================================================================

drive_uefi() {
  local outdir="$1"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  # NOTE: no -kernel. pflash OVMF + the ISO this harness built.
  # Record the argv: QEMU's own log does not echo it, and a grep of an
  # empty qemu.log would pass this check vacuously.
  printf '%s\n' \
    "qemu-system-x86_64" \
    "-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE_FILE" \
    "-drive if=pflash,format=raw,file=$WORKDIR/OVMF_VARS.fd" \
    "-cdrom $WORKDIR/uefi.iso" \
    "-m 256M" \
    >"$outdir/qemu.argv"
  timeout 90 qemu-system-x86_64 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE_FILE" \
    -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS.fd" \
    -cdrom "$WORKDIR/uefi.iso" \
    -m 256M \
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
    --keys "f,b,ret,wait:1500" \
    --addr-from-serial 'FB GOP [0-9A-Fa-f]+x[0-9A-Fa-f]+ [0-9A-Fa-f]+ ([0-9A-Fa-f]+)' \
    --pmemsave "$outdir/gop.bin" \
    --pmemsave-size "$MARK_BYTES"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status on the UEFI boot"
  fi
  # Derived exit: the kernel hlt-loops, so timeout 124 is the success
  # path, same as m0-boot. Any other nonzero is a QEMU-level failure.
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "UEFI qemu exited $qemu_status unexpectedly"
  fi
  # Anti-vacuity: this must not have been a -kernel boot.
  ck; grep -q -- '-cdrom' "$outdir/qemu.argv" \
    || fail "UEFI argv was not recorded (would make the no--kernel check vacuous)"
  ck; ! grep -q -- '-kernel' "$outdir/qemu.argv" \
    || fail "the UEFI qemu argv contains -kernel — PORT1 forbids QEMU's Multiboot loader"
  ck; grep -q -- 'if=pflash' "$outdir/qemu.argv" \
    || fail "the UEFI qemu argv has no pflash — this is not an OVMF boot"
}

drive_multiboot() {
  local outdir="$1"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 60 qemu-system-x86_64 \
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
    --keys "f,b,ret,wait:800"
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
echo "=== BOOT UEFI (OVMF + Limine, no -kernel) ==="
echo "OVMF CODE $OVMF_CODE_FILE"
echo "OVMF VARS $OVMF_VARS_FILE"
echo "Limine    $(limine --print-datadir) ($(limine version | head -1))"
drive_uefi "$WORKDIR/uefi"

echo
echo "=== BOOT Multiboot -kernel (negative) ==="
drive_multiboot "$WORKDIR/mb"

# ===========================================================================
# Step 5 — criterion.
# ===========================================================================
echo
echo "=== CRITERION ==="

WHEX=$(printf '%04X' "$GOP_W")
HHEX=$(printf '%04X' "$GOP_H")
PHEX=$(printf '%08X' "$PITCH")
EXPECT_GOP="FB GOP ${WHEX}x${HHEX} ${PHEX} "

UEFI_SER="$WORKDIR/uefi/serial.txt"
MB_SER="$WORKDIR/mb/serial.txt"

ck; [[ -s "$UEFI_SER" ]] || fail "UEFI serial file is empty — OVMF never ran (or serial was not attached)"
ck; grep -q 'OSCORTEX M0 OK' "$UEFI_SER" \
  || { echo "--- UEFI serial ---" >&2; cat -v "$UEFI_SER" >&2; \
       fail "UEFI serial has no OSCORTEX M0 OK — Limine did not reach kmain"; }
ck; grep -q 'M1 END' "$UEFI_SER" \
  || fail "UEFI serial has no M1 END — the kernel did not finish the M1 boot"

# PORT2: the printed geometry equals the mode the harness asked Limine for.
ck; grep -q "^${EXPECT_GOP}" "$UEFI_SER" \
  || { echo "--- UEFI serial ---" >&2; cat -v "$UEFI_SER" >&2; \
       echo "expected a line starting ${EXPECT_GOP}<addr>" >&2; \
       fail "UEFI fb did not print FB GOP ${WHEX}x${HHEX} ${PHEX} — GOP handoff missing or Bochs won"; }

GOP_LINE=$(grep "^FB GOP " "$UEFI_SER" | head -1)
GOP_ADDR=$(printf '%s' "$GOP_LINE" | awk '{print $5}')
ck; [[ -n "$GOP_ADDR" && "$GOP_ADDR" != "0000000000000000" ]] \
  || fail "FB GOP address is empty or zero — the tag was vacuous"
ck; [[ "$GOP_ADDR" != "00000000FD000000" ]] \
  || fail "FB GOP address is the Bochs BAR 0xFD000000 — this is not a GOP handoff"
ck; ! grep -q 'FB BAR' "$UEFI_SER" \
  || fail "UEFI boot printed FB BAR — shellFb talked to Bochs after a GOP tag"
ck; ! grep -q 'FB NOVBE' "$UEFI_SER" \
  || fail "UEFI boot printed FB NOVBE — it fell through to dispi"
echo "ASSERT: pass  UEFI fb printed $GOP_LINE (W×H and pitch derived from limine.conf ${GOP_W}x${GOP_H}x${GOP_BPP})"

# PORT2 paint: a derived colour at a derived coordinate, read back from
# guest physical memory at the address THE KERNEL printed. Outside the
# compiled-in 800x600 so a Bochs-sized fill cannot satisfy this.
ck; [[ "$MARK_X" -ge 800 ]] || fail "MARK_X $MARK_X is inside the Bochs width — the pixel check would not prove GOP geometry"
ck; [[ "$MARK_Y" -ge 600 ]] || fail "MARK_Y $MARK_Y is inside the Bochs height — the pixel check would not prove GOP geometry"
ck; [[ "$MARK_COLOR" -ne 0 ]] || fail "derived marker colour is 0 — vacuous against an unmapped dump"
ck; [[ "$MARK_COLOR" -ne 0x00101018 ]] || fail "derived marker colour equals fbColorBg — would not prove a paint"
GOP_BIN="$WORKDIR/uefi/gop.bin"
ck; [[ -f "$GOP_BIN" ]] || fail "pmemsave did not write gop.bin — the aperture was not dumped"
ck; [[ "$(wc -c <"$GOP_BIN" | tr -d ' ')" -eq "$MARK_BYTES" ]] \
  || fail "gop.bin is $(wc -c <"$GOP_BIN" | tr -d ' ') bytes, expected $MARK_BYTES"
ck; python3 - "$GOP_BIN" "$PITCH" "$MARK_X" "$MARK_Y" "$MARK_COLOR" <<'PY'
import struct, sys
path, pitch, x, y, want = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
data = open(path, "rb").read()
off = y * pitch + x * 4
if off + 4 > len(data):
    sys.exit("pixel offset %d is past dump size %d" % (off, len(data)))
got = struct.unpack_from("<I", data, off)[0]
if got != want:
    sys.exit("pixel (%d,%d) is 0x%08X, expected derived 0x%08X" % (x, y, got, want))
# A second sample inside the 16x16, and one just outside so this is a
# rectangle not a whole-aperture flood of the marker.
off2 = (y + 15) * pitch + (x + 15) * 4
got2 = struct.unpack_from("<I", data, off2)[0]
if got2 != want:
    sys.exit("pixel (%d,%d) is 0x%08X, expected the same derived colour" % (x + 15, y + 15, got2))
off3 = (y - 1) * pitch + x * 4
got3 = struct.unpack_from("<I", data, off3)[0]
if got3 == want:
    sys.exit("pixel (%d,%d) is also the marker — paint was not a rectangle" % (x, y - 1))
print("    pixel (%d,%d) and (%d,%d) = 0x%08X (derived); outside is 0x%08X" % (x, y, x + 15, y + 15, got, got3))
PY
ck; [[ $? -eq 0 ]] || fail "GOP pmemsave does not contain the derived marker colour at the derived coordinate"
echo "ASSERT: pass  pmemsave at the printed GOP addr has derived colour 0x$(printf '%08X' "$MARK_COLOR") at (${MARK_X},${MARK_Y})"

# Negative: -kernel is still Bochs.
ck; grep -q 'OSCORTEX M0 OK' "$MB_SER" \
  || fail "Multiboot serial has no OSCORTEX M0 OK"
ck; grep -q 'FB BAR FD000000 MODE 0320x0258x20 OK' "$MB_SER" \
  || { echo "--- Multiboot serial ---" >&2; cat -v "$MB_SER" >&2; \
       fail "Multiboot fb did not print the Bochs MODE 0320x0258x20 line"; }
ck; ! grep -q '^FB GOP ' "$MB_SER" \
  || fail "Multiboot -kernel printed FB GOP — QEMU's loader is not supposed to fill the tag"
echo "ASSERT: pass  -kernel fb is still Bochs 800x600; no GOP line"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "P2-gop: PASS — OVMF+Limine loaded kernel.elf without -kernel; serial OSCORTEX M0 OK; fb printed FB GOP ${WHEX}x${HHEX} ${PHEX} <addr>; pmemsave read back derived colour at (${MARK_X},${MARK_Y}); -kernel still Bochs; no new .bss"
exit 0
