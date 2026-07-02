#!/bin/bash
# idc-assert-class: behavior
# Phase 4 smoke — Build's deterministic guardrails:
#   (a) the merged review engine emits a STRUCTURED verdict that validates, and verdict
#       severity is consistent with the taxonomy (blocker->FAIL-BLOCKED, major->FAIL,
#       minor/nit->PASS-WITH-NITS, none->PASS); a malformed verdict is rejected;
#   (b) the build lifecycle over the real tracker: an issue is claimed (Status->In Progress
#       with a claim comment naming the agent) and, on a PASS review, closed (Status->Done).
# Failing-test-first: fails until scripts/idc_review_verdict_check.py exists.
#
# Usage: bash tests/smoke/phase4-build.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
VC="$PLUGIN/scripts/idc_review_verdict_check.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "review-verdict checker not found at $VC (not implemented yet)"

# ---- (a) review verdict structure + consistency ----------------------------------
cat > "$WORK/verdict-good.json" <<'JSON'
{
  "verdict": "PASS-WITH-NITS",
  "dimensions_run": ["protocol","contract-drift","error-handling","resource-mgmt","security",
    "stack-gotchas","unit-test-rigor","integration-test-gaps","dependency-bloat",
    "complexity-budget","git-history","stale-docs","simplification","test-genuineness"],
  "findings": [
    {"dimension":"simplification","severity":"minor","confidence":0.86,
     "evidence":"theme.ts:42 duplicates the resolver in settings.ts:88",
     "attack":"future edits drift the two copies out of sync",
     "unblock":"extract a shared resolveTheme() helper",
     "fingerprint":"simplification:theme.ts:42:dup-resolver"}
  ]
}
JSON
python3 "$VC" "$WORK/verdict-good.json" >/dev/null || fail "valid PASS-WITH-NITS verdict rejected"

# inconsistent: PASS verdict but carries a major finding
cat > "$WORK/verdict-inconsistent.json" <<'JSON'
{"verdict":"PASS","dimensions_run":["security"],
 "findings":[{"dimension":"security","severity":"major","confidence":0.95,
   "evidence":"x","attack":"y","unblock":"z","fingerprint":"f"}]}
JSON
python3 "$VC" "$WORK/verdict-inconsistent.json" >/dev/null 2>&1 && fail "inconsistent verdict (PASS with a major) was accepted"

# malformed: a finding missing the required attack/unblock fields
cat > "$WORK/verdict-malformed.json" <<'JSON'
{"verdict":"FAIL","dimensions_run":["security"],
 "findings":[{"dimension":"security","severity":"major","confidence":0.9,"evidence":"x"}]}
JSON
python3 "$VC" "$WORK/verdict-malformed.json" >/dev/null 2>&1 && fail "malformed finding (no attack/unblock) was accepted"

# a non-object element in findings[] must produce a CLEAN error, not a Python traceback
cat > "$WORK/verdict-nondict.json" <<'JSON'
{"verdict":"PASS","dimensions_run":["security"],"findings":["not-an-object"]}
JSON
out="$(python3 "$VC" "$WORK/verdict-nondict.json" 2>&1)" && fail "verdict with a non-object finding was accepted"
echo "$out" | grep -qi "traceback" && fail "non-object finding produced a Python traceback instead of a clean message: $out"
echo "$out" | grep -q "not a JSON object" || fail "non-object finding should report a clean 'not a JSON object' problem (got: $out)"

# ---- (b) build lifecycle over the real tracker -----------------------------------
T="$WORK/TRACKER.md"
python3 "$TRK" --tracker "$T" init || fail "tracker init failed"
issue=$(python3 "$TRK" --tracker "$T" create --title "Trivial contract issue" --wave "Wave 1")
python3 "$TRK" --tracker "$T" claim --num "$issue" --agent idc-implementer >/dev/null
[ "$(python3 "$TRK" --tracker "$T" show --num "$issue" --field Status)" = "In Progress" ] || fail "claim should set In Progress"
python3 "$TRK" --tracker "$T" show --num "$issue" --comments | grep -q idc-implementer || fail "claim should name the implementer"
# on a PASS review the finisher closes the issue
python3 "$TRK" --tracker "$T" close --num "$issue" >/dev/null
[ "$(python3 "$TRK" --tracker "$T" show --num "$issue" --field Status)" = "Done" ] || fail "PASS review should close the issue (Done)"

# ---- (c) P0-2: an all-static verification surface is a review FAIL (autorun #449 inert ship) ---
# The review engine must catch an inert deliverable (all-static surface that never exercises the
# GOAL's end-state) as a major/FAIL under contract-drift / test-genuineness. Lock the prose.
RE="$PLUGIN/skills/idc-review-engine/SKILL.md"
[ -f "$RE" ] || fail "skills/idc-review-engine/SKILL.md missing"
# The headline-string greps below catch REMOVAL/relabel of the rule. They do NOT catch a SEVERITY
# DOWNGRADE (major -> nit) that keeps the headline phrase intact — so the operative-directive grep
# that follows ties the rule to its `major` floor and goes red on a downgrade.
grep -qiE 'all-static verification surface\*\* is the same FAIL' "$RE" \
  || fail "idc-review-engine must classify an all-static verification surface as the same FAIL (P0-2, severity tie)"
grep -qiE 'inert deliverable' "$RE" \
  || fail "idc-review-engine must explain the all-static FAIL catches an inert deliverable (P0-2)"
grep -qiE 'flag it at .{0,3}major.{0,3} under' "$RE" \
  || fail "idc-review-engine must file the all-static finding at major ('Flag it at \`major\` under …') — a downgrade to minor/nit must go red (P0-2 severity floor)"

echo "PASS: review-verdict structure/consistency + build claim->close lifecycle green; all-static surface is a review FAIL"
