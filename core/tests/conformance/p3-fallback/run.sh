#!/usr/bin/env bash
# core/tests/conformance/p3-fallback/run.sh
#
# ADR-0064 — one `fb` probe, three winners, never hang.
# docs/design/portable-hardware.md §4 fallback table.
#
# (a) UEFI GOP wins: OVMF+Limine, no -kernel. `FB GOP` whose W×H equal
#     the resolution THIS harness wrote into limine.conf. No `FB BAR`.
# (b) -kernel Bochs wins: same kernel.elf, `-vga std`. `FB BAR … MODE
#     0320x0258x20 OK`. No `FB GOP`.
# (c) no GOP no Bochs: `-kernel -vga none`. `FB NONE`. No `FAULT` / `PF`.
#     Serial still has OSCORTEX M0 OK and a prompt after `fb`.
#
# Does not replace p2-gop (PORT2 paint + pmemsave). Does not write
# amdgpu. Does not claim a Ryzen laptop boot.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "P3-fallback: FAIL — $1" >&2; exit 1; }
setup_error() { echo "P3-fallback: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

# Derived from a run, not counted by hand.
ASSERTIONS_REQUIRED=42

GOP_W=1024
GOP_H=768
GOP_BPP=32

ck; [[ "$GOP_W" -ne 800 ]] || fail "GOP_W is 800 — that is the Bochs mode, the comparison would be vacuous"
ck; [[ "$GOP_H" -ne 600 ]] || fail "GOP_H is 600 — that is the Bochs mode, the comparison would be vacuous"

command -v qemu-system-x86_64 >/dev/null 2>&1 || setup_error "qemu-system-x86_64 not found on PATH (brew install qemu)"
command -v python3 >/dev/null 2>&1 || setup_error "python3 not found on PATH"
command -v xorriso >/dev/null 2>&1 || setup_error "xorriso not found on PATH (brew install xorriso)"
command -v limine >/dev/null 2>&1 || setup_error "limine not found on PATH (brew install limine)"
command -v x86_64-elf-readelf >/dev/null 2>&1 || setup_error "x86_64-elf-readelf not found on PATH"
command -v x86_64-elf-objdump >/dev/null 2>&1 || setup_error "x86_64-elf-objdump not found on PATH"

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
  Set OVMF_CODE / OVMF_VARS to override."
OVMF_VARS_FILE="$(find_ovmf_vars)" || setup_error \
  "OVMF VARS template not found.
  On this Mac: brew install qemu
  expected: /opt/homebrew/share/qemu/edk2-i386-vars.fd
  Set OVMF_VARS to override."

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-p3-fallback.XXXXXX")" || setup_error "mktemp failed"
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

ck; [[ -f "$CORE_DIR/kernel/gop.dart" ]] || fail "core/kernel/gop.dart is missing"
ck; grep -q "^part of 'kmain.dart';$" "$CORE_DIR/kernel/gop.dart" \
  || fail "gop.dart is not a part of kmain.dart"
ck; ! grep -qE '^@bss|final Bss ' "$CORE_DIR/kernel/gop.dart" \
  || fail "gop.dart declares donated .bss — fallback donates nothing"

HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing} bytes, expected 2511 — fallback added a help line"

LAST_BSS=$(x86_64-elf-objdump -t "$CORE_DIR/build/kmain.o" \
  | awk '$4==".bss" && $6!=".bss" {print $1,$6}' | sort | tail -1 | awk '{print $2}')
ck; [[ "$LAST_BSS" == "wmeventStore" ]] \
  || fail "last .bss is $LAST_BSS, not wmeventStore — D7 lost last place"

# Map failure must return 0, not print FB GOP. The paint/print block
# sits after this return; a tag that cannot be mapped falls through.
ck; grep -A2 'gopMap(addr, bytes)' "$CORE_DIR/kernel/gop.dart" \
  | grep -q 'return u64(0)' \
  || fail "gopTry does not return 0 when gopMap refuses — unmappable GOP would claim the path"

ck; ! grep -q 'gop\|uefi\|limine' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "fallback added a syscall — the criterion forbids one"

ck; ! grep -F "$GOP_W" "$CORE_DIR/kernel/gop.dart" "$CORE_DIR/kernel/fb.dart" \
  || fail "GOP_W $GOP_W appears in the kernel — the UEFI expectation would not be coming from the loader"

echo "STRUCTURAL: pass  no new .bss; help 2511; wmevent last; gopMap refuse returns 0"

echo
echo "=== ISO ==="
cat > "$WORKDIR/limine.conf" <<EOF
timeout: 0

/oscortex
    protocol: multiboot
    path: boot():/boot/kernel.elf
    resolution: ${GOP_W}x${GOP_H}x${GOP_BPP}
EOF

capture_sh ISO_OUT ISO_STATUS -- "LIMINE_CONF='$WORKDIR/limine.conf' bash '$CORE_DIR/scripts/build-uefi-image.sh' '$KERNEL_ELF' '$WORKDIR/uefi.iso'"
echo "$ISO_OUT"
ck; [[ $ISO_STATUS -eq 0 ]] || fail "build-uefi-image.sh exited $ISO_STATUS"
ck; [[ -f "$WORKDIR/uefi.iso" ]] || fail "no uefi.iso"
cp "$OVMF_VARS_FILE" "$WORKDIR/OVMF_VARS.fd" || fail "could not copy OVMF VARS"

drive_keys() {
  local outdir="$1"
  shift
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  timeout 90 qemu-system-x86_64 \
    "$@" \
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
    --keys "f,b,ret,wait:800"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2
    cat "$ser" >&2
    fail "qmp-drive.py exited $drive_status ($outdir)"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "qemu exited $qemu_status unexpectedly ($outdir)"
  fi
}

# M1 always prints `M1 FAULT 06` (deliberate #UD). A page fault from
# `fb` is `FAULT 0E` plus `PF CR2`, and it appears AFTER `M1 END`.
no_fault() {
  local ser="$1"
  local label="$2"
  ck; python3 - "$ser" "$label" <<'PY' || fail "$label took a page fault after fb"
import sys
text = open(sys.argv[1], "r", encoding="latin-1").read()
label = sys.argv[2]
i = text.find("M1 END")
tail = text[i:] if i >= 0 else text
if "\nFAULT 0E" in tail or "\nPF CR2" in tail or tail.startswith("FAULT 0E") or tail.startswith("PF CR2"):
    sys.stderr.write("--- %s serial (tail) ---\n%s\n" % (label, tail[-800:]))
    sys.exit(1)
PY
}

echo
echo "=== BOOT (a) UEFI GOP ==="
drive_keys "$WORKDIR/uefi" \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE_FILE" \
  -drive "if=pflash,format=raw,file=$WORKDIR/OVMF_VARS.fd" \
  -cdrom "$WORKDIR/uefi.iso"

echo
echo "=== BOOT (b) -kernel Bochs ==="
drive_keys "$WORKDIR/mb" \
  -kernel "$KERNEL_ELF" \
  -vga std

echo
echo "=== BOOT (c) -kernel -vga none ==="
drive_keys "$WORKDIR/none" \
  -kernel "$KERNEL_ELF" \
  -vga none

echo
echo "=== CRITERION ==="

WHEX=$(printf '%04X' "$GOP_W")
HHEX=$(printf '%04X' "$GOP_H")
EXPECT_GOP="FB GOP ${WHEX}x${HHEX} "

UEFI_SER="$WORKDIR/uefi/serial.txt"
MB_SER="$WORKDIR/mb/serial.txt"
NONE_SER="$WORKDIR/none/serial.txt"

# (a) GOP wins
ck; [[ -s "$UEFI_SER" ]] || fail "UEFI serial file is empty"
ck; grep -q 'OSCORTEX M0 OK' "$UEFI_SER" \
  || { echo "--- UEFI serial ---" >&2; cat -v "$UEFI_SER" >&2; \
       fail "UEFI serial has no OSCORTEX M0 OK"; }
ck; grep -q "^${EXPECT_GOP}" "$UEFI_SER" \
  || { echo "--- UEFI serial ---" >&2; cat -v "$UEFI_SER" >&2; \
       fail "UEFI fb did not print FB GOP ${WHEX}x${HHEX} — GOP should have won"; }
ck; ! grep -q 'FB BAR' "$UEFI_SER" \
  || fail "UEFI boot printed FB BAR — GOP won then the chain kept walking"
ck; ! grep -q 'FB NONE' "$UEFI_SER" \
  || fail "UEFI boot printed FB NONE — GOP should have won"
no_fault "$UEFI_SER" "UEFI"
echo "ASSERT: pass  (a) UEFI fb printed FB GOP ${WHEX}x${HHEX} (derived); no BAR, no NONE, no fault"

# (b) Bochs wins
ck; grep -q 'OSCORTEX M0 OK' "$MB_SER" \
  || fail "Multiboot serial has no OSCORTEX M0 OK"
ck; grep -q 'FB BAR FD000000 MODE 0320x0258x20 OK' "$MB_SER" \
  || { echo "--- Multiboot serial ---" >&2; cat -v "$MB_SER" >&2; \
       fail "Multiboot fb did not print the Bochs MODE 0320x0258x20 line"; }
ck; ! grep -q '^FB GOP ' "$MB_SER" \
  || fail "Multiboot -kernel printed FB GOP — QEMU's loader is not supposed to fill the tag"
ck; ! grep -q 'FB NONE' "$MB_SER" \
  || fail "Multiboot -vga std printed FB NONE — Bochs should have won"
no_fault "$MB_SER" "Multiboot"
echo "ASSERT: pass  (b) -kernel fb is still Bochs 800x600; no GOP, no NONE, no fault"

# (c) NONE, no fault, console still talks
ck; grep -q 'OSCORTEX M0 OK' "$NONE_SER" \
  || { echo "--- none serial ---" >&2; cat -v "$NONE_SER" >&2; \
       fail "-vga none serial has no OSCORTEX M0 OK — the kernel did not run"; }
ck; grep -q 'M1 END' "$NONE_SER" \
  || fail "-vga none serial has no M1 END"
ck; grep -q '^FB NONE' "$NONE_SER" \
  || { echo "--- none serial ---" >&2; cat -v "$NONE_SER" >&2; \
       fail "-vga none fb did not print FB NONE"; }
ck; ! grep -q '^FB GOP ' "$NONE_SER" \
  || fail "-vga none printed FB GOP — there is no loader tag"
ck; ! grep -q 'FB BAR' "$NONE_SER" \
  || fail "-vga none printed FB BAR — there is no VGA-class BAR"
no_fault "$NONE_SER" "-vga none"
# Prompt after fb: the chain returned, the shell still lives.
ck; python3 - "$NONE_SER" <<'PY' || fail "-vga none did not return to the prompt after fb — hang or fault ate the shell"
import sys
text = open(sys.argv[1], "r", encoding="latin-1").read()
i = text.find("FB NONE")
if i < 0:
    sys.exit("no FB NONE")
# A later oscortex> means the command finished and the idle shell reprinted.
if text.find("oscortex> ", i) < 0:
    sys.exit("no prompt after FB NONE")
PY
echo "ASSERT: pass  (c) -vga none printed FB NONE; prompt returned; no GOP, no BAR, no fault"

# The three boots must disagree on the winner — one stub would collapse them.
ck; python3 - "$UEFI_SER" "$MB_SER" "$NONE_SER" <<'PY' || fail "two of the three boots printed the same winner line — the split is vacuous"
import sys
def winner(path):
    for line in open(path, "r", encoding="latin-1"):
        if line.startswith("FB GOP ") or line.startswith("FB BAR ") or line.startswith("FB NONE"):
            return line.split()[1]
    return ""
a, b, c = winner(sys.argv[1]), winner(sys.argv[2]), winner(sys.argv[3])
if a != "GOP" or b != "BAR" or c != "NONE":
    sys.exit("winners were %s / %s / %s, expected GOP / BAR / NONE" % (a, b, c))
if len({a, b, c}) != 3:
    sys.exit("winner set collapsed")
print("    winners: GOP / BAR / NONE (three distinct)")
PY

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "P3-fallback: PASS — (a) UEFI GOP, (b) -kernel Bochs, (c) -vga none FB NONE; no fault; no new .bss"
exit 0
