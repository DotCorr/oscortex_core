#!/usr/bin/env python3
"""core/tests/conformance/de-chrome-cache/keycover.py

    keycover.py <osgfx_session.c> <osgfx_chrome.c>

DERIVES THE CACHE KEY'S CORRECTNESS CONDITION INSTEAD OF ASSERTING A LIST.

A cache is exactly its invalidation condition, and the failure mode of a
chrome cache is not "slow" -- it is a frame on the visible scanout that no
longer corresponds to the compositor's state. That happens the moment
`osgfx_session_paint` starts reading a mailbox word that `chrome_key` does not
fold in. It is a silent failure: nothing crashes, the harness's pixel probes
still pass because the picture is a VALID older picture, and the bug surfaces
months later as "the title bar sometimes doesn't update".

So this does not check that the key contains the eleven words it contains
today. It reads every `cmd->FIELD` the paint touches out of the paint's own
source, reads every `m->FIELD` the key folds out of the key's own source, and
fails if the first set is not a subset of the second. Add a field to the paint
without adding it to the key and this FAILS -- which is the only way a
structural check here is worth running.

Four fields are exempt, and each exemption is a claim that can be wrong:

  * `fb` and `pitch` -- the paint's DESTINATION. Under the cache the paint does
    not write the scanout at all; it writes the cache buffer, and the scanout
    is only ever the blit's target. A scanout that MOVED or changed stride is
    caught by `osgfx_chrome_fresh`'s explicit W/H test and by
    `osgfx_chrome_present`'s `pitch < w * 4` refusal, not by the key.
  * `gen` -- the per-tick counter. It changes on every kick by construction, so
    folding it in would make the key an expensive way to spell "always miss".
  * `magic` -- the mailbox header. `osgfx_guest_tick` refuses a bad magic before
    the paint is reached, so it cannot vary across two ticks that both paint.
  * `pop` -- menu card xy is a scanout overlay (`osgfx_session_blit_menu`).
    Folding it forced a full session MISS on the first click. The paint must
    not read `cmd->pop`; the overlay reads the live mailbox from the tick.

Exit 0 covered, 1 uncovered, 2 could not parse.
"""

import re
import sys

EXEMPT = {"fb", "pitch", "gen", "magic", "pop"}


def fields(path, var):
    """Every `<var>->field` in `path`, as a set of field names."""
    src = open(path, "r", encoding="utf-8").read()
    return set(re.findall(r"\b" + var + r"->([a-z0-9_]+)", src))


def key_body(path):
    """`chrome_key`'s body only.

    Scoped to the function rather than the file so that a `m->win0` in a
    COMMENT elsewhere, or in `chrome_buf`'s size check, cannot be mistaken for
    a fold. The brace counter starts at the opening `{` of the definition.
    """
    src = open(path, "r", encoding="utf-8").read()
    m = re.search(r"static\s+uint64_t\s+chrome_key\s*\([^)]*\)\s*\{", src)
    if not m:
        raise SystemExit("keycover: no chrome_key definition in %s" % path)
    i = m.end()
    depth = 1
    while i < len(src) and depth > 0:
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
        i += 1
    return src[m.end():i]


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    session_c, chrome_c = sys.argv[1], sys.argv[2]

    read = fields(session_c, "cmd")
    if not read:
        print("keycover: FAIL - no `cmd->` reads found in %s; the paint does "
              "not use the mailbox, or this parse is wrong" % session_c,
              file=sys.stderr)
        return 2

    body = key_body(chrome_c)
    folded = set(re.findall(r"\bm->([a-z0-9_]+)", body))
    if not folded:
        print("keycover: FAIL - chrome_key folds no mailbox word",
              file=sys.stderr)
        return 2

    need = read - EXEMPT
    missing = sorted(need - folded)
    if missing:
        print("keycover: FAIL - osgfx_session_paint reads %s but chrome_key "
              "does not fold %s. A cached frame would survive a change to "
              "%s and the screen would be stale."
              % (", ".join(sorted(read)), ", ".join(missing),
                 " and ".join(missing)),
              file=sys.stderr)
        return 1

    # The key may fold MORE than the paint reads and that is not a fault: it
    # costs a false miss, never a stale frame. Reported so the asymmetry is
    # visible rather than accidental.
    extra = sorted(folded - need)
    print("keycover: PASS - %d paint-visible words all folded (%s)%s"
          % (len(need), ", ".join(sorted(need)),
             ("; key also folds " + ", ".join(extra)) if extra else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
