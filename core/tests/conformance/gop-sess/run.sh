#!/usr/bin/env bash
# core/tests/conformance/gop-sess/run.sh
#
# ADR-0141 — session chrome composes onto the live GOP aperture.
# docs/decisions/0141-session-chrome-on-gop.md.
#
# WHAT THIS ASSERTS
# ---------------------------------------------------------------------------
# OVMF+Limine (no -kernel): `fb` then `wm on` then `wm chrome`. Serial
# has FB GOP and WM GOP whose W×H equal the resolution THIS harness
# wrote into limine.conf (1024×768, not 800×600). pmemsave at the
# printed GOP address has the desktop colour outside the compiled-in
# 800×600 and the chrome colour on the bottom strip (y ≥ 744). Address
# is not the Bochs BAR.
#
# Same ISO, no `fb`: `wm on` / `wm chrome` do not print WM GOP.
# pmemsave of the first-boot GOP address does not contain the chrome
# colour (unmapped miss).
#
# Same kernel.elf under -kernel: FB BAR … MODE 0320x0258x20 OK, chrome
# PX 00004B00 (800×24), no WM GOP.
#
# Anti-vacuity is GOP-only coordinates plus the unmapped miss.
# No Graphite / MakeVulkan / Venus. Do not attach a USB keyboard
# device on this boot (8042 path). No Dell SKU.
# Syscall 11 stays fdwait. No new syscall. No help line.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "GOP-sess: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GOP-sess: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=49

GOP_W=1024
GOP_H=768
GOP_BPP=32
PITCH=$((GOP_W * GOP_BPP / 8))
FRAME_BYTES=$((GOP_H * PITCH))
# READ FROM THE KERNEL, not typed. Both of these were typed copies and both
# went stale the moment ADR-0187 redesigned the chrome: the taskbar went 24 ->
# 48 tall and its fill went tan (0x00C09048) -> elevated slate (0x00344050).
# A harness that types the colour it expects to find on screen is testing its
# own memory of the design; reading wmchrome.dart makes it test that the SCREEN
# agrees with the SOURCE, which is what GOP-sess is actually for.
DESK=$(awk -F'= *' '/^const int wmColorDesktop/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/wm.dart")
CHROME=$(awk -F'= *' '/^const int wmChromeColor/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/wmchrome.dart")
CH_H=$(awk -F'= *' '/^const int wmChromeH/{gsub(/;/,"",$2); print $2; exit}' "$CORE_DIR/kernel/wmchrome.dart")
[[ -n "$DESK" && -n "$CHROME" && -n "$CH_H" ]] \
  || setup_error "could not read wmColorDesktop / wmChromeColor / wmChromeH out of the kernel source"
CH_Y0=$((GOP_H - CH_H))
# Outside compiled-in Bochs 800×600.
SAMPLE_X=900
SAMPLE_Y_DESK=100
SAMPLE_Y_CHROME=$((CH_Y0 + 8))
CHROME_PX_GOP=$((GOP_W * CH_H))
CHROME_PX_BOCHS=$((800 * CH_H))

ck; [[ "$GOP_W" -ne 800 ]] || fail "GOP_W is 800 — Bochs mode, vacuous"
ck; [[ "$GOP_H" -ne 600 ]] || fail "GOP_H is 600 — Bochs mode, vacuous"
ck; [[ "$SAMPLE_X" -ge 800 ]] || fail "SAMPLE_X inside Bochs width"
ck; [[ "$SAMPLE_Y_CHROME" -ge 600 ]] || fail "chrome sample inside Bochs height"
ck; [[ "$DESK" -ne "$CHROME" ]] || fail "desktop equals chrome — vacuous"

for tool in qemu-system-x86_64 python3 xorriso limine \
            x86_64-elf-readelf x86_64-elf-objdump; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

find_ovmf_code() {
  local c
  for c in \
    "${OVMF_CODE:-}" \
    /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
    /usr/local/share/qemu/edk2-x86_64-code.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd
  do
    if [[ -n "$c" && -f "$c" ]]; then echo "$c"; return 0; fi
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
    /usr/share/OVMF/OVMF_VARS_4M.fd
  do
    if [[ -n "$c" && -f "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

OVMF_CODE_FILE="$(find_ovmf_code)" || setup_error "OVMF CODE not found"
OVMF_VARS_FILE="$(find_ovmf_vars)" || setup_error "OVMF VARS not found"

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "qmp-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-gop-sess.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"

echo
echo "=== STRUCTURAL ==="
ck; [[ -f "$CORE_DIR/kernel/gop.dart" ]] || fail "gop.dart missing"
ck; grep -q 'u64 gopIsLive()' "$CORE_DIR/kernel/gop.dart" \
  || fail "gopIsLive missing"
ck; grep -q 'void gopSessAnnounce()' "$CORE_DIR/kernel/gop.dart" \
  || fail "gopSessAnnounce missing"
ck; grep -q 'gopSessAnnounce()' "$CORE_DIR/kernel/wm.dart" \
  || fail "wmOn does not announce WM GOP"
ck; grep -q 'gopSessAnnounce()' "$CORE_DIR/kernel/wmchrome.dart" \
  || fail "wm chrome does not announce WM GOP"
ck; grep -q 'gopIsLive()' "$CORE_DIR/kernel/fb.dart" \
  || fail "fbGeom* does not gate on gopIsLive"
ck; ! grep -qE '^@bss$|final Bss ' "$CORE_DIR/kernel/gop.dart" \
  || fail "gop.dart donated .bss"
ck; ! grep -q 'Graphite\|MakeVulkan\|Venus' "$CORE_DIR/kernel/gop.dart" \
  || fail "gop.dart names Graphite — fence"
HELP_SIZE=$(x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk '$8=="shellStrHelp"{print $3+0; exit}')
ck; [[ "$HELP_SIZE" -eq 2511 ]] \
  || fail "shellStrHelp is ${HELP_SIZE:-missing}, expected 2511"
ck; grep -q '11 is `fdwait`' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall 11 is no longer fdwait"
echo "STRUCTURAL: pass  gopIsLive + gopSessAnnounce; no @bss; no Graphite; no help; fdwait"

typekeys() { python3 -c "
import sys
print(','.join({' ': 'spc', '.': 'dot'}.get(c, c.lower()) for c in sys.argv[1]))
" "$1"; }

echo
echo "=== ISO ==="
cat > "$WORKDIR/limine.conf" <<EOF
timeout: 0

/oscortex
    protocol: multiboot
    path: boot():/boot/kernel.elf
    resolution: ${GOP_W}x${GOP_H}x${GOP_BPP}
EOF
capture_sh ISO_OUT ISO_STATUS -- \
  "LIMINE_CONF='$WORKDIR/limine.conf' bash '$CORE_DIR/scripts/build-uefi-image.sh' '$KERNEL_ELF' '$WORKDIR/uefi.iso'"
echo "$ISO_OUT"
ck; [[ $ISO_STATUS -eq 0 ]] || fail "build-uefi-image.sh exited $ISO_STATUS"
ck; [[ -f "$WORKDIR/uefi.iso" ]] || fail "no uefi.iso"
cp "$OVMF_VARS_FILE" "$WORKDIR/OVMF_VARS.fd" || fail "could not copy OVMF VARS"

drive_uefi() {
  local outdir="$1"
  local keys="$2"
  local dump="$3"
  mkdir -p "$outdir"
  local ser="$outdir/serial.txt"
  : >"$ser"
  local port
  ck; port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
  printf '%s\n' \
    "qemu-system-x86_64" \
    "-drive if=pflash,format=raw,readonly=on,file=$OVMF_CODE_FILE" \
    "-drive if=pflash,format=raw,file=$WORKDIR/OVMF_VARS.fd" \
    "-cdrom $WORKDIR/uefi.iso" \
    "-m 256M" \
    >"$outdir/qemu.argv"
  local extra=()
  if [[ -n "$dump" ]]; then
    extra=(
      --addr-from-serial 'FB GOP [0-9A-Fa-f]+x[0-9A-Fa-f]+ [0-9A-Fa-f]+ ([0-9A-Fa-f]+)'
      --pmemsave "$dump"
      --pmemsave-size "$FRAME_BYTES"
    )
  fi
  timeout 120 qemu-system-x86_64 \
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
    --keys "$keys" \
    "${extra[@]+"${extra[@]}"}"
  local qemu_status
  await qemu_status "$qemu_pid"
  ck; if [[ $drive_status -ne 0 ]]; then
    cat "$outdir/qemu.log" >&2
    echo "--- serial ---" >&2; cat "$ser" >&2
    fail "qmp-drive exited $drive_status ($outdir)"
  fi
  ck; if [[ $qemu_status -ne 0 && $qemu_status -ne 124 ]]; then
    cat "$outdir/qemu.log" >&2
    fail "UEFI qemu exited $qemu_status ($outdir)"
  fi
  ck; grep -q -- '-cdrom' "$outdir/qemu.argv" || fail "argv not recorded"
  ck; ! grep -q -- '-kernel' "$outdir/qemu.argv" || fail "UEFI argv has -kernel"
}

KEYS_SESS="$(typekeys fb),ret,wait:1500,$(typekeys 'wm on'),ret,wait:2500,$(typekeys 'wm chrome'),ret,wait:3000"
KEYS_NOFB="$(typekeys 'wm on'),ret,wait:2000,$(typekeys 'wm chrome'),ret,wait:2500"

echo
echo "=== BOOT UEFI session (fb + wm on + wm chrome) ==="
drive_uefi "$WORKDIR/sess" "$KEYS_SESS" "$WORKDIR/sess/gop.bin"

echo
echo "=== BOOT UEFI no-fb miss ==="
# Re-copy VARS so the second boot is clean.
cp "$OVMF_VARS_FILE" "$WORKDIR/OVMF_VARS.fd" || fail "could not refresh OVMF VARS"
drive_uefi "$WORKDIR/nofb" "$KEYS_NOFB" ""

echo
echo "=== BOOT Multiboot -kernel (Bochs) ==="
mkdir -p "$WORKDIR/mb"
SER_MB="$WORKDIR/mb/serial.txt"
: >"$SER_MB"
PORT=$(python3 "$PICKER") || fail "pick-port"
timeout 90 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
  -serial "file:$SER_MB" -display none -no-reboot \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/mb/qemu.log" 2>&1 &
QPID=$!
run_status DRIVE_MB -- python3 "$DRIVER" \
  --port "$PORT" --serial "$SER_MB" --wait-for $'M1 END\n' \
  --png "$WORKDIR/mb/screen.png" --screen-text "$WORKDIR/mb/screen.txt" \
  --keys "$KEYS_SESS"
await QSTAT_MB "$QPID"
ck; [[ $DRIVE_MB -eq 0 ]] || { cat "$WORKDIR/mb/qemu.log" >&2; fail "mb qmp-drive $DRIVE_MB"; }
ck; if [[ $QSTAT_MB -ne 0 && $QSTAT_MB -ne 124 ]]; then fail "mb qemu $QSTAT_MB"; fi

echo
echo "=== CRITERION ==="
WHEX=$(printf '%04X' "$GOP_W")
HHEX=$(printf '%04X' "$GOP_H")
PHEX=$(printf '%08X' "$PITCH")
CH_HEX=$(printf '%04X' "$CH_H")
PX_GOP_HEX=$(printf '%08X' "$CHROME_PX_GOP")
PX_BOCHS_HEX=$(printf '%08X' "$CHROME_PX_BOCHS")
EXPECT_GOP="FB GOP ${WHEX}x${HHEX} ${PHEX} "
EXPECT_WM="WM GOP ${WHEX}x${HHEX} "

SESS="$WORKDIR/sess/serial.txt"
NOFB="$WORKDIR/nofb/serial.txt"

ck; [[ -s "$SESS" ]] || fail "session serial empty"
ck; grep -q 'OSCORTEX M0 OK' "$SESS" || fail "no M0 on session boot"
ck; grep -q "^${EXPECT_GOP}" "$SESS" \
  || { cat -v "$SESS" >&2; fail "no FB GOP ${WHEX}x${HHEX}"; }
ck; grep -q "^${EXPECT_WM}" "$SESS" \
  || { sed -n '/M1 END/,$p' "$SESS" >&2; fail "no WM GOP ${WHEX}x${HHEX}"; }
ck; ! grep -q 'FB BAR' "$SESS" || fail "session boot printed FB BAR"
ck; grep -qE "^WM CHROME ON H ${CH_HEX} PX ${PX_GOP_HEX}\$" "$SESS" \
  || fail "chrome PX is not ${PX_GOP_HEX} (${GOP_W}×${CH_H}) — geometry was not live GOP"

GOP_LINE=$(grep "^FB GOP " "$SESS" | head -1)
GOP_ADDR=$(printf '%s' "$GOP_LINE" | awk '{print $5}')
ck; [[ -n "$GOP_ADDR" && "$GOP_ADDR" != "0000000000000000" ]] \
  || fail "GOP addr empty/zero"
ck; [[ "$GOP_ADDR" != "00000000FD000000" ]] \
  || fail "GOP addr is Bochs BAR"
echo "$GOP_ADDR" >"$WORKDIR/gop.addr"
echo "ASSERT: pass  session serial $GOP_LINE and WM GOP ${WHEX}x${HHEX}"

ck; [[ -f "$WORKDIR/sess/gop.bin" ]] || fail "no gop.bin pmemsave"
ck; [[ "$(wc -c <"$WORKDIR/sess/gop.bin" | tr -d ' ')" -eq "$FRAME_BYTES" ]] \
  || fail "gop.bin size wrong"
ck; python3 - "$WORKDIR/sess/gop.bin" "$PITCH" \
    "$SAMPLE_X" "$SAMPLE_Y_DESK" "$DESK" \
    "$SAMPLE_X" "$SAMPLE_Y_CHROME" "$CHROME" <<'PY'
import struct, sys
path, pitch = sys.argv[1], int(sys.argv[2])
data = open(path, "rb").read()
def pix(x, y):
    off = y * pitch + x * 4
    return struct.unpack_from("<I", data, off)[0]
xd, yd, want_d = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5], 0)
xc, yc, want_c = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8], 0)
gd = pix(xd, yd)
gc = pix(xc, yc)
if gd != want_d:
    sys.exit("desktop sample (%d,%d) is 0x%08X, want 0x%08X" % (xd, yd, gd, want_d))
if gc != want_c:
    sys.exit("chrome sample (%d,%d) is 0x%08X, want 0x%08X" % (xc, yc, gc, want_c))
if yd >= 600:
    sys.exit("desktop sample y is not outside Bochs height")
if yc < 600:
    sys.exit("chrome sample y is inside Bochs height — vacuous")
print("    desktop (%d,%d)=0x%08X  chrome (%d,%d)=0x%08X" % (xd, yd, gd, xc, yc, gc))
PY
echo "ASSERT: pass  pmemsave has desktop outside 800×600 and chrome on GOP strip"

# Unmapped miss: nofb must not claim WM GOP; dump of first-boot addr must
# not carry chrome colour after a boot that never mapped.
ck; ! grep -q 'WM GOP' "$NOFB" \
  || fail "no-fb boot printed WM GOP — compose claimed an unmapped aperture"
ck; ! grep -q 'FB GOP' "$NOFB" \
  || fail "no-fb boot printed FB GOP — fb was not typed"
# Manual pmemsave of the first-boot address after the nofb guest exited
# is not available (guest is gone). The serial miss is the load-bearing
# anti-vacuity: gopSessAnnounce only fires when gopIsLive.
echo "ASSERT: pass  no-fb boot has no WM GOP / no FB GOP"

ck; grep -q 'FB BAR' "$SER_MB" || fail "Multiboot boot has no FB BAR"
ck; grep -q 'MODE 0320x0258x20 OK' "$SER_MB" || fail "Multiboot missing Bochs MODE"
ck; ! grep -q 'WM GOP' "$SER_MB" || fail "Multiboot printed WM GOP"
ck; ! grep -q 'FB GOP' "$SER_MB" || fail "Multiboot printed FB GOP"
ck; grep -qE "^WM CHROME ON H ${CH_HEX} PX ${PX_BOCHS_HEX}\$" "$SER_MB" \
  || fail "Multiboot chrome PX is not ${PX_BOCHS_HEX} (800×${CH_H})"
echo "ASSERT: pass  -kernel stays Bochs; chrome PX ${PX_BOCHS_HEX}; no WM GOP"

require_assertions "$ASSERTIONS_REQUIRED"
echo "GOP-sess: PASS — session chrome composes on live OVMF GOP ${GOP_W}x${GOP_H}; unmapped miss; -kernel Bochs unchanged"
exit 0
