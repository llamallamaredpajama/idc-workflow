#!/bin/bash
# idc-assert-class: behavior
# janitor-cache-rescan.sh — U7 lost-cache rescan.
#
# A local Janitor cursor is only an accelerator. Deleting it must trigger a durable rescan from the
# adoption baseline, not grant amnesty to a post-boundary unreceipted fact.
#
# Usage: bash tests/smoke/governance/janitor-cache-rescan.sh
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
LEGACY="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'legacy item' --stage Buildable)" \
  || gov_fail "legacy item create failed"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)" || gov_fail "could not read baseline head"
cat > "$REPO/docs/workflow/reconciliation-adoption.json" <<JSON
{
  "schema_version": 1,
  "state": "legacy-adopted",
  "default_branch": {"name": "main", "head": "$HEAD_SHA"},
  "journal_entry_count": 0,
  "legacy_items": [
    {"number": $LEGACY, "stage": "Buildable", "status": "Todo", "evidence_class": "legacy-adopted", "historical_verification": "not-claimed"}
  ],
  "routed_obligations": [],
  "unresolved": []
}
JSON
RAW="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'raw post-boundary item' --stage Buildable)" \
  || gov_fail "post-boundary raw create failed"

set +e
OUT1="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC1=$?
set -e
[ "$RC1" -eq 1 ] || gov_fail "first janitor scan must exit 1 with findings, got $RC1"
REPORT_JSON="$OUT1" python3 - "$RAW" <<'PY' || gov_fail "first janitor scan did not surface the post-boundary raw fact"
import json, os, sys
raw = int(sys.argv[1])
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings", [])
hits = [f for f in findings if f.get("classification") == "post-boundary-unreceipted-tracker" and f.get("number") == raw]
assert hits, findings
PY
CURSOR="$REPO/.git/idc-reconciliation-cursor.json"
[ -f "$CURSOR" ] || gov_fail "first janitor scan did not write its local cursor"
rm -f "$CURSOR"

set +e
OUT2="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC2=$?
set -e
[ "$RC2" -eq 1 ] || gov_fail "second janitor scan after cursor deletion must exit 1 with findings, got $RC2"
REPORT_JSON="$OUT2" python3 - "$RAW" <<'PY' || gov_fail "deleting the local cursor granted amnesty instead of forcing a durable rescan"
import json, os, sys
raw = int(sys.argv[1])
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings", [])
hits = [f for f in findings if f.get("classification") == "post-boundary-unreceipted-tracker" and f.get("number") == raw]
assert hits, findings
plan = report.get("plan", {})
assert plan.get("rescanned_from_durable") is True, plan
PY

echo "PASS: deleting the local Janitor cursor forces a durable rescan; the post-boundary raw fact still blocks clean state"
