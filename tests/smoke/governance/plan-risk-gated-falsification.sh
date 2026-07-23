#!/bin/bash
# plan-risk-gated-falsification.sh — U6 deterministic risk-gated divergent discovery / falsification.
# Proves:
#   (a) trivial tickets deterministically skip discovery;
#   (b) only named fixed risk inputs trigger discovery;
#   (c) every candidate branch uses the exact four-field schema
#       {promise,failure_mode,observable_evidence,executable_check};
#   (d) skeptics ask exactly "show how this check passes while the goal is actually broken";
#   (e) any gate defeated by a majority is discarded (or replaced by a repaired candidate);
#   (f) discovery preserves the fixed validator digest, frozen-gate digest, path exclusions, and attempt ceiling.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
RG="$PLUGIN/scripts/idc_validation_risk_gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$RG" ] || fail "missing risk-gate helper: Plan still lacks deterministic high-risk falsification"

VALIDATOR='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
FROZEN='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

GOOD_SCENARIO="$WORK/good.json"
cat > "$GOOD_SCENARIO" <<'JSON'
{
  "candidates": [
    {
      "promise": "prove the admin export route returns a CSV",
      "failure_mode": "header-only route still 200s while emitting no rows",
      "observable_evidence": "captured response body includes at least one non-header row",
      "executable_check": "curl -s http://localhost:3000/admin/export.csv | tail -n +2 | grep -q ."
    },
    {
      "promise": "prove the admin export route returns a CSV with real rows",
      "failure_mode": "route returns 200 with only headers",
      "observable_evidence": "captured response body includes a seeded row beyond the header",
      "executable_check": "curl -s http://localhost:3000/admin/export.csv | awk 'NR>1 {exit 0} END {exit 1}'"
    }
  ],
  "skeptic_results": [
    {
      "question": "show how this check passes while the goal is actually broken",
      "majority_defeated": true
    },
    {
      "question": "show how this check passes while the goal is actually broken",
      "majority_defeated": false
    }
  ]
}
JSON

BAD_SHAPE="$WORK/bad-shape.json"
cat > "$BAD_SHAPE" <<'JSON'
{
  "candidates": [
    {
      "promise": "bad branch",
      "failure_mode": "extra key sneaks through",
      "observable_evidence": "unexpected extra field survives",
      "executable_check": "true",
      "extra": "boom"
    }
  ],
  "skeptic_results": [
    {
      "question": "show how this check passes while the goal is actually broken",
      "majority_defeated": false
    }
  ]
}
JSON

BAD_QUESTION="$WORK/bad-question.json"
cat > "$BAD_QUESTION" <<'JSON'
{
  "candidates": [
    {
      "promise": "good branch",
      "failure_mode": "wrong skeptic question",
      "observable_evidence": "the helper accepts the wrong falsification prompt",
      "executable_check": "true"
    }
  ],
  "skeptic_results": [
    {
      "question": "prove this is broken while the check still passes",
      "majority_defeated": false
    }
  ]
}
JSON

# (A) trivial ticket: deterministically skip discovery.
OUT_SKIP="$WORK/skip.json"
python3 "$RG" evaluate \
  --validator-digest "$VALIDATOR" \
  --frozen-gate-digest "$FROZEN" \
  --attempt-ceiling 3 \
  --touch src/allowed/ \
  --off-limits docs/ \
  --scenario "$GOOD_SCENARIO" \
  --out "$OUT_SKIP" >/dev/null \
  || fail "a trivial ticket should skip discovery deterministically"
python3 - "$OUT_SKIP" <<'PY' || exit 1
import json, sys
result = json.load(open(sys.argv[1], encoding='utf-8'))
if result.get('required') is not False:
    raise SystemExit(f"FAIL: trivial ticket should skip discovery, got {result}")
if result.get('selected') not in ([], None):
    raise SystemExit(f"FAIL: trivial ticket must not pay discovery fan-out, got {result.get('selected')!r}")
if result.get('validator_digest') != 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa':
    raise SystemExit(f"FAIL: skip path lost validator digest preservation: {result}")
if result.get('frozen_gate_digest') != 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb':
    raise SystemExit(f"FAIL: skip path lost frozen gate digest preservation: {result}")
if result.get('attempt_ceiling') != 3:
    raise SystemExit(f"FAIL: skip path lost attempt ceiling preservation: {result}")
print('ok: trivial ticket skipped risk-gated discovery deterministically')
PY

# (B) exact candidate shape is enforced.
out="$(python3 "$RG" evaluate \
  --validator-digest "$VALIDATOR" \
  --frozen-gate-digest "$FROZEN" \
  --attempt-ceiling 3 \
  --touch src/allowed/ \
  --off-limits docs/ \
  --risk-input security-sensitive-path \
  --scenario "$BAD_SHAPE" \
  --out "$WORK/bad-shape-out.json" 2>&1)" \
  && fail "a candidate with fields outside {promise,failure_mode,observable_evidence,executable_check} was accepted"
printf '%s\n' "$out" | grep -qiE 'exactly|promise|observable_evidence|executable_check|extra' \
  || fail "bad-shape refusal must explain the exact four-field schema; got: $out"

# (C) exact skeptic question is enforced.
out="$(python3 "$RG" evaluate \
  --validator-digest "$VALIDATOR" \
  --frozen-gate-digest "$FROZEN" \
  --attempt-ceiling 3 \
  --touch src/allowed/ \
  --off-limits docs/ \
  --risk-input security-sensitive-path \
  --scenario "$BAD_QUESTION" \
  --out "$WORK/bad-question-out.json" 2>&1)" \
  && fail "a skeptic result using the wrong question was accepted"
printf '%s\n' "$out" | grep -qiE 'show how this check passes while the goal is actually broken|skeptic question' \
  || fail "bad-question refusal must name the exact skeptic prompt; got: $out"

# (D) named fixed risk inputs trigger discovery, majority-defeated gates are discarded, and preserved
#     fixed inputs survive unchanged into the output.
OUT_HIGH="$WORK/high.json"
python3 "$RG" evaluate \
  --validator-digest "$VALIDATOR" \
  --frozen-gate-digest "$FROZEN" \
  --attempt-ceiling 3 \
  --touch src/allowed/ \
  --off-limits docs/ \
  --risk-input security-sensitive-path \
  --risk-input large-touch-set \
  --scenario "$GOOD_SCENARIO" \
  --out "$OUT_HIGH" >/dev/null \
  || fail "a high-risk ticket should trigger deterministic discovery/falsification"
python3 - "$OUT_HIGH" <<'PY' || exit 1
import json, sys
result = json.load(open(sys.argv[1], encoding='utf-8'))
if result.get('required') is not True:
    raise SystemExit(f"FAIL: high-risk ticket should require discovery, got {result}")
if result.get('risk_inputs') != ['security-sensitive-path', 'large-touch-set']:
    raise SystemExit(f"FAIL: output did not preserve the named fixed risk inputs: {result.get('risk_inputs')!r}")
if result.get('validator_digest') != 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa':
    raise SystemExit(f"FAIL: discovery rewrote the fixed validator digest: {result}")
if result.get('frozen_gate_digest') != 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb':
    raise SystemExit(f"FAIL: discovery rewrote the frozen gate digest: {result}")
if result.get('touch') != ['src/allowed/'] or result.get('off_limits') != ['docs/']:
    raise SystemExit(f"FAIL: discovery rewrote the path exclusions: {result}")
if result.get('attempt_ceiling') != 3:
    raise SystemExit(f"FAIL: discovery rewrote the attempt ceiling: {result}")
if result.get('skeptic_question') != 'show how this check passes while the goal is actually broken':
    raise SystemExit(f"FAIL: wrong skeptic question preserved: {result.get('skeptic_question')!r}")
selected = result.get('selected') or []
discarded = result.get('discarded_indexes') or []
if discarded != [0]:
    raise SystemExit(f"FAIL: the majority-defeated default gate was not discarded: {discarded}")
if len(selected) != 1:
    raise SystemExit(f"FAIL: exactly one surviving candidate should remain after discarding the defeated gate: {selected}")
branch = selected[0]
expected = {
    'promise': 'prove the admin export route returns a CSV with real rows',
    'failure_mode': 'route returns 200 with only headers',
    'observable_evidence': 'captured response body includes a seeded row beyond the header',
    'executable_check': "curl -s http://localhost:3000/admin/export.csv | awk 'NR>1 {exit 0} END {exit 1}'",
}
if branch != expected:
    raise SystemExit(f"FAIL: wrong surviving candidate selected: {branch}")
print('ok: high-risk discovery preserved fixed invariants and discarded the majority-defeated gate')
PY

echo "PASS: risk-gated discovery triggers only on named fixed risks, enforces the exact branch/skeptic schema, discards majority-defeated gates, and preserves fixed validator/frozen-gate/path/attempt inputs"