#!/usr/bin/env bash
# Configure-only linker. Apple ld cannot take ELF objects. FFmpeg
# --disable-programs never links a program; libraries are ar archives.
set -euo pipefail
out=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out="$a"
  fi
  prev="$a"
done
if [[ -n "$out" ]]; then
  : >"$out"
  chmod +x "$out" 2>/dev/null || true
fi
exit 0
