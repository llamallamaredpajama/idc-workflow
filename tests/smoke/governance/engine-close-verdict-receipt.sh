#!/bin/bash
# engine-close-verdict-receipt.sh — governance scenario: the engine's `close` op DENIES a close that
# lacks a validated review-verdict receipt for the linked PR.
#
# The invariant (v4 Phase 2, plan §3.1): close is a guarded terminal op — the machine table declares
# guard `verdict-validated`, so the engine refuses to drive an item to Done unless a verdict JSON that
# passes idc_review_verdict_check.py exists at the supplied --verdict path (a guard evaluated against
# an artifact on disk, NOT a prose claim). This kills the close-with-no-receipt drop class.
#
# Red-when-broken: remove/neuter the verdict guard (idc_transition.check_close_guards → load_verdict)
# → the no-verdict close SUCCEEDS → this scenario FAILs.
#
# Usage: bash tests/smoke/governance/engine-close-verdict-receipt.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
[ -f "$ENGINE" ] || fail "transition engine not found at $ENGINE (not implemented yet)"

T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT
eng() { python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" "$@"; }

n="$(gov_seed_item "$T" --title 'build' --stage Buildable --status 'In Progress')" || fail "seed failed"

# (1) close with NO verdict receipt ⇒ denied; item stays not-Done.
if eng close --num "$n" 2>/dev/null; then
  fail "(1) engine closed an item with NO verdict receipt (guard verdict-validated must deny)"
fi
[ "$(gov_field "$T" "$n" Status)" != "Done" ] || fail "(1) denied close still drove the item to Done"
echo "  ok (1) close with no verdict receipt is denied"

# (2) close with an INVALID verdict (fails idc_review_verdict_check) ⇒ denied.
#     PASS verdict but carrying a major finding → the checker rejects it as inconsistent.
cat > "$REPO/bad-verdict.json" <<JSON
{"verdict":"PASS","pr":9,
 "findings":[{"dimension":"correctness","severity":"major","confidence":0.95,"evidence":"e","attack":"a","unblock":"u","fingerprint":"fp"}]}
JSON
if eng close --num "$n" --verdict "$REPO/bad-verdict.json" --pr 9 2>/dev/null; then
  fail "(2) engine closed on a verdict that fails validation (guard must re-run the checker)"
fi
echo "  ok (2) close on an invalid verdict is denied"

# (3) close with a VALID verdict for the PR ⇒ allowed; item is Done.
cat > "$REPO/good-verdict.json" <<JSON
{"verdict":"PASS","pr":9,"findings":[]}
JSON
eng close --num "$n" --verdict "$REPO/good-verdict.json" --pr 9 >/dev/null 2>&1 \
  || fail "(3) engine denied a close backed by a VALID verdict receipt"
[ "$(gov_field "$T" "$n" Status)" = "Done" ] || fail "(3) valid-verdict close did not drive the item to Done"
echo "  ok (3) close backed by a valid verdict receipt succeeds"

echo "PASS: engine close requires a validated verdict receipt for the linked PR (no receipt / invalid receipt ⇒ denied; valid ⇒ Done)"
