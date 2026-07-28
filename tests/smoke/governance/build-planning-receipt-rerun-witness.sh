#!/bin/bash
# idc-assert-class: behavior
# build-planning-receipt-rerun-witness.sh — F27: a same-label planning-receipt RERUN must not
# invalidate an in-flight Build's borrow of the EARLIER receipt.
#
# The planning witness is keyed by the receipt's worktree-relative logical path. The label default is
# STABLE across same-projection reruns (`planning-<sha256(projection)[:12]>`), so the logical path is
# identical on re-apply — but `build_receipt` embeds a fresh `created_at`, so a re-apply writes
# DIFFERENT bytes at the SAME path. When the witness stored a SINGLE byte digest per path, that
# re-apply OVERWROTE it, and a Build worktree still holding the earlier committed receipt (the F19
# cross-worktree handoff) then failed `planning_witness_problem` "stale" at freeze — a legitimate
# receipt refused. The fix retains a witness per (path, byte digest), so a rerun ADDS a version rather
# than replacing the one an in-flight Build depends on.
#
# Red-when-broken: with a single-entry witness, recording the rerun's witness evicts the original's,
# so after restoring the earlier receipt its byte digest matches no witness and the freeze REFUSES —
# the "still borrowable" assertion fires. (The re-signed-forge refusal is still covered by the sibling
# build-planning-receipt-witness.sh case A, so retaining versions does not reopen F7.)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
VC="$PLUGIN/scripts/idc_validation_contract.py"
PR="$PLUGIN/scripts/idc_planning_receipt.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper"
[ -f "$VC" ]  || fail "missing build validation-contract helper"
[ -f "$PR" ]  || fail "missing planning-receipt helper"

receipt_of() {  # <repo> <frozen.json> -> absolute path of the receipt the apply wrote
  python3 - "$1" "$2" <<'PY'
import json, os, sys
repo, frozen = sys.argv[1:]
bundle = json.load(open(frozen, encoding='utf-8'))
print(os.path.join(repo, bundle['receipt_relpath']))
PY
}

plan_in() {  # <repo> <tracker> <label> <freeze.json> — init tracker, freeze+apply one planning txn.
  local repo="$1" trk="$2" label="$3" out="$4"
  python3 "$GOV_TRK" --tracker "$trk" init >/dev/null || fail "could not init tracker in $repo"
  cat > "$WORK/$label.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/]
    blocks_on: []
YAML
  python3 "$TXN" freeze --repo "$repo" --backend filesystem --tracker "$trk" \
    --matrix "$WORK/$label.yaml" --baseline expected-red --label "$label" \
    --out "$out" >/dev/null || fail "could not freeze a valid planning transaction in $repo"
  python3 "$TXN" apply --repo "$repo" --backend filesystem --tracker "$trk" \
    --frozen "$out" >/dev/null || fail "could not apply the frozen planning transaction in $repo"
}

# --- a receipt is written (witness recorded), then the SAME path is rewritten with new bytes --------
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
mkdir -p "$REPO/src"; printf 'x\n' > "$REPO/src/f.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init

plan_in "$REPO" "$REPO/TRACKER.md" rerun "$WORK/freeze.json"
RECEIPT="$(receipt_of "$REPO" "$WORK/freeze.json")"
[ -f "$RECEIPT" ] || fail "planning apply wrote no receipt at $RECEIPT"
cp "$RECEIPT" "$WORK/r1.json"                         # the EARLIER receipt an in-flight Build holds
R1_GRAPH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["graph_digest"])' "$WORK/r1.json")"

# Sanity: the original receipt IS borrowable before any rerun.
python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --planning-receipt "$RECEIPT" --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture --baseline expected-green --label pre \
  --out "$REPO/docs/workflow/build-validation/pre.json" >/dev/null \
  || fail "the original machine-witnessed receipt could not be borrowed before the rerun"

# Simulate a same-label re-apply: rewrite the receipt at the SAME path with DIFFERENT bytes (a fresh
# created_at, re-signed so self-integrity holds), and re-record its witness — exactly what a rerun of
# the same projection does. This must ADD a version, not evict the original's.
python3 - "$PLUGIN/scripts" "$RECEIPT" <<'PY'
import importlib.util, json, os, sys
scripts, receipt_path = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
spec = importlib.util.spec_from_file_location("idc_planning_receipt", os.path.join(scripts, "idc_planning_receipt.py"))
PR = importlib.util.module_from_spec(spec); spec.loader.exec_module(PR)
import idc_validation_contract as VC
receipt = json.load(open(receipt_path, encoding='utf-8'))
receipt['created_at'] = '2000-01-01T00:00:00Z'              # a DIFFERENT timestamp -> different bytes
receipt['receipt_digest'] = PR._recompute_receipt_digest(receipt)   # re-sign so self-integrity holds
PR.verify_receipt_integrity(receipt)                        # prove the rerun receipt is self-consistent
with open(receipt_path, 'w', encoding='utf-8') as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True); fh.write('\n')
VC.record_planning_witness(os.path.abspath(receipt_path), receipt)  # record the rerun's witness
print("ok: rerun receipt written and witnessed at the same logical path")
PY

# The in-flight Build still holds the EARLIER receipt bytes — restore them.
cp "$WORK/r1.json" "$RECEIPT"

# --- assertion: the ORIGINAL receipt is STILL borrowable after the rerun (F27) ----------------------
CONTRACT="$REPO/docs/workflow/build-validation/post.json"
python3 "$VC" freeze --repo "$REPO" --issue 2 --pr 402 --graph-node alpha \
  --planning-receipt "$RECEIPT" --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture --baseline expected-green --label post \
  --out "$CONTRACT" >/dev/null \
  || fail "the ORIGINAL receipt was refused after a same-label rerun clobbered its witness (F27)"
got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["graph_digest"])' "$CONTRACT")"
[ "$got" = "$R1_GRAPH" ] \
  || fail "post-rerun contract did not borrow the ORIGINAL receipt's graph_digest; got $got want $R1_GRAPH"

echo "PASS: a same-label planning-receipt rerun ADDS a witness rather than replacing it, so an in-flight Build still borrows the earlier receipt (F27)"
