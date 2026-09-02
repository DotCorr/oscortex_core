#!/usr/bin/env python3
"""Collect owner-progress status from files and host processes. No harness runs.

Scrapes (never re-runs suites):
  - ADRs in core/docs/decisions/ (number + title + withdrawn)
  - conformance/*/run.sh + last PASS/FAIL if a leftover log exists
  - kernel.elf nm: osgfx_fill_rrect / SkCanvas / oschrome / osmedia
  - shmMax, wm de, sit-in FAT names (serial + disk.img)
  - STUB/DEAD: leftover-named files, unused wm gfx, preview-ui.sh,
    osgfx_guest_* unhooked, withdrawn ADRs
  - WORKAROUND vs REAL: osgfx_sw vs Skia, GET_CAPSET vs virgl, host-only plat
  - Linear flow: GPU → osgfx plug → Skia → DE chrome → apps → browser → media

Writes core/build/progress.json and patches the owner-progress canvas snapshot.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

CEF_STAMP = "144.0.34+g8fc21c8+chromium-144.0.7559.261"
CEF_DIRNAME = f"cef_binary_{CEF_STAMP}_macosarm64_minimal"
CEF_FILE = f"{CEF_DIRNAME}.tar.bz2"
CEF_EXPECTED_BYTES = 115543660

# Named rungs that sit on the linear flow or are still leftover-sensitive.
RUNGS = [
    ("G0", "g0-virtgpu", "0059-virtio-gpu-is-recognised.md", "GPU probe"),
    ("G1", "g1-virtgpu", "0065-bus-master-is-a-write.md", "bus-master write"),
    ("G2", "g2-virtgpu", "0067-driver-ok-is-a-status-write.md", "DRIVER_OK"),
    ("G3", "g3-virtgpu", "0074-a-virtqueue-answers-get-display-info.md", "GET_DISPLAY_INFO"),
    ("G4", "g4-virtgpu", "0079-one-pixel-on-virtio-gpu.md", "one pixel"),
    ("G5", "g5-virtgpu", "0084-the-framebuffer-console-runs-on-virtio.md", "console on virtio"),
    ("G6", "g6-virtgpu", "0086-damage-is-a-number-and-scroll-flushes.md", "damage / scroll"),
    ("G7", "g7-virtgpu", "0091-virtio-gpu-pci-has-no-vga.md", "virtio-gpu-pci, no VGA"),
    ("G8", "g8-virtgpu", "0093-two-resources-set-scanout-flip.md", "SET_SCANOUT flip"),
    ("G9", "g9-virtgpu", "0097-get-capset-info-is-the-first-3d-command.md", "GET_CAPSET_INFO"),
    ("G10", "g10-virgl", "0098-virtio-gpu-3d-executes-alpha.md", "virgl CLEAR+BLIT alpha"),
    ("G11", "g11-osgfx-gl", "0107-osgfx-chrome-reaches-virgl-scanout.md", "osgfx on VIRGL scanout"),
    ("G12", "gpu-app0", "0114-osgpu-is-the-explicit-app-gpu.md", "osgpu explicit app GPU"),
    ("DE-osgfx", "de-osgfx", "0104-the-os-calls-osgfx.md", "kernel.elf calls osgfx"),
    ("DE-chrome", "de-chrome", "0106-de-chrome-is-compositor-policy.md", "DE chrome policy"),
    ("DE-wm", "de-wm", None, "wm de command"),
    ("DE-resize", "de-resize", "0121-resize-is-de-policy.md", "SE resize under wm de"),
    ("DE-sitfat", "de-sitfat", "0108-sit-in-start-lists-fat-names.md", "sit-in FAT names"),
    ("DE-shm", "de-shm", "0109-shmmax-is-four-slots.md", "shmMax four slots"),
    ("DE-apps", "de-apps", "0112-an-app-is-elf-plus-osframe.md", "app = ELF + osframe"),
    ("GFX0", "gfx0-host", "0080-host-osgfx-is-a-c-module.md", "host osgfx C module"),
    ("GFX1", "gfx1-graphite", "0082-skia-graphite-is-the-platform-rasterizer.md", "host Graphite"),
    ("COMPOSE0", "gfx2-compose", "0094-session-chrome-is-osgfx-graphite.md", "host compose scene"),
    ("GFX3", "gfx3-guest", "0096-guest-osgfx-skia-paints-sit-in.md", "withdrawn CPU Skia sit-in"),
    ("BROWSER0", "browser0", "0083-chromium-content-is-the-platform-webview.md", "host CEF WebView"),
    ("CHROME1", "cmod-chrome1", "0095-dcdart-calls-the-platform-webview.md", "DCDart calls oschrome"),
    ("MEDIA0", "media0", "0103-ffmpeg-is-the-platform-media-module.md", "host FFmpeg"),
    ("OSXUI4", "osxui4", "0113-osxui-paints-through-osgfx.md", "osxui through osgfx"),
    ("DE-glyph", "de-glyph", "0117-glyphs-through-osgfx.md", "Start/osxui 8.3 glyphs"),
    ("u0", "u0-xhci", None, "find qemu-xhci"),
    ("u1", "u1-xhci", "0068-the-kernel-reads-xhci-capability-registers.md", "xhci cap/op"),
    ("u2", "u2-hid", "0073-a-hid-report-is-a-set-1-scancode.md", "HID set-1"),
    ("u3", "u3-xhci", "0085-one-xhci-hid-report-on-the-wire.md", "one report on the wire"),
    ("nvm0", "nvm0", "0071-nvme-is-recognised.md", "find NVMe"),
    ("nvm1", "nvm1", "0074-the-kernel-reads-nvme-cap-and-vs.md", "CAP + VS"),
    ("nvm2", "nvm2", "0087-nvme-identify-controller.md", "Identify Controller"),
    ("nvm3", "nvm3", "0088-one-nvme-sector-read.md", "I/O-queue sector"),
    ("nvm4", "nvm4", "0089-one-nvme-sector-write.md", "I/O-queue write"),
    ("nvm5", "nvm5", "0090-fat-sectors-move-through-nvme.md", "FAT on NVMe"),
    ("nvm6", "nvm6", "0092-a-named-elf-loads-through-nvme.md", "named ELF on NVMe"),
]


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_iso() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def human_bytes(n: int | None) -> str:
    if n is None:
        return "—"
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB"


def file_info(path: Path) -> dict:
    if not path.exists() and not path.is_symlink():
        return {"exists": False, "path": str(path)}
    try:
        st = path.stat()
    except OSError:
        return {"exists": False, "path": str(path)}
    return {
        "exists": True,
        "path": str(path),
        "bytes": st.st_size,
        "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
        "mtime_unix": int(st.st_mtime),
    }


def du_bytes(path: Path) -> int | None:
    if not path.exists():
        return None
    try:
        out = subprocess.check_output(
            ["du", "-sk", str(path)], stderr=subprocess.DEVNULL, text=True
        )
        return int(out.split()[0]) * 1024
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        return None


def tail_lines(path: Path, n: int = 8, max_bytes: int = 65536) -> list[str]:
    if not path.is_file():
        return []
    try:
        with path.open("rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - max_bytes))
            data = f.read()
    except OSError:
        return []
    text = data.decode("utf-8", errors="replace")
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    return lines[-n:]


def grep_lines(path: Path, pattern: str, limit: int = 24) -> list[str]:
    if not path.is_file():
        return []
    cre = re.compile(pattern)
    hits = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for ln in f:
                if cre.search(ln):
                    hits.append(ln.rstrip()[:200])
                    if len(hits) >= limit:
                        break
    except OSError:
        return []
    return hits


def ninja_tail(path: Path, n: int = 6) -> list[str]:
    raw = tail_lines(path, n=n + 4, max_bytes=8192)
    out = []
    for ln in raw:
        if ln.startswith("#"):
            continue
        parts = ln.split("\t")
        if len(parts) >= 4:
            out.append(parts[3])
        else:
            out.append(ln[:120])
    return out[-n:]


def interesting_process(cmd: str) -> str | None:
    low = cmd.lower()
    if "watch-progress" in low or "progress-status.py" in low:
        return None
    if "qemu-system-" in low:
        return "qemu"
    if re.search(r"(^|/)(curl|wget)(\s|$)", cmd) and re.search(
        r"cef|spotifycdn|chromium|skia", low
    ):
        return "download"
    if re.search(r"(^|/)ninja(\s|$)", cmd):
        return "ninja"
    if re.search(r"(^|/)gn(\s|$)", cmd) or " bin/gn " in cmd or cmd.rstrip().endswith("/gn"):
        return "gn"
    if any(
        name in cmd
        for name in (
            "fetch-cef.sh",
            "build-skia-graphite.sh",
            "build-oschrome.sh",
            "build-osmedia.sh",
            "build-skia-guest.sh",
            "build-kernel.sh",
            "sit-in.sh",
        )
    ):
        return "script"
    if "cef-builds.spotifycdn.com" in low or "github.com/google/skia" in low:
        return "download"
    return None


def host_processes() -> list[dict]:
    try:
        out = subprocess.check_output(
            ["ps", "-ax", "-o", "pid=,etime=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return []
    found = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^(\d+)\s+(\S+)\s+(.*)$", line)
        if not m:
            continue
        pid, etime, cmd = m.group(1), m.group(2), m.group(3)
        kind = interesting_process(cmd)
        if not kind:
            continue
        found.append(
            {
                "pid": int(pid),
                "etime": etime,
                "kind": kind,
                "command": cmd[:220],
            }
        )
    return found


def tmp_roots() -> list[Path]:
    roots = [Path("/tmp")]
    env = os.environ.get("TMPDIR")
    if env:
        roots.append(Path(env))
    return roots


def newest_logs(core: Path) -> list[dict]:
    candidates: list[Path] = []
    build = core / "build"
    if build.is_dir():
        candidates.extend(build.glob("*.log"))
        candidates.extend(build.glob("*serial*.txt"))
        sit = build / "sit-in" / "qemu.log"
        if sit.is_file():
            candidates.append(sit)
    for root in tmp_roots():
        if not root.is_dir():
            continue
        for p in root.glob("oschrome*.log"):
            candidates.append(p)
        for p in root.glob("oscortex-*"):
            if p.is_dir():
                for log in list(p.glob("*.log")) + list(p.glob("*.txt")):
                    candidates.append(log)
            elif p.is_file():
                candidates.append(p)
    conf = core / "tests" / "conformance"
    if conf.is_dir():
        for p in conf.glob("*/*.log"):
            candidates.append(p)
        for p in conf.glob("*/last-run.txt"):
            candidates.append(p)
        for p in conf.glob("*/RESULT"):
            candidates.append(p)

    scored = []
    for p in candidates:
        try:
            st = p.stat()
        except OSError:
            continue
        if st.st_size <= 0:
            continue
        scored.append((st.st_mtime, p, st.st_size))
    scored.sort(reverse=True)
    items = []
    for mtime, p, size in scored[:8]:
        items.append(
            {
                "path": str(p),
                "mtime": datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S"),
                "bytes": size,
                "tail": tail_lines(p, n=5),
            }
        )
    return items


def pass_fail_from_lines(lines: list[str]) -> tuple[str | None, str | None]:
    last_status = None
    last_line = None
    for ln in lines:
        if not re.search(r"\b(PASS|FAIL)\b", ln):
            continue
        last_line = ln[:200]
        if re.search(r":\s*FAIL", ln) or " FAIL —" in ln or ln.endswith("FAIL"):
            last_status = "FAIL"
        elif re.search(r":\s*PASS", ln) or " PASS —" in ln or ln.endswith("PASS"):
            last_status = "PASS"
        elif "FAIL" in ln and "PASS" not in ln:
            last_status = "FAIL"
        elif "PASS" in ln and "FAIL" not in ln:
            last_status = "PASS"
    return last_status, last_line


def harness_log_candidates(core: Path, harness: str, ident: str) -> list[Path]:
    harness_dir = core / "tests" / "conformance" / harness
    names = [
        core / "build" / f"{harness}.log",
        core / "build" / f"{ident.lower()}-virtgpu.log",
        core / "build" / f"{harness}-serial.txt",
        harness_dir / "last-run.txt",
        harness_dir / "RESULT",
        harness_dir / f"{harness}.log",
        Path(f"/tmp/{harness}.log"),
        Path(f"/tmp/{ident.lower()}-qemu.log"),
    ]
    # Only this-tree leftovers: exact name or oscortex-{harness}*.
    # Do not glob *{harness}*.log — that picks stale FAIL files from other
    # worktrees (e.g. /tmp/b1-m9-ring3.log).
    for root in tmp_roots():
        if not root.is_dir():
            continue
        names.append(root / f"{harness}.log")
        names.append(root / f"{ident.lower()}-qemu.log")
        names.extend(sorted(root.glob(f"oscortex-{harness}*"))[:6])
    out = []
    seen = set()
    for p in names:
        if p in seen:
            continue
        seen.add(p)
        if p.is_dir():
            for child in list(p.glob("*.log")) + list(p.glob("*.txt")) + list(p.glob("RESULT")):
                if child not in seen:
                    out.append(child)
                    seen.add(child)
        else:
            out.append(p)
    return out


def infer_rung(core: Path, ident: str, harness: str, adr: str | None, note: str) -> dict:
    harness_dir = core / "tests" / "conformance" / harness
    run_sh = harness_dir / "run.sh"
    adr_path = (core / "docs" / "decisions" / adr) if adr else None
    last_log = None
    last_status = None
    last_line = None
    sources = []

    for p in harness_log_candidates(core, harness, ident):
        if not p.is_file() or p.stat().st_size <= 0:
            continue
        last_log = str(p)
        sources.append(str(p))
        status, line = pass_fail_from_lines(tail_lines(p, n=80))
        last_line = line
        last_status = status
        if last_status:
            break

    if last_status is None:
        serial_hits = list((core / "build").glob(f"{ident.lower()}*serial*.txt"))
        serial_hits += list((core / "build").glob(f"{harness}*serial*.txt"))
        if serial_hits:
            newest = max(serial_hits, key=lambda p: p.stat().st_mtime)
            sources.append(str(newest))
            last_log = str(newest)

    withdrawn = False
    if adr_path and adr_path.is_file():
        head = adr_path.read_text(encoding="utf-8", errors="replace")[:800]
        withdrawn = bool(re.search(r"(?i)withdrawn|superseded", head))

    if last_status:
        status = last_status
        how = f"last log: {last_log}"
    elif withdrawn:
        status = "withdrawn"
        how = "ADR withdrawn / superseded"
        sources.append(str(adr_path))
    elif run_sh.is_file() and adr_path and adr_path.is_file():
        status = "landed"
        how = "ADR + harness present; no last-run log"
        sources.append(str(adr_path))
        sources.append(str(run_sh))
    elif run_sh.is_file():
        status = "harness"
        how = "harness present; no last-run log"
        sources.append(str(run_sh))
    else:
        status = "unknown"
        how = "no harness, no ADR, no log"

    return {
        "id": ident,
        "harness": harness,
        "note": note,
        "status": status,
        "how": how,
        "last_line": last_line,
        "last_log": last_log,
        "harness_exists": run_sh.is_file(),
        "adr": adr,
        "withdrawn": withdrawn,
        "sources": sources[:4],
    }


def scan_adrs(core: Path) -> list[dict]:
    dec = core / "docs" / "decisions"
    items = []
    if not dec.is_dir():
        return items
    for p in sorted(dec.glob("[0-9][0-9][0-9][0-9]-*.md")):
        text = p.read_text(encoding="utf-8", errors="replace")
        first = text.splitlines()[0] if text else p.stem
        m = re.match(r"^#\s+ADR-(\d+)\s+[—-]\s+(.+)$", first)
        number = m.group(1) if m else p.stem[:4]
        title = m.group(2).strip() if m else p.stem[5:].replace("-", " ")
        status_line = ""
        for ln in text.splitlines()[:12]:
            if ln.startswith("**Status:**"):
                status_line = ln[len("**Status:**") :].strip()
                break
        withdrawn = bool(re.search(r"(?i)withdrawn|superseded", status_line or title))
        items.append(
            {
                "number": number,
                "title": title[:120],
                "file": p.name,
                "status": status_line[:180],
                "withdrawn": withdrawn,
            }
        )
    return items


def scan_harnesses(core: Path) -> list[dict]:
    conf = core / "tests" / "conformance"
    items = []
    if not conf.is_dir():
        return items
    for run in sorted(conf.glob("*/run.sh")):
        name = run.parent.name
        last_log = None
        last_status = None
        last_line = None
        for p in harness_log_candidates(core, name, name):
            if not p.is_file() or p.stat().st_size <= 0:
                continue
            last_log = str(p)
            last_status, last_line = pass_fail_from_lines(tail_lines(p, n=80))
            if last_status:
                break
        items.append(
            {
                "id": name,
                "harness_exists": True,
                "status": last_status or ("harness" if run.is_file() else "unknown"),
                "last_log": last_log,
                "last_line": last_line,
            }
        )
    return items


def find_nm() -> str | None:
    for name in ("x86_64-elf-nm", "llvm-nm", "nm"):
        if shutil.which(name):
            return name
    return None


def nm_text(path: Path) -> str:
    if not path.is_file():
        return ""
    nm = find_nm()
    if not nm:
        return ""
    try:
        return subprocess.check_output(
            [nm, str(path)], stderr=subprocess.DEVNULL, text=True, errors="replace"
        )
    except (OSError, subprocess.CalledProcessError):
        try:
            return subprocess.check_output(
                [nm, "-a", str(path)], stderr=subprocess.DEVNULL, text=True, errors="replace"
            )
        except (OSError, subprocess.CalledProcessError):
            return ""


def nm_has(nm_out: str, *needles: str) -> bool:
    return any(n in nm_out for n in needles)


def plat_status(core: Path) -> dict:
    elf = core / "build" / "kernel.elf"
    kmap = core / "build" / "kernel.map"
    info = file_info(elf)
    nm_out = nm_text(elf) if info.get("exists") else ""
    map_text = ""
    if kmap.is_file():
        try:
            map_text = kmap.read_text(encoding="utf-8", errors="replace")
        except OSError:
            map_text = ""

    fill = nm_has(nm_out, "osgfx_fill_rrect")
    tick_lines = [ln for ln in nm_out.splitlines() if "osgfx_guest_tick" in ln]
    tick_weak = any(re.search(r"\sW\s+_*osgfx_guest_tick", ln) for ln in tick_lines)
    tick_text = any(re.search(r"\sT\s+_*osgfx_guest_tick", ln) for ln in tick_lines)
    skia_canvas = nm_has(nm_out, "SkCanvas", "_ZN8SkCanvas")
    skia_draw = nm_has(nm_out, "drawRRect", "osgfx_skia")
    chrome_sym = nm_has(nm_out, "oschrome_init", "oschrome_create", "oschrome_ffi_init")
    media_sym = nm_has(nm_out, "osmedia_init", "osmedia_open", "osmedia_decode_frame", "avcodec_")
    sw_obj = "osgfx_sw.o" in map_text
    skia_obj = "osgfx_skia.o" in map_text or "libskia.a" in map_text
    guest_skia_obj = "osgfx_guest_skia" in map_text
    cmd_only = "osgfx_cmd.o" in map_text and not sw_obj and not skia_obj

    if fill and (skia_canvas or skia_obj):
        osgfx_kind = "real"
        osgfx_how = "kernel.elf defines osgfx_fill_rrect and Skia symbols"
    elif fill and sw_obj:
        osgfx_kind = "workaround"
        osgfx_how = "kernel.elf links osgfx_sw.o (software rrect, not Skia)"
    elif tick_weak and not fill:
        osgfx_kind = "stub"
        osgfx_how = "kernel.elf has weak osgfx_guest_tick only (osgfx_cmd.o); no osgfx_fill_rrect"
    elif info.get("exists"):
        osgfx_kind = "leftover"
        osgfx_how = "kernel.elf present but osgfx paint symbols missing"
    else:
        osgfx_kind = "missing"
        osgfx_how = "no kernel.elf"

    host_skia = core / "build" / "skia" / "out" / "graphite" / "libskia.a"
    guest_skia = core / "build" / "skia" / "out" / "guest-elf" / "libskia.a"
    chrome_bin = (
        core
        / "build"
        / "oschrome-headless.app"
        / "Contents"
        / "MacOS"
        / "oschrome-headless"
    )
    media_bin = core / "build" / "osmedia-headless"

    return {
        "kernel": info,
        "nm_osgfx_fill_rrect": fill,
        "nm_osgfx_guest_tick_weak": tick_weak,
        "nm_osgfx_guest_tick_text": tick_text,
        "nm_skcanvas": skia_canvas,
        "nm_draw_rrect": skia_draw,
        "nm_oschrome": chrome_sym,
        "nm_osmedia": media_sym,
        "map_osgfx_sw": sw_obj,
        "map_osgfx_skia": skia_obj,
        "map_osgfx_guest_skia": guest_skia_obj,
        "map_osgfx_cmd_only": cmd_only,
        "osgfx_kind": osgfx_kind,
        "osgfx_how": osgfx_how,
        "host_skia": file_info(host_skia),
        "guest_skia": file_info(guest_skia),
        "osgfx_sw_o": file_info(core / "build" / "osgfx_sw.o"),
        "osgfx_skia_o": file_info(core / "build" / "osgfx_skia.o"),
        "oschrome_host": file_info(chrome_bin),
        "osmedia_host": file_info(media_bin),
        "oschrome_kind": "real" if chrome_sym else ("workaround" if chrome_bin.exists() else "missing"),
        "osmedia_kind": "real" if media_sym else ("workaround" if media_bin.exists() else "missing"),
    }


def shm_facts(core: Path) -> dict:
    shm = core / "kernel" / "shm.dart"
    text = shm.read_text(encoding="utf-8", errors="replace") if shm.is_file() else ""
    m = re.search(r"const int shmMax = (\d+);", text)
    pages = re.search(r"const int shmMaxPages = (\d+);", text)
    return {
        "shmMax": int(m.group(1)) if m else None,
        "shmMaxPages": int(pages.group(1)) if pages else None,
        "source": "core/kernel/shm.dart",
        "ok": bool(m and int(m.group(1)) >= 4),
    }


def sitin_facts(core: Path) -> dict:
    serial = core / "build" / "sit-in-serial.txt"
    disk = core / "build" / "sit-in" / "disk.img"
    png = core / "build" / "sit-in.png"
    fat_dir = core / "tests" / "conformance" / "de-sitfat"
    lines = tail_lines(serial, n=200, max_bytes=200000) if serial.is_file() else []
    names = []
    for ln in grep_lines(serial, r"FILES NAME |FILES NAMES ", limit=20):
        m = re.search(r"FILES NAME (\S+)", ln)
        if m:
            names.append(m.group(1))
        m2 = re.search(r"FILES NAMES (\d+)", ln)
        if m2:
            names.append(f"count={m2.group(1)}")
    wm_de = any("WM DE ON" in ln for ln in grep_lines(serial, r"WM DE ON", limit=4))
    wm_gfx = any("WM GFX ON" in ln for ln in grep_lines(serial, r"WM GFX ON", limit=4))
    return {
        "serial": file_info(serial),
        "disk": file_info(disk),
        "png": file_info(png),
        "de_sitfat_harness": (fat_dir / "run.sh").is_file(),
        "wm_de": wm_de,
        "wm_gfx": wm_gfx,
        "fat_names": names[:12],
        "tail": lines[-6:],
    }


def leftover_files(core: Path) -> list[str]:
    hits = []
    for p in core.rglob("*leftover*"):
        s = str(p)
        if "/.git/" in s or "/node_modules/" in s:
            continue
        hits.append(str(p.relative_to(core.parent)) if core.parent in p.parents else s)
        if len(hits) >= 20:
            break
    return hits


def stubs_and_dead(core: Path, plat: dict, adrs: list[dict], sitin: dict) -> list[dict]:
    items = []
    preview = core / "scripts" / "preview-ui.sh"
    items.append(
        {
            "id": "preview-ui.sh",
            "kind": "gone",
            "note": "preview-ui.sh absent (good) — Preview.app is not the UI",
            "path": "core/scripts/preview-ui.sh",
            "present": preview.is_file(),
        }
    )
    named = leftover_files(core)
    items.append(
        {
            "id": "leftover-files",
            "kind": "gone" if not named else "dead",
            "note": "no files named leftover" if not named else f"{len(named)} leftover-named files",
            "path": ", ".join(named[:6]) if named else "—",
            "present": bool(named),
        }
    )
    guest_skia = core / "plat" / "osgfx" / "osgfx_guest_skia.cpp"
    items.append(
        {
            "id": "osgfx_guest_skia",
            "kind": "unhooked" if guest_skia.is_file() and not plat.get("map_osgfx_guest_skia") else "linked",
            "note": "osgfx_guest_skia.cpp on disk; not in kernel.map (ADR-0096 withdrawn)",
            "path": "core/plat/osgfx/osgfx_guest_skia.cpp",
            "present": guest_skia.is_file(),
        }
    )
    crt = core / "plat" / "osgfx" / "osgfx_guest_crt.c"
    items.append(
        {
            "id": "osgfx_guest_crt",
            "kind": "unhooked" if crt.is_file() and "osgfx_guest_crt.o" not in (
                (core / "build" / "kernel.map").read_text(encoding="utf-8", errors="replace")
                if (core / "build" / "kernel.map").is_file()
                else ""
            ) else "linked",
            "note": "osgfx_guest_crt.c exists; linked only when OSGFX_SKIA builds",
            "path": "core/plat/osgfx/osgfx_guest_crt.c",
            "present": crt.is_file(),
        }
    )
    items.append(
        {
            "id": "wm-gfx",
            "kind": "used" if sitin.get("wm_gfx") else "unused",
            "note": "sit-in serial has WM GFX ON" if sitin.get("wm_gfx") else "no WM GFX ON in sit-in serial",
            "path": "core/kernel/wmgfx.dart",
            "present": (core / "kernel" / "wmgfx.dart").is_file(),
        }
    )
    items.append(
        {
            "id": "osgfx_guest_tick",
            "kind": "stub" if plat.get("nm_osgfx_guest_tick_weak") and not plat.get("nm_osgfx_fill_rrect") else "real",
            "note": plat.get("osgfx_how") or "",
            "path": "core/plat/osgfx/osgfx_cmd.c",
            "present": True,
        }
    )
    withdrawn = [a for a in adrs if a.get("withdrawn")]
    for a in withdrawn[:8]:
        items.append(
            {
                "id": f"ADR-{a['number']}",
                "kind": "withdrawn",
                "note": a["title"],
                "path": f"core/docs/decisions/{a['file']}",
                "present": True,
            }
        )
    return items


def workarounds(plat: dict, rungs: list[dict], chrome: dict) -> list[dict]:
    items = []
    if plat.get("osgfx_kind") == "workaround" or plat.get("map_osgfx_sw"):
        items.append(
            {
                "id": "osgfx_sw",
                "kind": "workaround",
                "vs": "Skia Graphite / guest-elf libskia",
                "note": "osgfx_sw.c software rrect is the sit-in paint, not SkCanvas",
            }
        )
    elif plat.get("osgfx_kind") == "stub":
        items.append(
            {
                "id": "osgfx_cmd_weak",
                "kind": "stub",
                "vs": "osgfx_fill_rrect in kernel.elf",
                "note": "current kernel.elf links mailbox + weak tick only",
            }
        )
    if plat.get("host_skia", {}).get("exists") and not plat.get("nm_skcanvas"):
        items.append(
            {
                "id": "host-graphite",
                "kind": "workaround",
                "vs": "Skia in the running OS image",
                "note": "Mac Graphite libskia.a is present; kernel.elf has no SkCanvas",
            }
        )
    if plat.get("guest_skia", {}).get("exists") and not plat.get("map_osgfx_skia"):
        items.append(
            {
                "id": "guest-libskia-unlinked",
                "kind": "leftover",
                "vs": "linked guest-elf libskia.a",
                "note": "guest-elf libskia.a exists on disk; kernel.map does not load it",
            }
        )
    g9 = next((r for r in rungs if r["id"] == "G9"), None)
    g10 = next((r for r in rungs if r["id"] == "G10"), None)
    if g9 and g9.get("harness_exists"):
        items.append(
            {
                "id": "GET_CAPSET",
                "kind": "real" if g10 and g10.get("harness_exists") else "workaround",
                "vs": "virgl CLEAR/execute (G10)",
                "note": "G9 GET_CAPSET_INFO is the first 3D command; G10 harness is the execute",
            }
        )
    if plat.get("oschrome_kind") == "workaround":
        items.append(
            {
                "id": "oschrome-host",
                "kind": "workaround",
                "vs": "oschrome symbols in kernel.elf / sit-in",
                "note": f"host oschrome-headless {human_bytes(plat['oschrome_host'].get('bytes'))}; nm has no oschrome_*",
            }
        )
    if plat.get("osmedia_kind") == "workaround":
        items.append(
            {
                "id": "osmedia-host",
                "kind": "workaround",
                "vs": "osmedia / avcodec in kernel.elf",
                "note": f"host osmedia-headless {human_bytes(plat['osmedia_host'].get('bytes'))}; nm has no osmedia_*",
            }
        )
    if chrome.get("browser0_status") in ("built", "unknown"):
        items.append(
            {
                "id": "browser0-host",
                "kind": "workaround",
                "vs": "BROWSER0 PASS on a sit-in WebView",
                "note": f"browser0 last known: {chrome.get('browser0_status')} (host module, not the OS image)",
            }
        )
    return items


def linear_flow(plat: dict, rungs: list[dict], sitin: dict, shm: dict) -> list[dict]:
    by = {r["id"]: r for r in rungs}

    def rung_kind(ident: str) -> str:
        r = by.get(ident)
        if not r:
            return "unknown"
        if r["status"] == "PASS":
            return "done"
        if r["status"] == "FAIL":
            return "fail"
        if r["status"] == "withdrawn":
            return "withdrawn"
        if r["status"] in ("landed", "harness"):
            return "landed"
        return r["status"]

    gpu_ids = ["G0", "G1", "G2", "G3", "G4", "G5", "G6", "G7", "G8", "G9", "G10", "G11"]
    gpu_pass = sum(1 for i in gpu_ids if by.get(i, {}).get("status") == "PASS")
    gpu_landed = sum(1 for i in gpu_ids if by.get(i, {}).get("harness_exists"))
    virgl = by.get("G10", {})
    gpu_kind = "done" if gpu_pass >= 10 else ("landed" if gpu_landed >= 10 else "leftover")
    if virgl.get("status") == "FAIL":
        gpu_kind = "fail"

    osgfx_kind = plat.get("osgfx_kind") or "missing"
    if osgfx_kind == "real":
        osgfx_flow = "done"
    elif osgfx_kind == "workaround":
        osgfx_flow = "workaround"
    elif osgfx_kind == "stub":
        osgfx_flow = "stub"
    else:
        osgfx_flow = "leftover"

    if plat.get("nm_skcanvas"):
        skia_flow = "done"
        skia_note = "SkCanvas in kernel.elf"
    elif plat.get("guest_skia", {}).get("exists") and not plat.get("map_osgfx_skia"):
        skia_flow = "leftover"
        skia_note = "guest-elf libskia.a on disk, not linked into this kernel.elf"
    elif plat.get("host_skia", {}).get("exists"):
        skia_flow = "workaround"
        skia_note = "host Graphite only — not the OS image"
    else:
        skia_flow = "leftover"
        skia_note = "no Skia archive for the kernel triple"

    de_kind = "done" if sitin.get("wm_de") else (
        "landed" if by.get("DE-chrome", {}).get("harness_exists") else "leftover"
    )
    apps_kind = "done" if sitin.get("fat_names") else (
        "landed" if by.get("DE-apps", {}).get("harness_exists") else "leftover"
    )
    browser_kind = "done" if plat.get("nm_oschrome") else (
        "workaround" if plat.get("oschrome_host", {}).get("exists") else "leftover"
    )
    media_kind = "done" if plat.get("nm_osmedia") else (
        "workaround" if plat.get("osmedia_host", {}).get("exists") else "leftover"
    )

    return [
        {
            "id": "gpu",
            "label": "GPU",
            "kind": gpu_kind,
            "note": f"G0–G11 harnesses {gpu_landed}/12 · last-log PASS {gpu_pass} · G10 {rung_kind('G10')} · G11 {rung_kind('G11')}",
        },
        {
            "id": "osgfx",
            "label": "osgfx plug",
            "kind": osgfx_flow,
            "note": plat.get("osgfx_how") or "",
        },
        {
            "id": "skia",
            "label": "Skia",
            "kind": skia_flow,
            "note": skia_note,
        },
        {
            "id": "de",
            "label": "DE chrome",
            "kind": de_kind,
            "note": "sit-in serial WM DE ON" if sitin.get("wm_de") else "no WM DE ON in sit-in serial",
        },
        {
            "id": "apps",
            "label": "apps",
            "kind": apps_kind,
            "note": (
                "FAT names: " + ", ".join(sitin.get("fat_names") or [])
                if sitin.get("fat_names")
                else "no FILES NAME lines in sit-in serial"
            ),
        },
        {
            "id": "browser",
            "label": "browser",
            "kind": browser_kind,
            "note": (
                "oschrome_* in kernel.elf"
                if plat.get("nm_oschrome")
                else "host CEF / oschrome-headless only"
            ),
        },
        {
            "id": "media",
            "label": "media",
            "kind": media_kind,
            "note": (
                "osmedia_* in kernel.elf"
                if plat.get("nm_osmedia")
                else "host FFmpeg / osmedia-headless only"
            ),
        },
        {
            "id": "shm",
            "label": "shmMax",
            "kind": "done" if shm.get("ok") else "leftover",
            "note": f"shmMax={shm.get('shmMax')} pages={shm.get('shmMaxPages')} (ADR-0109 wants ≥ 4)",
        },
    ]


def leftovers_inflight(
    flow: list[dict], stubs: list[dict], works: list[dict], rungs: list[dict]
) -> list[dict]:
    items = []
    for step in flow:
        if step["kind"] in ("leftover", "stub", "workaround", "fail"):
            items.append(
                {
                    "id": step["id"],
                    "kind": step["kind"],
                    "note": f"{step['label']}: {step['note']}",
                }
            )
    for s in stubs:
        if s["kind"] in ("unhooked", "stub", "dead", "unused"):
            items.append({"id": s["id"], "kind": s["kind"], "note": s["note"]})
    for w in works:
        if w["kind"] in ("workaround", "leftover", "stub"):
            items.append({"id": w["id"], "kind": w["kind"], "note": w["note"]})
    for r in rungs:
        if r["status"] in ("FAIL", "leftover"):
            items.append(
                {"id": r["id"], "kind": r["status"].lower(), "note": r.get("last_line") or r["how"]}
            )
    # de-dupe by id, keep first
    seen = set()
    out = []
    for it in items:
        if it["id"] in seen:
            continue
        seen.add(it["id"])
        out.append(it)
    return out[:24]


def now_block(flow: list[dict], sitin: dict, plat: dict, procs: list[dict]) -> dict:
    first_hole = next(
        (s for s in flow if s["kind"] in ("stub", "fail", "leftover", "workaround")),
        None,
    )
    qemu = [p for p in procs if p["kind"] == "qemu"]
    sitin_qemu = any("oscortex-sit-in" in p["command"] for p in qemu)
    return {
        "headline": (
            f"{first_hole['label']}: {first_hole['note']}"
            if first_hole
            else "linear flow has no leftover/stub/workaround hole"
        ),
        "hole_id": first_hole["id"] if first_hole else None,
        "hole_kind": first_hole["kind"] if first_hole else "done",
        "sit_in_qemu": sitin_qemu,
        "wm_de": bool(sitin.get("wm_de")),
        "wm_gfx": bool(sitin.get("wm_gfx")),
        "osgfx_kind": plat.get("osgfx_kind"),
        "kernel_mtime": plat.get("kernel", {}).get("mtime"),
        "qemu_n": len(qemu),
    }


def cef_status(core: Path, procs: list[dict]) -> dict:
    root = core / "build" / "cef"
    archive = root / CEF_FILE
    part = root / f"{CEF_FILE}.part"
    dest = root / CEF_DIRNAME
    stamp = root / "READY"
    wrapper = root / "wrapper" / "libcef_dll_wrapper" / "libcef_dll_wrapper.a"
    fw = dest / "Release" / "Chromium Embedded Framework.framework"

    curl = [
        p
        for p in procs
        if p["kind"] == "download" and re.search(r"cef|spotifycdn|chromium", p["command"], re.I)
    ]
    extracting = any("tar " in p["command"] and "cef" in p["command"].lower() for p in procs)
    linking = any(
        p["kind"] in ("ninja", "script")
        and re.search(r"cef|oschrome|libcef_dll_wrapper", p["command"], re.I)
        for p in procs
    )

    if stamp.is_file() and (dest / "include").is_dir() and fw.is_dir() and not curl and not extracting:
        phase = "idle"
        if linking:
            phase = "linking"
    elif curl or part.is_file():
        phase = "downloading"
    elif extracting or (archive.is_file() and not (dest / "include").is_dir()):
        phase = "extracting"
    elif linking or (stamp.is_file() and not wrapper.is_file()):
        phase = "linking"
    elif stamp.is_file():
        phase = "idle"
    else:
        phase = "idle"

    tarball = file_info(archive if archive.exists() else part)
    if part.exists() and not archive.exists():
        tarball["partial"] = True
    present = tarball.get("bytes") if tarball.get("exists") else 0
    expected = CEF_EXPECTED_BYTES
    pct = min(100.0, (present / expected) * 100.0) if present else 0.0

    log_paths = [p for p in (Path("/tmp/oschrome-build2.log"), Path("/tmp/oschrome-build.log")) if p.is_file()]
    return {
        "phase": phase,
        "stamp": CEF_STAMP,
        "ready": stamp.is_file(),
        "ready_text": tail_lines(stamp, n=4) if stamp.is_file() else [],
        "tarball": tarball,
        "tarball_bytes": present,
        "expected_bytes": expected,
        "pct": round(pct, 1),
        "dir_exists": dest.is_dir(),
        "dir_du_bytes": du_bytes(dest) if dest.is_dir() else None,
        "include": (dest / "include").is_dir(),
        "framework": fw.is_dir(),
        "wrapper": file_info(wrapper),
        "curl": curl,
        "log_tail": tail_lines(log_paths[0], n=6) if log_paths else [],
        "log_path": str(log_paths[0]) if log_paths else None,
    }


def skia_status(core: Path, procs: list[dict]) -> dict:
    lib = core / "build" / "skia" / "out" / "graphite" / "libskia.a"
    ninja_log = core / "build" / "skia" / "out" / "graphite" / ".ninja_log"
    src = core / "build" / "skia" / "src"
    building = any(
        p["kind"] in ("ninja", "gn", "script") and re.search(r"skia|graphite", p["command"], re.I)
        for p in procs
    )
    info = file_info(lib)
    if info.get("exists"):
        phase = "present"
    elif building or (src / ".git").is_dir():
        phase = "building" if building else "cloned"
    else:
        phase = "missing"
    return {
        "phase": phase,
        "lib": info,
        "ninja_log": file_info(ninja_log) if ninja_log.is_file() else {"exists": False},
        "ninja_tail": ninja_tail(ninja_log) if ninja_log.is_file() else [],
        "src_git": (src / ".git").is_dir(),
        "building": building,
    }


def chrome_status(core: Path) -> dict:
    app_bin = core / "build" / "oschrome-headless.app" / "Contents" / "MacOS" / "oschrome-headless"
    link = core / "build" / "oschrome-headless"
    fw = (
        core
        / "build"
        / "oschrome-headless.app"
        / "Contents"
        / "Frameworks"
        / "Chromium Embedded Framework.framework"
    )
    browser0 = core / "tests" / "conformance" / "browser0"
    last = None
    last_status = None
    last_line = None
    for p in [
        browser0 / "last-run.txt",
        browser0 / "RESULT",
        browser0 / "browser0.log",
        core / "build" / "browser0.log",
        Path("/tmp/browser0.log"),
        Path("/tmp/oschrome-build2.log"),
    ]:
        if p.is_file() and p.stat().st_size > 0:
            last = str(p)
            for ln in tail_lines(p, n=80):
                if "BROWSER0:" in ln or re.search(r"BROWSER0: (PASS|FAIL)", ln):
                    last_line = ln[:200]
                    if "PASS" in ln:
                        last_status = "PASS"
                    if "FAIL" in ln:
                        last_status = "FAIL"
            if last_status:
                break
            if p.name.startswith("oschrome-build") and last_line is None:
                built = [ln for ln in tail_lines(p, n=20) if ln.startswith("built ")]
                if built:
                    last_line = built[-1][:200]
                    last_status = "built"
            break
    ppm = Path("/tmp/oschrome-page.ppm")
    return {
        "binary": file_info(app_bin),
        "symlink": file_info(link) if link.exists() or link.is_symlink() else {"exists": False},
        "framework": fw.is_dir(),
        "browser0_log": last,
        "browser0_status": last_status or "unknown",
        "browser0_line": last_line,
        "ppm": file_info(ppm) if ppm.is_file() else {"exists": False},
    }


def collect(core: Path) -> dict:
    procs = host_processes()
    cef = cef_status(core, procs)
    skia = skia_status(core, procs)
    chrome = chrome_status(core)
    rungs = [infer_rung(core, *row) for row in RUNGS]
    adrs = scan_adrs(core)
    harnesses = scan_harnesses(core)
    plat = plat_status(core)
    shm = shm_facts(core)
    sitin = sitin_facts(core)
    stubs = stubs_and_dead(core, plat, adrs, sitin)
    works = workarounds(plat, rungs, chrome)
    flow = linear_flow(plat, rungs, sitin, shm)
    leftovers = leftovers_inflight(flow, stubs, works, rungs)
    now = now_block(flow, sitin, plat, procs)
    logs = newest_logs(core)

    done = []
    if sitin.get("wm_de"):
        done.append({"id": "wm-de", "note": "sit-in serial: WM DE ON"})
    if sitin.get("wm_gfx"):
        done.append({"id": "wm-gfx", "note": "sit-in serial: WM GFX ON"})
    if sitin.get("fat_names"):
        done.append({"id": "sit-in-fat", "note": "FAT names " + ", ".join(sitin["fat_names"][:8])})
    if shm.get("ok"):
        done.append({"id": "shmMax", "note": f"shmMax={shm['shmMax']}"})
    if not (core / "scripts" / "preview-ui.sh").is_file():
        done.append({"id": "preview-gone", "note": "preview-ui.sh deleted"})
    for r in rungs:
        if r["status"] in ("PASS", "landed") and not r.get("withdrawn"):
            done.append({"id": r["id"], "note": f"{r['note']} ({r['status']})"})

    harness_counts = {"PASS": 0, "FAIL": 0, "harness": 0, "other": 0}
    for h in harnesses:
        harness_counts[h["status"] if h["status"] in harness_counts else "other"] += 1

    return {
        "updated_at": now_iso(),
        "updated_local": local_iso(),
        "updated_unix": int(time.time()),
        "live": False,
        "refresh": "file-backed snapshot — canvas cannot fetch; leave watch-progress.sh running and reopen/reload the canvas",
        "core": str(core),
        "now": now,
        "flow": flow,
        "done": done[:36],
        "leftovers": leftovers,
        "stubs": [s for s in stubs if s["kind"] != "gone"] + [s for s in stubs if s["kind"] == "gone"],
        "workarounds": works,
        "adrs": {
            "count": len(adrs),
            "withdrawn": [a for a in adrs if a.get("withdrawn")],
            "recent": adrs[-12:],
        },
        "harnesses": {
            "count": len(harnesses),
            "counts": harness_counts,
            "fail": [h for h in harnesses if h["status"] == "FAIL"][:12],
            "pass": [h for h in harnesses if h["status"] == "PASS"][:16],
        },
        "plat": plat,
        "sitin": sitin,
        "shm": shm,
        "cef": cef,
        "skia": skia,
        "chrome": chrome,
        "rungs": rungs,
        "processes": procs,
        "logs": logs,
        "sources": [
            "core/docs/decisions/ ADR-NNNN title + Status (withdrawn/superseded)",
            "core/tests/conformance/*/run.sh + last-run/RESULT/logs in core/build and /tmp (no suite re-run)",
            "nm kernel.elf: osgfx_fill_rrect, SkCanvas, oschrome_*, osmedia_* / avcodec_",
            "kernel.map: osgfx_sw.o vs osgfx_skia.o vs osgfx_cmd.o vs libskia.a",
            "core/kernel/shm.dart shmMax; sit-in-serial.txt WM DE / WM GFX / FILES NAME",
            "preview-ui.sh absent; *leftover* filenames; osgfx_guest_skia.cpp / osgfx_guest_crt.c vs map",
            "host plat: oschrome-headless, osmedia-headless, Graphite libskia.a, guest-elf libskia.a",
            "ps: qemu-system-*, sit-in, ninja, gn, cef/skia downloads",
        ],
    }


def write_json(data: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def box(title: str, rows: list[str], width: int = 78) -> list[str]:
    inner = width - 2
    out = [f"┌─ {title} " + "─" * max(0, inner - len(title) - 3) + "┐"]
    for row in rows:
        text = row[:inner]
        out.append("│ " + text.ljust(inner - 1) + "│")
    out.append("└" + "─" * inner + "┘")
    return out


def render_tty(data: dict) -> str:
    cols = shutil.get_terminal_size((80, 24)).columns
    width = max(72, min(110, cols))
    lines = []
    hdr = f"oscortex progress  {data['updated_local']}  (file-backed, not a live feed)"
    lines.append("╔" + "═" * (width - 2) + "╗")
    lines.append("║ " + hdr[: width - 4].ljust(width - 4) + "║")
    lines.append("╚" + "═" * (width - 2) + "╝")

    now = data["now"]
    lines.extend(
        box(
            "NOW",
            [
                now["headline"][: width - 6],
                f"sit-in qemu {'yes' if now['sit_in_qemu'] else 'no'}  wm de {now['wm_de']}  wm gfx {now['wm_gfx']}  osgfx {now['osgfx_kind']}  qemu {now['qemu_n']}",
                f"kernel.elf {now.get('kernel_mtime') or '—'}",
            ],
            width,
        )
    )

    flow_rows = [f"{s['label']:<12} {s['kind']:<12} {s['note'][: width - 28]}" for s in data["flow"]]
    lines.extend(box("Linear flow  GPU → osgfx → Skia → DE → apps → browser → media", flow_rows, width))

    done_rows = [f"{d['id']:<14} {d['note'][: width - 18]}" for d in data["done"][:10]]
    if not done_rows:
        done_rows = ["(none inferred this tick)"]
    lines.extend(box("Done (inferred, not re-run)", done_rows, width))

    left_rows = [f"{x['kind']:<12} {x['id']:<16} {x['note'][: width - 32]}" for x in data["leftovers"][:10]]
    if not left_rows:
        left_rows = ["(no leftover / stub / workaround hole)"]
    lines.extend(box("In flight leftovers", left_rows, width))

    stub_rows = [f"{s['kind']:<12} {s['id']:<20} {s['note'][: width - 36]}" for s in data["stubs"][:8]]
    lines.extend(box("Stubs / dead / withdrawn", stub_rows, width))

    work_rows = [f"{w['kind']:<12} {w['id']:<20} vs {w['vs'][: width - 36]}" for w in data["workarounds"][:8]]
    if not work_rows:
        work_rows = ["(none flagged)"]
    lines.extend(box("Workaround vs real", work_rows, width))

    adr = data["adrs"]
    h = data["harnesses"]
    lines.extend(
        box(
            "Scraped counts",
            [
                f"ADRs {adr['count']}  withdrawn {len(adr['withdrawn'])}  harnesses {h['count']}  PASS-log {h['counts']['PASS']}  FAIL-log {h['counts']['FAIL']}  no-log {h['counts']['harness']}",
                f"shmMax {data['shm'].get('shmMax')}  sit-in FAT {', '.join(data['sitin'].get('fat_names') or []) or '—'}",
            ],
            width,
        )
    )

    if data["processes"]:
        prows = [
            f"{p['pid']:<7} {p['etime']:<10} {p['kind']:<9} {p['command'][: width - 32]}"
            for p in data["processes"][:8]
        ]
    else:
        prows = ["(none of qemu-system-*, curl/wget cef|skia, ninja, gn, sit-in)"]
    lines.extend(box("Host processes", prows, width))
    lines.append("writes core/build/progress.json each tick · canvas is a snapshot of that file")
    lines.append("run: bash core/scripts/watch-progress.sh   ·  open canvases/owner-progress.canvas.tsx")
    return "\n".join(lines)


def patch_canvas(canvas: Path, data: dict) -> None:
    if not canvas.is_file():
        return
    text = canvas.read_text(encoding="utf-8")
    start = "/*PROGRESS_JSON*/"
    end = "/*/PROGRESS_JSON*/"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j <= i:
        return
    payload = json.dumps(data, indent=2)
    new = text[: i + len(start)] + "\n" + payload + "\n" + text[j:]
    canvas.write_text(new, encoding="utf-8")


def main() -> int:
    import argparse

    here = Path(__file__).resolve()
    core = here.parent.parent
    default_canvas = Path(
        "/Users/ghostportal/.cursor/projects/"
        "private-tmp-claude-501-Users-ghostportal-Desktop-dc-sys-"
        "0a8dccfa-95e0-46b8-8be8-f0687b1d2277-scratchpad-COMP/"
        "canvases/owner-progress.canvas.tsx"
    )
    ap = argparse.ArgumentParser(description="Collect oscortex owner-progress status")
    ap.add_argument("--json-only", action="store_true")
    ap.add_argument("--out", default=str(core / "build" / "progress.json"))
    ap.add_argument("--canvas", default=str(default_canvas))
    ap.add_argument("--no-canvas", action="store_true")
    args = ap.parse_args()
    data = collect(core)
    out = Path(args.out)
    write_json(data, out)
    if not args.no_canvas:
        patch_canvas(Path(args.canvas), data)
    if args.json_only:
        print(json.dumps(data, indent=2))
    else:
        print(render_tty(data))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
