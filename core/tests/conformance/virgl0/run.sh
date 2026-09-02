#!/usr/bin/env bash
# G10 lives at tests/conformance/g10-virgl/. This name stays so ADR-0098
# and older notes still resolve.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../g10-virgl" && pwd)/run.sh"
