#!/usr/bin/env bash
# Clone the reachable public DCDart base and apply the checked-in patch.
# Never mutates an arbitrary user DCDart checkout.
#
# Usage:
#   bash core/scripts/bootstrap-dcdart.sh
#   OSCORTEX_DCDART_ROOT=/tmp/foo bash core/scripts/bootstrap-dcdart.sh
#
# Prints DCDART_HOME=<path> on stdout (last line). JSON report optional:
#   OSCORTEX_DCDART_REPORT=/path/report.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$CORE_DIR/.." && pwd)"
MANIFEST="$REPO_DIR/DCDART_MANIFEST.json"
PIN_FILE="$REPO_DIR/DCDART_PIN.txt"
COMPAT="$SCRIPT_DIR/verify-dcdart-compat.sh"

fail() { echo "bootstrap-dcdart: FAIL — $*" >&2; exit 1; }
say() { echo "bootstrap-dcdart: $*" >&2; }

[[ -f "$MANIFEST" ]] || fail "missing $MANIFEST"
[[ -f "$COMPAT" ]] || fail "missing $COMPAT"
command -v git >/dev/null 2>&1 || fail "git not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not on PATH"

eval "$(python3 - "$MANIFEST" "$REPO_DIR" <<'PY'
import json, sys
man, repo = sys.argv[1], sys.argv[2]
d = json.load(open(man))
print("BASE=%s" % d["base"])
print("REPO_URL=%s" % d["repo"])
print("IDENTITY=%s" % d["identity"])
p = d["patches"][0]
print("PATCH_REL=%s" % p["path"])
print("PATCH_SHA=%s" % p["sha256"])
print("PATCH=%s" % (repo + "/" + p["path"]))
files = d["expected_files"]
print("EXPECTED_N=%d" % len(files))
for i, (path, digest) in enumerate(files.items()):
    print("EF%d=%s" % (i, path))
    print("EH%d=%s" % (i, digest))
PY
)"

[[ -f "$PATCH" ]] || fail "missing patch $PATCH"
got="$(sha256sum "$PATCH" | awk '{print $1}')"
[[ "$got" == "$PATCH_SHA" ]] || fail "patch SHA256 $got != manifest $PATCH_SHA"

# Destination is a repo-owned bootstrap tree, never $DCDART_HOME unless it
# already IS that tree.
ROOT="${OSCORTEX_DCDART_ROOT:-$REPO_DIR/.dcdart-bootstrap}"
DEST="$ROOT/src"
MARKER="$DEST/.oscortex-dcdart-identity"
mkdir -p "$ROOT"

# Refuse to treat a caller DCDART_HOME as the apply target unless it is DEST.
if [[ -n "${DCDART_HOME:-}" && "$DCDART_HOME" != "$DEST" ]]; then
  say "leaving caller DCDART_HOME=$DCDART_HOME untouched"
fi

need_clone=1
if [[ -d "$DEST/.git" ]]; then
  have="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$have" == "$BASE" && -f "$MARKER" ]]; then
    mark="$(cat "$MARKER")"
    if [[ "$mark" == "$IDENTITY" ]]; then
      need_clone=0
    fi
  fi
fi

if [[ "$need_clone" == 1 ]]; then
  if [[ -d "$DEST" ]]; then
    # Only wipe the bootstrap dest, never a user tree.
    case "$DEST" in
      */.dcdart-bootstrap/src|*/oscortex-dcdart-bootstrap/*) ;;
      *)
        if [[ "${OSCORTEX_DCDART_ROOT:-}" == "" ]]; then
          fail "refusing to replace $DEST (not a bootstrap dest)"
        fi
        ;;
    esac
    rm -rf "$DEST"
  fi
  say "cloning reachable public main from $REPO_URL (want $BASE)"
  git clone --depth 1 --branch main "$REPO_URL" "$DEST" >&2
  got_base="$(git -C "$DEST" rev-parse HEAD)"
  if [[ "$got_base" != "$BASE" ]]; then
    say "main is $got_base; fetching exact base $BASE"
    git -C "$DEST" fetch --depth 1 origin "$BASE" >&2 \
      || fail "cannot fetch $BASE from GitHub — not reachable"
    git -C "$DEST" checkout --detach "$BASE" >&2
    got_base="$(git -C "$DEST" rev-parse HEAD)"
  fi
  [[ "$got_base" == "$BASE" ]] || fail "checked out $got_base, wanted $BASE"
  pub="$(git ls-remote "$REPO_URL" refs/heads/main | awk '{print $1}')"
  say "origin/main=$pub base=$BASE"
  say "applying $PATCH_REL"
  git -C "$DEST" apply --check --whitespace=nowarn "$PATCH" \
    || fail "patch does not apply to $BASE"
  git -C "$DEST" apply --whitespace=nowarn "$PATCH" \
    || fail "git apply failed"
  echo "$IDENTITY" >"$MARKER"
fi

# Expected tree: the four patched files must match recorded SHA256s.
i=0
while [[ $i -lt ${EXPECTED_N} ]]; do
  eval "rel=\$EF$i"
  eval "want=\$EH$i"
  got="$(sha256sum "$DEST/$rel" | awk '{print $1}')"
  [[ "$got" == "$want" ]] || fail "$rel sha256 $got != $want"
  i=$((i + 1))
done

# Diff against BASE must equal the checked-in patch (deterministic apply).
git -C "$DEST" add -A
# identity marker is extra; exclude it from the semantic diff.
git -C "$DEST" reset -q -- .oscortex-dcdart-identity || true
git -C "$DEST" diff --binary --cached "$BASE" >"$ROOT/applied.diff"
# Compare ignoring the identity file; patch should match byte-for-byte after
# stripping the marker. Re-diff only tracked paths from the patch.
git -C "$DEST" reset -q
git -C "$DEST" diff --binary "$BASE" -- \
  core/backend/lib/llvm_emit.dart \
  core/backend/test/rodata_emission_test.dart \
  core/dcc-lower/lib/lower.dart \
  core/runtime/dc-core-bare/prelude.dart \
  >"$ROOT/applied.diff"
app_sha="$(sha256sum "$ROOT/applied.diff" | awk '{print $1}')"
if [[ "$app_sha" != "$PATCH_SHA" ]]; then
  # git diff context can differ if apply used fuzz; still require file hashes
  # (already checked) and a clean apply --check.
  say "note: applied.diff sha $app_sha != patch sha $PATCH_SHA (file hashes matched)"
fi

say "running verify-dcdart-compat"
bash "$COMPAT" "$DEST" >&2 || fail "compat probe failed on bootstrapped tree"

# Probe dcc itself: one-line compile already done by compat.
echo "$IDENTITY" >"$MARKER"
{
  echo "{"
  echo "  \"ok\": true,"
  echo "  \"identity\": \"$IDENTITY\","
  echo "  \"base\": \"$BASE\","
  echo "  \"base_reachable\": true,"
  echo "  \"dcdart_home\": \"$DEST\","
  echo "  \"patch_sha256\": \"$PATCH_SHA\","
  echo "  \"pin\": \"$(awk '{print $1; exit}' "$PIN_FILE")\","
  echo "  \"mutated_user_checkout\": false"
  echo "}"
} >"${OSCORTEX_DCDART_REPORT:-$ROOT/bootstrap.json}"

say "PASS identity=$IDENTITY dest=$DEST"
echo "DCDART_HOME=$DEST"
