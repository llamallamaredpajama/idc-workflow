#!/bin/bash
# idc-assert-class: behavior
# Phase 7 (update unrecorded-file detection) smoke — the 4.0.0 migration gap the U6 update-sandbox
# e2e caught: a receipt written by an OLDER plugin version does not list files a NEWER version
# scaffolds (a 3.x receipt has no docs/workflow/workflow-machine.yaml), and a verify that
# classifies only receipt entries never surfaces them — so /idc:update's §B "a missing copy is
# restored" promise was unreachable and the drift contract read ok:true while the migration was
# incomplete. verify --json must emit those paths in "unrecorded" so Phase 1 routes them.
#
# Hermetic: temp repo + real receipt stamp/verify against the real templates dir; no GitHub.
#
# Usage: bash tests/smoke/phase7-update-unrecorded-files.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_receipt_check.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "receipt helper not found at $HELPER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs/workflow"

# Seed a pre-4.0.0-shaped repo: the old stamped set WITHOUT workflow-machine.yaml.
printf 'w\n' > "$WORK/WORKFLOW.md"
printf 'c\n' > "$WORK/WORKFLOW-config.yaml"
printf 't\n' > "$WORK/docs/workflow/tracker-config.yaml"
python3 "$HELPER" stamp --repo "$WORK" --out "$WORK/docs/workflow/install-receipt.yaml" \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml >/dev/null \
  || fail "could not stamp the old-version receipt"

out="$(python3 "$HELPER" verify --repo "$WORK" --json)" || fail "verify exited non-zero"

# 1. The new-in-4.0.0 machine table must surface as unrecorded (it is governed: the template
#    exists in this plugin) — this is the red-when-broken core: remove the unrecorded
#    computation and this fails.
echo "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
u = o.get("unrecorded")
ok = o.get("ok")
assert isinstance(u, list), f"unrecorded key missing or not a list: {u!r}"
assert "docs/workflow/workflow-machine.yaml" in u, f"workflow-machine.yaml not in unrecorded: {u}"
# 2. ok stays a modified+missing contract (back-compat): nothing modified/missing here.
assert ok is True, f"ok must stay modified+missing-based, got {ok!r}"
# 3. Receipt-listed files must never appear unrecorded.
assert "WORKFLOW.md" not in u, f"receipt-listed WORKFLOW.md wrongly unrecorded: {u}"
' || fail "unrecorded detection assertions failed: $out"

# 4. Closing the loop: once the file exists and a fresh (4.0.0) stamp records it, unrecorded
#    must empty for it — the post-update drift contract is truthful again.
cp "$PLUGIN/templates/workflow-machine.yaml" "$WORK/docs/workflow/workflow-machine.yaml" \
  || fail "could not lay down the machine template"
python3 "$HELPER" stamp --repo "$WORK" --out "$WORK/docs/workflow/install-receipt.yaml" \
  --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
  WORKFLOW.md WORKFLOW-config.yaml docs/workflow/tracker-config.yaml \
  docs/workflow/workflow-machine.yaml >/dev/null || fail "could not re-stamp with the machine file"
out2="$(python3 "$HELPER" verify --repo "$WORK" --json)" || fail "post-restamp verify exited non-zero"
echo "$out2" | python3 -c '
import json, sys
o = json.load(sys.stdin)
u = o.get("unrecorded", [])
assert "docs/workflow/workflow-machine.yaml" not in u, \
    f"machine file still unrecorded after being stamped: {u}"
' || fail "post-restamp unrecorded assertions failed: $out2"

# 5. TSV output stays free of unrecorded rows (uninstall consumes TSV as its removal manifest —
#    a never-stamped file must not enter it).
tsv="$(python3 "$HELPER" verify --repo "$WORK" 2>/dev/null)" || fail "TSV verify exited non-zero"
echo "$tsv" | grep -q "unrecorded" && fail "TSV output must not carry unrecorded rows: $tsv"

echo "PASS: phase7-update-unrecorded-files"
exit 0
