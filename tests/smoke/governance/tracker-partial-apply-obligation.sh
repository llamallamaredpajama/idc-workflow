#!/bin/bash
# tracker-partial-apply-obligation.sh — U5 durable partial-apply recovery contract.
# Proves a journal/readback failure after some sanctioned writes does not blind-rollback, does not
# falsely complete, and leaves a durable obligation recording applied vs remaining operations.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper: partial-apply recovery obligation does not exist yet"

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
python3 - "$PLUGIN/scripts" "$REPO" "$T" "$WORK/phase1.yaml" "$WORK/partial.freeze.json" <<'PY' || exit 1
import json, os, sys
scripts, repo, tracker, matrix, frozen = sys.argv[1:]
sys.path.insert(0, scripts)
try:
    import idc_tracker_transaction as TX
    import idc_transition as E
except ImportError as exc:
    raise SystemExit(f"FAIL: U5 transaction helper import failed: {exc}")

bundle = TX.freeze_plan(
    repo=repo,
    matrix_path=matrix,
    backend='filesystem',
    tracker=tracker,
    baseline='expected-red',
    label='partial-apply',
)
TX.write_frozen(frozen, bundle)

orig = E.journal_append
calls = {'count': 0}

def failing_second_journal(*args, **kwargs):
    calls['count'] += 1
    if calls['count'] == 2:
        return False
    return orig(*args, **kwargs)

E.journal_append = failing_second_journal
try:
    TX.apply_frozen(frozen, repo=repo)
except TX.TransactionError as exc:
    message = str(exc)
    if 'journal' not in message.lower() and 'partial' not in message.lower():
        raise SystemExit(f"FAIL: partial-apply refusal must cite the journal/incomplete state, got: {message}")
else:
    raise SystemExit('FAIL: journal loss after a sanctioned write was accepted as a clean completion')
finally:
    E.journal_append = orig

bundle = json.load(open(frozen, encoding='utf-8'))
obligation_path = os.path.join(repo, bundle['obligation_relpath'])
receipt_path = os.path.join(repo, bundle['receipt_relpath'])
if not os.path.isfile(obligation_path):
    raise SystemExit(f"FAIL: partial apply left no durable obligation at {obligation_path}")
ob = json.load(open(obligation_path, encoding='utf-8'))
if ob.get('status') != 'partial-apply':
    raise SystemExit(f"FAIL: obligation must remain partial-apply, got {ob.get('status')!r}")
if not ob.get('applied_operations'):
    raise SystemExit(f"FAIL: obligation must record at least one applied operation, got {ob}")
if not ob.get('remaining_operations'):
    raise SystemExit(f"FAIL: obligation must record remaining operations for recovery, got {ob}")
if os.path.exists(receipt_path):
    raise SystemExit(f"FAIL: partial apply still wrote a planning receipt: {receipt_path}")
print('ok: partial apply left a durable obligation with applied vs remaining operations and no receipt')
PY

COUNT="$(gov_query "$T" --stage Buildable | grep -c . || true)"
[ "$COUNT" -ge 1 ] || fail "partial apply blind-rolled the already-landed tracker mutation away"
[ "$(gov_field "$T" 1 Stage)" = "Buildable" ] || fail "partial apply left the landed item unreadable"

echo "PASS: a journal/readback failure after some sanctioned writes leaves the landed work intact, records a durable partial-apply obligation, and withholds the receipt"