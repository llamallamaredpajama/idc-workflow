#!/bin/bash
# idc-assert-class: behavior
# planning-receipt-legacy-upgrade.sh — F55: a planning receipt minted BEFORE the out-of-tree witness
# existed must be refused with a NAMED recovery path, not a dead end.
#
# THE CUTOVER. `_planning_receipt_info` requires an out-of-tree witness for every planning receipt it
# borrows (F7). A receipt written by a pre-witness build of the plugin has no store entry, so an upgrade
# landing between a Plan and its Build refuses every previously-valid receipt.
#
# WHY IT IS NOT AUTO-HEALED. Nothing in the receipt distinguishes "minted by older code" from
# "hand-forged at a path the machine never wrote": `schema_version` did not change when witnessing was
# introduced, and every in-band field (`written_by`, `receipt_digest`) is forgeable — which is the whole
# reason the out-of-tree witness exists. Re-anchoring such a receipt in place would hand a forger the
# exact bypass F7 closes. So the REFUSAL is correct and must stay; what this test pins is that the
# refusal TELLS the operator what to do — re-run the sanctioned Plan apply — instead of failing with a
# bare "not machine-anchored".
#
# Red-when-broken, both directions:
#   * drop LEGACY_RECEIPT_RECOVERY from the refusal messages and the guidance assertions below fail;
#   * make the missing-witness case ACCEPT (or re-anchor) the receipt and the refusal assertion fails —
#     which is the F7 bypass, so this test guards that door too.
#
# Usage: bash tests/smoke/governance/planning-receipt-legacy-upgrade.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
PR="$PLUGIN/scripts/idc_planning_receipt.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$VC" ] || fail "missing validation-contract helper: scripts/idc_validation_contract.py"
[ -f "$PR" ] || fail "missing planning-receipt helper: scripts/idc_planning_receipt.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init

python3 - "$PLUGIN/scripts" "$REPO" <<'PY'
import os, sys
scripts, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_planning_receipt as PR
import idc_validation_contract as VC

path = os.path.join(repo, "docs", "workflow", "planning-receipts", "legacy.json")

# A STRUCTURALLY VALID receipt, built by the real builder so it passes self-integrity (F5) exactly as a
# pre-witness receipt did — the ONLY difference from a current one is that no witness was recorded.
# Writing the bytes directly (rather than through write_receipt) is precisely what the old code did.
bundle = {"backend": "filesystem", "label": "legacy", "projection": [], "operations": [],
          "obligation_relpath": "docs/workflow/obligations/legacy.md",
          "projection_digest": PR.sha256_json(PR.normalize_projection_rows([])),
          "operations_digest": PR.sha256_json([])}
doc = PR.build_receipt(repo, bundle, [], [])
os.makedirs(os.path.dirname(path), exist_ok=True)
VC.atomic_write_json(path, doc)
PR.verify_receipt_integrity(doc)      # a pre-witness receipt was self-consistent; prove this one is too

problem = VC.planning_witness_problem(path, doc)

# 1. It must still be REFUSED — a pre-witness receipt is indistinguishable from a forgery, so accepting
#    it (or silently re-anchoring it) would reopen the F7 bypass.
if problem is None:
    print("FAIL: a receipt with no recorded witness was accepted — a hand-forged receipt is "
          "indistinguishable from a pre-witness one, so this reopens the F7 bypass (F55)")
    sys.exit(1)

# 2. The refusal must NAME the sanctioned recovery, so the operator hitting the legitimate in-flight
#    upgrade knows the way forward instead of being stuck on a bare 'not machine-anchored'.
if "re-run the sanctioned Plan apply" not in problem:
    print("FAIL: the refusal does not name the sanctioned recovery (re-running Plan apply) — an upgrade "
          "landing between Plan and Build leaves the operator with no stated way forward (F55).\n"
          "  got: %s" % problem)
    sys.exit(1)
if "cannot be re-anchored" not in problem:
    print("FAIL: the refusal does not say the receipt cannot be re-anchored in place, inviting exactly "
          "the unsafe repair F55 warns against (F55).\n  got: %s" % problem)
    sys.exit(1)

# 3. The SAME guidance must reach the operator through the real borrow door, not just the helper.
try:
    VC._planning_receipt_info(path)
except VC.ValidationError as exc:
    if "re-run the sanctioned Plan apply" not in str(exc):
        print("FAIL: the contract-freeze refusal drops the recovery guidance (F55).\n  got: %s" % exc)
        sys.exit(1)
except PR.ReceiptError:
    pass          # a stub receipt can fail self-integrity first; the witness guidance is asserted above
else:
    print("FAIL: the contract freeze borrowed an unwitnessed receipt (F55/F7)")
    sys.exit(1)

# 4. Control — the SAME receipt path, written through the sanctioned writer, IS borrowable. This proves
#    the refusal above is about the missing witness and not about the receipt's shape.
ok_path = os.path.join(repo, "docs", "workflow", "planning-receipts", "current.json")
ok_doc = PR.build_receipt(repo, dict(bundle, label="current"), [], [])
PR.write_receipt(repo, ok_path, ok_doc)
current = VC.planning_witness_problem(ok_path, ok_doc)
if current is not None:
    print("FAIL: a receipt written by the sanctioned writer was refused (F55 control): %s" % current)
    sys.exit(1)

print("ok: a pre-witness receipt is refused AND told how to recover; a sanctioned one is borrowable")
PY
[ $? -eq 0 ] || fail "the legacy pre-witness receipt cutover is not handled (F55)"

echo "PASS: a planning receipt minted before the out-of-tree witness is refused (it is indistinguishable from a forgery, so it is never re-anchored) and the refusal names the sanctioned recovery — re-running the Plan apply to mint a fresh witnessed receipt (F55)"
