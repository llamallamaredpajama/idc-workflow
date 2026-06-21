#!/bin/bash
# Phase 4 smoke — the combined review AGENT (idc:idc-review-agent), the standing/queryable
# review service that promotes the 13-dimension engine to first class. Deterministic checks
# (no live LLM): we assert the agent's INTERFACE contract is wired, then run a fixture review
# over a known-bad diff and validate the emitted verdict with idc_review_verdict_check.py.
#
#   (a) the agent file exists and declares the combined contract: pi risk-tiering
#       (trivial/lite/full) + sanitized packets + isolation, idc's 13 dimensions + 0.8 floor
#       + fingerprint dedup + verdict ladder + test-genuineness=FAIL + the automerge hook,
#       fan-out routed through the runtime adapter's bounded-fan-out primitive (NOT hard-coded
#       Claude subagents), durable report under docs/workflow/code-reviews/;
#   (b) the verdict ladder over the known-bad fixture diff is correct end-to-end through the
#       real validator: blocker->FAIL-BLOCKED, major->FAIL, minor/nit->PASS-WITH-NITS,
#       clean->PASS;
#   (c) test genuineness is FAIL, not a nit: a shallow/placeholder test filed as a `nit`
#       test-genuineness finding is REJECTED by the validator; the same finding filed at
#       `major` (-> FAIL) is accepted.
# Failing-test-first: fails until agents/idc-review-agent.md and the fixture exist and the
# validator enforces the test-genuineness severity floor.
#
# Usage: bash tests/smoke/phase4-review-agent.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="$PLUGIN/agents/idc-review-agent.md"
VC="$PLUGIN/scripts/idc_review_verdict_check.py"
DIFF="$PLUGIN/tests/smoke/fixtures/review-agent/known-bad.diff"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

# ---- (a) the combined review agent exists + declares its interface ----------------
[ -f "$AGENT" ] || fail "combined review agent not found at $AGENT (not implemented yet)"
[ -f "$VC" ]    || fail "review-verdict checker not found at $VC"
[ -f "$DIFF" ]  || fail "known-bad fixture diff not found at $DIFF (not implemented yet)"

need() { grep -qi -- "$1" "$AGENT" || fail "agent interface missing: $2"; }
need "trivial"                     "pi risk tier (trivial)"
need "lite"                        "pi risk tier (lite)"
need "full"                        "pi risk tier (full)"
need "sanitiz"                     "sanitized review packet"
need "untrusted"                   "isolation: treat PR text/diff as untrusted data"
need "13 dimension"                "the 13 review dimensions"
need "0.8"                         "the 0.8 confidence floor"
need "fingerprint"                 "fingerprint dedup"
need "FAIL-BLOCKED"                "verdict ladder (FAIL-BLOCKED rung)"
need "PASS-WITH-NITS"              "verdict ladder (PASS-WITH-NITS rung)"
need "test-genuineness"            "test-genuineness enforcement"
need "automerge"                   "the build automerge hook"
need "docs/workflow/code-reviews/" "durable report path"
need "idc:idc-adapter-claude"      "Claude runtime adapter (bounded fan-out)"
need "idc:idc-adapter-codex"       "Codex runtime adapter (bounded fan-out)"
need "bounded fan-out"             "fan-out routed through the runtime primitive"
need "idc_review_verdict_check.py" "verdict validator wiring"
# fresh, cold reviewers per PR even though the service is standing
grep -qiE "fresh|cold" "$AGENT"   || fail "agent must spawn fresh/cold reviewers per PR"
grep -qi  "operator"   "$AGENT"   || fail "agent must be operator-invocable (standing service)"
# must NOT hard-code Claude subagents as the fan-out mechanic (route via the adapter)
grep -qiE "hard-?cod(e|ed) .*subagent" "$AGENT" \
  && fail "agent must route fan-out through the adapter primitive, not hard-coded subagents"

# ---- (b) verdict ladder over the known-bad fixture diff ---------------------------
# Each verdict represents what the review agent emits for the fixture at a given fix-state.
# The fixture lives at $DIFF; evidence cites it so the ladder is grounded in a real diff.
emit() { # severity, verdict, dimension -> writes $WORK/v.json
  local sev="$1" vd="$2" dim="$3"
  if [ "$sev" = "none" ]; then
    cat > "$WORK/v.json" <<JSON
{"verdict":"$vd","dimensions_run":["protocol","security","unit-test-rigor","test-genuineness"],
 "findings":[]}
JSON
  else
    cat > "$WORK/v.json" <<JSON
{"verdict":"$vd","dimensions_run":["protocol","security","unit-test-rigor","test-genuineness"],
 "findings":[{"dimension":"$dim","severity":"$sev","confidence":0.9,
   "evidence":"known-bad.diff: $dim defect at the changed hunk",
   "attack":"the failure mode this $sev enables",
   "unblock":"the concrete fix for this $sev finding",
   "fingerprint":"$dim:known-bad.diff:1:$sev"}]}
JSON
  fi
}

emit blocker FAIL-BLOCKED   security
python3 "$VC" "$WORK/v.json" >/dev/null || fail "blocker verdict (FAIL-BLOCKED) wrongly rejected"
emit major   FAIL           security
python3 "$VC" "$WORK/v.json" >/dev/null || fail "major verdict (FAIL) wrongly rejected"
emit minor   PASS-WITH-NITS simplification
python3 "$VC" "$WORK/v.json" >/dev/null || fail "minor verdict (PASS-WITH-NITS) wrongly rejected"
emit nit     PASS-WITH-NITS simplification
python3 "$VC" "$WORK/v.json" >/dev/null || fail "nit verdict (PASS-WITH-NITS) wrongly rejected"
emit none    PASS           ""
python3 "$VC" "$WORK/v.json" >/dev/null || fail "clean verdict (PASS) wrongly rejected"

# wrong rung must be rejected (ladder is fail-closed): a blocker hiding behind PASS
emit blocker PASS security
python3 "$VC" "$WORK/v.json" >/dev/null 2>&1 && fail "a blocker hidden behind PASS was accepted"

# ---- (c) a shallow/placeholder test is FAIL, not a nit ----------------------------
# The agent flags the fixture's placeholder test under dimension `test-genuineness`. Filed
# as a nit it MUST be rejected (escalate to FAIL); filed at major (-> FAIL) it is accepted.
cat > "$WORK/genuineness-nit.json" <<'JSON'
{"verdict":"PASS-WITH-NITS","dimensions_run":["unit-test-rigor","test-genuineness"],
 "findings":[{"dimension":"test-genuineness","severity":"nit","confidence":0.95,
   "evidence":"known-bad.diff: test_login asserts True and stubs the thing under test",
   "attack":"a green suite that proves nothing ships a real bug",
   "unblock":"assert real behavior through the public interface",
   "fingerprint":"test-genuineness:known-bad.diff:tests:placeholder"}]}
JSON
python3 "$VC" "$WORK/genuineness-nit.json" >/dev/null 2>&1 \
  && fail "a shallow/placeholder test filed as a nit was accepted (must be FAIL, not nit)"

cat > "$WORK/genuineness-major.json" <<'JSON'
{"verdict":"FAIL","dimensions_run":["unit-test-rigor","test-genuineness"],
 "findings":[{"dimension":"test-genuineness","severity":"major","confidence":0.95,
   "evidence":"known-bad.diff: test_login asserts True and stubs the thing under test",
   "attack":"a green suite that proves nothing ships a real bug",
   "unblock":"assert real behavior through the public interface",
   "fingerprint":"test-genuineness:known-bad.diff:tests:placeholder"}]}
JSON
python3 "$VC" "$WORK/genuineness-major.json" >/dev/null \
  || fail "a shallow/placeholder test filed at major (FAIL) was wrongly rejected"

# ---- (d) P1-2: structured deferral objects validate; malformed ones are rejected -------------
# Teammate closeouts must emit deferrals as a STRUCTURED, validated object
# {kind, what, blocks_goal: bool, suggested_issue} — not unparsed prose footnotes (autorun
# Defect 5). A well-formed deferrals[] validates; a malformed one (missing/empty field, a
# non-bool blocks_goal, or a non-object element) is rejected fail-closed.
cat > "$WORK/deferral-good.json" <<'JSON'
{"verdict":"PASS","dimensions_run":["security"],"findings":[],
 "deferrals":[{"kind":"out-of-boundary","what":"Spanner instance/db/IAM Terraform",
   "blocks_goal":true,"suggested_issue":"provision the Spanner instance for the two-store seed"}]}
JSON
python3 "$VC" "$WORK/deferral-good.json" >/dev/null \
  || fail "a well-formed deferrals[] object was wrongly rejected"

# missing a required field (suggested_issue)
cat > "$WORK/deferral-missing.json" <<'JSON'
{"verdict":"PASS","dimensions_run":["security"],"findings":[],
 "deferrals":[{"kind":"deferred","what":"x","blocks_goal":false}]}
JSON
python3 "$VC" "$WORK/deferral-missing.json" >/dev/null 2>&1 \
  && fail "a deferral missing suggested_issue was accepted (must reject)"

# non-bool blocks_goal — the string "true" passes a strip()-only check, but must be a JSON boolean
cat > "$WORK/deferral-badbool.json" <<'JSON'
{"verdict":"PASS","dimensions_run":["security"],"findings":[],
 "deferrals":[{"kind":"deferred","what":"x","blocks_goal":"true","suggested_issue":"y"}]}
JSON
python3 "$VC" "$WORK/deferral-badbool.json" >/dev/null 2>&1 \
  && fail "a deferral with a non-bool blocks_goal (string \"true\") was accepted (must be a JSON boolean)"

# a non-object deferral element must produce a CLEAN error, not a Python traceback
cat > "$WORK/deferral-nondict.json" <<'JSON'
{"verdict":"PASS","dimensions_run":["security"],"findings":[],"deferrals":["not-an-object"]}
JSON
out="$(python3 "$VC" "$WORK/deferral-nondict.json" 2>&1)" && fail "a non-object deferral was accepted"
echo "$out" | grep -qi "traceback" && fail "non-object deferral produced a Python traceback: $out"
echo "$out" | grep -qi "not a JSON object" || fail "non-object deferral should report a clean 'not a JSON object' problem (got: $out)"

echo "PASS: review-agent interface + verdict ladder + test-genuineness=FAIL + deferral schema green"
