#!/usr/bin/env bash
# core/tests/conformance/de-osgfx/run.sh
#
# ADR-0110 + ADR-0125 — sit-in paint is live SkCanvas::drawRRect.
# osgfx_fill_rrect calls drawRRect (not SkRRect::contains + stores).
# Sit-in / `wm gfx` paints rrect chrome. `wm chrome` stays the square
# blit so d2/d8 stay PASS. osgfx_sw.c stays in-tree; not linked.
#
# Binary:
#   * nm / map show osgfx_fill_rrect and a Skia symbol (SkCanvas /
#     drawRRect / SkRRect) in kernel.elf
#   * OSGFX_SKIA=0 link has neither (anti-vacuity)
#   * after `wm gfx` + two d3-session windows, AABB corner is desktop
#     0x184060 and the title interior is title — not a square blit
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

fail() { echo "DE-osgfx: FAIL — $1" >&2; exit 1; }
setup_error() { echo "DE-osgfx: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=44

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-nm; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-de-osgfx.XXXXXX")" \
  || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
SIT="$CORE_DIR/tests/conformance/d3-session"
PROBE="$CORE_DIR/tests/conformance/d2-compositor/probe.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$PROBE" ]] || setup_error "probe.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== ANTI-VACUITY (no Skia .o) ==="
capture_sh NOSKIA_OUT NOSKIA_STATUS -- "OSGFX_SKIA=0 OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$NOSKIA_OUT"
ck; [[ $NOSKIA_STATUS -eq 0 ]] || fail "OSGFX_SKIA=0 build-kernel.sh exited $NOSKIA_STATUS"
cp "$KERNEL_ELF" "$WORKDIR/kernel-noskia.elf"
NOSKIA_NM=$(x86_64-elf-nm "$WORKDIR/kernel-noskia.elf" 2>/dev/null || true)
ck; ! echo "$NOSKIA_NM" | grep -q 'osgfx_fill_rrect' \
  || fail "OSGFX_SKIA=0 kernel.elf still names osgfx_fill_rrect"
ck; ! echo "$NOSKIA_NM" | grep -qE 'SkCanvas|drawRRect|SkRRect' \
  || fail "OSGFX_SKIA=0 kernel.elf still names a Skia symbol"
ck; ! echo "$NOSKIA_NM" | grep -q 'osgfx_scene_compose' \
  || fail "OSGFX_SKIA=0 kernel.elf still names osgfx_scene_compose"
echo "ANTI-VACUITY: pass  no Skia symbols without osgfx_skia.o"

echo
echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "OSMEDIA_FFMPEG=0 bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"
ck; [[ -f "$CORE_DIR/build/osgfx_skia.o" ]] || fail "no osgfx_skia.o"
ck; [[ -f "$CORE_DIR/build/osgfx_scene.o" ]] || fail "no osgfx_scene.o"
ck; [[ -f "$CORE_DIR/build/skia/out/guest-elf/libskia.a" ]] \
  || fail "no guest-elf libskia.a"

NM=$(x86_64-elf-nm "$KERNEL_ELF" | grep -E 'osgfx_fill_rrect|osgfx_create|osgfx_scene_compose|osgfx_guest_tick|osgfx_backend_name|drawRRect|SkCanvas|SkRRect')
ck; echo "$NM" | grep -q 'osgfx_fill_rrect' \
  || fail "kernel.elf has no osgfx_fill_rrect — C backend not linked"
ck; echo "$NM" | grep -q 'osgfx_create' \
  || fail "kernel.elf has no osgfx_create"
ck; echo "$NM" | grep -q 'osgfx_scene_compose' \
  || fail "kernel.elf has no osgfx_scene_compose"
ck; echo "$NM" | grep -q 'osgfx_guest_tick' \
  || fail "kernel.elf has no osgfx_guest_tick"
ck; echo "$NM" | grep -q 'osgfx_backend_name' \
  || fail "kernel.elf has no osgfx_backend_name"
ck; echo "$NM" | grep -q 'drawRRect' \
  || fail "kernel.elf has no drawRRect — Skia not linked"
ck; echo "$NM" | grep -q 'SkCanvas' \
  || fail "kernel.elf has no SkCanvas"
ck; echo "$NM" | grep -q 'SkRRect' \
  || fail "kernel.elf has no SkRRect"
ck; grep -q 'osgfx_skia.o' "$CORE_DIR/build/kernel.map" \
  || fail "kernel.map does not name osgfx_skia.o"
ck; ! grep -q 'osgfx_sw.o' "$CORE_DIR/build/kernel.map" \
  || fail "kernel.map still names osgfx_sw.o — that is not Skia"
ck; python3 -c "import sys; sys.exit(0 if b'skia\x00' in open(sys.argv[1],'rb').read() else 1)" \
  "$KERNEL_ELF" || fail "kernel.elf has no skia backend string"
ck; python3 -c "import sys; sys.exit(0 if b'skia-draw\x00' in open(sys.argv[1],'rb').read() else 1)" \
  "$KERNEL_ELF" || fail "kernel.elf has no skia-draw paint-path string"
echo "SKIA BACKEND: pass  drawRRect / SkCanvas / SkRRect in kernel.elf"
echo "BUILD: pass  osgfx_* + Skia in kernel.elf and kernel.map"

echo
echo "=== STRUCTURAL ==="
FILL_SRC=$(awk '/^void osgfx_fill_rrect\(/,/^}/' \
  "$CORE_DIR/plat/osgfx/osgfx_skia.cpp")
ck; echo "$FILL_SRC" | grep -q 'drawRRect' \
  || fail "osgfx_fill_rrect does not call drawRRect"
ck; ! echo "$FILL_SRC" | grep -q 'contains' \
  || fail "osgfx_fill_rrect still uses SkRRect::contains + stores"
ck; grep -q 'skia-draw' "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "osgfx_skia.cpp lost the skia-draw token"
ck; grep -q 'SkRRect' "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "osgfx_skia.cpp has no SkRRect"
echo "BACKEND: pass  skia + DRAW (not CONTAINS)"
ck; grep -q 'osgfx_session_paint' "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "tick_body does not call osgfx session paint"
ck; grep -q 'osgfx_fill_rrect' "$CORE_DIR/plat/osgfx/osgfx_session.c" \
  || fail "osgfx_session.c does not call osgfx_fill_rrect"
ck; grep -q 'return "skia"' "$CORE_DIR/plat/osgfx/osgfx_skia.cpp" \
  || fail "osgfx_skia.cpp does not name the backend skia"
ck; [[ -f "$CORE_DIR/plat/osgfx/osgfx_sw.c" ]] \
  || fail "osgfx_sw.c missing — g11 greps the source; do not delete it"
ck; grep -q "typekeys 'wm gfx'" "$CORE_DIR/scripts/sit-in.sh" \
  || fail "sit-in.sh does not type wm gfx"
ck; grep -q "typekeys 'wm chrome'" "$CORE_DIR/tests/conformance/d8-chrome/run.sh" \
  || fail "d8-chrome no longer types wm chrome — goldens must keep the old blit"
ck; grep -q "typekeys 'wm chrome'" "$CORE_DIR/tests/conformance/d8-title/run.sh" \
  || fail "d8-title no longer types wm chrome"
ck; ! grep -q 'OSGFX_GUEST=1' "$CORE_DIR/scripts/sit-in.sh" \
  || fail "sit-in.sh sets OSGFX_GUEST=1 — do not copy Mac libskia into kernel.elf"
ck; grep -q '@extern' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart lost osgfx @extern doors"
ck; ! grep -q '^@bss' "$CORE_DIR/kernel/wmgfx.dart" \
  || fail "wmgfx.dart declares @bss"
ck; grep -q '11' "$CORE_DIR/docs/syscall-registry.md" \
  || fail "syscall-registry lost 11"
echo "STRUCTURAL: pass  Skia osgfx, sit-in wm gfx, d8 keeps wm chrome"

echo
echo "=== PROGRAMS ==="
ck; bash "$SIT/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "d3-session clients failed to build"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SIT/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py failed"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read slot LBAs"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
out=[]
for c in sys.argv[1]:
    out.append({' ':'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2500"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:800"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_A"),ret,until:D3S COMMIT,wait:400"
KEYS="$KEYS,$(typekeys "proc spawn $LBA_B"),ret,until:D3S COMMIT,wait:800"

SER="$WORKDIR/serial.txt"
FB_BIN="$WORKDIR/fb.bin"
PNG="$CORE_DIR/build/de-osgfx.png"
: >"$SER"
ck; PORT=$(python3 "$PICKER") || fail "no free QMP port"
timeout 180 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$PORT,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
QEMU_PID=$!
run_status DRIVE_STATUS -- python3 - "$PORT" "$SER" "$FB_BIN" "$PNG" "$KEYS" <<'PY'
import json, os, re, socket, struct, sys, time, zlib

port, serial, fb_bin, png, keys = (
    int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
)

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
                print("DE-osgfx: QEMU", hello.get("QMP", {}).get("version", {}))
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

def write_png(path, width, height, pitch, bgra):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        off = y * pitch
        row = bgra[off:off + width * 4]
        for x in range(width):
            b, g, r = row[x * 4], row[x * 4 + 1], row[x * 4 + 2]
            raw.extend((r, g, b))
    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    open(path, "wb").write(blob)

q = Qmp(port)
if not wait_marker(serial, "M1 END\n"):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.5)
commits = 0
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        commits += 1
        if not wait_marker(serial, marker + "\n", timeout=20, at_least=commits):
            raise SystemExit("never saw %d x %s" % (commits, marker))
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(1.2)
text = open(serial, "r", encoding="latin-1").read()
m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
if not m:
    raise SystemExit("never saw WM ON BASE")
addr = int(m.group(1), 16)
pitch = int(m.group(2), 16)
q.cmd("pmemsave", val=addr, size=600 * pitch, filename=os.path.abspath(fb_bin))
data = open(fb_bin, "rb").read()
write_png(png, 800, 600, pitch, data)
q.cmd("screendump", filename=os.path.abspath(png + ".q.png"), format="png")
q.cmd("quit")
print("DE-osgfx: dumped fb @ 0x%X pitch %d" % (addr, pitch))
PY
await QEMU_STATUS "$QEMU_PID"
ck; if [[ $DRIVE_STATUS -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial (tail) ---" >&2
  tail -80 "$SER" >&2
  fail "session driver exited $DRIVE_STATUS"
fi
ck; [[ -s "$SER" ]] || fail "serial capture is empty"
ck; grep -q 'WM GFX ON' "$SER" || fail "WM GFX ON did not print"
ck; [[ -s "$FB_BIN" ]] || fail "no framebuffer dump"

echo
echo "=== PIXELS ==="
PITCH=$((16#$(grep -m1 -oE '^WM ON BASE [0-9A-Fa-f]+ PITCH ([0-9A-Fa-f]+)' "$SER" | awk '{print $NF}')))
ck; [[ "$PITCH" -gt 0 ]] || fail "could not read pitch"
# Window A is 240x160 at (100,120). ADR-0196 outset the card stroke by
# half a border, so the AABB corner sits in the AA fringe of the curve
# (measured 0x194161 against desk 0x184060). A square blit lands a
# chrome/title/client SOLID. Assert the fringe is near desktop and not
# a solid, and a pixel outside the stroke AABB is exact desktop.
DESK_C=0x00184060
ck; python3 - "$FB_BIN" "$PITCH" "$DESK_C" <<'PY' \
  || fail "AABB (100,120) is not the rrect hole — chrome is still square or missing"
import sys
blob = open(sys.argv[1], "rb").read()
pitch = int(sys.argv[2])
desk = int(sys.argv[3], 16) & 0xFFFFFF
solids = (0x00344050, 0x00E8E0D0, 0x001A2430, 0x00F4F0E8)

def pix(x, y):
    o = y * pitch + x * 4
    return int.from_bytes(blob[o:o+4], "little") & 0xFFFFFF

def near(c, e, slop=0x18):
    return all(abs(((c >> s) & 0xFF) - ((e >> s) & 0xFF)) <= slop for s in (0, 8, 16))

aabb = pix(100, 120)
out = pix(94, 114)
if aabb in solids:
    raise SystemExit("AABB is solid %06X — square chrome, not an AA rrect hole" % aabb)
if not near(aabb, desk):
    raise SystemExit("AABB is %06X, not near desktop %06X" % (aabb, desk))
if out != desk:
    raise SystemExit("outside-stroke (94,114) is %06X, want exact desktop %06X" % (out, desk))
print("    aabb_corner            (100,120) = %06X near desk; (94,114) = %06X" % (aabb, out))
PY
# The title band. This used to be one exact-colour probe against 0x00D8B060,
# the tan OSGFX_TITLE of the flat-fill era. ADR-0187 replaced the flat fill plus
# stamped sheen with ONE Skia vertical gradient, SESS_TITLE_TOP -> OSGFX_TITLE,
# so no single row equals a constant and an exact probe can only be satisfied by
# a stamp. Same replacement de-session's worker made, and the same shared
# checker: assert both ENDS of the gradient and that the band really travels
# between them in several steps. Strictly stronger than the pixel it replaces —
# a flat fill in the right colour would now fail.
DE_SESSION_DERIVE="$CORE_DIR/tests/conformance/de-session/derive.py"
ck; [[ -f "$DE_SESSION_DERIVE" ]] || fail "de-session/derive.py is missing — the title-gradient checker is shared with it, not copied"
ck; python3 "$DE_SESSION_DERIVE" title_gradient "$FB_BIN" "$PITCH" 200 120 32 \
  0x00F4F0E8 0x00E8E0D0 \
  || fail "title band is not a Skia vertical gradient in the ADR-0187 title colours — osgfx did not paint the caption card"
# The taskbar. This used to be an exact probe against 0x00C09048, the tan strip
# of the stamp era; the DE chrome colour is now slate. The colour is READ out of
# osgfx.h rather than retyped, and osgfx.h's OSGFX_CHROME is required to equal
# wmchrome.dart's wmChromeColor first -- ADR-0106 makes DE chrome compositor
# policy, so the C module and the OS must be naming one colour, and a probe
# against a number this harness typed would pass while they disagreed.
CHROME_HDR=$(awk -F'= *' '/OSGFX_CHROME *=/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$CORE_DIR/plat/osgfx/osgfx.h")
CHROME_DART=$(awk -F'= *' '/^const int wmChromeColor/{gsub(/[^0-9A-Fa-fx]/,"",$2); print $2; exit}' "$CORE_DIR/kernel/wmchrome.dart")
ck; [[ -n "$CHROME_HDR" && "$CHROME_HDR" == "$CHROME_DART" ]] \
  || fail "osgfx.h's OSGFX_CHROME ($CHROME_HDR) and wmchrome.dart's wmChromeColor ($CHROME_DART) are different colours — ADR-0106 has DE chrome as one policy, painted by one module"
ck; python3 "$PROBE" "$FB_BIN" "$PITCH" 400 599 "$CHROME_HDR" "taskbar" \
  || fail "the taskbar's bottom row is not OSGFX_CHROME"
echo "PIXELS: pass  corner desktop, title interior title, taskbar chrome"

require_assertions "$ASSERTIONS_REQUIRED"
echo "DE-osgfx: PASS — kernel.elf live drawRRect; sit-in/wm gfx AABB is desktop ($ASSERTIONS checks)"
exit 0
