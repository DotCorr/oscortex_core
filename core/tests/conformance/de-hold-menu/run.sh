#!/usr/bin/env bash
# Round 24: HOLD + open FILES menu must dismiss then publish, or cancel.
# Watchdog guarantees every HOLD reaches VIS or WM HOLD TO.
set -euo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WMDE="$CORE_DIR/kernel/wmde.dart"
WM="$CORE_DIR/kernel/wm.dart"
PACE="$CORE_DIR/kernel/wmpace.dart"
KMAIN="$CORE_DIR/kernel/kmain.dart"
MB="$CORE_DIR/kernel/multiboot.dart"
FILES="$CORE_DIR/user/frame/files.c"
CHIP="$CORE_DIR/scripts/chip-scan-round24.py"
MEAS="$CORE_DIR/scripts/measure-round24.py"
M1="$CORE_DIR/tests/conformance/m1-interrupts/run.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'wmPageWCsdArmed' "$PACE" || fail "CSD down-edge latch missing"
grep -q 'void wmHoldWatch' "$WMDE" || fail "wmHoldWatch missing"
grep -q 'void wmHoldKick' "$WMDE" || fail "wmHoldKick missing"
grep -q 'void wmHoldCancel' "$WMDE" || fail "wmHoldCancel missing"
grep -q 'wmPageWHoldArm0' "$PACE" || fail "HOLD arm words missing"
grep -q 'wmHoldWatch' "$PACE" || fail "wmFrameTick does not run watchdog"
grep -q 'mbCmdHasM1Fault' "$KMAIN" || fail "kmain does not gate M1 FAULT"
grep -q 'mbCmdHasM1Fault' "$MB" || fail "mbCmdHasM1Fault missing"
grep -q 'm1fault' "$M1" || fail "m1-interrupts does not pass m1fault"
grep -q 'menu_on = 0' "$FILES" || fail "FILES does not dismiss menu on configure"
grep -q 'msg_menu_esc' "$FILES" || fail "FILES configure dismiss has no MENU ESC"
grep -q 'FILES MENU ESC' "$FILES" || fail "FILES MENU ESC token missing"
grep -q 'SCAN_ESC' "$FILES" || fail "FILES has no Escape scancode path"
[[ -f "$CORE_DIR/scripts/prove-files-menu-esc.py" ]] \
  || fail "live FILES MENU ESC prover missing"

python3 - "$WMDE" "$WM" "$FILES" "$CHIP" "$MEAS" "$KMAIN" <<'PY' || fail "hold/menu source checks"
import re, sys
wmde, wm, files, chip, meas, kmain = [open(p).read() for p in sys.argv[1:]]

def fn(src, name):
    m = re.search(r"(void|u64) %s\(" % name, src)
    if not m:
        raise SystemExit("missing %s" % name)
    rest = src[m.start():]
    nxt = re.search(r"\n(@bare\n)?(u64|void) \w+\(", rest[8:])
    return rest[: (8 + nxt.start())] if nxt else rest

toggle = fn(wmde, "wmToggleMaxWindow")
if "wmPopHide" not in toggle:
    raise SystemExit("toggle does not dismiss wallpaper menu")
if "wmHoldKick" not in toggle:
    raise SystemExit("toggle does not retry unpublished HOLD")

watch = fn(wmde, "wmHoldWatch")
if "wmHoldCancel" not in watch or "wmHoldKick" not in watch:
    raise SystemExit("watchdog missing kick/cancel")

cancel = fn(wmde, "wmHoldCancel")
if "wmStrHoldTo" not in cancel:
    raise SystemExit("cancel missing WM HOLD TO")

resize = fn(wm, "wmResizeStep")
if "wmPopHide" not in resize:
    raise SystemExit("resize does not dismiss menu before HOLD")

if "menu_on = 0" not in files or "msg_menu_esc" not in files:
    raise SystemExit("FILES configure does not dismiss the row menu")
if "SCAN_ESC" not in files or "files_on_key" not in files:
    raise SystemExit("FILES Escape is not a client key path")
if 'FILES MENU ESC\\n' not in files and 'FILES MENU ESC\n' not in files:
    raise SystemExit("FILES MENU ESC token has no newline (vacuous serial match risk)")

if "q.key" in chip[chip.find("def ensure_restored"):chip.find("\n    cycle")]:
    raise SystemExit("chip-scan still Esc-unsticks HOLD")
if "files-menu-max" not in chip:
    raise SystemExit("chip-scan does not exercise max+menu+restore")
if "hold-stuck" not in chip:
    raise SystemExit("chip-scan does not fail a stuck restore HOLD")

if "DRIVE_SKIP_LAT" in meas:
    raise SystemExit("measure still allows skipping pointer/menu")
if 'want_opid=True' not in meas:
    raise SystemExit("measure does not pair op-IDs")
if "n=0" not in meas:
    raise SystemExit("measure does not refuse n=0")

if "mbCmdHasM1Fault" not in kmain:
    raise SystemExit("production kmain still always faults")
if "m2Enter" not in fn(kmain, "kmain"):
    raise SystemExit("production kmain does not continue at m2Enter")
print("de-hold-menu static PASS")
PY
# Anti-vacuity: live prover must compare pixels, not only the serial token.
grep -q 'region_diff' "$CORE_DIR/scripts/prove-files-menu-esc.py" \
  || fail "ESC prover has no region_diff pixel restoration check"
grep -q 'pixel_restore' "$CORE_DIR/scripts/prove-files-menu-esc.py" \
  || fail "ESC prover does not record pixel_restore"
echo "de-hold-menu: PASS"
