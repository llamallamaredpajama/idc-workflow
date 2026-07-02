#!/bin/bash
# idc-assert-class: behavior
# Phase 7 (update legacy-receipt guard) smoke — fix/update-template-mapping Finding A hardening.
#
# init.md Phase 7 now stamps the two data-bearing configs --customized, so a CURRENT install is
# safe (phase7-update-preserves-data.sh covers that). But a repo installed by a PRE-GUARD plugin
# carries a legacy receipt that marks them `state: stamped` with real domains/field_ids on disk.
# update's plain rule (silently refresh when unchanged + stamped) would clobber that data on the
# first post-upgrade /idc:update. The belt-and-suspenders fix: update ALWAYS show-diff-and-asks for
# these two paths regardless of receipt state. The always-ask set lives in idc_receipt_check.py
# (single source of truth) and is exposed in `verify --json` as "always_ask".
#
# This test builds a legacy (pre-guard) receipt, reads the always-ask set from the helper, replays
# update's CORRECTED silent-refresh rule, and asserts the operator data survives.
# Hermetic: filesystem backend, no GitHub.
#
# Usage: bash tests/smoke/phase7-update-legacy-receipt-guard.sh   (exit 0 = pass)
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

# 2. Inject the operator's real domains into the scaffolded config.
grep -q 'domains: \[\]' "$CFG" || fail "template no longer has 'domains: []' to populate"
tmp="$(mktemp)"; sed "s|domains: \[\]|domains: [\"$SENTINEL\"]|" "$CFG" > "$tmp" && mv "$tmp" "$CFG"
grep -q "$SENTINEL" "$CFG" || fail "could not inject operator domains"

# 3. LEGACY (pre-guard) receipt: the two configs marked state: stamped (NO --customized), as a
#    receipt written before the init.md Phase 7 guard existed would record them.
( cd "$SBX" && python3 "$HELPER" stamp --repo "$SBX" --out "$RECEIPT" --written-by idc:init \
    WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/tracker-config.yaml docs/workflow/README.md \
    docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep ) \
  || fail "legacy stamp exited non-zero"

state_of()     { awk -v p="path: $1" 'index($0,p){f=1} f&&/state:/{print $2; exit}' "$RECEIPT"; }
verify_class() { python3 "$HELPER" verify --repo "$SBX" 2>/dev/null | awk -v p="$1" '$2==p{print $1; exit}'; }

# Confirm the legacy precondition: both configs are stamped (not customized) and unchanged on disk.
[ "$(state_of WORKFLOW-config.yaml)" = "stamped" ] \
  || fail "legacy precondition: WORKFLOW-config.yaml must be state: stamped (got '$(state_of WORKFLOW-config.yaml)')"
[ "$(state_of docs/workflow/tracker-config.yaml)" = "stamped" ] \
  || fail "legacy precondition: tracker-config.yaml must be state: stamped"

# 4. Read the always-ask set from the helper (single source of truth).
always_ask_json="$(python3 "$HELPER" verify --repo "$SBX" --json 2>/dev/null)" \
  || fail "verify --json exited non-zero"
in_always_ask() { printf '%s' "$always_ask_json" | python3 -c '
import json,sys
data=json.load(sys.stdin); aa=set(data.get("always_ask",[]))
sys.exit(0 if sys.argv[1] in aa else 1)' "$1"; }

in_always_ask WORKFLOW-config.yaml \
  || fail "WORKFLOW-config.yaml must be in verify --json always_ask (A-hardening not wired in idc_receipt_check.py)"
in_always_ask docs/workflow/tracker-config.yaml \
  || fail "docs/workflow/tracker-config.yaml must be in verify --json always_ask"

# 5. update's CORRECTED rule: silently refresh ONLY when unchanged AND stamped AND not always-ask.
silently_refreshable() {
  [ "$(verify_class "$1")" = "unchanged" ] && [ "$(state_of "$1")" = "stamped" ] && ! in_always_ask "$1"
}

# 6. Replay update Phase 2 and assert the operator's domains survive (legacy receipt notwithstanding).
if silently_refreshable WORKFLOW-config.yaml; then
  cp "$PLUGIN/templates/WORKFLOW-config.yaml" "$CFG"   # this would be the data loss
fi
grep -q "$SENTINEL" "$CFG" || fail "legacy-receipt guard failed: operator domains wiped by a silent refresh (Finding A)"

# 7. Control: a genuine pristine template file (WORKFLOW.md, not always-ask) IS silently-refreshable —
#    proving the guard is targeted at the data-bearing configs, not blocking all refreshes.
silently_refreshable WORKFLOW.md \
  || fail "control: a pristine non-data template file (WORKFLOW.md) should still be silently-refreshable"

echo "PASS: /idc:update always-asks for data-bearing configs even with a legacy state: stamped receipt"
