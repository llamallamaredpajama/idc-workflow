#!/bin/bash
# idc-assert-class: behavior
# build-planning-receipt-borrow.sh — F7: a frozen Build contract may borrow graph/projection
# bindings from a planning receipt ONLY after fully verifying the receipt (machine writer + recomputed
# self-digest). A repo-local edited receipt cannot inject a forged graph/projection binding into the
# frozen contract.
#
# Red-when-broken: with _planning_receipt_info() trusting only the caller-controlled written_by
# string, step (B) — an edited receipt whose graph_digest was swapped but whose receipt_digest was
# left stale — is borrowed into the frozen contract, and the assertion fires. Full receipt
# verification refuses it.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
VC="$PLUGIN/scripts/idc_validation_contract.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper"
[ -f "$VC" ]  || fail "missing build validation-contract helper"

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
mkdir -p "$REPO/src"
printf 'x\n' > "$REPO/src/f.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

T="$REPO/TRACKER.md"
python3 "$GOV_TRK" --tracker "$T" init >/dev/null || fail "could not init the throwaway tracker"

cat > "$WORK/phase1.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/]
    blocks_on: []
YAML

python3 "$TXN" freeze --repo "$REPO" --backend filesystem --tracker "$T" \
  --matrix "$WORK/phase1.yaml" --baseline expected-red --label borrow \
  --out "$WORK/freeze.json" >/dev/null || fail "could not freeze a valid planning transaction"
python3 "$TXN" apply --repo "$REPO" --backend filesystem --tracker "$T" \
  --frozen "$WORK/freeze.json" >/dev/null || fail "could not apply the frozen planning transaction"
RECEIPT="$(python3 - "$REPO" "$WORK/freeze.json" <<'PY'
import json, os, sys
repo, frozen = sys.argv[1:]
bundle = json.load(open(frozen, encoding='utf-8'))
print(os.path.join(repo, bundle['receipt_relpath']))
PY
)"
[ -f "$RECEIPT" ] || fail "planning apply wrote no receipt at $RECEIPT"
GRAPH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["graph_digest"])' "$RECEIPT")"
PROJ="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["projection_digest"])' "$RECEIPT")"

# (A) A valid, machine-owned receipt lets the frozen contract borrow its graph/projection bindings.
CONTRACT="$REPO/docs/workflow/build-validation/borrow.json"
mkdir -p "$(dirname "$CONTRACT")"
python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --planning-receipt "$RECEIPT" \
  --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture \
  --baseline expected-green --label borrow --out "$CONTRACT" >/dev/null \
  || fail "a valid planning receipt could not be borrowed into a frozen contract"
python3 - "$CONTRACT" "$GRAPH" "$PROJ" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
graph, proj = sys.argv[2:4]
if contract.get('graph_digest') != graph:
    raise SystemExit(f"FAIL: contract did not borrow graph_digest {graph}, got {contract.get('graph_digest')}")
if contract.get('projection_digest') != proj:
    raise SystemExit(f"FAIL: contract did not borrow projection_digest {proj}, got {contract.get('projection_digest')}")
print("ok: the frozen contract borrowed the verified planning receipt's graph/projection bindings")
PY

# (B) An edited receipt (graph_digest swapped, receipt_digest left stale) cannot inject a forged
#     binding into a frozen contract.
python3 - "$RECEIPT" <<'PY'
import json, sys
path = sys.argv[1]
receipt = json.load(open(path, encoding='utf-8'))
receipt['graph_digest'] = 'd' * 64    # inject a forged binding; leave the stale receipt_digest
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
out="$(python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --planning-receipt "$RECEIPT" \
  --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture \
  --baseline expected-green --label borrow2 \
  --out "$REPO/docs/workflow/build-validation/injected.json" 2>&1)" \
  && fail "an edited planning receipt injected a forged graph binding into a frozen Build contract"
printf '%s\n' "$out" | grep -qiE 'receipt|digest|machine-owned|tamper' \
  || fail "injection refusal must name the receipt-verification failure; got: $out"

echo "PASS: a frozen Build contract borrows planning-receipt bindings only after full receipt verification; an edited receipt cannot inject a forged binding"
