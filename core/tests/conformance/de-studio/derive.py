#!/usr/bin/env python3
"""core/tests/conformance/de-studio/derive.py

Studio2 catalog/geometry lines, plus the DE exhibit (HAVE) and the
hidden idle-line `go` spelling. Not from a guest transcript.

    derive.py <apps.txt> <studio.c>
"""

import os
import subprocess
import sys


if len(sys.argv) != 3:
    raise SystemExit("usage: derive.py <apps.txt> <studio.c>")

here = os.path.dirname(os.path.abspath(__file__))
studio2 = os.path.join(here, "..", "studio2", "derive.py")
apps, studio_c = sys.argv[1], sys.argv[2]
sys.stdout.write(subprocess.check_output(
    [sys.executable, studio2, apps, studio_c], text=True))

catalog = open(apps, "rb").read()
names = [ln.decode("ascii") for ln in catalog.split(b"\n") if ln]
if not names:
    raise SystemExit("derive: planted catalog is empty")

print("have_line=USER WRITE STUDIO2 HAVE %s" % names[0])
print("go_line=GO")
print("go_cmd=go %s" % names[0].lower())
print("go_token=%s" % names[0])
