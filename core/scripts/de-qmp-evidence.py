#!/usr/bin/env python3
"""Capture deterministic DE interaction screenshots from a live sit-in QEMU.

This helper is intentionally small and dependency-free.  The public entrypoint
is verify-de-mac.sh; running this file directly is useful only for debugging.
"""

import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path


class Qmp:
    def __init__(self, port: int):
        deadline = time.time() + 20
        sock = None
        while time.time() < deadline:
            try:
                sock = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                time.sleep(0.2)
        if sock is None:
            raise RuntimeError(f"cannot connect to QMP on 127.0.0.1:{port}")
        sock.settimeout(15)
        self.sock = sock
        self.file = sock.makefile("rw", encoding="utf-8", newline="\n")
        greeting = self._read()
        if "QMP" not in greeting:
            raise RuntimeError(f"unexpected QMP greeting: {greeting!r}")
        self.command("qmp_capabilities")

    def _read(self):
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError("QMP connection closed")
            message = json.loads(line)
            if "event" not in message:
                return message

    def command(self, name, **arguments):
        request = {"execute": name}
        if arguments:
            request["arguments"] = arguments
        self.file.write(json.dumps(request) + "\n")
        self.file.flush()
        reply = self._read()
        if "error" in reply:
            raise RuntimeError(f"{name}: {reply['error']}")
        return reply.get("return")

    def close(self):
        self.file.close()
        self.sock.close()


def serial_bytes(path: Path) -> bytes:
    try:
        return path.read_bytes().replace(b"\0", b"")
    except FileNotFoundError:
        return b""


def marker_count(path: Path, marker: str) -> int:
    return serial_bytes(path).count(marker.encode("ascii"))


def wait_new_marker(path: Path, marker: str, old_count: int, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if marker_count(path, marker) > old_count:
            return True
        time.sleep(0.1)
    return False


class Driver:
    def __init__(self, qmp: Qmp, width: int, height: int):
        self.qmp = qmp
        self.width = width
        self.height = height

    def _axis(self, value: int, extent: int) -> int:
        value = min(max(value, 0), extent - 1)
        return value * 32767 // max(1, extent - 1)

    def move(self, x: int, y: int):
        self.qmp.command(
            "input-send-event",
            events=[
                {"type": "abs", "data": {"axis": "x", "value": self._axis(x, self.width)}},
                {"type": "abs", "data": {"axis": "y", "value": self._axis(y, self.height)}},
            ],
        )

    def button(self, button: str, down: bool):
        self.qmp.command(
            "input-send-event",
            events=[{"type": "btn", "data": {"button": button, "down": down}}],
        )

    def click(self, x: int, y: int, button: str = "left"):
        self.move(x, y)
        time.sleep(0.12)
        self.button(button, True)
        time.sleep(0.10)
        self.button(button, False)
        time.sleep(0.5)

    def drag(self, start, end, steps: int = 10):
        self.move(*start)
        time.sleep(0.12)
        self.button("left", True)
        time.sleep(0.12)
        for index in range(1, steps + 1):
            x = start[0] + (end[0] - start[0]) * index // steps
            y = start[1] + (end[1] - start[1]) * index // steps
            self.move(x, y)
            time.sleep(0.07)
        self.button("left", False)
        time.sleep(0.7)

    def screenshot(self, path: Path):
        self.qmp.command("screendump", filename=str(path.resolve()), format="png")
        deadline = time.time() + 10
        while time.time() < deadline:
            if path.is_file() and path.stat().st_size > 0:
                return
            time.sleep(0.1)
        raise RuntimeError(f"screendump did not create {path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--serial", type=Path, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    rows = []
    failures = 0
    qmp = Qmp(args.port)
    driver = Driver(qmp, args.width, args.height)

    def run(name, screenshot_name, operation=None, marker=None, timeout=20):
        nonlocal failures
        before = marker_count(args.serial, marker) if marker else 0
        status = "PASS"
        detail = ""
        try:
            if operation:
                operation()
            if marker and not wait_new_marker(args.serial, marker, before, timeout):
                raise RuntimeError(f"serial did not emit a new {marker!r}")
            time.sleep(0.5)
            shot = args.output / screenshot_name
            driver.screenshot(shot)
            detail = str(shot)
            print(f"de-qmp-evidence: PASS {name}: {shot}")
        except Exception as exc:  # continue to preserve later evidence
            status = "FAIL"
            failures += 1
            detail = str(exc)
            print(f"de-qmp-evidence: FAIL {name}: {exc}", file=sys.stderr)
        rows.append((name, status, detail))

    # sit-in-view performs its own Start-click input proof before returning.
    # This is the baseline before this runner's interaction sequence.
    run("baseline", "00-before-runner-interactions.png")

    def pointer_sweep():
        points = [
            (args.width // 2, args.height // 2),
            (args.width - 80, 100),
            (80, 120),
            (args.width - 100, args.height - 100),
            (args.width // 2, args.height // 2),
        ]
        for point in points:
            driver.move(*point)
            time.sleep(0.18)

    run("pointer-sweep", "01-after-pointer-sweep.png", pointer_sweep)

    # Empty desk, clear of the fixed 48,40 400x280 FILES geometry.
    menu_x = min(args.width - 140, 600)
    menu_y = min(args.height - 180, 350)
    run(
        "wall-menu-open",
        "02-after-menu-open.png",
        lambda: driver.click(menu_x, menu_y, "right"),
        "WM WALL MENU",
    )
    run(
        "wall-menu-regen",
        "03-after-menu-action.png",
        lambda: driver.click(menu_x + 20, menu_y + 8 + 12),
        "WM WALL REGEN ",
    )

    # DESK owns the strip, so Start is the 244..280 hamburger. The first
    # launch row is FILES.ELF at y=(height-48-80)+4+10.
    def launch_files():
        driver.click(262, args.height - 24)
        time.sleep(0.5)
        driver.click(80, args.height - 48 - 80 + 14)

    run(
        "launch-files",
        "04-after-app-launch.png",
        launch_files,
        "FILES READY",
        timeout=35,
    )

    # FILES starts at 48,40 and is 400x280. Keep title grab left of controls.
    # The resulting origin is 148,94.
    run(
        "title-drag",
        "05-after-title-drag.png",
        lambda: driver.drag((120, 56), (220, 110)),
        "WM MOVE W ",
    )

    # Resize the moved FILES window from its SE corner, shrinking enough to
    # expose a meaningful vacated region while staying above minimum geometry.
    run(
        "corner-resize",
        "06-after-corner-resize.png",
        lambda: driver.drag((547, 373), (507, 343)),
        "WM RESIZE W ",
    )

    # There is no maximise operation in the current display protocol. Exercise
    # the implemented minimise control; record maximise honestly as unavailable.
    run(
        "window-minimise",
        "07-after-window-minimise.png",
        lambda: driver.click(505, 103),
        "WM MIN W ",
    )
    rows.append(
        (
            "window-maximise",
            "SKIP",
            "not implemented: display-protocol.md explicitly has no maximise command",
        )
    )
    print("de-qmp-evidence: SKIP window-maximise: operation is not implemented")
    run("final-visible", "08-final-visible.png")

    qmp.close()
    args.results.parent.mkdir(parents=True, exist_ok=True)
    with args.results.open("w", encoding="utf-8") as output:
        output.write("interaction\tstatus\tdetail\n")
        for row in rows:
            output.write("\t".join(value.replace("\t", " ") for value in row) + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"de-qmp-evidence: FAIL — {exc}", file=sys.stderr)
        raise SystemExit(2)
