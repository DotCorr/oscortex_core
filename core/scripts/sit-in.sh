#!/usr/bin/env bash
# core/scripts/sit-in.sh
#
# Boots THIS working tree in a QEMU window you can look at. Turns the
# compositor on, types `wm de`, and SPAWNS from a FAT volume (ADR-0108 /
# ADR-0197): DESK.ELF only — wallpaper + split glass dock. No FILES/SET
# auto-spawn. The disk is FAT16
# 8.3 names, not OSCXPRG1 LBA. Start caches the first four ELF names
# (FILES SET PING STUDIO); the volume also plants BROWSE PLAY TAP (+
# APP1). The windows outlive `proc spawn` because the clients attach,
# paint once, and stay alive (spin + yield). A cooperative two-program
# session that then exits REAPs the surfaces (GAP-0306).
#
# A PNG of the framebuffer is written to core/build/sit-in.png so the
# screen is visible even if a cocoa window cannot open.
#
#   sit-in.sh                 start / replace the session (Multiboot + Bochs)
#   sit-in.sh --uefi          OVMF + Limine ISO, GOP 1024×768 wins
#   sit-in.sh --bios          SeaBIOS + the same Limine hybrid ISO (no OVMF)
#   sit-in.sh --kill          stop it
#   SITIN_SKIP_BUILD=1        reuse core/build/kernel.elf (dirty-tree escape)
#   SITIN_DISPLAY=none|cocoa|cocoa,zoom-to-fit=on
#                             override the display probe (default zooms)
#   SITIN_UEFI=1              same as --uefi
#   SITIN_BIOS=1              same as --bios
#   SITIN_FRAME2=1            spawn SURF.ELF (FRAME2) instead of FILES.ELF.
#                             Same FAT volume; Start still lists names.
#
# Not a conformance harness. Asserts nothing on the Multiboot path. The
# prompt comes back after each spawn (D3 lone quantum). Two READY
# residents then schedule among themselves; further typed commands wait
# until a slot is not READY. The UEFI path probes one derived desktop
# pixel outside the compiled-in 800×600 so a Bochs-sized compose cannot
# satisfy the GOP dump.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
RUN_DIR="$CORE_DIR/build/sit-in"
PIDFILE="$RUN_DIR/qemu.pid"
SITFAT="$CORE_DIR/tests/conformance/de-sitfat"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"

say() { printf 'sit-in: %s\n' "$*"; }
fail() { printf 'sit-in: FAIL — %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "--kill" ]]; then
  if [[ -f "$PIDFILE" ]]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  pkill -f 'oscortex-sit-in' 2>/dev/null || true
  say "stopped"
  exit 0
fi

UEFI=0
BIOS=0
if [[ "${1:-}" == "--uefi" || "${SITIN_UEFI:-}" == 1 ]]; then
  UEFI=1
fi
if [[ "${1:-}" == "--bios" || "${SITIN_BIOS:-}" == 1 ]]; then
  BIOS=1
fi
if [[ "$UEFI" == 1 && "$BIOS" == 1 ]]; then
  fail "--uefi and --bios are mutually exclusive"
fi

ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
[[ -f /Users/ghostportal/Desktop/dc_sys/env.sh ]] && ENV_SH=/Users/ghostportal/Desktop/dc_sys/env.sh
# shellcheck disable=SC1090
[[ -f "$ENV_SH" ]] && source "$ENV_SH"

mkdir -p "$RUN_DIR"
if [[ -f "$PIDFILE" ]]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi
pkill -f 'oscortex-sit-in' 2>/dev/null || true

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
if [[ "${SITIN_SKIP_BUILD:-}" == 1 ]]; then
  say "skipping kernel build (SITIN_SKIP_BUILD=1)"
  [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
else
  say "building kernel"
  bash "$CORE_DIR/scripts/build-kernel.sh" || fail "build-kernel.sh failed"
  [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf"
fi

if [[ "${SITIN_FRAME2:-}" == 1 ]]; then
  say "building FAT volume (FILES SET PING STUDIO BROWSE PLAY TAP + SURF.ELF)"
  bash "$SITFAT/build-disk.sh" "$RUN_DIR" --surf \
    || fail "de-sitfat/build-disk.sh failed"
  say "SURF.ELF on FAT (proc spawn by 8.3 name); Start still first 4"
else
  say "building FAT volume (FILES SET PING STUDIO + BROWSE PLAY TAP)"
  bash "$SITFAT/build-disk.sh" "$RUN_DIR" \
    || fail "de-sitfat/build-disk.sh failed"
  say "FAT plants FILES SET PING STUDIO BROWSE PLAY TAP (+APP1); Start lists first 4"
fi
[[ -s "$RUN_DIR/disk.img" ]] || fail "no FAT disk.img"
[[ -s "$RUN_DIR/model.txt" ]] || fail "no de-sitfat model.txt"
RELS_START=$(grep -m1 '^rels_start=' "$RUN_DIR/model.txt" | cut -d= -f2-)
RELS_PING=$(grep -m1 '^rels_ping_row=' "$RUN_DIR/model.txt" | cut -d= -f2-)
START_N=$(grep -m1 '^start_count=' "$RUN_DIR/model.txt" | cut -d= -f2-)
[[ -n "$RELS_START" && -n "$RELS_PING" ]] || fail "derive.py omitted start / PING rels"

# FILES.ELF is 400×280 at (48,40). SET.ELF is 300×260 at (460,48).
# Both fit 800×600 and Venus 1280×720. Start lists the first four
# .ELF names (ADR-0108); BROWSE/PLAY/TAP are also on FAT (ADR-0173).

typekeys() {
  python3 -c "
import sys
out=[]
for c in sys.argv[1]:
    out.append({' ':'spc', '.': 'dot'}.get(c, c.lower()))
print(','.join(out))
" "$1"
}

PORT=$(python3 "$PICKER") || fail "no free QMP port"
SER="$CORE_DIR/build/sit-in-serial.txt"
PNG="$CORE_DIR/build/sit-in.png"
: >"$SER"

# Cocoa when this session can open a window; otherwise still boot so the PNG
# exists. zoom-to-fit scales the guest FB (800×600 Bochs / 1024×768 GOP) to
# the Mac window — without it Retina shows a postage stamp (ADR-0175).
# SITIN_DISPLAY=none|cocoa|… overrides the probe.
DISPLAY_ARG="-display cocoa,zoom-to-fit=on"
if [[ -n "${SITIN_DISPLAY:-}" ]]; then
  DISPLAY_ARG="-display $SITIN_DISPLAY"
elif ! qemu-system-x86_64 -display help 2>&1 | grep -q cocoa; then
  DISPLAY_ARG="-display none"
fi

ISO=""
OVMF_CODE_FILE=""
OVMF_VARS_COPY="$RUN_DIR/OVMF_VARS.fd"
if [[ "$UEFI" == 1 || "$BIOS" == 1 ]]; then
  command -v xorriso >/dev/null 2>&1 || fail "xorriso not found (brew install xorriso)"
  command -v limine >/dev/null 2>&1 || fail "limine not found (brew install limine)"
fi
if [[ "$UEFI" == 1 ]]; then
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
  OVMF_CODE_FILE="$(find_ovmf_code)" || fail "OVMF CODE firmware not found (set OVMF_CODE)"
  OVMF_VARS_FILE="$(find_ovmf_vars)" || fail "OVMF VARS template not found (set OVMF_VARS)"
  cp "$OVMF_VARS_FILE" "$OVMF_VARS_COPY" || fail "could not copy OVMF VARS"
  ISO="$RUN_DIR/uefi.iso"
  UEFI_KERNEL="$KERNEL_ELF"
  if [[ -f "$CORE_DIR/build/kernel-uefi.elf" ]]; then
    UEFI_KERNEL="$CORE_DIR/build/kernel-uefi.elf"
    say "UEFI kernel $UEFI_KERNEL (9MiB, avoids OVMF 8MiB hole)"
  fi
  say "building UEFI ISO (OVMF + Limine, GOP from limine.conf)"
  bash "$CORE_DIR/scripts/build-uefi-image.sh" "$UEFI_KERNEL" "$ISO" \
    || fail "build-uefi-image.sh failed"
elif [[ "$BIOS" == 1 ]]; then
  ISO="$RUN_DIR/bios.iso"
  say "building hybrid ISO (SeaBIOS + Limine, no OVMF)"
  bash "$CORE_DIR/scripts/build-uefi-image.sh" "$KERNEL_ELF" "$ISO" \
    || fail "build-uefi-image.sh failed"
fi

# Double-fork + setsid so a tool-shell teardown cannot SIGTERM the
# cocoa window. stdin from /dev/null; stdio to qemu.log. The grandchild
# execs QEMU so the pidfile is the real emulator pid.
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

launch_qemu() {
  local -a q
  if [[ "$UEFI" == 1 ]]; then
    q=(qemu-system-x86_64
      -name oscortex-sit-in
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE_FILE"
      -drive "if=pflash,format=raw,file=$OVMF_VARS_COPY"
      -cdrom "$ISO"
      -m 512M
      -cpu qemu64
      -serial "file:$SER"
      $DISPLAY_ARG
      -no-reboot
      -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk"
      -qmp "tcp:127.0.0.1:$PORT,server,nowait")
  elif [[ "$BIOS" == 1 ]]; then
    q=(qemu-system-x86_64
      -name oscortex-sit-in
      -cdrom "$ISO"
      -m 128M
      -cpu qemu64
      -vga std
      -serial "file:$SER"
      $DISPLAY_ARG
      -no-reboot
      -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk"
      -qmp "tcp:127.0.0.1:$PORT,server,nowait")
  else
    q=(qemu-system-x86_64
      -name oscortex-sit-in
      -kernel "$KERNEL_ELF"
      -m 128M
      -cpu qemu64
      -vga std
      -serial "file:$SER"
      $DISPLAY_ARG
      -no-reboot
      -drive "file=$RUN_DIR/disk.img,format=raw,if=ide,index=0,media=disk"
      -qmp "tcp:127.0.0.1:$PORT,server,nowait")
  fi
  _daemon_qemu "${q[@]}"
}

if [[ "${SITIN_FRAME2:-}" == 1 ]]; then
  say "booting QEMU ($DISPLAY_ARG) — compositor + FRAME2 SURF.ELF on FAT, then it stays up"
elif [[ "$UEFI" == 1 ]]; then
  say "booting QEMU UEFI ($DISPLAY_ARG) — GOP + compositor + FAT start list"
elif [[ "$BIOS" == 1 ]]; then
  say "booting QEMU BIOS ($DISPLAY_ARG) — SeaBIOS + Limine hybrid, no OVMF"
else
  say "booting QEMU ($DISPLAY_ARG) — compositor + FAT start list, then it stays up"
fi
launch_qemu
QEMU_PID=$(cat "$PIDFILE")
sleep 1
if ! kill -0 "$QEMU_PID" 2>/dev/null; then
  say "cocoa window failed, retrying headless so you still get a PNG"
  DISPLAY_ARG="-display none"
  launch_qemu
  QEMU_PID=$(cat "$PIDFILE")
  sleep 1
  kill -0 "$QEMU_PID" 2>/dev/null || { cat "$RUN_DIR/qemu.log" >&2; fail "qemu died"; }
fi

WM_WAIT=2500
MODE=mb
if [[ "$UEFI" == 1 ]]; then
  MODE=uefi
  WM_WAIT=3500
fi
KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:$WM_WAIT"
KEYS="$KEYS,$(typekeys 'wm gfx'),ret,wait:800"
KEYS="$KEYS,$(typekeys 'wm de'),ret,wait:800"
# Opt-in 50 fps cap for interactive drag/commit smoothness. Harnesses that
# measure unpaced behaviour never type this — only sit-in does (ADR-0188).
if [[ "${SITIN_PACE:-1}" != 0 ]]; then
  KEYS="$KEYS,$(typekeys 'wm pace'),ret,wait:400"
fi
KEYS="$KEYS,$(typekeys 'proc spawn DESK.ELF'),ret,until:DESK READY,wait:600"
if [[ "${SITIN_FRAME2:-}" == 1 ]]; then
  KEYS="$KEYS,$(typekeys 'proc spawn SURF.ELF'),ret,until:FRAME2 COMMIT,wait:400"
fi
# Cold boot is wallpaper + dock. FILES / SET open from dock icons.

# Drive, screenshot, do NOT quit — a one-off python so qmp-drive's final quit
# cannot kill the window you are supposed to be looking at.
python3 - "$PORT" "$SER" "$PNG" "$KEYS" "$MODE" "$RUN_DIR" "$CORE_DIR/kernel/wm.dart" "$START_N" <<'PY' || fail "could not drive the session"
import json, os, re, socket, struct, sys, time, zlib

port, serial, png, keys, mode, run_dir, wm_src, start_n = (
    int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4],
    sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8],
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
                print("sit-in: QEMU", hello.get("QMP", {}).get("version", {}))
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
        if len(row) < width * 4:
            raise SystemExit("pitch %d shorter than width %d" % (pitch, width))
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
m1_timeout = 45 if mode == "uefi" else 25
if not wait_marker(serial, "M1 END\n", timeout=m1_timeout):
    raise SystemExit("kernel never reached the prompt")
time.sleep(0.5)
commits_seen = 0
for item in [k for k in keys.split(",") if k]:
    if item.startswith("wait:"):
        time.sleep(int(item.split(":", 1)[1]) / 1000.0)
        continue
    if item.startswith("until:"):
        marker = item.split(":", 1)[1]
        commits_seen += 1
        if not wait_marker(serial, marker, timeout=20, at_least=commits_seen):
            raise SystemExit("never saw %d x %s" % (commits_seen, marker))
        continue
    if item.startswith("rel:"):
        _, dx, dy = item.split(":")
        events = []
        if int(dx):
            events.append({"type": "rel", "data": {"axis": "x", "value": int(dx)}})
        if int(dy):
            events.append({"type": "rel", "data": {"axis": "y", "value": int(dy)}})
        q.cmd("input-send-event", events=events)
        time.sleep(0.05)
        continue
    if item.startswith("btn:"):
        parts = item.split(":")
        if len(parts) != 3 or parts[2] not in ("down", "up"):
            raise SystemExit("malformed button element %r" % item)
        q.cmd("input-send-event", events=[
            {"type": "btn", "data": {"button": parts[1],
                                     "down": parts[2] == "down"}}])
        time.sleep(0.05)
        continue
    q.cmd("send-key", keys=[{"type": "qcode", "data": item}])
    time.sleep(0.05)
time.sleep(1.2)

text = open(serial, "r", encoding="latin-1").read()
if "DESK READY" not in text:
    raise SystemExit("sit-in never saw DESK READY")
if "DESK DOCK" not in text:
    raise SystemExit("sit-in never saw DESK DOCK")
if "FILES READY" in text and os.environ.get("SITIN_FRAME2") != "1":
    raise SystemExit("sit-in auto-opened FILES — boot is wallpaper + dock")
print("sit-in: DESK READY; empty desk (no FILES on boot)")
if mode != "uefi":
    q.cmd("screendump", filename=os.path.abspath(png), format="png")
    print("sit-in: wrote", png)
    base_m = re.search(r"^WM ON BASE ([0-9A-Fa-f]+) PITCH ([0-9A-Fa-f]+)", text, re.M)
    if not base_m:
        raise SystemExit("sit-in never saw WM ON BASE")
    addr = int(base_m.group(1), 16)
    pitch = int(base_m.group(2), 16)
    raw_path = os.path.join(run_dir, "fb.bin")
    q.cmd("pmemsave", val=addr, size=600 * pitch, filename=os.path.abspath(raw_path))
    data = open(raw_path, "rb").read()
    def pix(x, y):
        return struct.unpack_from("<I", data, y * pitch + x * 4)[0] & 0x00FFFFFF
    corner = pix(100, 120)
    title = pix(120, 124)
    if text.count("D3S COMMIT") >= 2:
        if corner != 0x184060:
            raise SystemExit(
                "window AABB (100,120) is 0x%06X, expected desktop 0x184060 (osgfx rrect)"
                % corner
            )
        if title != 0xD8B060:
            raise SystemExit(
                "title interior (120,124) is 0x%06X, expected 0xD8B060 — osgfx did not paint"
                % title
            )
        print("sit-in: (100,120)=desktop 0x184060 (not title); (120,124)=title")
    raise SystemExit(0)

if "FB BAR" in text:
    raise SystemExit("UEFI boot printed FB BAR — GOP should have won")
m = re.search(r"^FB GOP ([0-9A-Fa-f]+)x([0-9A-Fa-f]+) ([0-9A-Fa-f]+) ([0-9A-Fa-f]+)\s*$",
              text, re.M)
if not m:
    raise SystemExit("UEFI boot never printed FB GOP <w>x<h> <pitch> <addr>")
width = int(m.group(1), 16)
height = int(m.group(2), 16)
pitch = int(m.group(3), 16)
addr = int(m.group(4), 16)
if width == 800 or height == 600:
    raise SystemExit("FB GOP geometry is %dx%d — that is the Bochs mode" % (width, height))
if addr == 0 or addr == 0xFD000000:
    raise SystemExit("FB GOP address 0x%X is empty or the Bochs BAR" % addr)
if pitch < width * 4:
    raise SystemExit("FB GOP pitch %d is narrower than width %d" % (pitch, width))

desk_m = re.search(r"^const int wmColorDesktop = (0x[0-9A-Fa-f]+|\d+);",
                   open(wm_src, encoding="latin-1").read(), re.M)
if not desk_m:
    raise SystemExit("could not read wmColorDesktop from wm.dart")
desk = int(desk_m.group(1), 0)
# Same origin and colour gop.dart derives from the loader geometry.
mark_x, mark_y = width - 32, height - 32
mark = ((width >> 4) << 16) | ((height >> 4) << 8) | 0xA5
if mark_x < 800 or mark_y < 600:
    raise SystemExit("probe (%d,%d) is inside the Bochs rectangle" % (mark_x, mark_y))

raw_path = os.path.join(run_dir, "gop.bin")
nbytes = height * pitch
q.cmd("pmemsave", val=addr, size=nbytes, filename=os.path.abspath(raw_path))
data = open(raw_path, "rb").read()
if len(data) != nbytes:
    raise SystemExit("pmemsave wrote %d bytes, expected %d" % (len(data), nbytes))

off = mark_y * pitch + mark_x * 4
got = struct.unpack_from("<I", data, off)[0] & 0x00FFFFFF
want = desk & 0x00FFFFFF
if got == (mark & 0x00FFFFFF):
    raise SystemExit(
        "pixel (%d,%d) is still the GOP marker 0x%06X — compositor did not fill GOP geometry"
        % (mark_x, mark_y, got)
    )
if got != want:
    raise SystemExit(
        "pixel (%d,%d) is 0x%06X, expected desktop 0x%06X (derived from wm.dart + GOP tag)"
        % (mark_x, mark_y, got, want)
    )

write_png(png, width, height, pitch, data)
print("sit-in: GOP %dx%d pitch %d @ 0x%X" % (width, height, pitch, addr))
print("sit-in: probe (%d,%d) = desktop 0x%06X (not marker 0x%06X)" % (mark_x, mark_y, got, mark))
print("sit-in: wrote", png)
# no quit — the window stays
PY

say "framebuffer PNG: $PNG"
say "serial:          $SER"
if [[ "$UEFI" == 1 ]]; then
  say "boot:             UEFI OVMF+Limine (GOP aperture dump)"
elif [[ "$BIOS" == 1 ]]; then
  say "boot:             BIOS SeaBIOS+Limine hybrid (no OVMF, no -kernel)"
else
  say "boot:             Multiboot -kernel (Bochs 800×600)"
fi
say "QEMU pid $QEMU_PID is still running — look at that window, or sit-in.sh --kill"
exit 0
