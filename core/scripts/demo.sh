#!/usr/bin/env bash
# core/scripts/demo.sh
#
# THE SHOWCASE HARNESS. Boots the operating system this repo builds, in a real
# QEMU window where the machine has one, drives a scripted tour of everything
# the kernel can currently do, and LEAVES THE MACHINE RUNNING so a human can
# look at it and type into it. The next run of this script kills the previous
# one first.
#
# It is NOT a conformance harness and asserts nothing. Nothing under
# core/tests/conformance/ depends on it, and it depends on the conformance
# tree only by READING it (build-progs.sh and make-image.py, invoked out of the
# isolated worktree, never edited). If this script disagrees with a harness,
# the harness is right.
#
#   Usage:
#     core/scripts/demo.sh                 # HEAD, window if the machine has one
#     core/scripts/demo.sh <commit-ish>    # any ref: a tag, a branch, a SHA
#     core/scripts/demo.sh --headless      # force -display none + PNG only
#     core/scripts/demo.sh --window        # insist on a window; fail if impossible
#     core/scripts/demo.sh --quit-when-done # shut the machine down after the tour
#     core/scripts/demo.sh --kill          # kill the running demo and exit
#     core/scripts/demo.sh --status        # is one running, and which commit
#     core/scripts/demo.sh --clean         # kill it, then delete every worktree,
#                                          # toolchain copy and run this made
#     core/scripts/demo.sh --watch [secs]  # never stop: re-demo every time the
#                                          # commit moves (default poll 60s)
#
#   Exit status: 0 on a completed tour, 1 on a build/boot failure, 2 on a
#   setup error (missing tool, unusable checkout).
#
# WHY AN ISOLATED WORKTREE
# ---------------------------------------------------------------------------
# The demo must be runnable AT ANY MOMENT, including while three other agents
# have half-finished edits in core/kernel/ and a fourth is regenerating a
# golden. So it never builds the working tree. It builds a `git worktree` at a
# COMMIT, in /private/tmp, with its own copy of the DCDart toolchain, and its
# own core/build/ inside that worktree. Nothing it does is visible from the
# checkout you are working in.
#
# The DCDart copy is an APFS clone (`cp -Rc`), not a symlink: dcc resolves
# `.dart_tool/package_config.json` relative to the DCDART_HOME it is handed,
# and a symlinked home resolves back into the shared checkout, which is exactly
# the isolation this is buying.
#
# THE DISPLAY IS DETECTED, NOT ASSUMED
# ---------------------------------------------------------------------------
# `-display cocoa` needs three things that are all false on a build machine: a
# QEMU built with the Cocoa UI, macOS, and a session connected to the window
# server. All three are probed, and then the launch itself is probed -- if QEMU
# dies inside two seconds with a window it could not open, the whole boot is
# retried headless rather than reported as a failure. A headless run is a
# complete run: the PNG and the serial transcript are the same artefacts.
#
# WHY THIS DRIVES QMP ITSELF INSTEAD OF CALLING qmp-drive.py
# ---------------------------------------------------------------------------
# core/tests/conformance/m2-console/qmp-drive.py ends every session with
# `{"execute":"quit"}`, because a harness's last act is to stop the machine. A
# demo's last act is the opposite: the window has to stay up. The embedded
# driver below is that one difference plus per-stage screenshots -- it speaks
# the same protocol, injects keys the same way (`send-key` with qcodes, one
# key at a time, with a gap so the 8042's one-byte output buffer is not
# overrun), and takes the same `screendump`. qmp-drive.py is not touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"

DEMO_ROOT="${OSCORTEX_DEMO_ROOT:-/private/tmp/oscortex-demo}"
PIDFILE="$DEMO_ROOT/demo.pid"
INFOFILE="$DEMO_ROOT/demo.info"
QEMU_MARKER="oscortex-demo"

say()  { printf '%s\n' "demo: $*"; }
fail() { printf '%s\n' "demo: FAIL — $*" >&2; exit 1; }
setup_error() { printf '%s\n' "demo: FAIL — $*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Arguments.
# ---------------------------------------------------------------------------
COMMITISH="HEAD"
FORCE_DISPLAY=""      # "", "cocoa", "none"
ACTION="run"
QUIT_WHEN_DONE=0
WATCH=0
REFRESH_DCDART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --headless)        FORCE_DISPLAY="none" ;;
    --window|--gui)    FORCE_DISPLAY="window" ;;
    --kill)            ACTION="kill" ;;
    --status)          ACTION="status" ;;
    --clean)           ACTION="clean" ;;
    --quit-when-done)  QUIT_WHEN_DONE=1 ;;
    --refresh-toolchain) REFRESH_DCDART=1 ;;
    --watch)           WATCH=60
                       # an optional numeric argument, without eating a commit-ish
                       if [[ "${2:-}" =~ ^[0-9]+$ ]]; then WATCH="$2"; shift; fi ;;
    --commit)          shift; COMMITISH="${1:-}" ;;
    -h|--help)         sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                setup_error "unknown option $1 (try --help)" ;;
    *)                 COMMITISH="$1" ;;
  esac
  shift
done

mkdir -p "$DEMO_ROOT" || setup_error "could not create $DEMO_ROOT"

# ---------------------------------------------------------------------------
# --watch: the owner's actual request -- a window that is ALWAYS showing the
# current commit. Re-invokes this script rather than looping around its body, so
# one demo is still exactly one process and a failed build is one failed child
# rather than a broken loop. The child never inherits --watch, so this cannot
# recurse.
# ---------------------------------------------------------------------------
if [[ $WATCH -gt 0 && "$ACTION" == "run" ]]; then
  say "watching $COMMITISH every ${WATCH}s — every new commit gets a fresh window"
  LAST=""
  while :; do
    CUR="$(git -C "$REPO_DIR" rev-parse "$COMMITISH" 2>/dev/null)"
    if [[ -n "$CUR" && "$CUR" != "$LAST" ]]; then
      [[ -n "$LAST" ]] && say "$COMMITISH moved ${LAST:0:7} -> ${CUR:0:7} — re-demoing"
      CHILD=(bash "${BASH_SOURCE[0]}" --commit "$CUR")
      case "$FORCE_DISPLAY" in
        none)   CHILD+=(--headless) ;;
        window) CHILD+=(--window) ;;
      esac
      if "${CHILD[@]}"; then
        LAST="$CUR"
      else
        say "the demo of ${CUR:0:7} failed — leaving the previous window up, retrying at the next change"
        LAST="$CUR"   # do not spin on a commit that cannot build
      fi
    fi
    sleep "$WATCH"
  done
fi

# ---------------------------------------------------------------------------
# Kill whatever the last run left behind. This runs on EVERY path, including
# --kill and --status's sibling, because "one demo at a time" is the whole
# point of the pidfile.
# ---------------------------------------------------------------------------
kill_previous() {
  local killed=0 pid=""
  if [[ -f "$PIDFILE" ]]; then
    pid="$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      # Confirm it is OURS before signalling it: a recycled pid belonging to
      # someone else's process must not be killed by this script.
      if ps -o command= -p "$pid" 2>/dev/null | grep -q "qemu-system-x86_64"; then
        kill -TERM "$pid" 2>/dev/null
        local n=0
        while kill -0 "$pid" 2>/dev/null && (( n < 40 )); do sleep 0.1; n=$((n+1)); done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
        killed=1
        say "killed the previous demo (pid $pid)"
      fi
    fi
    rm -f "$PIDFILE"
  fi
  # Belt and braces: a QEMU carrying our -name that no pidfile knows about,
  # e.g. because the pidfile was deleted or a run was interrupted mid-launch.
  local stray
  stray="$(pgrep -f "qemu-system-x86_64.*name $QEMU_MARKER" 2>/dev/null)"
  if [[ -n "$stray" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $stray 2>/dev/null
    sleep 0.5
    # shellcheck disable=SC2086
    kill -KILL $stray 2>/dev/null
    killed=1
    say "killed stray demo QEMU: $(tr '\n' ' ' <<<"$stray")"
  fi
  [[ $killed -eq 0 ]] && say "no previous demo was running"
  rm -f "$INFOFILE"
  return 0
}

demo_status() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "demo: RUNNING  pid $pid"
      [[ -f "$INFOFILE" ]] && sed 's/^/demo:   /' "$INFOFILE"
      return 0
    fi
  fi
  echo "demo: not running"
  return 0
}

case "$ACTION" in
  kill)   kill_previous; exit 0 ;;
  status) demo_status;   exit 0 ;;
  clean)
    kill_previous
    # Unregister the worktrees BEFORE deleting them, or `git worktree list` in
    # the checkout other people are working in keeps naming directories that
    # are not there any more.
    for d in "$DEMO_ROOT"/src-*; do
      [[ -d "$d" ]] && git -C "$REPO_DIR" worktree remove --force "$d" >/dev/null 2>&1
    done
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1
    rm -rf "$DEMO_ROOT"
    say "removed $DEMO_ROOT and pruned its worktrees"
    exit 0 ;;
esac

# ---------------------------------------------------------------------------
# The toolchain. dc_sys/env.sh is this machine's own environment file (it puts
# the Dart SDK dcc needs, and llvm-nm/llvm-objdump, on PATH). It is sourced
# WHEN PRESENT and never required -- a machine that already has the toolchain
# on PATH needs nothing.
# ---------------------------------------------------------------------------
ENV_SH="${OSCORTEX_ENV_SH:-$REPO_DIR/../env.sh}"
if [[ -f "$ENV_SH" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_SH"
  say "sourced $ENV_SH"
fi

for tool in git qemu-system-x86_64 python3 clang; do
  command -v "$tool" >/dev/null 2>&1 || setup_error "$tool not found on PATH"
done
command -v dcc >/dev/null 2>&1 || command -v dart >/dev/null 2>&1 \
  || setup_error "neither dcc nor dart on PATH (source dc_sys/env.sh, or set OSCORTEX_ENV_SH)"

# ---------------------------------------------------------------------------
# The commit, and the worktree that holds it.
# ---------------------------------------------------------------------------
git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
  || setup_error "$REPO_DIR is not a git checkout"
SHA="$(git -C "$REPO_DIR" rev-parse "$COMMITISH" 2>/dev/null)" \
  || setup_error "no such commit: $COMMITISH"
SHORT="$(git -C "$REPO_DIR" rev-parse --short "$SHA")"
SUBJECT="$(git -C "$REPO_DIR" log -1 --format=%s "$SHA")"
WT="$DEMO_ROOT/src-$SHORT"

git -C "$REPO_DIR" worktree prune >/dev/null 2>&1
if [[ ! -d "$WT" ]]; then
  say "creating an isolated worktree at $WT ($SHORT)"
  git -C "$REPO_DIR" worktree add --detach "$WT" "$SHA" >/dev/null 2>&1 \
    || setup_error "git worktree add failed for $SHORT"
else
  say "reusing the worktree at $WT ($SHORT)"
fi
[[ -f "$WT/core/scripts/build-kernel.sh" ]] \
  || setup_error "$WT does not look like an oscortex checkout"

# ---------------------------------------------------------------------------
# The toolchain checkout. An APFS clone, made once and reused.
# ---------------------------------------------------------------------------
DCDART_SRC="${DCDART_SRC:-$REPO_DIR/../DCDart}"
DCDART_COPY="$DEMO_ROOT/DCDart"
if [[ $REFRESH_DCDART -eq 1 ]]; then rm -rf "$DCDART_COPY"; fi
if [[ ! -d "$DCDART_COPY" ]]; then
  [[ -d "$DCDART_SRC" ]] || setup_error "no DCDart checkout at $DCDART_SRC (set DCDART_SRC)"
  say "cloning the DCDart toolchain into $DCDART_COPY (APFS clone, once)"
  cp -Rc "$DCDART_SRC" "$DCDART_COPY" 2>/dev/null || cp -R "$DCDART_SRC" "$DCDART_COPY" \
    || setup_error "could not copy $DCDART_SRC to $DCDART_COPY"
fi
export DCDART_HOME="$DCDART_COPY"

# ---------------------------------------------------------------------------
# Build.
# ---------------------------------------------------------------------------
RUN_DIR="$DEMO_ROOT/runs/$(date +%Y%m%d-%H%M%S)-$SHORT"
mkdir -p "$RUN_DIR" || setup_error "could not create $RUN_DIR"

say "building $SHORT ($SUBJECT)"
BUILD_LOG="$RUN_DIR/build.log"
if ! ( cd "$WT" && bash core/scripts/build-kernel.sh ) >"$BUILD_LOG" 2>&1; then
  tail -40 "$BUILD_LOG" >&2
  fail "build-kernel.sh failed for $SHORT (full log: $BUILD_LOG)"
fi
KERNEL_ELF="$WT/core/build/kernel.elf"
[[ -f "$KERNEL_ELF" ]] || fail "build-kernel.sh reported success but $KERNEL_ELF is missing"
say "built $(wc -c <"$KERNEL_ELF" | tr -d ' ') bytes of kernel.elf"

# The freestanding rule, reported rather than asserted -- this is a demo, and a
# demo that refused to show you a kernel because of a leaked symbol would be
# hiding the very thing worth looking at. The conformance harnesses assert it.
FS_LINE="$( (cd "$WT/core" && bash scripts/verify-freestanding.sh build/kmain.o) 2>&1 \
            | grep -Ei 'PASS|FAIL|declared extern' | tail -1 | cut -c1-96 )"
[[ -n "$FS_LINE" ]] || FS_LINE="(verify-freestanding.sh said nothing this script recognised)"

# ---------------------------------------------------------------------------
# The disk. Built by the milestone that OWNS it, out of the worktree, so a demo
# of an older commit gets that commit's image builder and that commit's
# programs. Nothing here is copied from a harness; the harness's own scripts are
# invoked, unedited, at the path the worktree puts them.
#
# The candidates are tried newest-first because a newer volume shows more: M16's
# carries three programs and a fragmented free list and the guest WRITES to it;
# M15's and M14's are read-only. A commit older than M14 has no filesystem at
# all, and the tour drops those stages rather than failing.
# ---------------------------------------------------------------------------
CONF="$WT/core/tests/conformance"
IMG=""
DISK_KIND=""      # write | read
PROG_RUN=""       # the program the tour runs off the volume
CAT_FILE=""       # a small file the tour prints
DISK_NOTE=""

try_disk() {
  local dir="$1"; shift
  [[ -f "$CONF/$dir/build-progs.sh" && -f "$CONF/$dir/make-image.py" ]] || return 1
  bash "$CONF/$dir/build-progs.sh" "$RUN_DIR/progs" >>"$RUN_DIR/progs.log" 2>&1 || return 1
  local args=()
  local f
  for f in "$@"; do args+=("$RUN_DIR/progs/$f"); done
  python3 "$CONF/$dir/make-image.py" "$RUN_DIR/demo.img" "${args[@]}" \
      >>"$RUN_DIR/progs.log" 2>&1 || return 1
  IMG="$RUN_DIR/demo.img"
  return 0
}

: >"$RUN_DIR/progs.log"
if   try_disk m16-filewrite prog.elf progn.elf verify.elf; then
  DISK_KIND=write; PROG_RUN="prog.elf";  CAT_FILE="empty.txt"
  DISK_NOTE="M16's volume: three ELF programs, a deliberately fragmented free list, and the guest writes to it"
elif try_disk m15-fileio    prog.elf progn.elf; then
  DISK_KIND=read;  PROG_RUN="prog.elf";  CAT_FILE="small.txt"
  DISK_NOTE="M15's volume: two ELF programs and files scattered across the FAT (read-only)"
elif try_disk m14-fat       progA.elf progB.elf; then
  DISK_KIND=read;  PROG_RUN="progA.elf"; CAT_FILE="hello.txt"
  DISK_NOTE="M14's volume: two named ELF programs (read-only)"
fi

IMG_SHA_BEFORE=""
if [[ -n "$IMG" ]]; then
  IMG_SHA_BEFORE="$(shasum -a 256 "$IMG" 2>/dev/null | cut -d' ' -f1)"
  say "built a $(wc -c <"$IMG" | tr -d ' ')-byte FAT16 volume — $DISK_NOTE"
else
  say "no disk image could be built for $SHORT — the tour will skip its filesystem stages"
  say "  (details in $RUN_DIR/progs.log)"
fi

# ---------------------------------------------------------------------------
# Which display can this machine actually give us?
# ---------------------------------------------------------------------------
can_window() {
  qemu-system-x86_64 -display help 2>/dev/null | grep -qx "cocoa" || return 1
  [[ "$(uname -s)" == "Darwin" ]] || return 1
  # The window server. `launchctl managername` answers "Aqua" in a GUI login
  # session and "Background"/"StandardIO" in a daemon or over ssh -- which is
  # the difference between a window appearing and QEMU exiting with
  # "Failed to initialize the Cocoa UI".
  [[ "$(launchctl managername 2>/dev/null)" == "Aqua" ]] || return 1
  return 0
}
can_window_linux() {
  qemu-system-x86_64 -display help 2>/dev/null | grep -qxE "gtk|sdl" || return 1
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || return 1
  return 0
}

DISPLAY_ARG="none"
DISPLAY_WHY=""
case "$FORCE_DISPLAY" in
  none)
    DISPLAY_ARG="none"; DISPLAY_WHY="--headless was asked for" ;;
  window)
    if can_window; then DISPLAY_ARG="cocoa"; DISPLAY_WHY="--window, and this is an Aqua session"
    elif can_window_linux; then DISPLAY_ARG="$(qemu-system-x86_64 -display help | grep -m1 -xE 'gtk|sdl')"; DISPLAY_WHY="--window, and \$DISPLAY is set"
    else setup_error "--window was asked for but this machine cannot open one (no cocoa/gtk/sdl backend, or no window-server session)"; fi ;;
  *)
    if can_window; then DISPLAY_ARG="cocoa"; DISPLAY_WHY="macOS, QEMU has the cocoa backend, and launchctl says this is an Aqua session"
    elif can_window_linux; then DISPLAY_ARG="$(qemu-system-x86_64 -display help | grep -m1 -xE 'gtk|sdl')"; DISPLAY_WHY="\$DISPLAY is set and QEMU has that backend"
    else DISPLAY_ARG="none"; DISPLAY_WHY="no usable window backend was found on this machine"; fi ;;
esac
say "display: -display $DISPLAY_ARG ($DISPLAY_WHY)"

# ---------------------------------------------------------------------------
# THE TOUR. One stage per line:
#
#   send <ms> <line>   type <line>, press Enter, then wait for the serial
#                      capture to stop growing (at most <ms>)
#   shot <file>        QEMU's own screendump, PNG
#   screen <file>      the VGA text buffer, read out of guest physical memory
#   mark <text>        a progress line on stdout
#   pause <ms>
# ---------------------------------------------------------------------------
TOUR="$RUN_DIR/tour.txt"
{
  echo "mark THE SHELL"
  echo "send 4000 help"
  echo "shot $RUN_DIR/01-help.png"
  echo "mark THE MACHINE"
  echo "send 4000 cpu"
  echo "send 4000 mem"
  echo "send 6000 pci"
  echo "shot $RUN_DIR/02-machine.png"
  if [[ -n "$IMG" ]]; then
    echo "mark THE DISK AND THE FILESYSTEM"
    echo "send 8000 disk id"
    echo "send 8000 fs"
    echo "send 8000 ls"
    echo "shot $RUN_DIR/03-filesystem.png"
  fi
  if [[ "$DISK_KIND" == "write" ]]; then
    echo "mark A C PROGRAM OFF THE FILESYSTEM, IN RING 3, WRITING FILES"
    # `frames` brackets the program: the frame allocator's free count printed
    # before and after is the leak check for everything the ELF loader and the
    # file syscalls touched.
    echo "send 6000 frames"
    echo "send 180000 run $PROG_RUN"
    echo "shot $RUN_DIR/04-program.png"
    echo "mark WHAT THE PROGRAM LEFT ON THE DISK"
    echo "send 8000 ls"
    # EMPTY.TXT was a ZERO-LENGTH file on the volume before the boot. The
    # program opened it for writing and gave it 40 bytes; this is the kernel
    # reading those bytes back, by name, through the chain it built itself.
    echo "send 8000 cat $CAT_FILE"
    echo "send 6000 frames"
    echo "shot $RUN_DIR/05-after.png"
  elif [[ "$DISK_KIND" == "read" ]]; then
    echo "mark READING A FILE BY NAME, AND RUNNING A PROGRAM BY NAME"
    echo "send 8000 cat $CAT_FILE"
    echo "send 6000 frames"
    echo "send 180000 run $PROG_RUN"
    echo "shot $RUN_DIR/04-program.png"
    echo "send 6000 frames"
  else
    echo "mark THE MEMORY MANAGER AND THE ADDRESS SPACE"
    echo "send 6000 frames"
    echo "send 12000 frames test"
    echo "send 6000 vm"
    echo "mark RING 3"
    echo "send 8000 user"
    echo "send 8000 user gp"
    echo "shot $RUN_DIR/04-ring3.png"
  fi
  echo "mark FAULTING ON PURPOSE, AND COMING BACK"
  echo "send 6000 crash div"
  echo "send 6000 proc"
  # The VGA text buffer is read BEFORE `fb`, deliberately. `conPutc` keeps
  # writing 0xB8000 either way, so the dump stays valid -- but taking it first
  # keeps the text artefact and the final PNG describing the same screen.
  echo "screen $RUN_DIR/screen.txt"
  # THE ONLY PIXELS THIS OPERATING SYSTEM HAS. `fb` finds the display
  # controller by PCI class, reads BAR0, sets an 800x600x32 mode through the
  # Bochs VBE registers and blits 8x16 glyphs out of a .rodata font. Something
  # has to be PRINTED afterwards or the new mode shows an empty screen, which
  # is why `pci` follows it -- m5-pci's own session does the same for the same
  # reason. The demo ENDS here so the window you are left looking at is the
  # graphical console rather than VGA text.
  echo "mark THE FRAMEBUFFER — REAL PIXELS, AT AN ADDRESS THE KERNEL DISCOVERED"
  echo "send 8000 fb"
  echo "send 8000 pci"
  echo "shot $RUN_DIR/demo.png"
} >"$TOUR"

# ---------------------------------------------------------------------------
# The QMP driver. See the header for why this is not qmp-drive.py.
# ---------------------------------------------------------------------------
DRIVER="$RUN_DIR/drive.py"
cat >"$DRIVER" <<'PYEOF'
#!/usr/bin/env python3
"""The demo's QMP driver: qmp-drive.py's protocol, minus the final `quit`.

Reads a tour file (one stage per line) and plays it into a running QEMU. The
machine is deliberately LEFT ALIVE at the end -- the point of the exercise is
a window somebody can keep looking at and typing into.
"""
import json, os, socket, sys, time

FAIL = 3
def die(m):
    print("drive: " + m, file=sys.stderr)
    sys.exit(FAIL)

QCODE = {" ": "spc", ".": "dot", "-": "minus", "/": "slash", ",": "comma",
         ";": "semicolon", "'": "apostrophe", "=": "equal", "[": "bracket_left",
         "]": "bracket_right", "\\": "backslash", "`": "grave_accent"}

class Qmp:
    def __init__(self, host, port, timeout):
        deadline = time.time() + timeout
        sock = None
        while time.time() < deadline:
            try:
                sock = socket.create_connection((host, port), timeout=2); break
            except OSError:
                sock = None; time.sleep(0.1)
        if sock is None:
            die("could not reach QMP at %s:%d in %ds -- did QEMU start?" % (host, port, timeout))
        self.f = sock.makefile("rw", encoding="utf-8", newline="\n")
        g = self._read()
        if "QMP" not in g:
            die("unexpected QMP greeting: %r" % (g,))
        v = g["QMP"]["version"]["qemu"]
        self.version = "%d.%d.%d" % (v["major"], v["minor"], v["micro"])
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.f.readline()
            if not line:
                die("QMP connection closed -- QEMU exited")
            msg = json.loads(line)
            if "event" in msg:      # RESET/SHUTDOWN/... interleave with replies
                continue
            return msg

    def cmd(self, name, **args):
        m = {"execute": name}
        if args:
            m["arguments"] = args
        self.f.write(json.dumps(m) + "\n"); self.f.flush()
        r = self._read()
        if "error" in r:
            die("QMP %s failed: %s" % (name, r["error"]))
        return r.get("return")

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})


def wait_marker(path, marker, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(path, "rb") as fh:
                if marker in fh.read():
                    return True
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    return False


def wait_quiet(path, quiet_for, timeout):
    """True once the capture has stopped growing for `quiet_for` seconds."""
    deadline = time.time() + timeout
    last, since = -1, time.time()
    while time.time() < deadline:
        size = os.path.getsize(path) if os.path.exists(path) else 0
        if size != last:
            last, since = size, time.time()
        elif time.time() - since >= quiet_for:
            return True
        time.sleep(0.05)
    return False


def type_line(q, text):
    for ch in text:
        code = QCODE.get(ch, ch.lower())
        q.cmd("send-key", keys=[{"type": "qcode", "data": code}])
        time.sleep(0.05)     # the 8042 has a ONE-byte output buffer
    q.cmd("send-key", keys=[{"type": "qcode", "data": "ret"}])


def read_text_buffer(q, base, cells):
    out = q.hmp("xp/%dhx 0x%x" % (cells, base))
    words = []
    for line in out.splitlines():
        if ":" not in line:
            continue
        for tok in line.split(":", 1)[1].split():
            if tok.startswith("0x"):
                words.append(int(tok, 16))
    return words


def main():
    port, serial, tour = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    marker = sys.argv[4].encode()
    q = Qmp("127.0.0.1", port, 25)
    print("drive: connected to QEMU %s" % q.version, flush=True)
    if not wait_marker(serial, marker, 40):
        die("the kernel never printed %r -- it did not reach the shell" % marker.decode())
    print("drive: the kernel reached its interactive console", flush=True)
    # The marker hits COM1 BEFORE the keyboard driver has drained the 8042 and
    # unmasked IRQ1; keys typed into that window are drained and thrown away.
    time.sleep(1.0)

    for raw in open(tour):
        raw = raw.rstrip("\n")
        if not raw.strip():
            continue
        verb, _, rest = raw.partition(" ")
        if verb == "mark":
            print("drive: --- %s" % rest, flush=True)
        elif verb == "pause":
            time.sleep(int(rest) / 1000.0)
        elif verb == "send":
            ms, _, line = rest.partition(" ")
            t0 = time.time()
            type_line(q, line)
            wait_quiet(serial, 0.6, int(ms) / 1000.0)
            print("drive:     $ %-24s (%.1fs)" % (line, time.time() - t0), flush=True)
        elif verb == "shot":
            q.cmd("screendump", filename=os.path.abspath(rest), format="png")
            print("drive:     screenshot -> %s" % rest, flush=True)
        elif verb == "screen":
            w = read_text_buffer(q, 0xB8000, 80 * 25)
            lines = []
            for r in range(25):
                row = w[r * 80:(r + 1) * 80]
                lines.append("".join(chr(c & 0xFF) if 0x20 <= (c & 0xFF) < 0x7F else "?"
                                     for c in row).rstrip())
            open(rest, "w").write("\n".join(lines) + "\n")
            print("drive:     screen text -> %s" % rest, flush=True)
        else:
            die("unknown tour verb %r" % verb)

    if os.environ.get("DEMO_QUIT_WHEN_DONE") == "1":
        q.cmd("quit")
        print("drive: sent quit -- the machine is stopped", flush=True)
    else:
        print("drive: tour finished; the machine is STILL RUNNING", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

# ---------------------------------------------------------------------------
# Boot. Launched fully detached (`nohup`, own stdio) so that it outlives this
# script -- which is the whole deal: the window stays up until the NEXT demo.
# ---------------------------------------------------------------------------
PICK_PORT="$WT/core/tests/conformance/m2-console/pick-port.py"
pick_port() {
  if [[ -f "$PICK_PORT" ]]; then python3 "$PICK_PORT"; else
    python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
  fi
}

SERIAL="$RUN_DIR/serial.txt"
QEMU_LOG="$RUN_DIR/qemu.log"

launch() {
  local disp="$1" port="$2"
  local args=(
    -name "$QEMU_MARKER"
    -kernel "$KERNEL_ELF"
    -m 128M
    -cpu qemu64
    -vga std
    -serial "file:$SERIAL"
    -display "$disp"
    -no-reboot
    -qmp "tcp:127.0.0.1:$port,server,nowait"
  )
  [[ -n "$IMG" ]] && args+=(-drive "file=$IMG,format=raw,if=ide,index=0,media=disk")
  nohup qemu-system-x86_64 "${args[@]}" >"$QEMU_LOG" 2>&1 </dev/null &
  QEMU_PID=$!
  disown "$QEMU_PID" 2>/dev/null || true
}

# ONE DEMO AT A TIME. Deliberately here and not earlier: a build that fails
# should leave the machine you were already looking at up on the screen.
kill_previous

# The launch is retried for TWO different reasons, and they are not the same
# reason:
#
#   * the QMP port. pick-port.py asks the kernel for a free port and then closes
#     it, so something else can take it in the gap before QEMU binds
#     (GAP-0150). The conformance harnesses retry for exactly this; so does this.
#   * the window. Detection can be right about the machine and wrong about the
#     moment. A windowed launch that dies inside two seconds is retried headless
#     ONCE, and the run continues -- a demo does not get to fail because the
#     machine has no screen.
ATTEMPT=0
while :; do
  : >"$SERIAL"
  PORT="$(pick_port)"
  launch "$DISPLAY_ARG" "$PORT"
  sleep 2
  kill -0 "$QEMU_PID" 2>/dev/null && break

  if LC_ALL=C grep -qiE "address already in use|failed to find an available port" "$QEMU_LOG" \
     && (( ATTEMPT < 5 )); then
    ATTEMPT=$((ATTEMPT + 1))
    say "QMP port $PORT was taken between picking it and binding it — retry $ATTEMPT of 5"
    continue
  fi

  if [[ "$DISPLAY_ARG" != "none" ]]; then
    say "QEMU could not open a window (see $QEMU_LOG) — retrying headless"
    sed 's/^/demo:   qemu: /' "$QEMU_LOG" >&2
    DISPLAY_ARG="none"; DISPLAY_WHY="the windowed launch died immediately"
    ATTEMPT=0
    continue
  fi

  cat "$QEMU_LOG" >&2
  fail "QEMU exited immediately (log above)"
done

echo "$QEMU_PID" >"$PIDFILE"
{
  echo "commit   $SHORT  $SUBJECT"
  echo "worktree $WT"
  echo "display  -display $DISPLAY_ARG"
  echo "run dir  $RUN_DIR"
  echo "qmp      127.0.0.1:$PORT"
} >"$INFOFILE"
say "QEMU is up (pid $QEMU_PID, QMP on 127.0.0.1:$PORT)"

# ---------------------------------------------------------------------------
# Drive the tour.
# ---------------------------------------------------------------------------
DEMO_QUIT_WHEN_DONE="$QUIT_WHEN_DONE" python3 "$DRIVER" "$PORT" "$SERIAL" "$TOUR" 'M1 END'
DRIVE_STATUS=$?
if [[ $DRIVE_STATUS -ne 0 ]]; then
  echo "--- qemu.log ---" >&2; cat "$QEMU_LOG" >&2
  echo "--- serial captured so far ---" >&2; tail -40 "$SERIAL" >&2
  fail "the scripted session failed (exit $DRIVE_STATUS); QEMU is still running as pid $QEMU_PID"
fi

# ---------------------------------------------------------------------------
# What an independent tool makes of the volume the guest just wrote. Best
# effort, and reported either way -- a demo does not get to fail here.
# ---------------------------------------------------------------------------
FSCK_NOTE=""
if [[ -n "$IMG" ]]; then
  cp "$IMG" "$RUN_DIR/after.img" 2>/dev/null
  IMG_SHA_AFTER="$(shasum -a 256 "$RUN_DIR/after.img" 2>/dev/null | cut -d' ' -f1)"
  if [[ "$DISK_KIND" == "write" ]]; then
    if [[ -n "$IMG_SHA_BEFORE" && "$IMG_SHA_BEFORE" == "$IMG_SHA_AFTER" ]]; then
      FSCK_NOTE="the volume is UNCHANGED — the guest wrote nothing"
    elif command -v fsck_msdos >/dev/null 2>&1; then
      if OUT="$(fsck_msdos -n "$RUN_DIR/after.img" 2>&1)"; then
        FSCK_NOTE="the guest CHANGED the volume, and fsck_msdos — a tool that knows nothing about this kernel — calls it clean: $(grep -E 'files,' <<<"$OUT" | tail -1)"
      else
        FSCK_NOTE="the guest changed the volume and fsck_msdos was unhappy with the result (see $RUN_DIR/after.img)"
      fi
    else
      FSCK_NOTE="the guest CHANGED the volume (sha256 ${IMG_SHA_BEFORE:0:12} -> ${IMG_SHA_AFTER:0:12}); fsck_msdos is not on this machine"
    fi
  else
    if [[ -n "$IMG_SHA_BEFORE" && "$IMG_SHA_BEFORE" == "$IMG_SHA_AFTER" ]]; then
      FSCK_NOTE="the volume came back BYTE-FOR-BYTE IDENTICAL (sha256 ${IMG_SHA_BEFORE:0:16}...) — this commit's filesystem is read-only and it read only"
    else
      FSCK_NOTE="the volume CHANGED, and at this commit nothing should have been able to write to it (see $RUN_DIR/after.img)"
    fi
  fi
fi

if [[ $QUIT_WHEN_DONE -eq 1 ]]; then
  rm -f "$PIDFILE" "$INFOFILE"
fi

# ---------------------------------------------------------------------------
# The summary a human reads.
# ---------------------------------------------------------------------------
SER_BYTES=$(wc -c <"$SERIAL" | tr -d ' ')
ln -sfn "$RUN_DIR" "$DEMO_ROOT/latest"

echo
echo "==============================================================================="
echo " oscortex demo — $SHORT"
echo "   $SUBJECT"
echo "==============================================================================="
echo "  built from   $WT (isolated worktree; your checkout was not touched)"
echo "  toolchain    $DCDART_HOME"
echo "  kernel       $(wc -c <"$KERNEL_ELF" | tr -d ' ') bytes   $FS_LINE"
[[ -n "$IMG" ]] && echo "  disk         $(wc -c <"$IMG" | tr -d ' ')-byte FAT16 volume — $DISK_NOTE"
echo "  display      -display $DISPLAY_ARG  ($DISPLAY_WHY)"
echo
echo "  demonstrated:"
sed -n 's/^send [0-9]* /    $ /p' "$TOUR"
echo
# WHAT THE MACHINE ITSELF SAID. Pulled out of the serial capture rather than
# out of this script, so the summary cannot claim anything the kernel did not
# print. A pattern that matched nothing simply prints nothing.
echo "  what the machine said (from $SERIAL):"
demo_evidence() {
  local label="$1" pat="$2" line
  line="$(LC_ALL=C grep -a -- "$pat" "$SERIAL" 2>/dev/null | tail -1)"
  [[ -n "$line" ]] && printf '    %-14s %s\n' "$label" "$line"
  return 0
}
demo_evidence "cpu"       "CPU BRAND"
demo_evidence "memory"    "MEM MIB"
demo_evidence "pci"       "PCI TOTAL"
demo_evidence "ata"       "DISK ID"
demo_evidence "fat16"     "FS GEOM"
demo_evidence "ring 3"    "ELF ENTER RIP"
demo_evidence "file write" "USER WRITE NEW WROTE"
demo_evidence "write path" "FILEW WRITES"
demo_evidence "exit"      "ELF DONE EXIT"
demo_evidence "cat"       "FS CAT"
demo_evidence "frames"    "PMM MANAGED"
demo_evidence "fault"     "FAULT RECOVERED"
echo
[[ -n "$FSCK_NOTE" ]] && echo "  $FSCK_NOTE" && echo
echo "  screenshot   $RUN_DIR/demo.png"
ls "$RUN_DIR"/*.png >/dev/null 2>&1 && \
  echo "  stages       $(cd "$RUN_DIR" && ls *.png | tr '\n' ' ')"
echo "  transcript   $SERIAL  ($SER_BYTES bytes)"
echo "  screen text  $RUN_DIR/screen.txt"
echo "  everything   $DEMO_ROOT/latest -> $RUN_DIR"
echo
if [[ $QUIT_WHEN_DONE -eq 1 ]]; then
  echo "  the machine was shut down (--quit-when-done)."
else
  echo "  THE MACHINE IS STILL RUNNING as pid $QEMU_PID — type into the window."
  echo "  The next 'core/scripts/demo.sh' kills it; 'core/scripts/demo.sh --kill' does too."
fi
echo "==============================================================================="
exit 0
