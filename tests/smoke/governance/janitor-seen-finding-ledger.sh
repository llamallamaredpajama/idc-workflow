#!/bin/bash
# idc-assert-class: behavior
# janitor-seen-finding-ledger.sh — U7 Janitor all-seen dedupe ledger.
#
# A post-boundary blocker that resurfaces on a later Janitor pass must be marked `seen_before`, must
# not count as a new blocker again, and must be backed by a durable repo-scoped seen ledger. A direct
# model-authored ledger write with an invalid shape must be refused fail-closed.
#
# Red-when-broken (reviewed): omit the durable seen ledger => the second pass still treats the blocker
# as new; ignore the persisted ledger => `seen_before` never flips; accept an invalid direct ledger
# write => the final refusal assertion flips.
#
# Usage: bash tests/smoke/governance/janitor-seen-finding-ledger.sh
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
LEDGER="$REPO/docs/workflow/reconciliation-seen-findings.json"

set +e
OUT1="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC1=$?
OUT2="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC2=$?
set -e
[ "$RC1" -eq 1 ] || gov_fail "first Janitor scan must exit 1 with findings, got $RC1"
[ "$RC2" -eq 1 ] || gov_fail "second Janitor scan must exit 1 with findings, got $RC2"
REPORT_JSON="$OUT2" python3 - "$RAW" "$LEDGER" <<'PY' || gov_fail "a resurfaced Janitor blocker was still treated as new instead of deduping against the durable all-seen ledger"
import json, os, sys
raw = int(sys.argv[1])
ledger_path = sys.argv[2]
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings") or []
hits = [f for f in findings if f.get("classification") == "post-boundary-unreceipted-tracker" and f.get("number") == raw]
assert hits, findings
hit = hits[0]
assert hit.get("seen_before") is True, hit
assert isinstance(hit.get("fingerprint"), str) and hit["fingerprint"], hit
plan = report.get("plan") or {}
assert plan.get("new_blocker_count") == 0, plan
assert plan.get("new_blockers") == [], plan
assert os.path.isfile(ledger_path), ledger_path
ledger = json.load(open(ledger_path))
entries = ledger.get("entries") or []
matching = [entry for entry in entries if entry.get("fingerprint") == hit["fingerprint"]]
assert len(matching) == 1, entries
assert int(matching[0].get("seen_count") or 0) >= 2, matching[0]
PY

cat > "$LEDGER" <<'JSON'
{"schema_version":1,"entries":["model-authored-pass"]}
JSON
set +e
BAD="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json 2>&1)"; BADRC=$?
set -e
[ "$BADRC" -eq 2 ] \
  || gov_fail "Janitor accepted an invalid direct seen-ledger write instead of refusing it fail-closed (rc=$BADRC)"
printf '%s' "$BAD" | grep -qi 'seen' \
  || gov_fail "invalid seen-ledger refusal did not mention the seen ledger problem: [$BAD]"

echo "PASS: Janitor persists a durable all-seen ledger, marks resurfaced blockers seen_before, and refuses invalid direct ledger writes"
