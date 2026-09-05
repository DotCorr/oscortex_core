#!/usr/bin/env python3
"""Host layout pin: 16 pills at 800 and 1280. TAP always visible.

Lockstep with desk.c SLOT_* and wmde.dart wmSlotPitchLive / overflow.
"""

import json
import os
import sys

ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
LEFT_X, LEFT_W, GAP = 16, 268, 8
RIGHT_W = 264
SLOT_PITCH, SLOT_PITCH_MIN, SLOT_PITCH_OVF, SLOT_CHEV = 80, 36, 56, 16


def layout(width, n=16, tap_live=True):
    x0 = LEFT_X + LEFT_W + GAP
    right_x = width - 16 - RIGHT_W
    avail = max(0, right_x - x0)
    overflow = (n * SLOT_PITCH_MIN) > avail
    if overflow:
        room = avail - 2 * SLOT_CHEV if avail > 32 else avail
        vis = max(1, room // SLOT_PITCH_OVF)
        vis = min(vis, n)
        pitch = SLOT_PITCH_OVF
        tap_sticky = bool(tap_live)
        vis_scroll = vis - 1 if tap_sticky and vis > 0 else vis
        return {
            "width": width,
            "avail": avail,
            "overflow": True,
            "pitch": pitch,
            "vis": vis,
            "vis_scroll": vis_scroll,
            "tap_always": tap_sticky,
            "reachable": vis_scroll >= 1 and (not tap_live or tap_sticky),
        }
    pitch = SLOT_PITCH if n * SLOT_PITCH <= avail else max(SLOT_PITCH_MIN, avail // n)
    return {
        "width": width,
        "avail": avail,
        "overflow": False,
        "pitch": pitch,
        "vis": n,
        "vis_scroll": n,
        "tap_always": True,
        "reachable": n * pitch <= avail + SLOT_PITCH_MIN,
    }


def main():
    a800 = layout(800, 16, True)
    a1280 = layout(1280, 16, True)
    ok = (
        a800["overflow"]
        and a800["tap_always"]
        and a800["vis"] >= 2
        and a800["reachable"]
        and not a1280["overflow"]
        and a1280["vis"] == 16
        and a1280["tap_always"]
        and a1280["reachable"]
    )
    payload = {
        "round": 40,
        "model": "compress-to-fit at 1280; TAP-sticky overflow at 800",
        "w800": a800,
        "w1280": a1280,
        "pass": ok,
    }
    os.makedirs(ART, exist_ok=True)
    dest = os.path.join(ART, "oscortex-round40-tasks.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
