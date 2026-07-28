#!/bin/bash
# tracker-transaction-postcondition.sh — U5 exact postcondition contract.
# Proves:
#   (a) an invalid pure simulation writes nothing;
#   (b) an extra live mutation outside the frozen action set fails the exact postcondition and withholds the receipt.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
REC="$PLUGIN/scripts/idc_planning_receipt.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper: planning apply still has no exact postcondition gate"
[ -f "$REC" ] || fail "missing planning receipt helper: planning apply has no machine-owned receipt surface"

# (A) Invalid simulation / graph-projection parity failure writes nothing.
cat > "$WORK/rogue-live.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: planned-only
    wave: 1
    domain: core
    surfaces: [src/planned-only/]
    blocks_on: []
YAML
T_BAD="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for invalid-simulation case"
ROGUE_NUM="$(gov_seed_item "$T_BAD" --title rogue-live --stage Buildable --status Todo --wave 1 --phase "Phase 1" --domain core)" \
  || fail "could not seed rogue live Buildable"
REPO_BAD="$(dirname "$T_BAD")"
BEFORE_BAD="$(shasum -a 256 "$T_BAD" | awk '{print $1}')"
out="$(python3 "$TXN" freeze \
  --repo "$REPO_BAD" \
  --backend filesystem \
  --tracker "$T_BAD" \
  --matrix "$WORK/rogue-live.yaml" \
  --baseline expected-red \
  --label postcondition-invalid \
  --out "$WORK/rogue-live.freeze.json" 2>&1)" \
  && fail "invalid simulation / parity freeze was accepted (must fail before any write)"
AFTER_BAD="$(shasum -a 256 "$T_BAD" | awk '{print $1}')"
[ "$BEFORE_BAD" = "$AFTER_BAD" ] \
  || fail "invalid simulation refusal still mutated the live tracker ($BEFORE_BAD -> $AFTER_BAD)"
[ "$(gov_field "$T_BAD" "$ROGUE_NUM" Status)" = "Todo" ] \
  || fail "invalid simulation refusal mutated the rogue live item"
printf '%s\n' "$out" | grep -qiE 'planning horizon|absent from the graph|simulation|projection' \
  || fail "invalid simulation refusal must name the graph/projection failure; got: $out"

# (B) Extra live mutation outside the frozen action set fails the exact postcondition.
cat > "$WORK/postcondition.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
YAML
T_POST="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for postcondition case"
REPO_POST="$(dirname "$T_POST")"
python3 - "$PLUGIN/scripts" "$REPO_POST" "$T_POST" "$WORK/postcondition.yaml" "$WORK/postcondition.freeze.json" <<'PY' || exit 1
import json, os, sys
scripts, repo, tracker, matrix, frozen = sys.argv[1:]
sys.path.insert(0, scripts)
try:
    import idc_tracker_transaction as TX
    import idc_tracker_fs as FS
except ImportError as exc:
    raise SystemExit(f"FAIL: U5 transaction helper import failed: {exc}")

bundle = TX.freeze_plan(
    repo=repo,
    matrix_path=matrix,
    backend='filesystem',
    tracker=tracker,
    baseline='expected-red',
    label='postcondition-extra',
)
TX.write_frozen(frozen, bundle)

state = FS.load(tracker)
rogue_number = state['next_number']

def inject_extra_live_mutation(ctx, frozen_bundle):
    live = FS.load(tracker)
    live['issues'].append({
        'number': rogue_number,
        'title': 'rogue-extra',
        'status': 'Todo',
        'stage': 'Buildable',
        'wave': '99',
        'phase': 'Phase 1',
        'domain': 'core',
        'blocked_by': [],
        'attempt': 0,
        'comments': [],
    })
    live['next_number'] = rogue_number + 1
    FS.save(tracker, live)

try:
    TX.apply_frozen(frozen, repo=repo, after_apply_hook=inject_extra_live_mutation)
except TX.TransactionError as exc:
    message = str(exc)
    if 'postcondition' not in message.lower() and 'unexpected live' not in message.lower():
        raise SystemExit(f"FAIL: extra live mutation must fail the exact postcondition, got: {message}")
else:
    raise SystemExit('FAIL: extra live mutation outside the frozen action set was accepted')

bundle = json.load(open(frozen, encoding='utf-8'))
receipt_path = os.path.join(repo, bundle['receipt_relpath'])
if os.path.exists(receipt_path):
    raise SystemExit(f"FAIL: postcondition failure still wrote a planning receipt: {receipt_path}")
print('ok: extra live mutation failed the exact postcondition and withheld the receipt')
PY

echo "PASS: invalid simulation writes nothing, and an extra live mutation outside the frozen action set fails the exact postcondition without issuing a receipt"