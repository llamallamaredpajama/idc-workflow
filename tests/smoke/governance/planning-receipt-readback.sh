#!/bin/bash
# planning-receipt-readback.sh — U5 source-owned planning receipt contract.
# Proves a successful planning transaction writes a machine-owned receipt that binds start/projection /
# ordered operations / final live readback, and that forged or stale final digests are refused.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
REC="$PLUGIN/scripts/idc_planning_receipt.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper: planning transactions cannot yet write a machine-owned receipt"
[ -f "$REC" ] || fail "missing planning receipt helper: no receipt verification surface exists yet"

cat > "$WORK/phase1.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
YAML

T="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md"
REPO="$(dirname "$T")"
python3 "$TXN" freeze \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --matrix "$WORK/phase1.yaml" \
  --baseline expected-red \
  --label planning-receipt \
  --out "$WORK/receipt.freeze.json" >/dev/null \
  || fail "could not freeze a valid planning transaction bundle"
python3 "$TXN" apply \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --frozen "$WORK/receipt.freeze.json" >/dev/null \
  || fail "could not apply a valid frozen planning transaction"
RECEIPT_PATH="$(python3 - "$REPO" "$WORK/receipt.freeze.json" <<'PY'
import json, os, sys
repo, frozen = sys.argv[1:]
bundle = json.load(open(frozen, encoding='utf-8'))
print(os.path.join(repo, bundle['receipt_relpath']))
PY
)"
[ -f "$RECEIPT_PATH" ] || fail "apply succeeded but no planning receipt was written at $RECEIPT_PATH"

python3 "$REC" verify \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --receipt "$RECEIPT_PATH" >/dev/null \
  || fail "the freshly written planning receipt did not verify against the live board"

python3 - "$RECEIPT_PATH" <<'PY' || exit 1
import json, sys
receipt = json.load(open(sys.argv[1], encoding='utf-8'))
required = [
    'schema_version', 'kind', 'start_digest', 'projection_digest', 'operations_digest',
    'final_digest', 'projection', 'operations', 'readback', 'obligation_relpath'
]
missing = [key for key in required if key not in receipt]
if missing:
    raise SystemExit(f"FAIL: planning receipt is missing required field(s): {missing}")
readback = receipt.get('readback') or {}
if not readback.get('ok'):
    raise SystemExit(f"FAIL: planning receipt must record an exact successful readback, got {readback}")
print('ok: planning receipt carries the frozen/start/final digests, ordered operations, obligation link, and exact readback result')
PY

python3 - "$RECEIPT_PATH" "$WORK/forged-receipt.json" <<'PY'
import json, sys
src, dst = sys.argv[1:]
receipt = json.load(open(src, encoding='utf-8'))
receipt['final_digest'] = '0' * 64
with open(dst, 'w', encoding='utf-8') as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
out="$(python3 "$REC" verify \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --receipt "$WORK/forged-receipt.json" 2>&1)" \
  && fail "forged planning receipt with a mismatched final digest was accepted"
printf '%s\n' "$out" | grep -qiE 'final digest|live board|mismatch' \
  || fail "forged receipt refusal must name the final-digest mismatch; got: $out"

python3 "$GOV_TRK" --tracker "$T" set --num 1 --field Domain --value drift >/dev/null \
  || fail "could not inject a post-receipt live board drift"
out="$(python3 "$REC" verify \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --receipt "$RECEIPT_PATH" 2>&1)" \
  && fail "stale planning receipt was accepted after the live board drifted from its final digest"
printf '%s\n' "$out" | grep -qiE 'final digest|live board|mismatch|stale' \
  || fail "stale receipt refusal must explain the live final-digest mismatch; got: $out"

echo "PASS: a successful planning transaction writes a machine-owned receipt that verifies against the live board, and forged or stale final digests are refused"