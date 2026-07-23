#!/bin/bash
# planning-transaction-baseline.sh — U5 red/green contract for planning transaction baselines.
# Proves:
#   (a) a non-empty planning delta is classified and frozen as expected-red;
#   (b) an exact no-op rerun is classified and frozen as expected-green;
#   (c) unexpected-green is refused before any live tracker mutation;
#   (d) a frozen planning gate cannot be tampered with between freeze and apply.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper: planning apply still has no expected-red/expected-green freeze contract"

cat > "$WORK/phase1.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
YAML

# (A) expected-red: empty tracker vs one planned Buildable.
T_RED="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md"
REPO_RED="$(dirname "$T_RED")"
python3 "$TXN" freeze \
  --repo "$REPO_RED" \
  --backend filesystem \
  --tracker "$T_RED" \
  --matrix "$WORK/phase1.yaml" \
  --baseline expected-red \
  --label baseline-red \
  --out "$WORK/baseline-red.json" >/dev/null \
  || fail "expected-red planning freeze was refused on a real delta"
python3 - "$WORK/baseline-red.json" <<'PY' || exit 1
import json, sys
bundle = json.load(open(sys.argv[1], encoding='utf-8'))
base = bundle.get('baseline') or {}
if base.get('expected') != 'expected-red' or base.get('actual') != 'expected-red':
    raise SystemExit(f"FAIL: expected-red bundle must record expected-red/actual expected-red, got {base}")
if not bundle.get('action_plan'):
    raise SystemExit('FAIL: expected-red bundle must carry a non-empty action_plan')
if not bundle.get('operations'):
    raise SystemExit('FAIL: expected-red bundle must freeze a non-empty sanctioned operations list')
print('ok: expected-red bundle froze a real planning delta')
PY

# (B) expected-green: board already equals the frozen projection.
T_GREEN="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for expected-green"
gov_seed_item "$T_GREEN" --title alpha --stage Buildable --status Todo --wave 1 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed exact-green Buildable"
REPO_GREEN="$(dirname "$T_GREEN")"
python3 "$TXN" freeze \
  --repo "$REPO_GREEN" \
  --backend filesystem \
  --tracker "$T_GREEN" \
  --matrix "$WORK/phase1.yaml" \
  --baseline expected-green \
  --label baseline-green \
  --out "$WORK/baseline-green.json" >/dev/null \
  || fail "expected-green planning freeze was refused on an exact no-op rerun"
python3 - "$WORK/baseline-green.json" <<'PY' || exit 1
import json, sys
bundle = json.load(open(sys.argv[1], encoding='utf-8'))
base = bundle.get('baseline') or {}
if base.get('expected') != 'expected-green' or base.get('actual') != 'expected-green':
    raise SystemExit(f"FAIL: expected-green bundle must record expected-green/actual expected-green, got {base}")
if bundle.get('action_plan'):
    raise SystemExit(f"FAIL: expected-green bundle must freeze an empty action_plan, got {bundle.get('action_plan')}")
if bundle.get('operations'):
    raise SystemExit(f"FAIL: expected-green bundle must freeze zero sanctioned operations, got {bundle.get('operations')}")
print('ok: expected-green bundle froze an idempotent no-op rerun')
PY

# (C) unexpected-green: claiming expected-green on a real delta must refuse before any write.
T_BAD="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for unexpected-green"
REPO_BAD="$(dirname "$T_BAD")"
BEFORE_BAD="$(shasum -a 256 "$T_BAD" | awk '{print $1}')"
out="$(python3 "$TXN" freeze \
  --repo "$REPO_BAD" \
  --backend filesystem \
  --tracker "$T_BAD" \
  --matrix "$WORK/phase1.yaml" \
  --baseline expected-green \
  --label baseline-unexpected-green \
  --out "$WORK/baseline-bad.json" 2>&1)" \
  && fail "unexpected-green planning freeze was accepted (must refuse mutation)"
AFTER_BAD="$(shasum -a 256 "$T_BAD" | awk '{print $1}')"
[ "$BEFORE_BAD" = "$AFTER_BAD" ] \
  || fail "unexpected-green refusal still mutated the live tracker ($BEFORE_BAD -> $AFTER_BAD)"
printf '%s\n' "$out" | grep -qi 'unexpected-green' \
  || fail "unexpected-green refusal must name the baseline mismatch; got: $out"

# (D) frozen gate integrity: tampering the frozen bundle after freeze must refuse apply.
T_TAMPER="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for tamper case"
REPO_TAMPER="$(dirname "$T_TAMPER")"
python3 "$TXN" freeze \
  --repo "$REPO_TAMPER" \
  --backend filesystem \
  --tracker "$T_TAMPER" \
  --matrix "$WORK/phase1.yaml" \
  --baseline expected-red \
  --label baseline-tamper \
  --out "$WORK/baseline-tamper.json" >/dev/null \
  || fail "could not freeze a valid expected-red bundle for tamper case"
python3 - "$WORK/baseline-tamper.json" <<'PY'
import json, sys
path = sys.argv[1]
bundle = json.load(open(path, encoding='utf-8'))
bundle['operations'][0]['logical_id'] = 'tampered-alpha'
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(bundle, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
BEFORE_TAMPER="$(shasum -a 256 "$T_TAMPER" | awk '{print $1}')"
out="$(python3 "$TXN" apply \
  --repo "$REPO_TAMPER" \
  --backend filesystem \
  --tracker "$T_TAMPER" \
  --frozen "$WORK/baseline-tamper.json" 2>&1)" \
  && fail "a tampered frozen bundle was accepted by apply (must fail closed)"
AFTER_TAMPER="$(shasum -a 256 "$T_TAMPER" | awk '{print $1}')"
[ "$BEFORE_TAMPER" = "$AFTER_TAMPER" ] \
  || fail "tampered frozen bundle changed the live tracker ($BEFORE_TAMPER -> $AFTER_TAMPER)"
printf '%s\n' "$out" | grep -qiE 'frozen|digest|tamper|mismatch' \
  || fail "tampered frozen-bundle refusal must explain the integrity failure; got: $out"

echo "PASS: planning transaction baselines classify expected-red/expected-green correctly, refuse unexpected-green before mutation, and reject a tampered frozen gate"