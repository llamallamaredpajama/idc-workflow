#!/bin/bash
# idc-assert-class: behavior
# plan-risk-gate-authoritative.sh — F59: the validation risk gate decides its own requiredness.
#
# THE DEFECT THIS LANE LOCKS. `idc_validation_risk_gate.evaluate` answered
# `required = bool(risk_inputs)` where `risk_inputs` came straight from the caller's repeatable
# `--risk-input` flag. Omit every flag and the gate returned `required: false` and exit 0 WITHOUT
# inspecting the touch set, the dependency delta, the baseline, or a scenario — so the adversarial
# falsification requirement was satisfied by simply not asking for it. A verdict that is a function
# of a caller-supplied flag is bookkeeping, not a gate.
#
# The fix derives risk in FIXED CODE from the frozen contract's own facts (`--touch`, and the
# baseline classification when `--baseline` is supplied — both machine-owned fields the builder
# cannot author) and unions that with whatever the caller declared. A caller can ADD risk; it can no
# longer subtract it.
#
# What it proves:
#   A. the repro — a security-sensitive touch set with NO --risk-input and NO --scenario is REFUSED
#      (exit 2) instead of returning required:false, exit 0;
#   B. each derivation dimension fires independently, from the touch set alone;
#   C. a declared risk input survives and derived risk is added, not substituted, and the output
#      reports the two sets separately;
#   D. a genuinely trivial contract still skips — the "trivial tickets deterministically skip"
#      contract is preserved, so this is not a blanket everything-is-high-risk change;
#   E. with derived risk AND a real scenario the bounded falsification still runs and selects;
#   F. the output NAMES which dimensions fixed code can decide, so `required: false` can never be
#      read as "fixed code inspected everything".
#
# Red-when-broken: restore `required = bool(declared)` (or empty the derivation table) and A/B/C/E
# fail. Make derivation fire on anything at all and D fails.
#
# Usage: bash tests/smoke/governance/plan-risk-gate-authoritative.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
RG="$PLUGIN/scripts/idc_validation_risk_gate.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$RG" ] || fail "missing risk-gate helper at $RG"

V='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
F='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

SCENARIO="$WORK/scenario.json"
cat > "$SCENARIO" <<'JSON'
{
  "candidates": [
    {
      "promise": "prove the hook denies an unauthorized write",
      "failure_mode": "the hook exits 0 with no output and the write lands",
      "observable_evidence": "the captured hook stdout carries permissionDecision deny",
      "executable_check": "printf '%s' \"$OUT\" | grep -q '\"permissionDecision\": *\"deny\"'"
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

# gate <args…> -> OUT (stdout+stderr), RC. Each case is individually bounded.
gate() { OUT="$(timeout 60 python3 "$RG" evaluate --validator-digest "$V" --frozen-gate-digest "$F" \
  --attempt-ceiling 3 --off-limits docs/ "$@" 2>&1)"; RC=$?; }

# refuses_naming <expected-risk-name> <touch/baseline args…>
refuses_naming() {
  local want="$1"; shift
  gate "$@"
  [ "$RC" -ne 0 ] \
    || fail "the gate returned success for a contract carrying derived risk '$want' and no scenario — this is F59 (falsification skipped by simply not asking for it). args=[$*] out=[$OUT]"
  printf '%s\n' "$OUT" | grep -q -- "$want" \
    || fail "the refusal did not name the derived risk '$want'; args=[$*] got: $OUT"
}

# --- A + B. every derivation dimension fires from the contract facts alone, with NO --risk-input ---
refuses_naming security-sensitive-path  --touch scripts/hooks/idc_interlock_gate.py
refuses_naming security-sensitive-path  --touch src/auth/session.ts
refuses_naming security-sensitive-path  --touch .github/workflows/release.yml
refuses_naming new-runtime-dependency   --touch services/api/package.json
refuses_naming new-runtime-dependency   --touch pyproject.toml
refuses_naming large-touch-set          --touch a/1 --touch b/2 --touch c/3 --touch d/4 --touch e/5
refuses_naming cross-cutting-surface    --touch alpha/x --touch beta/y --touch gamma/z
refuses_naming expected-green-baseline  --touch src/allowed/ --baseline expected-green

# --- D. a genuinely trivial contract still skips discovery deterministically ----------------------
gate --touch src/allowed/
[ "$RC" -eq 0 ] || fail "a trivial contract was refused — derivation must not make everything high-risk: $OUT"
printf '%s' "$OUT" | timeout 60 python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["required"] is False, f"trivial contract became required: {result}"
derived, declared = result["derived_risk_inputs"], result["declared_risk_inputs"]
assert derived == [], f"trivial contract derived risk: {derived}"
assert declared == [], f"trivial contract declared risk: {declared}"
print("ok: trivial contract still skips")
' || fail "trivial-skip assertions failed"

# A single non-security, non-manifest path under two roots must also stay trivial (the derivation
# thresholds are real thresholds, not a rubber stamp).
gate --touch src/allowed/ --touch src/other/
[ "$RC" -eq 0 ] || fail "two same-root touch entries were treated as cross-cutting: $OUT"

# --- C. declared risk survives; derived risk is ADDED, never substituted --------------------------
gate --risk-input expected-green-baseline --touch scripts/hooks/idc_interlock_gate.py --scenario "$SCENARIO"
[ "$RC" -eq 0 ] || fail "a declared+derived high-risk contract with a valid scenario was refused: $OUT"
printf '%s' "$OUT" | timeout 60 python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["required"] is True, f"declared+derived contract not required: {result}"
assert result["declared_risk_inputs"] == ["expected-green-baseline"], result["declared_risk_inputs"]
assert result["derived_risk_inputs"] == ["security-sensitive-path"], result["derived_risk_inputs"]
eff = result["risk_inputs"]
assert set(eff) == {"expected-green-baseline", "security-sensitive-path"}, eff
assert eff[0] == "expected-green-baseline", f"declared order must be preserved first: {eff}"
print("ok: declared and derived risk union cleanly, reported separately")
' || fail "declared+derived union assertions failed"

# --- E. with derived risk and a real scenario the bounded falsification still runs -----------------
gate --touch scripts/hooks/idc_interlock_gate.py --scenario "$SCENARIO"
[ "$RC" -eq 0 ] || fail "derived-only high risk with a valid scenario was refused: $OUT"
printf '%s' "$OUT" | timeout 60 python3 -c '
import json, sys
result = json.load(sys.stdin)
assert result["required"] is True, f"derived-only contract not required: {result}"
selected = result["selected"]
assert len(selected) == 1, f"falsification did not select the surviving candidate: {selected}"
assert result["validator_digest"] == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert result["frozen_gate_digest"] == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
assert result["attempt_ceiling"] == 3, result["attempt_ceiling"]
print("ok: derived risk runs the bounded falsification and preserves the fixed inputs")
' || fail "derived-risk discovery assertions failed"

# --- F. the output names what fixed code can decide, so required:false is not over-readable -------
gate --touch src/allowed/
printf '%s' "$OUT" | timeout 60 python3 -c '
import json, sys
result = json.load(sys.stdin)
table = result.get("derivation") or {}
derived_by_code = table.get("derived_by_fixed_code") or []
for name in ("security-sensitive-path", "cross-cutting-surface", "new-runtime-dependency", "large-touch-set"):
    assert name in derived_by_code, f"{name} missing from the published derivation table: {table}"
assert "expected-green-baseline" in table, f"the declaration-only dimension is not disclosed: {table}"
assert result.get("baseline") == "unknown", result.get("baseline")
print("ok: the derivation table is published with the verdict")
' || fail "derivation-table disclosure assertions failed"

echo "PASS: the validation risk gate derives risk in fixed code from the frozen contract's touch set and baseline, unions it with declared risk (add-only), refuses when derived risk has no falsification scenario, still skips genuinely trivial contracts, and publishes which dimensions it can decide"
