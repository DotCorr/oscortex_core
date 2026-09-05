#!/usr/bin/env bash
# core/tests/conformance/d9-focus/run.sh
#
# D9 — Keystrokes reach the focused surface.
# display-protocol.md §6, ADR-0062.
#
# Binary: two surfaces. Click a point that is only inside the blue
# window. Inject derived keys via send-key. The focused client's
# kbdevent (syscall 24) prints the derived make+break sequence; the
# unfocused client prints NONE. The shell does not consume them while
# a surface is focused (drain skips).
#
# Negative control: a host model that delivered the sequence to the
# unfocused client produces a different line than the one this harness
# requires.
#
# Usage: bash run.sh
# Exit:  0 PASS, 1 FAIL, 2 setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "D9-focus: FAIL — $1" >&2; exit 1; }
setup_error() { echo "D9-focus: FAIL — $1" >&2; exit 2; }

source "$SCRIPT_DIR/../_lib/harness.sh"

ASSERTIONS_REQUIRED=43

for tool in qemu-system-x86_64 python3 clang x86_64-elf-ld x86_64-elf-objdump \
            x86_64-elf-readelf; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/oscortex-d9-focus.XXXXXX")" || setup_error "mktemp failed"
WORKDIR="$(cd "$WORKDIR" && pwd -P)"
cleanup() { [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"; }
trap cleanup EXIT

KERNEL_ELF="$CORE_DIR/build/kernel.elf"
DRIVER="$SCRIPT_DIR/d9-drive.py"
PICKER="$CORE_DIR/tests/conformance/m2-console/pick-port.py"
[[ -f "$DRIVER" ]] || setup_error "d9-drive.py not found"
[[ -f "$PICKER" ]] || setup_error "pick-port.py not found"

echo "=== BUILD ==="
capture_sh BUILD_OUT BUILD_STATUS -- "bash '$CORE_DIR/scripts/build-kernel.sh' 2>&1"
echo "$BUILD_OUT"
ck; [[ $BUILD_STATUS -eq 0 ]] || fail "build-kernel.sh exited $BUILD_STATUS"
ck; [[ -f "$KERNEL_ELF" ]] || fail "no kernel.elf after a successful build"

echo
echo "=== DERIVED ==="
MODEL="$WORKDIR/model.txt"
capture_sh DV_OUT DV_STATUS -- "python3 '$SCRIPT_DIR/derive.py' '$SCRIPT_DIR/prog.c' \
  '$CORE_DIR/kernel/wm.dart' '$CORE_DIR/kernel/kbdq.dart' > '$MODEL'"
ck; [[ $DV_STATUS -eq 0 ]] || { echo "$DV_OUT" >&2; fail "derive.py could not build the host model"; }
d() { grep -m1 "^$1=" "$MODEL" | cut -d= -f2-; }

CLICK_X=$(d click_x); CLICK_Y=$(d click_y)
RELS=$(d rels_to_click)
KEYS_IN=$(d keys)
SEQ=$(d seq)
SEQ_N=$(d seq_n)
SYSNO=$(d syscall)
FOCUS_WORD=$(d focus_word)

ck; [[ -n "$SEQ" ]] || fail "the model emitted no packed sequence"
ck; [[ "$SEQ_N" -eq 6 ]] || fail "the model says SEQ_N $SEQ_N, expected 6"
echo "DERIVED: click ($CLICK_X,$CLICK_Y) exclusive to B, keys $KEYS_IN -> $SEQ"

echo
echo "=== PROGRAMS ==="
ck; bash "$SCRIPT_DIR/build-progs.sh" "$WORKDIR" "$CORE_DIR/kernel" \
  || fail "the test programs could not be built"
DISK_IMG="$WORKDIR/disk.img"
LAYOUT_JSON="$WORKDIR/layout.json"
ck; python3 "$SCRIPT_DIR/make-image.py" "$DISK_IMG" \
  "$WORKDIR/progA.elf" "$WORKDIR/progB.elf" --json >"$LAYOUT_JSON" \
  || fail "make-image.py could not produce a verified image"
lba_of() { python3 -c "import json,sys; print('%X' % json.load(open(sys.argv[1]))[sys.argv[2]]['header_lba'])" "$LAYOUT_JSON" "$1"; }
LBA_A=$(lba_of A)
LBA_B=$(lba_of B)
ck; [[ -n "$LBA_A" && -n "$LBA_B" ]] || fail "could not read slot LBAs"
ck; [[ "$LBA_A" != "$LBA_B" ]] || fail "both clients have the same header LBA"
echo "IMAGE: pass  window A at 0x$LBA_A, window B at 0x$LBA_B"

echo
echo "=== STRUCTURAL ==="
dartconst() {
  python3 - "$CORE_DIR/kernel/$2" "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"^const int %s = (0x[0-9A-Fa-f]+|\d+);" % re.escape(sys.argv[2]), src, re.M)
print(int(m.group(1), 0) if m else "")
PY
}

K_SYS=$(dartconst kbdqSysNo kbdq.dart)
K_STORE=$(dartconst kbdqStoreBytes kbdq.dart)
K_DEPTH=$(dartconst kbdqDepth kbdq.dart)
W_FOCUS=$(dartconst wmMetaFocus wm.dart)
W_CHROME=$(dartconst wmMetaChrome wmchrome.dart)
W_SIZE=$(dartconst wmStoreBytes wm.dart)
PROG_SYS=$(grep -m1 '^#define SYS_KBDEVENT ' "$SCRIPT_DIR/prog.c" | awk '{print $3}')

ck; [[ "$K_SYS" -eq 24 ]] || fail "kbdqSysNo is $K_SYS, expected 24"
ck; [[ "$PROG_SYS" -eq "$K_SYS" ]] || fail "prog.c says SYS_KBDEVENT is $PROG_SYS and the kernel says $K_SYS"
ck; [[ "$K_SYS" -eq "$SYSNO" ]] || fail "the model and the kernel disagree about the syscall number"
ck; [[ "$W_FOCUS" -eq 20 ]] || fail "wmMetaFocus is $W_FOCUS, expected 20"
ck; [[ "$W_CHROME" -eq 19 ]] || fail "wmMetaChrome is $W_CHROME, expected 19"
ck; [[ "$W_FOCUS" -ne "$W_CHROME" ]] || fail "focus and chrome share a wmStore word"
ck; [[ "$W_SIZE" -eq 1472 ]] || fail "wmStoreBytes is $W_SIZE, expected 1472 — focus must not grow the block"
ck; [[ "$K_STORE" -eq 288 ]] || fail "kbdqStoreBytes is $K_STORE, expected 288"
ck; [[ "$K_DEPTH" -eq 32 ]] || fail "kbdqDepth is $K_DEPTH, expected 32"

ck; grep -q 'wmFocusLive()' "$CORE_DIR/kernel/kbdq.dart" \
  || fail "kbdq.dart does not ask wmFocusLive — drain and pop would ignore focus"
ck; awk '/void kbdqDrainToShell/,/^}/' "$CORE_DIR/kernel/kbdq.dart" | grep -q 'wmFocusLive' \
  || fail "kbdqDrainToShell does not skip when focus is live"
ck; awk '/void kbdqSys/,/^}/' "$CORE_DIR/kernel/kbdq.dart" | grep -q 'kbdqCallerMayRead' \
  || fail "kbdqSys does not gate pops on the focused owner"
ck; ! grep -qE 'userSysNo.*= *11|const int .*= 11;' "$CORE_DIR/kernel/kbdq.dart" \
  || fail "kbdq.dart took syscall 11"
ck; ! grep -qE 'kbdqSysNo = 2[12];' "$CORE_DIR/kernel/kbdq.dart" \
  || fail "kbdq.dart took syscall 21 or 22"

capture_sh REG_OUT REG_STATUS -- "bash '$CORE_DIR/scripts/verify-syscall-registry.sh' 2>&1"
echo "$REG_OUT"
ck; [[ $REG_STATUS -eq 0 ]] || fail "the syscall registry does not accept $K_SYS"

# No help line (GAP-0304).
ck; ! grep -qF "kbdevent" <(x86_64-elf-objdump -s -j .rodata "$CORE_DIR/build/kmain.o" | cut -c53-) \
  || fail "the kernel's .rodata contains kbdevent — a help line would move goldens"

bssfield() { x86_64-elf-readelf -sW "$CORE_DIR/build/kmain.o" \
  | awk -v n="$1" -v f="$2" '$4=="OBJECT" && $8==n {print $f; exit}'; }
bsssize() { bssfield "$1" 3; }
bssoff()  { bssfield "$1" 2; }
EV_SIZE=$(bsssize wmeventStore)
KBDQ_SIZE=$(bsssize kbdqStore)
WM_SIZE=$(bsssize wmStore)
EV_OFF=$(bssoff wmeventStore)
KBDQ_OFF=$(bssoff kbdqStore)
WM_OFF=$(bssoff wmStore)
ck; [[ "$EV_SIZE" -eq 1920 ]] || fail "wmeventStore is ${EV_SIZE:-missing} bytes, expected 1920"
ck; [[ "$KBDQ_SIZE" -eq 288 ]] || fail "kbdqStore is ${KBDQ_SIZE:-missing} bytes, expected 288"
ck; [[ "$WM_SIZE" -eq 1472 ]] || fail "wmStore is ${WM_SIZE:-missing} bytes, expected 1472"
DART_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kmain.o" | awk '$2==".bss"{print $3; exit}')
DART_BSS=$((16#$DART_BSS_HEX))
ck; [[ $(( 16#$EV_OFF + EV_SIZE )) -eq "$DART_BSS" ]] \
  || fail "wmeventStore is not last in .bss"
ck; [[ $(( 16#$KBDQ_OFF + KBDQ_SIZE )) -eq $(( 16#$EV_OFF )) ]] \
  || fail "kbdqStore is not immediately before wmeventStore"
ck; [[ $(( 16#$WM_OFF + WM_SIZE )) -eq $(( 16#$KBDQ_OFF )) ]] \
  || fail "wmStore is not immediately before kbdqStore"
ASM_BSS_HEX=$(x86_64-elf-objdump -h "$CORE_DIR/build/kdata.o" | awk '$2==".bss"{print $3; exit}')
TOTAL_BSS=$(( DART_BSS + 16#$ASM_BSS_HEX ))
ck; [[ "$TOTAL_BSS" -eq 51936 ]] \
  || fail "the kernel's mutable static storage is $TOTAL_BSS bytes, expected 51936 — ADR-0109's 23264, plus ADR-0155's doubling of `pmmMaxFrames` to 65536 (`pmmStore` 4672 -> 8768 and `shmStore` 4480 -> 8576, because `shmPlaneFrames` must equal `pmmMaxFrames`), plus ADR-0189's larger fine map (`vmStore` 128 -> 240), plus the two geometry words ADR-0064's fallback chain needs (`fbStateBlock` 32 -> 48)"
echo "STRUCTURAL: pass  syscall 24, wmMetaFocus=20, wmeventStore still last, total .bss $TOTAL_BSS"

printf -v WANT_B 'D9 B SEQ N %02X %s' "$SEQ_N" "$SEQ"
WANT_A="D9 A NONE"
WANT_A_SEQ="D9 A SEQ"
WANT_B_NONE="D9 B NONE"
ck; [[ "$WANT_B" != "$WANT_A" ]] \
  || fail "the host model of a focused report equals the unfocused line"
echo "NEGATIVE: pass  an unfocused report would be '$WANT_A', not '$WANT_B'"

echo
echo "=== BOOT ==="
typekeys() { python3 -c "
import sys
out = []
for c in sys.argv[1]:
    out.append({' ': 'spc'}.get(c, c.lower()))
print(','.join(out))
" "$1"; }

# send-key of each letter is make+break, matching the derived sequence.
SEQ_KEYS=$(python3 -c "print(','.join(list('$KEYS_IN')))")

KEYS="$(typekeys 'fb'),ret,wait:1500"
KEYS="$KEYS,$(typekeys 'wm on'),ret,wait:3000"
KEYS="$KEYS,$(typekeys "proc run $LBA_A $LBA_B"),ret"
KEYS="$KEYS,until:D9 A HOLD"
KEYS="$KEYS,until:D9 B HOLD"
KEYS="$KEYS,$RELS,wait:400"
KEYS="$KEYS,btn:left:down,wait:400,btn:left:up,wait:200"
KEYS="$KEYS,$SEQ_KEYS,wait:800"
KEYS="$KEYS,until:D9 B SEQ"
KEYS="$KEYS,until:D9 A NONE"

SER="$WORKDIR/serial.txt"
SHOT="$CORE_DIR/build/d9-focus.png"
mkdir -p "$CORE_DIR/build"
: >"$SER"
port=$(python3 "$PICKER") || fail "pick-port.py could not find a free TCP port"
timeout 240 qemu-system-x86_64 \
  -kernel "$KERNEL_ELF" \
  -m 128M \
  -cpu qemu64 \
  -vga std \
  -serial "file:$SER" \
  -display none \
  -no-reboot \
  -drive "file=$DISK_IMG,format=raw,if=ide,index=0,media=disk" \
  -qmp "tcp:127.0.0.1:$port,server,nowait" \
  >"$WORKDIR/qemu.log" 2>&1 &
qemu_pid=$!
run_status drive_status -- python3 "$DRIVER" --port "$port" --serial "$SER" \
  --wait-for 'M1 END\n' --png "$SHOT" --keys "$KEYS"
kill "$qemu_pid" 2>/dev/null || true
await qemu_status "$qemu_pid"
ck; if [[ $drive_status -ne 0 ]]; then
  cat "$WORKDIR/qemu.log" >&2
  echo "--- serial ---" >&2
  cat "$SER" >&2
  fail "d9-drive.py exited $drive_status"
fi
cp "$SER" "$CORE_DIR/build/d9-focus-serial.txt"
echo "BOOT: serial captured, screenshot $SHOT"

echo
echo "=== SERIAL ==="
have() { grep -qF -- "$1" "$SER" || { sed -n '/D9 /,$p' "$SER" >&2; fail "the transcript does not contain: $1"; }; }
havenot() { ! grep -qF -- "$1" "$SER" || { sed -n '/D9 /,$p' "$SER" >&2; fail "the transcript unexpectedly contains: $1"; }; }

ck; have "D9 A HOLD"
ck; have "D9 B HOLD"
ck; have "$WANT_B"
ck; have "$WANT_A"
ck; havenot "$WANT_A_SEQ"
ck; havenot "$WANT_B_NONE"
# A NONE after B SEQ — an early NONE would make the unfocused check vacuous.
ck; python3 - "$SER" "$WANT_B" "$WANT_A" <<'PY' || fail "D9 A NONE appeared before the focused sequence"
import sys
blob = open(sys.argv[1], "rb").read().decode("latin-1", "replace")
ib = blob.find(sys.argv[2])
ia = blob.find(sys.argv[3])
if ib < 0 or ia < 0 or ia < ib:
    raise SystemExit(1)
PY
# The shell is in state 2 for the whole of proc run, and drain skips
# when focus != 0 either way. A command built from the injected letters
# would appear after PROC END if the drain had consumed them at the
# next prompt; those letters must not become a shell line.
ck; ! grep -qE 'USER WRITE.*\bxyz\b|CMD .*xyz' "$SER" \
  || { sed -n '/D9 /,$p' "$SER" >&2; fail "the shell consumed the focused keys"; }
ck; ! grep -qE '^(M4|USER) FAULT VEC' "$SER" \
  || { sed -n '/M1 END/,$p' "$SER" >&2; fail "something faulted during the D9 boot"; }
echo "SERIAL: pass  focused client reported $WANT_B; unfocused reported NONE; shell did not consume"

require_assertions "$ASSERTIONS_REQUIRED"
echo
echo "D9-focus: PASS — syscall 24, click-to-focus, derived $KEYS_IN reached only the focused client, unfocused NONE"
exit 0
