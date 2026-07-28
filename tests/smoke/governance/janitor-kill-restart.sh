#!/bin/bash
# idc-assert-class: behavior
# janitor-kill-restart.sh — U7 kill/restart safety for bootstrap.
#
# A bootstrap that dies mid-flight must leave an honest baseline-pending marker behind, write no false
# adoption receipt, and resume cleanly on the next run.
#
# Usage: bash tests/smoke/governance/janitor-kill-restart.sh
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

set +e
IDC_JANITOR_TEST_INTERRUPT_AFTER='after-baseline-marker' \
  python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --bootstrap --json >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -eq 99 ] || gov_fail "bootstrap interrupt hook did not surface the expected test exit 99 (got $RC)"
[ -f "$REPO/docs/workflow/reconciliation-baseline-required.json" ] \
  || gov_fail "interrupted bootstrap did not leave the baseline-required marker behind"
[ ! -f "$REPO/docs/workflow/reconciliation-adoption.json" ] \
  || gov_fail "interrupted bootstrap wrote an adoption receipt before completion"

OUT="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --bootstrap --json)" \
  || gov_fail "bootstrap restart failed"
REPORT_JSON="$OUT" python3 - "$REPO/docs/workflow/reconciliation-adoption.json" <<'PY' || gov_fail "bootstrap restart did not resume honestly from the interrupted baseline state"
import json, os, sys
receipt_path = sys.argv[1]
report = json.loads(os.environ["REPORT_JSON"])
plan = report.get("plan", {})
assert plan.get("resumed") is True, plan
assert report.get("baseline", {}).get("state") == "legacy-adopted", report
assert os.path.isfile(receipt_path), receipt_path
PY
[ ! -f "$REPO/docs/workflow/reconciliation-baseline-required.json" ] \
  || gov_fail "bootstrap restart did not clear the baseline-required marker after success"

echo "PASS: interrupted bootstrap leaves the repo baseline-pending and a later run resumes to a real adoption receipt"
