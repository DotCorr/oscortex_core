#!/usr/bin/env bash
# core/scripts/sit-in-view.sh
#
# Display door for looking at oscortex on a Mac without a postage-stamp
# window (ADR-0175). QEMU remains the Graphite emulator; this script is
# the controlled viewer / scale path, not a second hypervisor.
#
# Absolute-pointer door (ADR-0193) — what the owner should click:
#   sit-in-view.sh --abs     QEMU cocoa window `oscortex-abs-pointer`
#                            + virtio-tablet-pci. One cursor, 1:1.
#                            SLIRP user-net + e1000 (ADR-0151 live OTA)
#                            + OTAKEY/SLOT.TXT on the sit-in FAT.
#                            If cocoa cannot open, QEMU's own -vnc on
#                            VNC_PORT (not x11vnc-rawfb) + tablet.
#   Input:     QEMU tablet ABS → virtab → mouseAbsPlace. Not PS/2 rel.
#   OTA:       host listener on 127.0.0.1:<port>; in the OS shell
#              `ota get <port>` → 10.0.2.2 (SLIRP) → OTA OK. No sshd.
#   Do NOT:    docker ps -aq --filter ancestor=oscortex-qemu-gl:local |
#              xargs docker rm -f
#
# Venus Graphite look path still exists (--venus) but is not the
# pointer door. It now also attaches virtio-tablet; QMP abs is the
# INPUT prove (no relative warp).
#
#   sit-in-view.sh                local cocoa, zoom-to-fit (Bochs 800×600)
#   sit-in-view.sh --uefi-hd      UEFI GOP 1280×720 + cocoa zoom-to-fit
#   sit-in-view.sh --venus        Docker Venus Graphite: Xvfb 1280×720,
#                                 sdl,gl=on (Venus GL) + x11vnc -rawfb of
#                                 guest SCAN at VIEW_W×VIEW_H via -rawfb
#                                 (NO 640×480 clip — that cropped the desk)
#                                 PLUS -pipeinput → QMP input bridge so
#                                 Tiger pointer/keyboard reach PS/2 (not a
#                                 stale picture). Darwin: INTEGER aspect-fit
#                                 -scale into Mac bounds (1× or 2× …;
#                                 letterbox OK; crop not OK; never fractional
#                                 mush / :nb) + Tiger -FullScreen=1 (Raw /
#                                 NoJPEG). VNC host port default 5900.
#   sit-in-view.sh --abs          cocoa (or QEMU -vnc) + virtio-tablet
#                                 + e1000 user-net + OTA FAT plants
#   sit-in-view.sh --kill         stop local / Venus view sessions
#
# Env:
#   VIEW_W / VIEW_H     guest mode for --uefi-hd / --venus (default 1280×720)
#   VNC_PORT            host port for Venus x11vnc (default 5900)
#   VNC_SCALE_W/H       x11vnc -scale size (default VIEW; Darwin Mac-fit
#                       overrides when SITIN_MAC_FILL=1)
#   SITIN_MAC_FILL=1    Darwin: integer scale into Mac logical bounds
#                       (letterbox; never crop; default on Darwin; harness=0)
#   SITIN_TIGER=1       Darwin: launch TigerVNC -FullScreen=1 (default on)
#   SITIN_SKIP_BUILD=1  reuse core/build/kernel.elf
#   SITIN_DISPLAY=...   override local -display (default cocoa,zoom-to-fit=on)
#   SITIN_ABS_OTA=0     abs door: skip live OTA prove (NIC+keys still on)
#
# PASS tokens: serial `VIEW MODE <w>x<h>`, PNG at that size under
# core/build/sit-in-view*.png. Harness: tests/conformance/view-door/.
# Abs OTA: serial `OTA OK <paylen>` after host listener + `ota get`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
RUN_DIR="$CORE_DIR/build/sit-in-view"
VENUS_DIR="$CORE_DIR/build/sit-in-view-venus"
PIDFILE="$RUN_DIR/qemu.pid"
SITFAT="$CORE_DIR/tests/conformance/de-sitfat"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
DRIVER="$CORE_DIR/tests/conformance/m2-console/qmp-drive.py"

VIEW_W="${VIEW_W:-1280}"
VIEW_H="${VIEW_H:-720}"
VNC_PORT="${VNC_PORT:-5900}"
IMAGE="${OSCORTEX_QEMU_GL_IMAGE:-oscortex-qemu-gl:local}"

# Darwin live: fill Mac without cropping the 16:9 desk (letterbox OK).
if [[ "$(uname -s)" == "Darwin" ]]; then
  SITIN_MAC_FILL="${SITIN_MAC_FILL:-1}"
  SITIN_TIGER="${SITIN_TIGER:-1}"
else
  SITIN_MAC_FILL="${SITIN_MAC_FILL:-0}"
  SITIN_TIGER="${SITIN_TIGER:-0}"
fi

mac_logical_size() {
  osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
    | python3 -c 'import sys; p=[int(x.strip()) for x in sys.stdin.read().split(",")]; print(p[2]-p[0], p[3]-p[1])' \
    2>/dev/null
}

# Integer aspect-fit of VIEW into max_w×max_h (letterbox, never crop).
# Fractional scale (e.g. 1280→1800) stair-steps thin chrome under Tiger
# even when x11vnc blends; prefer 1×/2× sharpness. Mac letterbox is OK.
# x11vnc blending (bilinear) is the default — never append :nb (nearest).
letterbox_scale() {
  python3 -c 'import sys
vw,vh,mw,mh=map(int,sys.argv[1:])
if vw < 1 or vh < 1:
  print(1, 1); raise SystemExit
f = max(1, min(mw // vw, mh // vh))
print(vw * f, vh * f)' "$1" "$2" "$3" "$4"
}

VNC_SCALE_W="${VNC_SCALE_W:-$VIEW_W}"
VNC_SCALE_H="${VNC_SCALE_H:-$VIEW_H}"
if [[ "$SITIN_MAC_FILL" == 1 ]]; then
  if mac_wh="$(mac_logical_size)" && [[ -n "$mac_wh" ]]; then
    mac_w="${mac_wh%% *}"
    mac_h="${mac_wh##* }"
    scaled="$(letterbox_scale "$VIEW_W" "$VIEW_H" "$mac_w" "$mac_h")"
    VNC_SCALE_W="${scaled%% *}"
    VNC_SCALE_H="${scaled##* }"
  fi
fi

say() { printf 'sit-in-view: %s\n' "$*"; }
fail() { printf 'sit-in-view: FAIL — %s\n' "$*" >&2; exit 1; }

kill_all() {
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  pkill -f 'oscortex-sit-in-view' 2>/dev/null || true
  # Do NOT pkill oscortex-abs-pointer on ordinary --kill / view relaunch.
  # That cocoa tablet door is owned by the live DE session (GAP-0355).
  # --kill-all still tears it down.
  pkill -x vncviewer 2>/dev/null || true
  rm -f "$VENUS_DIR/DOOR_LOCK"
  docker rm -f oscortex-interactive-door oscortex-venus-view oscortex-tiger-view 2>/dev/null || true
  # Boot aliases (temp names during INPUT prove).
  docker ps -aq --filter name=oscortex-interactive-door-boot- 2>/dev/null | xargs docker rm -f 2>/dev/null || true
  # Leave abs-pointer and the older oscortex-venus-graphite alone unless --kill-all.
  if [[ "${1:-}" == "all" ]]; then
    pkill -f 'oscortex-abs-pointer' 2>/dev/null || true
    docker rm -f oscortex-venus-graphite 2>/dev/null || true
  fi
  say "stopped"
}

launch_tiger_fullscreen() {
  local port="$1"
  local app="/Applications/TigerVNC.app"
  [[ -d "$app" ]] || { say "TigerVNC not at $app — open vnc://127.0.0.1:${port} yourself"; return 0; }
  pkill -x vncviewer 2>/dev/null || true
  sleep 0.5
  # LAUNCH VIA launchd (`open -a`), NOT `nohup ... & disown`.
  #
  # Measured: a nohup'd, disowned vncviewer connects, logs through "Choosing
  # security type None(1)", and is then killed with no error line and no
  # further output when the launching shell's process group is reaped. nohup
  # only covers SIGHUP, so it does not survive that. The door outlives this
  # script by design, and the viewer has to outlive it too, so the viewer must
  # not be our child at all. `open -a` hands it to launchd, which is a
  # different session; measured alive well past the point both nohup attempts
  # had already been reaped.
  #
  # -FullScreen is also dropped. It made the viewer exit within seconds under
  # the same conditions, and a window the owner can see beats a fullscreen one
  # that is gone. Raw + NoJPEG: Tight/JPEG softens thin chrome into mush.
  # RemoteResize=0: the server size is the rawfb door's own size.
  : >"$VENUS_DIR/tigervnc.log"
  open -a "$app" --args \
    -Shared=1 -RemoteResize=0 -ReconnectOnError=1 \
    -AutoSelect=0 -PreferredEncoding=Raw -FullColor=1 -NoJPEG=1 \
    -QualityLevel=9 \
    "127.0.0.1::${port}" >>"$VENUS_DIR/tigervnc.log" 2>&1 || true
  sleep 4
  if pgrep -x vncviewer >/dev/null; then
    say "TigerVNC pid $(pgrep -n -x vncviewer) → 127.0.0.1:${port} (launchd; survives this script)"
  else
    say "WARN — TigerVNC did not stay up; see $VENUS_DIR/tigervnc.log"
    say "      open vnc://127.0.0.1:${port} yourself"
  fi
}

if [[ "${1:-}" == "--kill" ]]; then
  kill_all
  exit 0
fi
if [[ "${1:-}" == "--kill-all" ]]; then
  kill_all all
  exit 0
fi

MODE=local
ABS_DOOR=0
if [[ "${1:-}" == "--uefi-hd" || "${1:-}" == "--hd" ]]; then
  MODE=uefi-hd
elif [[ "${1:-}" == "--venus" ]]; then
  MODE=venus
elif [[ "${1:-}" == "--abs" ]]; then
  ABS_DOOR=1
  MODE=local
elif [[ "${1:-}" == "--local" || -z "${1:-}" ]]; then
  MODE=local
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
else
  fail "unknown arg $1 (want --local | --uefi-hd | --abs | --venus | --kill)"
fi

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

mkdir -p "$RUN_DIR"
# --abs replaces the owner door by name. Ordinary --kill / other modes
# leave oscortex-abs-pointer alone (GAP-0355); only --abs / --kill-all
# tear it down so the disk unlocks for a NIC+OTA relaunch.
if [[ "$ABS_DOOR" == 1 ]]; then
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  pkill -f 'oscortex-abs-pointer' 2>/dev/null || true
  sleep 0.4
else
  kill_all >/dev/null 2>&1 || true
fi

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
if [[ "${SITIN_SKIP_BUILD:-}" == 1 ]]; then
  say "skipping kernel build (SITIN_SKIP_BUILD=1)"
  [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
else
  say "building kernel"
  bash "$CORE_DIR/scripts/build-kernel.sh" || fail "build-kernel.sh failed"
  [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
fi

say "building FAT volume"
bash "$SITFAT/build-disk.sh" "$RUN_DIR" || fail "de-sitfat/build-disk.sh failed"
[[ -s "$RUN_DIR/disk.img" ]] || fail "no FAT disk.img"

# ADR-0151 live path on the abs door: plant OTAKEY + SLOT.TXT (ADR-0199).
# Pointer-only abs boots previously omitted these on purpose.
if [[ "$ABS_DOOR" == 1 ]]; then
  say "planting OTAKEY + SLOT.TXT on sit-in FAT"
  python3 - "$RUN_DIR/disk.img" "$RUN_DIR" <<'PY' || fail "OTA FAT plant failed"
import os, struct, sys

img_path, out_dir = sys.argv[1], sys.argv[2]
img = bytearray(open(img_path, "rb").read())
SECTOR = 512
bps = struct.unpack_from("<H", img, 11)[0]
spc = img[13]
reserved = struct.unpack_from("<H", img, 14)[0]
nfats = img[16]
root_ents = struct.unpack_from("<H", img, 17)[0]
fat_secs = struct.unpack_from("<H", img, 22)[0]
root_secs = (root_ents * 32) // bps
fat_start = reserved
root_start = reserved + nfats * fat_secs
data_start = root_start + root_secs
cluster_bytes = spc * bps
total_secs = len(img) // SECTOR
cluster_count = (total_secs - data_start) // spc

def fat_get(c):
    at = fat_start * SECTOR + c * 2
    return struct.unpack_from("<H", img, at)[0]

def fat_put(c, v):
    for n in range(nfats):
        at = (fat_start + n * fat_secs) * SECTOR + c * 2
        struct.pack_into("<H", img, at, v)

def cluster_lba(c):
    return data_start + (c - 2) * spc

def find_free_cluster():
    for c in range(2, cluster_count + 2):
        if fat_get(c) == 0:
            return c
    raise SystemExit("no free cluster")

def find_free_dir_slot():
    root = root_start * SECTOR
    for i in range(root_ents):
        off = root + i * 32
        b0 = img[off]
        if b0 == 0 or b0 == 0xE5:
            return off
    raise SystemExit("no free root dir slot")

def dir_ent(raw11, first, size):
    e = bytearray(32)
    e[0:11] = raw11
    e[11] = 0x20
    struct.pack_into("<H", e, 26, first)
    struct.pack_into("<I", e, 28, size)
    struct.pack_into("<H", e, 24, ((2026 - 1980) << 9) | (1 << 5) | 1)
    return bytes(e)

def name_present(raw11):
    root = root_start * SECTOR
    for i in range(root_ents):
        off = root + i * 32
        if img[off] in (0, 0xE5):
            continue
        if img[off:off + 11] == raw11:
            return True
    return False

def digest(payload, key):
    out = bytearray(8)
    n = len(payload)
    for i in range(8):
        out[i] = key[i] ^ payload[i % n] ^ payload[(i * 3) % n] ^ (n & 0xFF) ^ i
    return bytes(out)

OLD = b"OLD!"
key = os.urandom(8)
payload = os.urandom(16)
if payload == OLD or key == bytes(8):
    key = os.urandom(8)
    payload = os.urandom(16)
sig = digest(payload, key)
blob = b"OTA1" + len(payload).to_bytes(2, "big") + sig + payload
bad = bytearray(blob)
bad[6] ^= 0x01
if bad[6] == blob[6]:
    bad[7] ^= 0x01

plants = [
    (b"SLOT    TXT", OLD),
    (b"OTAKEY     ", key),
]
for raw11, data in plants:
    if name_present(raw11):
        continue
    cl = find_free_cluster()
    fat_put(cl, 0xFFFF)
    off = find_free_dir_slot()
    img[off:off + 32] = dir_ent(raw11, cl, len(data))
    lba = cluster_lba(cl)
    base = lba * SECTOR
    chunk = data + b"\0" * (cluster_bytes - len(data))
    img[base:base + cluster_bytes] = chunk

open(img_path, "wb").write(img)
open(os.path.join(out_dir, "OTAKEY"), "wb").write(key)
open(os.path.join(out_dir, "SLOT.TXT"), "wb").write(OLD)
open(os.path.join(out_dir, "ota-blob.bin"), "wb").write(blob)
open(os.path.join(out_dir, "ota-bad.bin"), "wb").write(bytes(bad))
open(os.path.join(out_dir, "ota-payload.bin"), "wb").write(payload)
open(os.path.join(out_dir, "ota-meta.txt"), "w").write(
    "KEY=%s\nPAYLOAD=%s\nSIG=%s\nPAYLEN=%d\n"
    % (key.hex().upper(), payload.hex().upper(), sig.hex().upper(),
       len(payload)))
print("OTA plant: key=%s paylen=%d" % (key.hex().upper(), len(payload)))
PY
fi

typekeys() {
  python3 -c "
import sys
out=[]
for c in sys.argv[1]:
    out.append({' ':'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"
}

# QMP abs (0..32767) → virtio-tablet → MOUSE ABS. No relative warp.
prove_abs_input() {
  local port="$1" ser="$2" gw="$3" gh="$4"
  python3 - "$port" "$ser" "$gw" "$gh" <<'PY'
import json, socket, sys, time, re

port, ser = int(sys.argv[1]), sys.argv[2]
gw, gh = int(sys.argv[3]), int(sys.argv[4])
chrome_h = 48
# Hamburger on the left glass island (LEFT_X + HAM_OFF + 18).
tx = 262
ty = gh - chrome_h + 20
# QEMU input-send-event abs is 0..32767 (tablet logical max).
abs_x = tx * 32767 // max(1, gw - 1)
abs_y = ty * 32767 // max(1, gh - 1)

def send_once(events):
    last = None
    for attempt in range(10):
        s = None
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=3)
            s.settimeout(8)
            f = s.makefile("rw", encoding="utf-8")
            json.loads(f.readline())
            f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
            json.loads(f.readline())
            f.write(json.dumps({"execute": "input-send-event",
                                "arguments": {"events": events}}) + "\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    raise OSError("closed")
                msg = json.loads(line)
                if "return" in msg or "error" in msg:
                    if "error" in msg:
                        raise OSError(str(msg["error"]))
                    return
        except (OSError, json.JSONDecodeError, ValueError) as e:
            last = e
            time.sleep(0.05 * (attempt + 1))
        finally:
            if s is not None:
                try:
                    s.close()
                except OSError:
                    pass
    raise OSError("send_once failed: %s" % last)

def last_abs():
    lines = [l for l in open(ser, encoding="latin-1") if "MOUSE ABS" in l]
    if not lines:
        return None
    m = re.search(r"X ([0-9A-Fa-f]+) Y ([0-9A-Fa-f]+)", lines[-1])
    if not m:
        return None
    return int(m.group(1), 16), int(m.group(2), 16)

def abs_ok(cx, cy):
    return abs(cx - tx) <= 2 and abs(cy - ty) <= 2

def place_abs(px, py):
    # Bare abs is silent on COM1 (virtab announces only on button edge).
    ax = px * 32767 // max(1, gw - 1)
    ay = py * 32767 // max(1, gh - 1)
    send_once([
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}},
    ])

before = open(ser, encoding="latin-1").read()
# Wake the tablet queue (de-desk does the same before classified clicks).
place_abs(8, 8)
time.sleep(0.12)
got = None
hit = False
for attempt in range(12):
    marked = open(ser, encoding="latin-1").read()
    n = marked.count("MOUSE ABS")
    # Coordinates and the edge are one tablet report. Splitting these into
    # separate QMP commands allowed a busy compositor to observe the press at
    # the previous position, and the old proof therefore retried around the
    # race instead of testing the input contract.
    send_once([
        {"type": "abs", "data": {"axis": "x", "value": abs_x}},
        {"type": "abs", "data": {"axis": "y", "value": abs_y}},
        {"type": "btn", "data": {"button": "left", "down": True}},
    ])
    deadline = time.time() + 1.8
    while time.time() < deadline:
        text = open(ser, encoding="latin-1").read()
        if text.count("MOUSE ABS") > n:
            got = last_abs()
            if got and abs_ok(got[0], got[1]):
                break
        time.sleep(0.04)
    if not got or not abs_ok(got[0], got[1]):
        send_once([
            {"type": "abs", "data": {"axis": "x", "value": abs_x}},
            {"type": "abs", "data": {"axis": "y", "value": abs_y}},
            {"type": "btn", "data": {"button": "left", "down": False}},
        ])
        time.sleep(0.08 * (attempt + 1))
        continue
    print("sit-in-view: INPUT abs pass  MOUSE ABS X %04X Y %04X (want %d,%d)" % (
        got[0], got[1], tx, ty))
    deadline = time.time() + 1.8
    while time.time() < deadline:
        text = open(ser, encoding="latin-1").read()
        if "WM DE START" in text[len(marked):]:
            print("sit-in-view: INPUT Start click pass  @ (%d,%d) WM DE START" % (tx, ty))
            hit = True
            break
        time.sleep(0.05)
    send_once([
        {"type": "abs", "data": {"axis": "x", "value": abs_x}},
        {"type": "abs", "data": {"axis": "y", "value": abs_y}},
        {"type": "btn", "data": {"button": "left", "down": False}},
    ])
    if hit:
        break
    time.sleep(0.2)
if not got:
    raise SystemExit("no MOUSE ABS after QMP abs+click")
cx, cy = got
if not abs_ok(cx, cy):
    raise SystemExit("MOUSE ABS at (%d,%d) want Start center (%d,%d)" % (cx, cy, tx, ty))
if not hit:
    raise SystemExit("Start click @ (%d,%d) produced no WM DE START (cursor %s)" % (tx, ty, got))
PY
}

# Host TCP listener + QMP `ota get <port>` on the live abs door (ADR-0151/0199).
prove_abs_ota() {
  local qmp_port="$1" ser="$2" out_dir="$3"
  local blob="$out_dir/ota-blob.bin"
  local meta="$out_dir/ota-meta.txt"
  local portfile="$out_dir/ota-listen.port"
  local logfile="$out_dir/ota-listen.log"
  [[ -s "$blob" ]] || fail "no ota-blob.bin — OTA plant missing"
  [[ -s "$meta" ]] || fail "no ota-meta.txt"
  local paylen
  paylen=$(awk -F= '/^PAYLEN=/{print $2; exit}' "$meta")
  local paylen_hex
  paylen_hex=$(printf '%04X' "$paylen")
  rm -f "$portfile"
  : >"$logfile"
  python3 - "$blob" "$portfile" "$logfile" "$PICKER" <<'PY' &
import socket, sys, subprocess, time
blob_path, portfile, logfile, picker = sys.argv[1:5]
port = int(subprocess.check_output(["python3", picker], text=True).strip())
blob = open(blob_path, "rb").read()
log = open(logfile, "w")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
srv.settimeout(1.0)
open(portfile, "w").write(str(port))
log.write("LISTEN %d bytes=%d\n" % (port, len(blob)))
log.flush()
deadline = time.time() + 90.0
while time.time() < deadline:
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        continue
    except Exception as e:
        log.write("ACCEPT-ERR %s\n" % e)
        break
    log.write("ACCEPT %s\n" % (addr,))
    log.flush()
    try:
        conn.sendall(blob)
        conn.shutdown(socket.SHUT_WR)
        time.sleep(0.05)
    except Exception as e:
        log.write("SEND-ERR %s\n" % e)
    finally:
        conn.close()
        log.write("SENT\n")
        log.flush()
srv.close()
log.close()
PY
  local listen_pid=$!
  local i=0
  while [[ ! -s "$portfile" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$portfile" ]] || { kill "$listen_pid" 2>/dev/null || true; fail "OTA listener did not publish a port"; }
  local ota_port
  ota_port=$(tr -d '[:space:]' < "$portfile")
  echo "$ota_port" >"$out_dir/ota.hostport"
  say "OTA host listener 127.0.0.1:${ota_port} (SLIRP 10.0.2.2:${ota_port})"
  # Type `ota get <port>` via QMP qcodes (session already up — no wait-for).
  python3 - "$qmp_port" "$ota_port" <<'PY' || fail "QMP ota get typing failed"
import json, socket, sys, time
port, ota = int(sys.argv[1]), sys.argv[2]
cmd = "ota get " + ota

def connect():
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(8)
    f = s.makefile("rw", encoding="utf-8")
    json.loads(f.readline())
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
    json.loads(f.readline())
    return s, f

def send_key(f, qcode, down):
    f.write(json.dumps({
        "execute": "input-send-event",
        "arguments": {"events": [{
            "type": "key",
            "data": {"key": {"type": "qcode", "data": qcode}, "down": down},
        }]},
    }) + "\n")
    f.flush()
    line = f.readline()
    if not line:
        raise OSError("qmp closed")
    msg = json.loads(line)
    if "error" in msg:
        raise OSError(str(msg["error"]))

def qcode_for(c):
    if c == " ":
        return "spc"
    if c == ".":
        return "dot"
    if c == "-":
        return "minus"
    if c.isdigit() or c.isalpha():
        return c.lower()
    raise SystemExit("unsupported char %r" % c)

s, f = connect()
for c in cmd:
    q = qcode_for(c)
    send_key(f, q, True)
    send_key(f, q, False)
    time.sleep(0.03)
send_key(f, "ret", True)
send_key(f, "ret", False)
s.close()
time.sleep(10)
PY
  kill "$listen_pid" 2>/dev/null || true
  wait "$listen_pid" 2>/dev/null || true
  if ! tr -d '\000' < "$ser" | grep -q "OTA OK $paylen_hex"; then
    echo "--- ota listen ---" >&2
    cat "$logfile" >&2 || true
    echo "--- serial tail ---" >&2
    tr -d '\000' < "$ser" | tail -60 >&2
    fail "live abs OTA did not print OTA OK $paylen_hex"
  fi
  say "OTA OK $paylen_hex (live abs door)"
  echo "OTA OK $paylen_hex" >"$out_dir/ota.ok"
  echo "$ota_port" >"$CORE_DIR/build/sit-in-abs-ota.port"
  # Leave a ready-to-re-serve blob path for the owner.
  say "owner OTA: python3 -c \"import socket;b=open('$blob','rb').read();s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',$ota_port));s.listen(1);c,_=s.accept();c.sendall(b);c.close()\" &"
  say "owner OTA: then type  ota get $ota_port  in the OS shell (or re-run prove)"
}

# Cocoa zoom-to-fit scales the guest FB to the Mac window. Without it,
# 800×600 (or Venus ~640×480 under gtk) reads as a postage stamp on Retina.
DISPLAY_ARG="-display cocoa,zoom-to-fit=on"
if [[ -n "${SITIN_DISPLAY:-}" ]]; then
  DISPLAY_ARG="-display $SITIN_DISPLAY"
elif ! qemu-system-x86_64 -display help 2>&1 | grep -q cocoa; then
  DISPLAY_ARG="-display none"
fi
if [[ "$ABS_DOOR" == 1 && "$DISPLAY_ARG" == "-display cocoa"* &&
      "$DISPLAY_ARG" != *"show-cursor="* ]]; then
  # The compositor already paints the Skia guest sprite. Hiding Cocoa's host
  # cursor leaves one authority on the absolute tablet path instead of two
  # arrows that separate while the window is scaled.
  DISPLAY_ARG="${DISPLAY_ARG},show-cursor=off"
fi

# Abs door: SLIRP user-net + e1000 (same as ota-host/). Pointer-only abs
# previously omitted NIC on purpose; live OTA needs 10.0.2.2 (ADR-0199).
NET_ARGS=()
if [[ "$ABS_DOOR" == 1 ]]; then
  NET_ARGS=(
    -net none
    -netdev user,id=n0,net=10.0.2.0/24
    -device e1000,netdev=n0,mac=52:54:00:0A:14:49,romfile=
  )
fi

_daemon_qemu() {
  python3 - "$PIDFILE" "$RUN_DIR/qemu.log" "$@" <<'PY'
import os, sys
pidfile, logfile = sys.argv[1], sys.argv[2]
argv = sys.argv[3:]
r, w = os.pipe()
pid = os.fork()
if pid > 0:
    os.close(w)
    data = b""
    while b"\n" not in data:
        chunk = os.read(r, 32)
        if not chunk:
            break
        data += chunk
    os.close(r)
    os.waitpid(pid, 0)
    sys.exit(0 if data.strip() else 1)
os.close(r)
os.setsid()
if os.fork() > 0:
    os._exit(0)
devnull = os.open(os.devnull, os.O_RDWR)
logfd = os.open(logfile, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.dup2(devnull, 0)
os.dup2(logfd, 1)
os.dup2(logfd, 2)
if devnull > 2:
    os.close(devnull)
if logfd > 2:
    os.close(logfd)
open(pidfile, "w").write("%d\n" % os.getpid())
os.write(w, b"%d\n" % os.getpid())
os.close(w)
os.execvp(argv[0], argv)
PY
}

write_view_png() {
  # args: serial png mode
  python3 - "$1" "$2" "$3" "$RUN_DIR" <<'PY'
import os, re, struct, sys, zlib, json, socket, time

serial, png, mode, run_dir = sys.argv[1:5]
text = open(serial, "r", encoding="latin-1").read()

def write_png(path, width, height, pitch, bgra):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        off = y * pitch
        row = bgra[off:off + width * 4]
        if len(row) < width * 4:
            raise SystemExit("pitch shorter than width")
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

width = height = pitch = addr = None
m = re.search(r"^VIEW MODE (\d+)x(\d+)\s*$", text, re.M)
# VIRTIO MODE outranks VIRTIO SCAN: the driver picks the scanout mode and
# SET_SCANOUT's rect resizes the host console, while SCAN is only the
# device's GET_DISPLAY_INFO readback (GAP-0328).
mode = re.search(
    r"^VIRTIO MODE ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)", text, re.M)
scan = re.search(
    r"^VIRTIO SCAN [0-9A-Fa-f]+ [0-9A-Fa-f]+ ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)",
    text, re.M)
gop = re.search(
    r"^FB GOP ([0-9A-Fa-f]+)x([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)",
    text, re.M)
base = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
back = re.search(r"^VIRTIO BACK ([0-9A-Fa-f]+)", text, re.M)

if mode:
    width = int(mode.group(1), 16)
    height = int(mode.group(2), 16)
elif scan:
    width = int(scan.group(1), 16)
    height = int(scan.group(2), 16)
elif gop:
    width = int(gop.group(1), 16)
    height = int(gop.group(2), 16)
    pitch = int(gop.group(3), 16)
    addr = int(gop.group(4), 16)
elif m:
    width = int(m.group(1))
    height = int(m.group(2))

if base:
    addr = int(base.group(1), 16)
    pitch = int(base.group(2), 16)
    if width is None and pitch:
        # Bochs sit-in: pitch/4 × 600
        width = pitch // 4
        height = 600
elif back and addr is None:
    # Venus virtgpuk scanout before / without WM ON BASE line.
    addr = int(back.group(1), 16)
if width is None or height is None:
    raise SystemExit("no VIEW MODE / SCAN / GOP / WM ON geometry")
if pitch is None:
    pitch = width * 4
if addr is None:
    raise SystemExit("no framebuffer address")

print("sit-in-view: geometry %dx%d pitch %d @ 0x%X" % (width, height, pitch, addr))
# pmemsave path must be visible to QEMU. Local: host path. Venus: /work/...
raw_host = os.path.join(run_dir, "view-fb.bin")
raw_qemu = raw_host
venus_dir = os.path.join(os.path.dirname(run_dir), "sit-in-view-venus")
if os.path.isdir(venus_dir) and os.path.samefile(
        os.path.dirname(os.path.abspath(serial)), venus_dir):
    # Side file: do not truncate view-fb.bin (x11vnc -rawfb mmaps it).
    raw_host = os.path.join(venus_dir, "view-fb-dump.bin")
    raw_qemu = "/work/view-fb-dump.bin"
port_path = os.path.join(run_dir, "qmp.port")
# Only steal Venus QMP when THIS dump's serial lives in the Venus dir.
# A leftover sit-in-view-venus/qmp.port must not hijack the cocoa door.
if os.path.isdir(venus_dir) and os.path.isfile(os.path.join(venus_dir, "qmp.port")):
    if os.path.isdir(venus_dir) and os.path.samefile(
            os.path.dirname(os.path.abspath(serial)), venus_dir):
        port_path = os.path.join(venus_dir, "qmp.port")
# Venus: fb-refresh holds the primary QMP. Prefer the input QMP for the
# one-shot host pmemsave so the two do not serialize/refuse each other.
# A leftover sit-in-view/qmp-input.port must not steal the cocoa door's QMP.
if os.path.isdir(venus_dir) and os.path.samefile(
        os.path.dirname(os.path.abspath(serial)), venus_dir):
    port_in_path = os.path.join(os.path.dirname(port_path), "qmp-input.port")
    if os.path.isfile(port_in_path):
        port_path = port_in_path
if not os.path.isfile(port_path):
    raise SystemExit("no qmp.port")
port = int(open(port_path).read().strip())

def qmp_read(f):
    while True:
        line = f.readline()
        if not line:
            raise OSError("QMP closed")
        msg = json.loads(line)
        if "return" in msg or "error" in msg:
            return msg

deadline = time.time() + 30
last = None
while time.time() < deadline:
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        f = s.makefile("rw", encoding="utf-8")
        json.loads(f.readline())
        f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
        f.flush()
        qmp_read(f)
        f.write(json.dumps({
            "execute": "pmemsave",
            "arguments": {
                "val": addr,
                "size": height * pitch,
                "filename": raw_qemu,
            },
        }) + "\n")
        f.flush()
        msg = qmp_read(f)
        if "error" in msg:
            raise SystemExit("pmemsave: %s" % msg["error"])
        break
    except (OSError, json.JSONDecodeError) as e:
        last = e
        time.sleep(0.5)
else:
    raise SystemExit("qmp: %s" % last)

data = open(raw_host, "rb").read()
if len(data) < height * pitch:
    raise SystemExit("pmemsave short (%d < %d)" % (len(data), height * pitch))
write_png(png, width, height, pitch, data)
print("sit-in-view: wrote %s (%dx%d)" % (png, width, height))
# Append VIEW MODE if the shell did not print it (local path stamps via this).
open(serial, "a", encoding="latin-1").write("VIEW MODE %dx%d\n" % (width, height))
print("VIEW MODE %dx%d" % (width, height))
PY
}

# ---------------------------------------------------------------------------
# Venus Graphite path (Docker oscortex-qemu-gl + virtio-gpu-gl,venus=on)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "venus" ]]; then
  command -v docker >/dev/null 2>&1 || fail "docker not found"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    say "building $IMAGE"
    bash "$CORE_DIR/scripts/build-qemu-gl.sh" || fail "build-qemu-gl.sh failed"
  fi
  mkdir -p "$VENUS_DIR"
  # Sibling agents share this script and used to docker-rm the live door
  # mid-qmp-drive. DOOR_LOCK blocks new script instances; boot under a
  # temporary name so old-script `docker rm -f oscortex-interactive-door`
  # cannot race-kill QMP before INPUT is proven.
  if [[ -f "$VENUS_DIR/DOOR_LOCK" ]]; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Eqx 'oscortex-interactive-door(-boot-[0-9]+)?'; then
      fail "interactive door is locked live (see $VENUS_DIR/DOOR_LOCK). Run --kill if intentional."
    fi
    rm -f "$VENUS_DIR/DOOR_LOCK"
  fi
  cp "$KERNEL_ELF" "$VENUS_DIR/kernel.elf" || fail "copy kernel"
  cp "$RUN_DIR/disk.img" "$VENUS_DIR/disk.img" || fail "copy disk"
  SER="$CORE_DIR/build/sit-in-view-venus-serial.txt"
  PNG="$CORE_DIR/build/sit-in-view-venus.png"
  : >"$SER"
  PORT=$(python3 "$PICKER") || fail "no free QMP port"
  PORT_IN=$(python3 "$PICKER") || fail "no free input QMP port"
  echo "$PORT" >"$VENUS_DIR/qmp.port"
  echo "$PORT_IN" >"$VENUS_DIR/qmp-input.port"
  echo "$PORT" >"$RUN_DIR/qmp.port"
  echo "$PORT_IN" >"$RUN_DIR/qmp-input.port"
  DOOR_BOOT="oscortex-interactive-door-boot-$$"
  DOOR_NAME="oscortex-interactive-door"

  say "booting Venus Graphite (${VIEW_W}x${VIEW_H}, sdl,gl + guest-FB x11vnc :${VNC_PORT} + QMP input)"
  # gtk,gl shrinks GET_DISPLAY_INFO to ~640×480 under Xvfb. sdl,gl keeps
  # xres/yres (measured 1280×720) and arms Venus GL. QEMU -full-screen
  # collapses SCAN to 640×480 — do not use it. xdotool windowsize blanks
  # the SDL GL paint — do not use it for the look path.
  #
  # SDL on Xvfb still paints only a ~640×480 cell (window chrome may be
  # 1280×720 with black letterbox). Clipping that cell and -scale'ing it
  # crops the desk — the owner complaint. Fix: x11vnc -rawfb of the guest
  # SCAN buffer (same pixels as pmemsave / sit-in-view-venus.png) at
  # VIEW_W×VIEW_H. No -clip 640x480. No stretch-to-Mac-points. Tiger
  # FullScreen letterboxes 16:9. QEMU -vnc cannot share a GL context.
  #
  # Input: -rawfb discards pointer/keyboard by default. -pipeinput feeds
  # sit-in-view-input-bridge.py → QMP input-send-event on a *second* QMP
  # socket (PORT_IN). PORT stays for qmp-drive + fb-refresh. Guest mouse
  # is PS/2 8042 — no usb-tablet (kernel has no tablet HID path yet).
  docker rm -f "$DOOR_BOOT" 2>/dev/null || true
  echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ) $DOOR_BOOT" >"$VENUS_DIR/DOOR_LOCK"
  cp "$CORE_DIR/scripts/sit-in-view-fb-refresh.py" "$VENUS_DIR/fb-refresh.py" \
    || fail "copy fb-refresh.py"
  cp "$CORE_DIR/scripts/sit-in-view-input-bridge.py" "$VENUS_DIR/input-bridge.py" \
    || fail "copy input-bridge.py"
  chmod +x "$VENUS_DIR/input-bridge.py" "$VENUS_DIR/fb-refresh.py" 2>/dev/null || true
  # Seed a zeroed FB so -rawfb can bind before the first pmemsave.
  python3 -c "open(r'$VENUS_DIR/view-fb.bin','wb').write(b'\\0'*($VIEW_W*$VIEW_H*4))"
  rm -f "$VENUS_DIR/keys-done" "$VENUS_DIR/input.ok"
  : >"$VENUS_DIR/serial.txt"
  docker run -d --name "$DOOR_BOOT" \
    -v "$VENUS_DIR/kernel.elf:/kernel.elf:ro" \
    -v "$VENUS_DIR:/work" \
    -p "127.0.0.1:${PORT}:${PORT}" \
    -p "127.0.0.1:${PORT_IN}:${PORT_IN}" \
    -p "127.0.0.1:${VNC_PORT}:5900" \
    -e LIBGL_ALWAYS_SOFTWARE=1 \
    -e GALLIUM_DRIVER=llvmpipe \
    -e VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
    -e SDL_VIDEODRIVER=x11 \
    -e SDL_VIDEO_WINDOW_POS=0,0 \
    -e SDL_VIDEO_HIGHDPI_DISABLED=1 \
    "$IMAGE" \
    bash -c "set -e
      if ! command -v x11vnc >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq x11vnc
      fi
      if ! command -v xdotool >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xdotool
      fi
      # Geometry MUST equal guest SCAN (VIEW_W×VIEW_H). Do not enlarge Xvfb.
      Xvfb :99 -screen 0 ${VIEW_W}x${VIEW_H}x24 -dpi 96 -nolisten tcp &
      for i in \$(seq 1 50); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
      export DISPLAY=:99
      export SDL_VIDEODRIVER=x11
      export SDL_VIDEO_WINDOW_POS=0,0
      export SDL_VIDEO_HIGHDPI_DISABLED=1
      # Do not exec: replacing the shell SIGHUPs Xvfb/x11vnc and SDL then
      # exits QEMU (clean exit 0) before the PNG dump.
      qemu-system-x86_64 \
        -name oscortex-sit-in-view-venus \
        -kernel /kernel.elf -m 512M -cpu qemu64 -vga none \
        -device virtio-gpu-gl-pci,venus=on,blob=on,hostmem=256M,xres=${VIEW_W},yres=${VIEW_H} \
        -drive file=/work/disk.img,format=raw,if=ide,index=0,media=disk \
        -device virtio-tablet-pci \
        -display sdl,gl=on,window-close=off \
        -serial file:/work/serial.txt \
        -qmp tcp:0.0.0.0:${PORT},server,nowait \
        -qmp tcp:0.0.0.0:${PORT_IN},server,nowait \
        -no-reboot &
      QPID=\$!
      # Pin primary SDL to +0+0 (move only — windowsize blanks GL paint).
      wid=\"\"
      for i in \$(seq 1 100); do
        wid=\$(xdotool search --name 'oscortex-sit-in-view-venus-0' 2>/dev/null | head -1 || true)
        [ -z \"\$wid\" ] && wid=\$(xdotool search --name 'oscortex-sit-in-view-venus' 2>/dev/null | head -1 || true)
        [ -n \"\$wid\" ] && break
        sleep 0.1
      done
      if [ -n \"\$wid\" ]; then
        xdotool windowmove --sync \"\$wid\" 0 0 || true
        geom=\$(xdotool getwindowgeometry \"\$wid\" 2>/dev/null || true)
        echo \"sit-in-view: pinned SDL wid=\$wid to +0+0 (\$geom)\" >/work/sdl-pin.log
        for other in \$(xdotool search --name oscortex 2>/dev/null || true); do
          if [ \"\$other\" != \"\$wid\" ]; then
            xdotool windowminimize \"\$other\" 2>/dev/null \
              || xdotool windowmove \"\$other\" 4000 4000 2>/dev/null || true
          fi
        done
      else
        echo \"sit-in-view: WARN — no SDL window to pin\" >/work/sdl-pin.log
      fi
      # Full guest SCAN over VNC (display-only until keys-done).
      # Pipeinput AFTER keys-done so qmp-drive keeps exclusive PORT and the
      # bridge does not race boot.
      x11vnc -rawfb \"map:/work/view-fb.bin@${VIEW_W}x${VIEW_H}x32:ff0000/ff00/ff\" \
        -scale ${VNC_SCALE_W}x${VNC_SCALE_H} \
        -forever -shared -rfbport 5900 -nopw -ncache 0 \
        >/work/x11vnc.log 2>&1 &
      X11VNC_PID=\$!
      echo \"sit-in-view: x11vnc -rawfb ${VIEW_W}x${VIEW_H} -scale ${VNC_SCALE_W}x${VNC_SCALE_H} (pipeinput after keys-done)\" >>/work/sdl-pin.log
      # fb-refresh + pipeinput after drive releases PORT.
      for i in \$(seq 1 180); do
        [ -f /work/keys-done ] && break
        sleep 1
      done
      kill \$X11VNC_PID 2>/dev/null || true
      sleep 0.3
      x11vnc -rawfb \"map:/work/view-fb.bin@${VIEW_W}x${VIEW_H}x32:ff0000/ff00/ff\" \
        -scale ${VNC_SCALE_W}x${VNC_SCALE_H} \
        -forever -shared -rfbport 5900 -nopw -ncache 0 \
        -pipeinput \"reopen:python3 -u /work/input-bridge.py ${PORT_IN} ${VIEW_W} ${VIEW_H} ${VNC_SCALE_W} ${VNC_SCALE_H}\" \
        >/work/x11vnc.log 2>&1 &
      X11VNC_PID=\$!
      echo \"sit-in-view: x11vnc pipeinput→QMP :${PORT_IN} armed\" >>/work/sdl-pin.log
      python3 /work/fb-refresh.py \"\$QPID\" ${PORT} ${VIEW_W} ${VIEW_H} \
        >/work/fb-refresh.log 2>&1 &
      REFRESH_PID=\$!
      wait \$QPID
      status=\$?
      kill \$X11VNC_PID \$REFRESH_PID 2>/dev/null || true
      kill \$(jobs -p) 2>/dev/null || true
      exit \$status" \
    || fail "docker run failed"

  # serial is inside the container volume — do NOT truncate after QEMU
  # opens it (that punches a hole under the writer). Wait for M1 END.
  ln -sf "$VENUS_DIR/serial.txt" "$SER" 2>/dev/null || true

  for i in $(seq 1 60); do
    if grep -q 'M1 END' "$VENUS_DIR/serial.txt" 2>/dev/null; then
      say "M1 END at ${i}s"
      break
    fi
    sleep 1
  done
  grep -q 'M1 END' "$VENUS_DIR/serial.txt" || {
    docker logs "$DOOR_BOOT" 2>&1 | tail -40 >&2
    fail "Venus boot never reached M1 END"
  }

  # Wait until QMP accepts (docker port publish can lag M1 END).
  # Probe BOTH sockets — PORT_IN must be live before pipeinput/INPUT smoke,
  # or the bridge races a refused connect and the smoke sees a dead port.
  for i in $(seq 1 40); do
    if python3 - "$PORT" "$PORT_IN" <<'PY' 2>/dev/null
import json, socket, sys
for p in (int(sys.argv[1]), int(sys.argv[2])):
    s = socket.create_connection(("127.0.0.1", p), timeout=1)
    s.settimeout(2)
    f = s.makefile("rw", encoding="utf-8")
    json.loads(f.readline())
    f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
    json.loads(f.readline())
    s.close()
PY
    then
      say "QMP ready :${PORT}/:${PORT_IN} at +${i}s"
      # Settle so the probe's close is not raced by qmp-drive's open, and
      # docker-proxy has finished wiring both published ports.
      sleep 1.0
      break
    fi
    sleep 0.5
  done

  KEYS="$(typekeys 'virtgpuv'),ret,wait:8000"
  KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:22000"
  KEYS="$KEYS,$(typekeys 'virtgpuk'),ret,wait:16000"
  KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:2000"
  KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:1200"
  KEYS="$KEYS,$(typekeys 'vtab'),ret,wait:800"
  KEYS="$KEYS,$(typekeys 'proc spawn DESK.ELF'),ret,wait:1500"

  drive_rc=0
  python3 "$DRIVER" \
    --port "$PORT" --serial "$VENUS_DIR/serial.txt" --wait-for 'M1 END\n' \
    --png "$VENUS_DIR/driver.png" --screen-text "$VENUS_DIR/driver.txt" \
    --keys "$KEYS" --no-screendump --no-quit \
    || drive_rc=$?
  if [[ "$drive_rc" -ne 0 ]] && ! grep -q 'VIRTIO SCAN' "$VENUS_DIR/serial.txt" 2>/dev/null; then
    say "note: qmp-drive exited ${drive_rc}; retrying once after settle"
    sleep 1.5
    python3 "$DRIVER" \
      --port "$PORT" --serial "$VENUS_DIR/serial.txt" --wait-for 'M1 END\n' \
      --png "$VENUS_DIR/driver.png" --screen-text "$VENUS_DIR/driver.txt" \
      --keys "$KEYS" --no-screendump --no-quit \
      || say "note: qmp-drive retry exited $? (session may still be up)"
  elif [[ "$drive_rc" -ne 0 ]]; then
    say "note: qmp-drive exited ${drive_rc} (session may still be up)"
  fi
  : >"$VENUS_DIR/keys-done"

  grep -q 'VIRTIO VENUS OK' "$VENUS_DIR/serial.txt" \
    || fail "no VIRTIO VENUS OK — Graphite path not armed"
  grep -q 'VIRTIO SCAN' "$VENUS_DIR/serial.txt" \
    || fail "no VIRTIO SCAN"
  grep -q 'VIRTIO MODE' "$VENUS_DIR/serial.txt" \
    || fail "no VIRTIO MODE — the kernel predates the GAP-0328 mode floor"

  # Stamp VIEW MODE from the driver's chosen mode into serial AND a side
  # stamp file (QEMU also writes serial.txt — host appends can race; the
  # stamp file is harness-owned). VIRTIO MODE, not VIRTIO SCAN: SCAN is the
  # device's GET_DISPLAY_INFO readback and the UI frontend can pin it to a
  # 640x480 placeholder, which is GAP-0328. The mode the OS actually drove
  # SET_SCANOUT at is the one the framebuffer is sized for.
  python3 - "$VENUS_DIR/serial.txt" "$VIEW_W" "$VIEW_H" "$VENUS_DIR/view.mode" <<'PY'
import re, sys
ser, want_w, want_h, stamp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
text = open(ser, encoding="latin-1").read()
m = re.search(
    r"^VIRTIO MODE ([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)", text, re.M)
if not m:
    raise SystemExit("no MODE")
w, h, src = int(m.group(1), 16), int(m.group(2), 16), int(m.group(3), 16)
line = "VIEW MODE %dx%d\n" % (w, h)
open(ser, "a").write(line)
open(stamp, "w").write(line)
s = re.search(
    r"^VIRTIO SCAN [0-9A-Fa-f]+ [0-9A-Fa-f]+ ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)",
    text, re.M)
if s:
    print("sit-in-view: GET_DISPLAY_INFO hint %dx%d"
          % (int(s.group(1), 16), int(s.group(2), 16)))
print("sit-in-view: MODE %dx%d (%s; want >= %dx%d)"
      % (w, h, "driver floor" if src else "device pmode", want_w, want_h))
if w < want_w or h < want_h:
    print("sit-in-view: WARN — MODE below VIEW_W×VIEW_H")
else:
    print("sit-in-view: MODE meets %dx%d" % (want_w, want_h))
PY

  # Venus PNG: host pmemsave on PORT_IN (fb-refresh owns PORT). Fall back to
  # waiting for view-fb.bin if the one-shot dump flaps.
  if ! write_view_png "$VENUS_DIR/serial.txt" "$PNG" venus; then
    say "WARN — pmemsave PNG failed; waiting for view-fb.bin"
    python3 - "$VENUS_DIR/view-fb.bin" "$PNG" "$VIEW_W" "$VIEW_H" <<'PY' \
      || fail "PNG dump failed"
import struct, sys, time, zlib
raw_path, png, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
pitch = w * 4
need = h * pitch
deadline = time.time() + 45
data = b""
while time.time() < deadline:
    try:
        data = open(raw_path, "rb").read()
    except OSError:
        data = b""
    if len(data) >= need and data[:4096] != b"\0" * 4096:
        break
    time.sleep(0.4)
else:
    raise SystemExit("view-fb not ready")
raw = bytearray()
for y in range(h):
    raw.append(0)
    off = y * pitch
    for x in range(w):
        b, g, r = data[off + x * 4], data[off + x * 4 + 1], data[off + x * 4 + 2]
        raw.extend((r, g, b))
def chunk(tag, body):
    crc = zlib.crc32(tag + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", crc)
ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
open(png, "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", ihdr)
    + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    + chunk(b"IEND", b"")
)
print("sit-in-view: wrote %s from view-fb.bin (%dx%d)" % (png, w, h))
print("VIEW MODE %dx%d" % (w, h))
PY
  fi
  python3 - "$VENUS_DIR/serial.txt" <<'PY' || true
import re, sys
text = open(sys.argv[1], encoding="latin-1").read()
base = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
back = re.search(r"^VIRTIO BACK ([0-9A-Fa-f]+)", text, re.M)
scan = re.search(
    r"^VIRTIO MODE ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)", text, re.M)
if scan and (base or back):
    w, h = int(scan.group(1), 16), int(scan.group(2), 16)
    if base:
        addr, pitch = int(base.group(1), 16), int(base.group(2), 16)
    else:
        addr, pitch = int(back.group(1), 16), w * 4
    print("sit-in-view: geometry %dx%d pitch %d @ 0x%X" % (w, h, pitch, addr))
PY
  cp "$PNG" "$CORE_DIR/build/sit-in-graphite.png" 2>/dev/null || true
  cp "$PNG" "$CORE_DIR/build/tigervnc-live-now.png" 2>/dev/null || true

  # Presence: Start tile + titled window + close affordance (not empty green desk).
  # Probe the pmemsave PNG (same pixels as guest SCAN), not view-fb.bin —
  # the rawfb mmap can still be zeroed when fb-refresh has not caught up.
  python3 - "$PNG" "$VIEW_W" "$VIEW_H" <<'PY' || fail "DE presence probes failed"
import struct, sys, zlib

path, want_w, want_h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
data = open(path, "rb").read()
if data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit("not a PNG")
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
if w != want_w or h != want_h:
    raise SystemExit("PNG %dx%d != %dx%d" % (w, h, want_w, want_h))
img = zlib.decompress(raw)
row = w * 3 + 1

def pix(x, y):
    off = y * row + 1 + x * 3
    r, g, b = img[off], img[off + 1], img[off + 2]
    return (r << 16) | (g << 8) | b

chrome_h = 48
bar_y = h - chrome_h
dock_y = bar_y + 4 + 20  # ISLAND_Y + mid-row within panel
# Sample frosted fill, not clock/hamburger glyphs (HAM_OFF ≈ x244).
samples = [pix(x, y) for y in (bar_y + 4 + 12, bar_y + 4 + 28)
           for x in (56, 160, 200, 240) if x < w]
for ink in samples:
    r, g, b = (ink >> 16) & 255, (ink >> 8) & 255, ink & 255
    if ink == 0xC87840:
        raise SystemExit("left island is still copper Start")
    if r + g + b < 200:
        raise SystemExit("left island 0x%06X is not frosted glass" % ink)
if len(set(samples)) < 2:
    raise SystemExit("island pixels are one flat colour — no frost")
ink = samples[0]
gap = pix(min(w - 1, 400 if w >= 800 else w // 2), dock_y)
if gap == ink:
    raise SystemExit("gap matches island — dock is still a bar")
win = pix(min(w - 1, 54), min(h - 1, 46))
wr, wg, wb = (win >> 16) & 255, (win >> 8) & 255, win & 255
if wr > 200 and wg > 190 and wb >= 150 and win != gap:
    print("sit-in-view: WARN — (54,46)=0x%06X looks like a window on boot" % win)
print("sit-in-view: PRESENCE pass  glass %06X gap %06X empty-win %06X" % (ink, gap, win))
PY

  if [[ ! -e "$SER" ]]; then
    cp "$VENUS_DIR/serial.txt" "$SER" || true
  fi

  say "framebuffer PNG: $PNG  (guest FB — VNC -rawfb serves the same buffer)"
  say "serial:          $VENUS_DIR/serial.txt"
  say "VNC:             vnc://127.0.0.1:${VNC_PORT}  (rawfb ${VIEW_W}x${VIEW_H} → scale ${VNC_SCALE_W}x${VNC_SCALE_H})"
  say "input:           x11vnc -pipeinput → QMP :${PORT_IN} (PS/2 mouse+keys; not display-only)"
  say "Docker:          ${DOOR_BOOT} (booting; renames to ${DOOR_NAME} after INPUT)"
  say "kill:            sit-in-view.sh --kill"
  # Record what TigerVNC actually sees (scaled door size; content is full SCAN).
  python3 - "$VNC_PORT" "$VENUS_DIR/vnc.geometry" "$VNC_SCALE_W" "$VNC_SCALE_H" <<'PY' || true
import socket, struct, sys
port, path, want_w, want_h = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=3)
    s.settimeout(3)
    s.recv(12); s.sendall(b"RFB 003.008\n")
    nb = s.recv(1)
    if not nb:
        raise OSError("empty security-types length")
    n = nb[0]
    if n:
        s.recv(n)
    s.sendall(bytes([1])); s.recv(4)
    s.sendall(struct.pack(">B", 1))
    hdr = b""
    while len(hdr) < 24:
        chunk = s.recv(24 - len(hdr))
        if not chunk:
            raise OSError("short ServerInit")
        hdr += chunk
    w, h = struct.unpack(">HH", hdr[:4])
    open(path, "w").write("%dx%d\n" % (w, h))
    print("sit-in-view: VNC desktop %dx%d (want %dx%d)" % (w, h, want_w, want_h))
    s.close()
except (OSError, IndexError, struct.error) as e:
    print("sit-in-view: WARN — could not probe VNC geometry: %s" % e)
PY
  # Ensure rawfb VNC + input bridge are alive after PNG dump / late start.
  docker exec "$DOOR_BOOT" bash -c '
    if ! pgrep -x x11vnc >/dev/null || ! pgrep -f input-bridge.py >/dev/null; then
      pkill -x x11vnc 2>/dev/null || true
      sleep 0.3
      x11vnc -rawfb "map:/work/view-fb.bin@'"${VIEW_W}"'x'"${VIEW_H}"'x32:ff0000/ff00/ff" \
        -scale '"${VNC_SCALE_W}"'x'"${VNC_SCALE_H}"' \
        -forever -shared -rfbport 5900 -nopw -ncache 0 \
        -pipeinput "reopen:python3 -u /work/input-bridge.py '"${PORT_IN}"' '"${VIEW_W}"' '"${VIEW_H}"' '"${VNC_SCALE_W}"' '"${VNC_SCALE_H}"'" \
        >/work/x11vnc.log 2>&1 &
      echo sit-in-view: (re)started x11vnc -rawfb + pipeinput→'"${PORT_IN}"' >>/work/sdl-pin.log
    fi
    if ! pgrep -f fb-refresh.py >/dev/null; then
      QPID=$(pgrep -n qemu-system-x86_64 || true)
      if [ -n "$QPID" ]; then
        python3 /work/fb-refresh.py "$QPID" '"${PORT}"' '"${VIEW_W}"' '"${VIEW_H}"' \
          >/work/fb-refresh.log 2>&1 &
      fi
    fi
  ' 2>/dev/null || true
  sleep 1.5
  # ADR-0193: QMP abs → virtio-tablet. No relative warp.
  prove_abs_input "$PORT_IN" "$VENUS_DIR/serial.txt" "$VIEW_W" "$VIEW_H" \
    || fail "INPUT path failed (MOUSE ABS / Start click)"
  echo "INPUT OK" >"$VENUS_DIR/input.ok"
  # Publish the stable door name only after INPUT proves — foreign agents
  # that `docker rm -f oscortex-interactive-door` mid-boot can no longer
  # race-kill the QMP session.
  docker rm -f "$DOOR_NAME" 2>/dev/null || true
  docker rename "$DOOR_BOOT" "$DOOR_NAME" \
    || fail "could not rename $DOOR_BOOT → $DOOR_NAME"
  echo "$$ $(date -u +%Y-%m-%dT%H:%M:%SZ) $DOOR_NAME" >"$VENUS_DIR/DOOR_LOCK"
  say "Docker:          $DOOR_NAME (live; INPUT proved)"
  if [[ "$SITIN_TIGER" == 1 ]]; then
    launch_tiger_fullscreen "$VNC_PORT"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Local cocoa path (optional UEFI HD 1280×720)
# ---------------------------------------------------------------------------
PORT=$(python3 "$PICKER") || fail "no free QMP port"
echo "$PORT" >"$RUN_DIR/qmp.port"
SER="$CORE_DIR/build/sit-in-view-serial.txt"
PNG="$CORE_DIR/build/sit-in-view.png"
: >"$SER"

ISO=""
OVMF_CODE_FILE=""
OVMF_VARS_COPY="$RUN_DIR/OVMF_VARS.fd"
QEMU_NAME="oscortex-sit-in-view"
[[ "$ABS_DOOR" == 1 ]] && QEMU_NAME="oscortex-abs-pointer"
if [[ "$MODE" == "uefi-hd" ]]; then
  command -v xorriso >/dev/null 2>&1 || {
    if [[ "$ABS_DOOR" == 1 ]]; then MODE=local; else fail "xorriso not found"; fi
  }
  # Prefer Limine 12 even when PATH has Limine 8 (KERNEL_PATH panic).
  if ! eval "$(bash "$CORE_DIR/scripts/find-limine.sh")"; then
    if [[ "$ABS_DOOR" == 1 ]]; then MODE=local; else fail "limine not found"; fi
  fi
  export LIMINE LIMINE_DATADIR LIMINE_MAJOR
  export PATH="$(dirname "${LIMINE:-/usr/bin/limine}"):$PATH"
fi
if [[ "$MODE" == "uefi-hd" ]]; then
  find_ovmf_code() {
    local c
    for c in \
      "${OVMF_CODE:-}" "${OVMF:-}" \
      /opt/homebrew/share/qemu/edk2-x86_64-code.fd \
      /usr/local/share/qemu/edk2-x86_64-code.fd \
      /usr/share/OVMF/OVMF_CODE_4M.fd \
      /usr/share/OVMF/OVMF_CODE.fd
    do
      [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
  }
  find_ovmf_vars() {
    local c
    for c in \
      "${OVMF_VARS:-}" \
      /opt/homebrew/share/qemu/edk2-i386-vars.fd \
      /usr/local/share/qemu/edk2-i386-vars.fd \
      /usr/share/OVMF/OVMF_VARS_4M.fd \
      /usr/share/OVMF/OVMF_VARS.fd
    do
      [[ -n "$c" && -f "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
  }
  if ! OVMF_CODE_FILE="$(find_ovmf_code)"; then
    if [[ "$ABS_DOOR" == 1 ]]; then
      say "abs door: OVMF missing — Bochs 800×600 cocoa + tablet"
      MODE=local
    else
      fail "OVMF CODE not found"
    fi
  fi
  if [[ "$MODE" == "uefi-hd" ]]; then
    OVMF_VARS_FILE="$(find_ovmf_vars)" || fail "OVMF VARS not found"
  fi
fi
if [[ "$MODE" == "uefi-hd" ]]; then
  cp "$OVMF_VARS_FILE" "$OVMF_VARS_COPY" || fail "copy OVMF VARS"
  # View-only limine.conf — do not change boot-uefi/limine.conf (p2-gop 1024×768).
  cat >"$RUN_DIR/limine-view.conf" <<EOF
timeout: 0

/oscortex
    protocol: multiboot
    path: boot():/boot/kernel.elf
    KERNEL_PATH: boot():/boot/kernel.elf
    resolution: ${VIEW_W}x${VIEW_H}x32
EOF
  ISO="$RUN_DIR/view-uefi.iso"
  UEFI_KERNEL="$KERNEL_ELF"
  if [[ -f "$CORE_DIR/build/kernel-uefi.elf" ]]; then
    UEFI_KERNEL="$CORE_DIR/build/kernel-uefi.elf"
    say "UEFI kernel $UEFI_KERNEL (9MiB, avoids OVMF 8MiB hole)"
  fi
  say "building UEFI ISO (GOP ${VIEW_W}×${VIEW_H})"
  LIMINE_CONF="$RUN_DIR/limine-view.conf" \
    bash "$CORE_DIR/scripts/build-uefi-image.sh" "$UEFI_KERNEL" "$ISO" \
    || fail "build-uefi-image.sh failed"
fi

if [[ "$MODE" == "uefi-hd" ]]; then
  say "booting QEMU UEFI ($DISPLAY_ARG) — GOP ${VIEW_W}×${VIEW_H} + zoom-to-fit"
  _daemon_qemu qemu-system-x86_64 \
    -name "$QEMU_NAME" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE_FILE" \
    -drive "if=pflash,format=raw,file=$OVMF_VARS_COPY" \
    -cdrom "$ISO" \
    -m 512M -cpu qemu64 \
    -serial "file:$SER" \
    $DISPLAY_ARG \
    -device virtio-tablet-pci \
    "${NET_ARGS[@]}" \
    -no-reboot \
    -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$PORT,server,nowait"
else
  say "booting QEMU ($DISPLAY_ARG) — Bochs 800×600 + cocoa zoom-to-fit + tablet"
  [[ "$ABS_DOOR" == 1 ]] && say "abs net: user SLIRP + e1000 (10.0.2.2 host)"
  _daemon_qemu qemu-system-x86_64 \
    -name "$QEMU_NAME" \
    -kernel "$KERNEL_ELF" \
    -m 128M -cpu qemu64 -vga std \
    -serial "file:$SER" \
    $DISPLAY_ARG \
    -device virtio-tablet-pci \
    "${NET_ARGS[@]}" \
    -no-reboot \
    -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk" \
    -qmp "tcp:127.0.0.1:$PORT,server,nowait"
fi

QEMU_PID=$(cat "$PIDFILE")
sleep 1
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  if [[ "$ABS_DOOR" == 1 ]]; then
    say "cocoa failed — QEMU -vnc 127.0.0.1:${VNC_PORT} + virtio-tablet"
    DISPLAY_ARG="-vnc 127.0.0.1:$((VNC_PORT - 5900))"
  else
    say "cocoa failed, retrying headless for PNG"
    DISPLAY_ARG="-display none"
  fi
  if [[ "$MODE" == "uefi-hd" ]]; then
    _daemon_qemu qemu-system-x86_64 \
      -name "$QEMU_NAME" \
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE_FILE" \
      -drive "if=pflash,format=raw,file=$OVMF_VARS_COPY" \
      -cdrom "$ISO" -m 512M -cpu qemu64 \
      -serial "file:$SER" $DISPLAY_ARG -device virtio-tablet-pci \
      "${NET_ARGS[@]}" -no-reboot \
      -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk" \
      -qmp "tcp:127.0.0.1:$PORT,server,nowait"
  else
    _daemon_qemu qemu-system-x86_64 \
      -name "$QEMU_NAME" \
      -kernel "$KERNEL_ELF" -m 128M -cpu qemu64 -vga std \
      -serial "file:$SER" $DISPLAY_ARG -device virtio-tablet-pci \
      "${NET_ARGS[@]}" -no-reboot \
      -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk" \
      -qmp "tcp:127.0.0.1:$PORT,server,nowait"
  fi
  QEMU_PID=$(cat "$PIDFILE")
  sleep 1
  kill -0 "$QEMU_PID" 2>/dev/null || { cat "$RUN_DIR/qemu.log" >&2; fail "qemu died"; }
fi

WM_WAIT=2500
[[ "$MODE" == "uefi-hd" ]] && WM_WAIT=3500
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:$WM_WAIT"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:800"
KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:800"
KEYS="$KEYS,$(typekeys 'vtab'),ret,wait:600"
KEYS="$KEYS,$(typekeys 'proc spawn DESK.ELF'),ret,wait:3000"
KEYS="$KEYS,$(typekeys 'wm draw'),ret,wait:800"

# Abs live OTA (ADR-0199): run `ota get` while keyboard focus is still
# the shell (D9). prove_abs_input's Start click steals focus afterward.
ABS_OTA_LISTEN_PID=""
if [[ "$ABS_DOOR" == 1 && "${SITIN_ABS_OTA:-1}" != 0 ]]; then
  [[ -s "$RUN_DIR/ota-blob.bin" ]] || fail "no ota-blob.bin — OTA plant missing"
  [[ -s "$RUN_DIR/ota-meta.txt" ]] || fail "no ota-meta.txt"
  rm -f "$RUN_DIR/ota-listen.port"
  : >"$RUN_DIR/ota-listen.log"
  python3 - "$RUN_DIR/ota-blob.bin" "$RUN_DIR/ota-listen.port" \
    "$RUN_DIR/ota-listen.log" "$PICKER" <<'PY' &
import socket, sys, subprocess, time
blob_path, portfile, logfile, picker = sys.argv[1:5]
port = int(subprocess.check_output(["python3", picker], text=True).strip())
blob = open(blob_path, "rb").read()
log = open(logfile, "w")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
srv.settimeout(1.0)
open(portfile, "w").write(str(port))
log.write("LISTEN %d bytes=%d\n" % (port, len(blob)))
log.flush()
deadline = time.time() + 120.0
while time.time() < deadline:
    try:
        conn, addr = srv.accept()
    except socket.timeout:
        continue
    except Exception as e:
        log.write("ACCEPT-ERR %s\n" % e)
        break
    log.write("ACCEPT %s\n" % (addr,))
    log.flush()
    try:
        conn.sendall(blob)
        conn.shutdown(socket.SHUT_WR)
        time.sleep(0.05)
    except Exception as e:
        log.write("SEND-ERR %s\n" % e)
    finally:
        conn.close()
        log.write("SENT\n")
        log.flush()
srv.close()
log.close()
PY
  ABS_OTA_LISTEN_PID=$!
  i=0
  while [[ ! -s "$RUN_DIR/ota-listen.port" && $i -lt 50 ]]; do
    sleep 0.1
    i=$((i + 1))
  done
  [[ -s "$RUN_DIR/ota-listen.port" ]] \
    || { kill "$ABS_OTA_LISTEN_PID" 2>/dev/null || true; fail "OTA listener did not publish a port"; }
  ABS_OTA_PORT=$(tr -d '[:space:]' < "$RUN_DIR/ota-listen.port")
  echo "$ABS_OTA_PORT" >"$RUN_DIR/ota.hostport"
  say "OTA host listener 127.0.0.1:${ABS_OTA_PORT} (SLIRP 10.0.2.2:${ABS_OTA_PORT})"
  KEYS="$KEYS,$(typekeys "ota get $ABS_OTA_PORT"),ret,wait:10000"
fi

drive_rc=0
python3 "$DRIVER" \
  --port "$PORT" --serial "$SER" --wait-for 'M1 END\n' \
  --png "$RUN_DIR/driver.png" --screen-text "$RUN_DIR/driver.txt" \
  --keys "$KEYS" --no-screendump --no-quit \
  || drive_rc=$?
if [[ -n "$ABS_OTA_LISTEN_PID" ]]; then
  kill "$ABS_OTA_LISTEN_PID" 2>/dev/null || true
  wait "$ABS_OTA_LISTEN_PID" 2>/dev/null || true
fi
if [[ "$drive_rc" -ne 0 ]]; then
  if grep -q 'WM DE ON' "$SER" 2>/dev/null; then
    say "note: qmp-drive exited ${drive_rc} (session is up; IRQ0/tablet may keep serial busy)"
  else
    fail "could not drive the session"
  fi
fi

if [[ "$ABS_DOOR" == 1 && "${SITIN_ABS_OTA:-1}" != 0 ]]; then
  PAYLEN=$(awk -F= '/^PAYLEN=/{print $2; exit}' "$RUN_DIR/ota-meta.txt")
  PAYLEN_HEX=$(printf '%04X' "$PAYLEN")
  if ! tr -d '\000' < "$SER" | grep -q "OTA OK $PAYLEN_HEX"; then
    echo "--- ota listen ---" >&2
    cat "$RUN_DIR/ota-listen.log" >&2 || true
    echo "--- serial tail ---" >&2
    tr -d '\000' < "$SER" | tail -60 >&2
    fail "live abs OTA did not print OTA OK $PAYLEN_HEX"
  fi
  say "OTA OK $PAYLEN_HEX (live abs door)"
  echo "OTA OK $PAYLEN_HEX" >"$RUN_DIR/ota.ok"
  echo "$ABS_OTA_PORT" >"$CORE_DIR/build/sit-in-abs-ota.port"
fi

write_view_png "$SER" "$PNG" "$MODE" || fail "PNG dump failed"
cp "$PNG" "$CORE_DIR/build/tigervnc-live-now.png" 2>/dev/null || true

ABS_W=800
ABS_H=600
if [[ "$MODE" == "uefi-hd" ]]; then
  ABS_W="$VIEW_W"
  ABS_H="$VIEW_H"
fi
prove_abs_input "$PORT" "$SER" "$ABS_W" "$ABS_H" \
  || fail "INPUT path failed (MOUSE ABS / Start click)"

# After Start, focus is on DE — clear it with a desktop click so the
# owner can still type shell commands; desk Start already proved clickable.
if [[ "$ABS_DOOR" == 1 ]]; then
  python3 - "$PORT" "$ABS_W" "$ABS_H" <<'PY' || true
import json, socket, sys, time
port, gw, gh = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
tx, ty = gw // 2, gh // 2
ax = tx * 32767 // max(1, gw - 1)
ay = ty * 32767 // max(1, gh - 1)
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(8)
f = s.makefile("rw", encoding="utf-8")
json.loads(f.readline())
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush()
json.loads(f.readline())
def send(events):
    f.write(json.dumps({"execute": "input-send-event",
                        "arguments": {"events": events}}) + "\n")
    f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg:
            return
send([{"type": "abs", "data": {"axis": "x", "value": ax}},
      {"type": "abs", "data": {"axis": "y", "value": ay}}])
time.sleep(0.08)
send([{"type": "btn", "data": {"button": "left", "down": True}}])
time.sleep(0.04)
send([{"type": "btn", "data": {"button": "left", "down": False}}])
s.close()
PY
fi

say "framebuffer PNG: $PNG"
say "serial:          $SER"
if [[ "$DISPLAY_ARG" == -vnc* ]]; then
  say "door:             QEMU -vnc 127.0.0.1:${VNC_PORT} + virtio-tablet (absolute)"
  say "click:            vnc://127.0.0.1:${VNC_PORT}  (QEMU VNC, not x11vnc-rawfb)"
  if [[ "$ABS_DOOR" == 1 && "$SITIN_TIGER" == 1 ]]; then
    launch_tiger_fullscreen "$VNC_PORT"
  fi
elif [[ "$MODE" == "uefi-hd" ]]; then
  say "door:             QEMU cocoa window '${QEMU_NAME}' — GOP ${VIEW_W}×${VIEW_H} + virtio-tablet"
  say "click:            the QEMU window (one cursor; tablet is absolute)"
else
  say "door:             QEMU cocoa window '${QEMU_NAME}' — Bochs 800×600 + virtio-tablet"
  say "click:            the QEMU window (one cursor; tablet is absolute)"
fi
if [[ "$ABS_DOOR" == 1 ]]; then
  say "net:              -net none -netdev user,id=n0,net=10.0.2.0/24 -device e1000,netdev=n0,..."
  say "OTA FAT:          OTAKEY + SLOT.TXT planted; blob $RUN_DIR/ota-blob.bin"
  if [[ -f "$RUN_DIR/ota.hostport" ]]; then
    say "OTA last port:    $(tr -d '[:space:]' < "$RUN_DIR/ota.hostport") (host 127.0.0.1 / OS 10.0.2.2)"
  fi
  say "OTA trigger:      serve ota-blob.bin on a host port; type  ota get <port>  (shell focus: click empty desk first)"
fi
say "QEMU pid $QEMU_PID"
say "kill:            sit-in-view.sh --kill-all   # abs door; --kill leaves abs up"
exit 0
