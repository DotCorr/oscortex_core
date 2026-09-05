#!/usr/bin/env python3
"""Restage Round 39 shots + overview + matrix on the exact leftover."""

import importlib.util
import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


p39 = load("p39", os.path.join(HERE, "prove-round39.py"))
d15 = p39.d15
m36 = p39.m36
ART = os.environ.get("ARTIFACTS_DIR", "/opt/cursor/artifacts")
RUN = os.environ.get("DRIVE_RUN", "/workspace/core/build/daily-drive-r39")


def main():
    q = d15.Qmp(int(open(os.path.join(RUN, "qmp.port")).read()))
    ser = d15.Serial(os.path.join(RUN, "serial.txt"),
                     int(open(os.path.join(RUN, "serial.port")).read()))
    p39.dismiss(q)
    time.sleep(0.08)
    log = []
    for cap in p39.NEED_FIRST:
        p39.ensure_stem(q, ser, cap, log)
    p39.ensure_tap_last(q, ser, log)
    p39.dismiss(q)
    time.sleep(0.08)
    info = p39.live_from(p39.harvest(ser))
    if info.get("tap_slots"):
        info = p39.raise_tap(q, ser, info["tap_slots"][0])
        time.sleep(0.12)
    shot16 = p39.shot(q, ser, "oscortex-round39-all-six-apps.png")
    p39.dismiss(q)
    time.sleep(0.06)
    p39.fire_overview(q)
    time.sleep(0.28)
    for _ in range(4):
        try:
            m36.qcode_edge(q, "tab", True)
            m36.qcode_edge(q, "tab", False)
        except Exception:
            pass
        time.sleep(0.05)
    shot_ov = p39.shot(q, ser, "oscortex-round39-overview-16.png")
    p39.dismiss(q)
    time.sleep(0.08)
    shot_tok = p39.shot(q, ser, "oscortex-round39-atomic-tokens.png")
    matrix = {}
    info = p39.live_from(p39.harvest(ser))
    for cap in p39.STEMS:
        slots = [w for w in info["ordinary_slots"]
                 if info["windows"].get(w, {}).get("cap") == cap]
        if not slots:
            matrix[p39.CAP_NAME[cap]] = {"ok": False, "missing": True}
            continue
        ev = p39.interact_slot(q, ser, slots[0])
        matrix[p39.CAP_NAME[cap]] = ev
        info = p39.live_from(p39.harvest(ser))
    after = p39.harvest(ser)
    after_info = p39.live_from(after)
    ok_vis, rejected = p39.tok.harvest_vis(after)
    stems = set(after_info.get("stem_live") or [])
    overview = ("WM SWITCH SHOW" in after or "DESK SWITCH" in after
                or "WM KEY 57" in after)
    tap_last = bool(after_info.get("tap_slots")) and len(after_info["ordinary_slots"]) >= 15
    payload = {
        "round": 39,
        "restage": True,
        "live": {
            "ordinary_slots": after_info["ordinary_slots"],
            "captions": after_info["captions"],
            "stem_live": after_info.get("stem_live"),
            "unique_geoms": after_info["unique_geoms"],
            "tap_slots": after_info.get("tap_slots"),
            "overlay_slots": after_info["overlay_slots"],
        },
        "six_ok": stems == set(p39.STEMS) or set(stems) >= {1, 2, 3, 4, 5, 6},
        "tap_last": tap_last,
        "overview_show": overview,
        "action_matrix": {
            k: {kk: vv for kk, vv in ev.items() if kk != "tokens"}
            for k, ev in matrix.items()
        },
        "matrix_ok": all((matrix.get(p39.CAP_NAME[c]) or {}).get("ok")
                         for c in p39.STEMS),
        "tokens": {"vis_ok": len(ok_vis), "rejected": rejected,
                   "pass": rejected.get("malformed", 0) == 0
                   and rejected.get("checksum", 0) == 0
                   and rejected.get("interleaved", 0) == 0
                   and len(ok_vis) >= 8},
        "shots": {"all_six": shot16, "overview": shot_ov, "tokens": shot_tok},
        "fault": after.count("FAULT "),
        "oom": after.count("OSGFX OOM"),
        "reap": after.count("REAP "),
    }
    payload["pass"] = (
        payload["six_ok"] and payload["tap_last"] and payload["overview_show"]
        and payload["tokens"]["pass"] and payload["fault"] == 0
        and len(after_info["ordinary_slots"]) >= 15)
    dest = os.path.join(ART, "oscortex-round39-apps.json")
    open(dest, "w").write(json.dumps(payload, indent=2) + "\n")
    print(json.dumps({
        "ordinary": after_info["ordinary_slots"],
        "stems": after_info.get("stem_live"),
        "tap": after_info.get("tap_slots"),
        "six_ok": payload["six_ok"],
        "tap_last": tap_last,
        "overview": overview,
        "matrix": {k: ev.get("ok") for k, ev in matrix.items()},
        "token_ok": payload["tokens"]["pass"],
        "pass": payload["pass"],
    }, indent=2))
    return 0 if payload["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
