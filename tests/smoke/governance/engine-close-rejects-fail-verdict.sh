#!/bin/bash
# engine-close-rejects-fail-verdict.sh — governance scenario: the close guard requires a PASSING
# verdict disposition, not merely a schema-valid one.
#
# The gap this closes (PR #133 review MAJOR-2): a well-formed FAIL / FAIL-BLOCKED verdict passed
# idc_review_verdict_check.py (it is structurally valid) and the engine drove the item to Done — a
# failed review must be FIXED, never closed. The close guard now rejects any disposition outside
# idc_review_verdict_check.PASSING (PASS / PASS-WITH-NITS).
#
# Red-when-broken: neuter the disposition check in idc_transition.check_close_guards → the FAIL
# close SUCCEEDS → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-close-rejects-fail-verdict.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
git -C "$REPO" init -q -b main >/dev/null 2>&1
mkdir -p "$REPO/docs/workflow/code-reviews"

n1="$(gov_seed_item "$T" --title 'build1' --stage Buildable --status 'In Progress')" || fail "seed failed"
# A WELL-FORMED FAIL verdict (a major finding ⇒ verdict=FAIL — this is schema-VALID, unlike the
# inconsistent verdict in engine-close-verdict-receipt), bound to the item + PR.
V_FAIL="$REPO/docs/workflow/code-reviews/2026-07-22-pr-9-fail.json"
cat > "$V_FAIL" <<JSON
{"verdict":"FAIL","pr":9,"issue":$n1,
 "findings":[{"dimension":"correctness","severity":"major","confidence":0.95,"evidence":"off-by-one","attack":"a","unblock":"fix the bound","fingerprint":"c:f.py:3:obo"}]}
JSON
python3 "$CHECK" "$V_FAIL" >/dev/null 2>&1 \
  || fail "(precondition) the FAIL verdict is not even schema-valid — pick a valid one"
echo "  ok (precondition) the FAIL verdict is schema-valid (so only the disposition guard can stop it)"

if eng close --num "$n1" --verdict "$V_FAIL" --pr 9 2>/dev/null; then
  fail "(1) engine closed on a valid-but-FAIL verdict (disposition guard must deny)"
fi
[ "$(gov_field "$T" "$n1" Status)" != "Done" ] || fail "(1) FAIL-verdict close still drove the item to Done"
echo "  ok (1) close on a schema-valid FAIL verdict is denied"

# FAIL-BLOCKED (a blocker finding) is likewise denied.
n2="$(gov_seed_item "$T" --title 'build2' --stage Buildable --status 'In Progress')" || fail "seed failed"
V_BLOCKED="$REPO/docs/workflow/code-reviews/2026-07-22-pr-9-blocked.json"
cat > "$V_BLOCKED" <<JSON
{"verdict":"FAIL-BLOCKED","pr":9,"issue":$n2,
 "findings":[{"dimension":"security","severity":"blocker","confidence":0.99,"evidence":"rce","attack":"a","unblock":"sanitize","fingerprint":"s:f.py:1:rce"}]}
JSON
python3 "$CHECK" "$V_BLOCKED" >/dev/null 2>&1 || fail "(2) the FAIL-BLOCKED verdict is malformed"
if eng close --num "$n2" --verdict "$V_BLOCKED" --pr 9 2>/dev/null; then
  fail "(2) engine closed on a FAIL-BLOCKED verdict"
fi
echo "  ok (2) close on a FAIL-BLOCKED verdict is denied"

# A PASS-WITH-NITS verdict still closes (the guard rejects FAILs, not all findings).
n3="$(gov_seed_item "$T" --title 'build3' --stage Buildable --status 'In Progress')" || fail "seed failed"
V_NITS="$REPO/docs/workflow/code-reviews/2026-07-22-pr-9-nits.json"
cat > "$V_NITS" <<JSON
{"verdict":"PASS-WITH-NITS","pr":9,"issue":$n3,
 "findings":[{"dimension":"style","severity":"nit","confidence":0.9,"evidence":"e","attack":"a","unblock":"u","fingerprint":"st:f.py:7:x"}]}
JSON
python3 "$CHECK" "$V_NITS" >/dev/null 2>&1 || fail "(3) the PASS-WITH-NITS verdict is malformed"
eng close --num "$n3" --verdict "$V_NITS" --pr 9 >/dev/null 2>&1 \
  || fail "(3) engine denied a close backed by a PASS-WITH-NITS verdict"
[ "$(gov_field "$T" "$n3" Status)" = "Done" ] || fail "(3) PASS-WITH-NITS close did not drive the item to Done"
echo "  ok (3) close on a PASS-WITH-NITS verdict still succeeds"

echo "PASS: close requires a PASSING disposition — schema-valid FAIL / FAIL-BLOCKED verdicts are denied, PASS / PASS-WITH-NITS close"
