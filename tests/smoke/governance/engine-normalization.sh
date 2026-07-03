#!/bin/bash
# engine-normalization.sh — governance scenario: NO engine op can yield a Stage set without a Status
# (the #255/#256 bug class dies at the single write door).
#
# The invariant (v4 Phase 2, plan §3.1): every op is normalized — an item with a Stage but an empty
# Status is an illegal shape the engine refuses to write, and the post-op read-back re-checks it.
#
# Two halves, both red-when-broken:
#   (A) UNIT — idc_transition.assert_normalized rejects (Stage set, Status empty) and accepts the
#       legal shapes (both set; or neither set = not-yet-staged). Neuter assert_normalized → (A) FAILs.
#   (B) END-TO-END — a real create op (recirculate-intake → Stage=Recirculation) always reads back a
#       non-empty Status. Break the backend/read-back so a blank Status could survive → (B) FAILs.
#
# Usage: bash tests/smoke/governance/engine-normalization.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
[ -f "$ENGINE" ] || fail "transition engine not found at $ENGINE (not implemented yet)"

# ── (A) UNIT: assert_normalized ────────────────────────────────────────────────────────────────
python3 - "$GOV_PLUGIN/scripts" <<'PY' || fail "(A) assert_normalized unit assertions failed"
import sys
sys.path.insert(0, sys.argv[1])
import idc_transition as E

# Illegal: Stage set, Status empty → must raise.
try:
    E.assert_normalized("Recirculation", "")
    print("FAIL: assert_normalized accepted Stage-without-Status (#255/#256 shape)"); sys.exit(1)
except E.TransitionError:
    pass
# Legal: both set.
E.assert_normalized("Recirculation", "Todo")
# Legal: neither set (an item not yet staged is fine — the bug is Stage WITHOUT Status).
E.assert_normalized("", "")
print("  ok (A) assert_normalized rejects Stage-without-Status, accepts both-set and neither-set")
PY

# ── (B) END-TO-END: a create op always reads back a non-empty Status ────────────────────────────
T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT

n="$(python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" \
       recirculate-intake --title 'nit' --body 'Stage: Recirculation')" \
  || fail "(B) recirculate-intake op failed"
[ -n "$n" ] || fail "(B) create returned an empty issue number"
[ "$(gov_field "$T" "$n" Stage)" = "Recirculation" ] || fail "(B) Stage did not round-trip to Recirculation"
st="$(gov_field "$T" "$n" Status)"
[ -n "$st" ]      || fail "(B) create left an EMPTY Status with a set Stage (#255/#256 shape)"
[ "$st" = "Todo" ] || fail "(B) create Status was '$st', expected Todo"
echo "  ok (B) recirculate-intake reads back Stage=Recirculation with a non-empty Status (Todo)"

echo "PASS: no engine op yields a Stage without a Status — assert_normalized rejects the shape and the create read-back confirms it"
