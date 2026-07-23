#!/bin/bash
# idc-assert-class: behavior
# janitor-foreign-tool-preserve.sh — U7 preserve-and-route foreign-tool work.
#
# Foreign-tool artifacts (Codex / Claude / other non-IDC tooling) affecting the repo must be surfaced,
# preserved, and routed for investigation — never auto-deleted by `--apply-safe`.
#
# Usage: bash tests/smoke/governance/janitor-foreign-tool-preserve.sh
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
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)" || gov_fail "could not read baseline head"
cat > "$REPO/docs/workflow/reconciliation-adoption.json" <<JSON
{
  "schema_version": 1,
  "state": "legacy-adopted",
  "default_branch": {"name": "main", "head": "$HEAD_SHA"},
  "journal_entry_count": 0,
  "legacy_items": [],
  "routed_obligations": [],
  "unresolved": []
}
JSON

git -C "$REPO" checkout -q -b codex/experiment
printf codex > "$REPO/codex.txt"
git -C "$REPO" add codex.txt
git -C "$REPO" commit -qm 'codex work'
git -C "$REPO" checkout -q main

set +e
OUT="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --apply-safe --json)"; RC=$?
set -e
[ "$RC" -eq 1 ] || gov_fail "janitor apply-safe json must exit 1 with remaining findings, got $RC"
git -C "$REPO" show-ref --verify --quiet refs/heads/codex/experiment \
  || gov_fail "foreign-tool branch was deleted by janitor --apply-safe"
REPORT_JSON="$OUT" python3 - <<'PY' || gov_fail "foreign-tool work was not preserved + routed honestly"
import json, os
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings", [])
hits = [f for f in findings if f.get("name") == "codex/experiment"]
assert hits, findings
hit = hits[0]
assert hit.get("tier") == "REPORT-ONLY", hit
assert hit.get("route") == "investigate", hit
assert hit.get("preserve") is True, hit
applied = report.get("applied") or []
assert not any(item.get("name") == "codex/experiment" and item.get("ok") for item in applied), applied
PY

echo "PASS: foreign-tool work is preserved and routed for investigation; janitor never auto-deletes it"
