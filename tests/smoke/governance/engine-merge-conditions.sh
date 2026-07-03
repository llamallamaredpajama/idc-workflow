#!/bin/bash
# engine-merge-conditions.sh — governance scenario: the engine's `close` guard honors the verdict's
# merge_conditions[] — Done is blocked while any condition is unmet.
#
# The invariant (v4 Phase 2, plan §3.1 / §3.3): idc_review_verdict_check.py gained a
# backward-compatible merge_conditions[] (each {id, description, met}); the engine's close guard
# `merge-conditions-met` blocks close while any entry's `met` is not true. This closes the
# silently-downgraded pre-merge-condition failure (#246 -> #248) — a review that says "merge only
# after X" can no longer be closed before X is satisfied.
#
# Red-when-broken: neuter idc_transition.unmet_merge_conditions / the merge-conditions-met guard →
# the unmet-condition close SUCCEEDS → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-merge-conditions.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
[ -f "$ENGINE" ] || fail "transition engine not found at $ENGINE (not implemented yet)"

T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT
eng() { python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" "$@"; }

# Backward-compat first: a verdict WITHOUT merge_conditions still validates (absent ⇒ no conditions).
cat > "$REPO/v-plain.json" <<JSON
{"verdict":"PASS","pr":9,"findings":[]}
JSON
python3 "$CHECK" "$REPO/v-plain.json" >/dev/null 2>&1 \
  || fail "(compat) a verdict with no merge_conditions no longer validates (broke backward compat)"
echo "  ok (compat) verdict without merge_conditions still validates"

# (1) verdict with an UNMET merge_condition ⇒ close denied.
n1="$(gov_seed_item "$T" --title 'build1' --stage Buildable --status 'In Progress')" || fail "seed failed"
cat > "$REPO/v-unmet.json" <<JSON
{"verdict":"PASS-WITH-NITS","pr":10,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,"evidence":"e","attack":"a","unblock":"u","fingerprint":"fp1"}],
 "merge_conditions":[{"id":"ci-green","description":"CI must be green before merge","met":false}]}
JSON
python3 "$CHECK" "$REPO/v-unmet.json" >/dev/null 2>&1 || fail "(1) the unmet-condition verdict is itself malformed"
if eng close --num "$n1" --verdict "$REPO/v-unmet.json" --pr 10 2>/dev/null; then
  fail "(1) engine closed while a merge_condition was unmet (guard merge-conditions-met must deny)"
fi
[ "$(gov_field "$T" "$n1" Status)" != "Done" ] || fail "(1) denied close still drove the item to Done"
echo "  ok (1) close is blocked while a merge_condition is unmet"

# (2) same verdict with the condition MET ⇒ close allowed.
n2="$(gov_seed_item "$T" --title 'build2' --stage Buildable --status 'In Progress')" || fail "seed failed"
cat > "$REPO/v-met.json" <<JSON
{"verdict":"PASS-WITH-NITS","pr":10,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,"evidence":"e","attack":"a","unblock":"u","fingerprint":"fp1"}],
 "merge_conditions":[{"id":"ci-green","description":"CI must be green before merge","met":true}]}
JSON
eng close --num "$n2" --verdict "$REPO/v-met.json" --pr 10 >/dev/null 2>&1 \
  || fail "(2) engine denied close even though every merge_condition was met"
[ "$(gov_field "$T" "$n2" Status)" = "Done" ] || fail "(2) all-conditions-met close did not drive the item to Done"
echo "  ok (2) close is allowed once every merge_condition is met"

echo "PASS: engine close honors verdict merge_conditions[] — unmet blocks Done, all-met allows it (backward-compatible when absent)"
