#!/bin/bash
# idc-assert-class: behavior
# janitor-convergence-bootstrap.sh — U7 bootstrap convergence, dedupe, and validated repair/routing.
#
# A bootstrap run must create the one-time adoption receipt, preserve any current outside-path work as a
# routed obligation (not historical verification), validate its route/repair plan before apply, and be
# idempotent on a re-run (no duplicate routed obligations for the same root fact).
#
# Red-when-broken (reviewed): remove `--bootstrap` => the command has no adoption path; skip plan
# validation => `plan.validated` flips; append a new routed obligation every run => the second-pass
# dedupe assertion flips.
#
# Usage: bash tests/smoke/governance/janitor-convergence-bootstrap.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$JAN" ] || gov_fail "scripts/idc_git_janitor.py not found"
[ -f "$TRK" ] || gov_fail "scripts/idc_tracker_fs.py not found"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow" || gov_fail "could not create repo dirs"
git init -q -b main "$REPO" || gov_fail "git init failed"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "tracker init failed"
mkdir -p "$REPO/docs/workflow" && : > "$REPO/docs/workflow/transition-journal.ndjson"
printf base > "$REPO/app.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
cat > "$REPO/docs/workflow/reconciliation-baseline-required.json" <<'JSON'
{
  "schema_version": 1,
  "state": "baseline-pending",
  "reason": "reconciliation-baseline-required"
}
JSON
python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'legacy buildable' --stage Buildable >/dev/null \
  || gov_fail "legacy item create failed"

# Current outside-path work at bootstrap: must be PRESERVED and routed, not blessed as historical IDC work.
git -C "$REPO" checkout -q -b feature-outside
printf branch > "$REPO/outside.txt"
git -C "$REPO" add outside.txt
git -C "$REPO" commit -qm 'outside branch work'
git -C "$REPO" checkout -q main

BOOT1="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --bootstrap --json)" \
  || gov_fail "bootstrap scan failed"
REPORT_JSON="$BOOT1" python3 - "$REPO/docs/workflow/reconciliation-adoption.json" <<'PY' || gov_fail "bootstrap did not write a validated, honest adoption receipt"
import json, os, sys
receipt_path = sys.argv[1]
report = json.loads(os.environ["REPORT_JSON"])
assert report.get("plan", {}).get("validated") is True, report
assert report.get("baseline", {}).get("state") == "legacy-adopted", report
assert os.path.isfile(receipt_path), receipt_path
receipt = json.load(open(receipt_path))
legacy_items = receipt.get("legacy_items") or []
assert legacy_items, receipt
assert legacy_items[0].get("historical_verification") == "not-claimed", legacy_items[0]
routed = receipt.get("routed_obligations") or []
assert len(routed) == 1, routed
assert routed[0].get("root_id"), routed
assert routed[0].get("route") == "intake", routed[0]
assert receipt.get("unresolved") == [], receipt
PY
[ ! -e "$REPO/docs/workflow/reconciliation-baseline-required.json" ] \
  || gov_fail "bootstrap left the baseline-required marker behind after a clean completion"

# Re-run: idempotent. The same routed outside branch must not duplicate itself in the durable receipt.
BOOT2="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --bootstrap --json)" \
  || gov_fail "bootstrap re-run failed"
REPORT_JSON="$BOOT2" python3 - "$REPO/docs/workflow/reconciliation-adoption.json" <<'PY' || gov_fail "bootstrap re-run duplicated a routed obligation instead of deduping it"
import json, os, sys
receipt = json.load(open(sys.argv[1]))
routed = receipt.get("routed_obligations") or []
assert len(routed) == 1, routed
report = json.loads(os.environ["REPORT_JSON"])
assert report.get("plan", {}).get("validated") is True, report
PY

echo "PASS: bootstrap writes an honest adoption receipt, validates its plan, and dedupes routed obligations across runs"
