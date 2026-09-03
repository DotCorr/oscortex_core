"""Resolve a writable artifacts directory without smashing platform paths."""

from __future__ import annotations

import os
import shutil
import sys


def resolve_artifacts(prefer=None, fallback=None):
    """Return (path, warning). Never deletes a symlink at prefer."""
    prefer = prefer or os.environ.get("ARTIFACTS_DIR") or "/opt/cursor/artifacts"
    if fallback is None:
        here = os.path.dirname(os.path.abspath(__file__))
        fallback = os.path.join(os.path.dirname(here), "build", "artifacts")

    def writable(d):
        if not os.path.isdir(d):
            return False
        probe = os.path.join(d, ".artifacts-write-test.%d" % os.getpid())
        try:
            with open(probe, "wb") as fh:
                fh.write(b"ok")
            os.remove(probe)
            return True
        except OSError:
            try:
                os.remove(probe)
            except OSError:
                pass
            return False

    if writable(prefer):
        return prefer, ""
    if os.path.islink(prefer):
        warn = "%s is a symlink and is not writable; using %s" % (prefer, fallback)
    elif os.path.exists(prefer):
        warn = "%s exists but is not writable; using %s" % (prefer, fallback)
    else:
        try:
            os.makedirs(prefer, exist_ok=True)
        except OSError:
            warn = "cannot create %s; using %s" % (prefer, fallback)
        else:
            if writable(prefer):
                return prefer, ""
            warn = "cannot create %s; using %s" % (prefer, fallback)
    os.makedirs(fallback, exist_ok=True)
    if not writable(fallback):
        raise SystemExit("artifacts: fallback %s is not writable" % fallback)
    return fallback, warn


def write_bytes(path, data, also=None):
    """Write data to path; if that fails and also is set, copy there."""
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path
    except OSError as exc:
        if not also:
            raise
        os.makedirs(os.path.dirname(also) or ".", exist_ok=True)
        with open(also, "wb") as fh:
            fh.write(data)
        print("WARN: wrote fallback copy %s (%s)" % (also, exc), file=sys.stderr)
        return also


def copy_file(src, dest, also=None):
    try:
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        shutil.copy2(src, dest)
        return dest
    except OSError as exc:
        if not also:
            raise
        os.makedirs(os.path.dirname(also) or ".", exist_ok=True)
        shutil.copy2(src, also)
        print("WARN: copied fallback %s (%s)" % (also, exc), file=sys.stderr)
        return also
