#!/bin/bash
# Phase 7 (update data-loss guard) smoke — audit F8.
#
# /idc:init writes real operator/board data into two scaffold files AFTER copying the template:
#   - WORKFLOW-config.yaml          (the derived `domains:` list)
#   - docs/workflow/tracker-config.yaml (project_number + board field_ids node IDs)
# If init stamps them `state: stamped`, /idc:update Phase 1 classifies them "unchanged +
# state: stamped" = pristine and Phase 2 silently overwrites them from the template, wiping the
# operator's domains / board wiring. The fix: init stamps them `state: customized`, which routes
# them to update's show-diff-and-ask instead.
#
# This test runs the REAL scaffold helper, simulates init's domain-write + the prescribed stamp,
# then faithfully replays update's silent-refresh rule and asserts the operator data survives.
# Hermetic: filesystem backend, no GitHub.
#
# Usage: bash tests/smoke/phase7-update-preserves-data.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_receipt_check.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "receipt helper not found at $HELPER"

# 1. Scaffold a filesystem repo with the real init scaffold helper.
bash "$PLUGIN/scripts/idc_init_scaffold.sh" "$PLUGIN" "$SBX" "TestProj" filesystem >/dev/null \
  || fail "scaffold helper exited non-zero"

CFG="$SBX/WORKFLOW-config.yaml"
RECEIPT="$SBX/docs/workflow/install-receipt.yaml"
SENTINEL="alpha-domain-sentinel"

# 2. Simulate init Phase 3's agent step: write derived domains into WORKFLOW-config.yaml.
#    (inline flow-list keeps the test sed portable across BSD/GNU — no newline in replacement)
grep -q 'domains: \[\]' "$CFG" || fail "template no longer has 'domains: []' to populate"
tmp="$(mktemp)"; sed "s|domains: \[\]|domains: [\"$SENTINEL\"]|" "$CFG" > "$tmp" && mv "$tmp" "$CFG"
grep -q "$SENTINEL" "$CFG" || fail "could not inject operator domains"

# 3. Stamp exactly as commands/init.md Phase 7 now prescribes: the two operator-data files
#    flagged --customized, the rest plain.
( cd "$SBX" && python3 "$HELPER" stamp --repo "$SBX" --out "$RECEIPT" --written-by idc:init \
    --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
    WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/tracker-config.yaml docs/workflow/README.md \
    docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep ) \
  || fail "stamp exited non-zero"

# literal-substring lookups (no regex) for the receipt state + verify class of a path
state_of()    { awk -v p="path: $1" 'index($0,p){f=1} f&&/state:/{print $2; exit}' "$RECEIPT"; }
verify_class() { python3 "$HELPER" verify --repo "$SBX" 2>/dev/null | awk -v p="$1" '$2==p{print $1; exit}'; }
# update Phase 1 rule: a file is silently overwritten ONLY when unchanged AND state: stamped.
silently_refreshable() { [ "$(verify_class "$1")" = "unchanged" ] && [ "$(state_of "$1")" = "stamped" ]; }

# 4. The fix: both operator-data files are state: customized; ordinary template files are stamped.
[ "$(state_of WORKFLOW-config.yaml)" = "customized" ] \
  || fail "WORKFLOW-config.yaml must be state: customized (got '$(state_of WORKFLOW-config.yaml)')"
[ "$(state_of docs/workflow/tracker-config.yaml)" = "customized" ] \
  || fail "tracker-config.yaml must be state: customized (got '$(state_of docs/workflow/tracker-config.yaml)')"
[ "$(state_of WORKFLOW.md)" = "stamped" ] \
  || fail "WORKFLOW.md must stay state: stamped (got '$(state_of WORKFLOW.md)')"

# 5. Faithfully replay /idc:update Phase 2 (silent refresh of pristine files) and assert the
#    operator's domains survive — because the customized file is NOT silently-refreshable.
if silently_refreshable WORKFLOW-config.yaml; then
  cp "$PLUGIN/templates/WORKFLOW-config.yaml" "$CFG"   # this would be the data loss
fi
grep -q "$SENTINEL" "$CFG" || fail "operator domains were wiped by a silent update refresh (F8)"
# control: a genuine pristine template file IS silently-refreshable (else the test proves nothing).
silently_refreshable WORKFLOW.md \
  || fail "a pristine template file (WORKFLOW.md) should be silently-refreshable (control)"

# 6. Negative control — without --customized the data loss returns, proving the flag is what
#    protects the file (guards against a silent revert of the init.md Phase 7 change).
tmp="$(mktemp)"; sed "s|domains: \[\]|domains: [\"$SENTINEL\"]|" "$PLUGIN/templates/WORKFLOW-config.yaml" > "$tmp" && mv "$tmp" "$CFG"
( cd "$SBX" && python3 "$HELPER" stamp --repo "$SBX" --out "$RECEIPT" --written-by idc:init \
    WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/tracker-config.yaml docs/workflow/README.md \
    docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep ) \
  || fail "re-stamp (no --customized) exited non-zero"
silently_refreshable WORKFLOW-config.yaml \
  || fail "without --customized, WORKFLOW-config.yaml must be silently-refreshable (else the test can't catch the bug)"
cp "$PLUGIN/templates/WORKFLOW-config.yaml" "$CFG"   # update would overwrite it...
grep -q "$SENTINEL" "$CFG" && fail "negative control: domains should have been wiped without --customized"

echo "PASS: init stamps operator-data files customized → /idc:update can't silently wipe domains/field_ids"
