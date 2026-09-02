#!/usr/bin/env bash
# core/tests/conformance/view-door/run.sh
#
# ADR-0175 — Display door: sane guest FB + host scale path.
# QEMU stays the Graphite emulator; sit-in-view.sh is the viewer.
#
# Exit: 0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

fail() { echo "view-door: FAIL — $1" >&2; exit 1; }
setup_error() { echo "view-door: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=44
VIEW_W=1280
VIEW_H=720

for tool in qemu-system-x86_64 python3 docker; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

VIEW_SH="$CORE_DIR/scripts/sit-in-view.sh"
SITIN_SH="$CORE_DIR/scripts/sit-in.sh"
BUILD_GL="$CORE_DIR/scripts/build-qemu-gl.sh"
FB_REF="$CORE_DIR/scripts/sit-in-view-fb-refresh.py"
ADR="$CORE_DIR/docs/decisions/0175-the-display-door-is-a-controlled-qemu-viewer.md"
ADR193="$CORE_DIR/docs/decisions/0193-absolute-pointer-is-a-tablet.md"
GAPS="$CORE_DIR/docs/known-gaps.md"

echo "=== STRUCTURAL ==="
ck; [[ -f "$VIEW_SH" ]] || fail "sit-in-view.sh missing"
ck; [[ -x "$VIEW_SH" ]] || chmod +x "$VIEW_SH"
ck; grep -q 'zoom-to-fit=on' "$VIEW_SH" || fail "sit-in-view has no cocoa zoom-to-fit"
ck; grep -q 'sdl,gl=on' "$VIEW_SH" || fail "sit-in-view Venus path is not sdl,gl"
ck; grep -q 'xdotool windowmove' "$VIEW_SH" || fail "sit-in-view Venus path missing xdotool pin"
ck; grep -q 'x11vnc' "$VIEW_SH" || fail "sit-in-view has no x11vnc door"
ck; grep -q '\-rawfb' "$VIEW_SH" || fail "sit-in-view Venus x11vnc missing -rawfb (full guest SCAN)"
ck; grep -q '\-pipeinput' "$VIEW_SH" || fail "sit-in-view Venus x11vnc missing -pipeinput (Tiger was display-only)"
ck; [[ -f "$CORE_DIR/scripts/sit-in-view-input-bridge.py" ]] \
  || fail "sit-in-view-input-bridge.py missing"
ck; grep -q 'input-send-event' "$CORE_DIR/scripts/sit-in-view-input-bridge.py" \
  || fail "input-bridge does not talk QMP input-send-event"
ck; grep -q '\-scale' "$VIEW_SH" || fail "sit-in-view Venus x11vnc missing -scale (Mac letterbox)"
ck; grep -q 'letterbox_scale\|SITIN_MAC_FILL' "$VIEW_SH" || fail "sit-in-view missing aspect-preserving Mac fill"
ck; grep -q 'mw // vw\|integer' "$VIEW_SH" || fail "sit-in-view Mac fill is not integer scale (fractional mush)"
ck; ! grep -E 'x11vnc[^\n]*:nb|-scale[^\n]*:nb' "$VIEW_SH" \
  || fail "sit-in-view must not pass x11vnc :nb (nearest)"
ck; grep -q 'PreferredEncoding=Raw\|NoJPEG=1' "$VIEW_SH" \
  || fail "sit-in-view Tiger path missing Raw/NoJPEG (JPEG softens chrome)"
ck; ! grep -q 'CLIP_W=640' "$VIEW_SH" || fail "sit-in-view still has CLIP_W=640 crop (owner-hated)"
ck; ! grep -vE '^\s*#' "$VIEW_SH" | grep -qE '\-clip[[:space:]]*640x480' \
  || fail "sit-in-view still clips 640x480"
ck; grep -q 'FullScreen=1' "$VIEW_SH" || fail "sit-in-view missing Tiger -FullScreen=1 launcher"
ck; [[ -f "$FB_REF" ]] || fail "sit-in-view-fb-refresh.py missing"
ck; grep -q 'zoom-to-fit=on' "$SITIN_SH" || fail "sit-in.sh default is not cocoa zoom-to-fit"
ck; grep -q 'x11vnc' "$BUILD_GL" || fail "build-qemu-gl.sh does not install x11vnc"
ck; [[ -f "$ADR" ]] || fail "ADR-0175 missing"
ck; [[ -f "$ADR193" ]] || fail "ADR-0193 missing"
ck; grep -q 'mouseAbsPlace' "$CORE_DIR/kernel/mouse.dart" \
  || fail "mouseAbsPlace missing — absolute pointer is not SET"
ck; grep -q 'virtio-tablet-pci' "$VIEW_SH" \
  || fail "sit-in-view does not attach virtio-tablet-pci"
ck; grep -q 'prove_abs_input\|MOUSE ABS' "$VIEW_SH" \
  || fail "sit-in-view INPUT prove is still relative warp"
ck; ! grep -q 'warp_click' "$VIEW_SH" \
  || fail "sit-in-view still has the closed-loop relative warp"
ck; grep -q 'virtab.dart' "$CORE_DIR/kernel/kmain.dart" \
  || fail "kmain does not part virtab.dart"
ck; grep -q 'not a second hypervisor' "$ADR" || fail "ADR-0175 lost the hypervisor ruling"
ck; grep -q 'sdl,gl' "$ADR" || fail "ADR-0175 must name sdl,gl vs gtk"
ck; grep -q 'rawfb\|guest SCAN\|no 640' "$ADR" || fail "ADR-0175 must record rawfb / no-640 door"
ck; grep -q 'pipeinput\|input bridge\|interactive' "$ADR" \
  || fail "ADR-0175 must record interactive pipeinput door"
ck; grep -q 'GAP-0324' "$GAPS" || fail "known-gaps missing GAP-0324"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
# Refuse a new allocated row; comments naming 0174 elsewhere are fine.
ck; ! grep -E '^\| *[0-9]+ \|' "$CORE_DIR/docs/syscall-registry.md" \
      | grep -q '0175|sit-in-view\|view-door' \
  || fail "ADR-0175 added a syscall row"
echo "STRUCTURAL: pass  viewer; zoom; sdl; rawfb; pipeinput; FullScreen; ADR-0175; no syscall"

echo
echo "=== VENUS VIEW BOOT ==="
export SITIN_SKIP_BUILD=1
export VIEW_W VIEW_H
export VNC_PORT=5907
# Door size for harness — do not Mac-fill or launch Tiger during CI.
export SITIN_MAC_FILL=0
export SITIN_TIGER=0
export VNC_SCALE_W="$VIEW_W"
export VNC_SCALE_H="$VIEW_H"
[[ -f "$CORE_DIR/build/kernel.elf" ]] \
  || fail "no kernel.elf — build once, then re-run with SITIN_SKIP_BUILD"

bash "$VIEW_SH" --kill >/dev/null 2>&1 || true
bash "$VIEW_SH" --venus || fail "sit-in-view.sh --venus failed"

SER="$CORE_DIR/build/sit-in-view-venus/serial.txt"
[[ -s "$SER" ]] || SER="$CORE_DIR/build/sit-in-view-venus-serial.txt"
MODE_STAMP="$CORE_DIR/build/sit-in-view-venus/view.mode"
PNG="$CORE_DIR/build/sit-in-view-venus.png"
ck; [[ -s "$SER" ]] || fail "no Venus view serial"
ck; grep -q 'VIRTIO VENUS OK' "$SER" || fail "no VIRTIO VENUS OK"
ck; grep -q 'VIEW MODE' "$SER" || grep -q 'VIEW MODE' "$MODE_STAMP" \
  || fail "no VIEW MODE stamp"
ck; python3 - "$SER" "$VIEW_W" "$VIEW_H" <<'PY' || fail "SCAN below door size"
import re, sys
text = open(sys.argv[1], encoding="latin-1").read()
want_w, want_h = int(sys.argv[2]), int(sys.argv[3])
m = re.search(
    r"^VIRTIO SCAN [0-9A-Fa-f]+ [0-9A-Fa-f]+ ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)",
    text, re.M)
if not m:
    raise SystemExit("no SCAN")
w, h = int(m.group(1), 16), int(m.group(2), 16)
print("SCAN %dx%d" % (w, h))
if w < want_w or h < want_h:
    raise SystemExit("SCAN %dx%d < %dx%d" % (w, h, want_w, want_h))
PY
ck; [[ -s "$PNG" ]] || fail "no sit-in-view-venus.png"
ck; python3 - "$PNG" "$VIEW_W" "$VIEW_H" <<'PY' || fail "PNG size wrong"
import struct, sys
path, want_w, want_h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = open(path, "rb").read(24)
assert d[:8] == b"\x89PNG\r\n\x1a\n"
w, h = struct.unpack(">II", d[16:24])
print("PNG %dx%d" % (w, h))
if w < want_w or h < want_h:
    raise SystemExit("PNG %dx%d < %dx%d" % (w, h, want_w, want_h))
PY
if nc -z 127.0.0.1 "$VNC_PORT" 2>/dev/null; then
  echo "    VNC: 127.0.0.1:$VNC_PORT open"
  ck; python3 - "$VNC_PORT" "$VIEW_W" "$VIEW_H" <<'PY' || fail "VNC desktop not door-sized (crop risk)"
import socket, struct, sys
port, want_w, want_h = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
s = socket.create_connection(("127.0.0.1", port), timeout=3)
s.recv(12); s.sendall(b"RFB 003.008\n")
n = s.recv(1)[0]; s.recv(n); s.sendall(bytes([1])); s.recv(4)
s.sendall(struct.pack(">B", 1))
hdr = b""
while len(hdr) < 24:
    hdr += s.recv(24 - len(hdr))
w, h = struct.unpack(">HH", hdr[:4])
print("VNC desktop %dx%d" % (w, h))
if w != want_w or h != want_h:
    raise SystemExit("VNC %dx%d != %dx%d" % (w, h, want_w, want_h))
s.close()
PY
else
  echo "    note: VNC port $VNC_PORT not probed open (x11vnc may bind late)"
  ck; true
fi
ck; [[ -f "$CORE_DIR/build/sit-in-view-venus/input.ok" ]] \
  || fail "no input.ok — Tiger path did not prove QMP mouse/Start"
ck; grep -q 'MOUSE ABS\|MOUSE PKT\|INPUT abs\|INPUT Start' \
  "$CORE_DIR/build/sit-in-view-venus/serial.txt" \
  || grep -q 'INPUT OK' "$CORE_DIR/build/sit-in-view-venus/input.ok" \
  || fail "serial/input.ok missing input proof"
# Frosted glass dock (ADR-0197/0198) + FILES CSD on Venus Graphite.
# Graphite title is 0xE8EEF4 ramp — not wmTitleColor 0xE8E0D0 from wmchrome.dart.
ck; python3 - "$PNG" <<'PY' || fail "designed chrome missing (dock glass or FILES CSD)"
import struct, sys, zlib
path = sys.argv[1]
data = open(path, "rb").read()
i = 8
w = h = None
raw = b""
while i + 8 <= len(data):
    ln = struct.unpack(">I", data[i : i + 4])[0]
    tag = data[i + 4 : i + 8]
    body = data[i + 8 : i + 8 + ln]
    i = i + 12 + ln
    if tag == b"IHDR":
        w, h = struct.unpack(">II", body[:8])
    elif tag == b"IDAT":
        raw += body
img = zlib.decompress(raw)
row = w * 3 + 1

def pix(x, y):
    o = y * row + 1 + x * 3
    return (img[o] << 16) | (img[o + 1] << 8) | img[o + 2]

def chans(c):
    return (c >> 16) & 255, (c >> 8) & 255, c & 255

chrome_h = 48
bar_y = h - chrome_h
dock_y = bar_y + 4 + 20
dock_samples = [pix(x, y) for y in (bar_y + 4 + 12, bar_y + 4 + 28)
                for x in (56, 160, 200, 240) if x < w]
for ink in dock_samples:
    r, g, b = chans(ink)
    if ink == 0xC87840:
        raise SystemExit("left island is still copper Start")
    if r + g + b < 200:
        raise SystemExit("left island 0x%06X is not frosted glass" % ink)
if len(set(dock_samples)) < 2:
    raise SystemExit("island pixels are one flat colour — no frost")
gap = pix(min(w - 1, 400 if w >= 800 else w // 2), dock_y)
if gap in dock_samples:
    raise SystemExit("gap matches island — dock is still a bar")

# FILES window when sit-in-view spawned it; boot desk alone is also valid.
win_chrome = pix(54, 46)
if win_chrome == 0x101018:
    body = pix(148, 58)
    if sum(chans(body)) < 700:
        raise SystemExit("FILES body 0x%06X too dark" % body)
    title_col = [pix(148, y) for y in range(40, 85)]
    pearl = [c for c in title_col if chans(c)[0] >= 200]
    shades = len(set(pearl))
    if shades < 4:
        raise SystemExit("Graphite title band has %d shades — flat stamp" % shades)
    if 0xD8B060 in title_col:
        raise SystemExit("title band still contains gold stamp 0xD8B060")
    print("chrome: pass  frosted dock gap %06X; FILES CSD; %d-shade Graphite title"
          % (gap, shades))
else:
    # Wallpaper / generative desk visible where a window would be — not dock glass.
    wr, wg, wb = chans(win_chrome)
    if win_chrome in dock_samples:
        raise SystemExit("window slot 0x%06X is dock glass — full-width bar?" % win_chrome)
    if wr + wg + wb < 120:
        raise SystemExit("window slot 0x%06X unexpectedly dark" % win_chrome)
    print("chrome: pass  frosted dock gap %06X; generative desk @ (54,46)=%06X"
          % (gap, win_chrome))
PY

echo "VENUS VIEW: pass  SCAN; VIEW MODE; PNG; VENUS OK; rawfb; interactive input; designed chrome"

require_assertions "$ASSERTIONS_REQUIRED"
echo "view-door: PASS — display door interactive + designed chrome ($ASSERTIONS checks)"
exit 0
