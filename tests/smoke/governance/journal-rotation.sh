#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: rotation must archive terminal entries from the canonical transition journal while
# leaving live-item lines intact in a single rewritten active journal.

. "$(dirname "$0")/lib.sh"
gov_engine_env

git -C "$REPO" init -b main >/dev/null 2>&1
git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
git -C "$REPO" config user.name "Test" >/dev/null 2>&1
git -C "$REPO" commit --allow-empty -m "initial commit" >/dev/null 2>&1

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

active=$(eng create-ticket --title 'journal rotation active' --stage 'Buildable' --status 'Todo')
eng move --num "$active" --to-status "In Progress" >/dev/null

terminal=$(eng create-ticket --title 'journal rotation terminal' --stage 'Buildable' --status 'Todo')
eng move --num "$terminal" --to-status "In Progress" >/dev/null
VERDICT_PATH="$REPO/verdict.json"
cat > "$VERDICT_PATH" <<EOF
{
  "verdict": "PASS",
  "issue": $terminal,
  "pr": 1,
  "merge_conditions": [
    {"id": "c1", "description": "d1", "met": true}
  ]
}
EOF
eng close --num "$terminal" --verdict "$VERDICT_PATH" --pr 1 >/dev/null

[ -f "$JOURNAL" ] || fail "canonical transition journal was not created at $JOURNAL"

python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --rotate-journal --tracker "$T"

python3 - "$JOURNAL" "$REPO/docs/workflow/journal-archive" "$active" "$terminal" <<'PY'
import json
import pathlib
import sys

journal = pathlib.Path(sys.argv[1])
archive_dir = pathlib.Path(sys.argv[2])
active = int(sys.argv[3])
terminal = int(sys.argv[4])

def read_items(path):
    items = []
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            entry = json.loads(line)
            items.append(entry.get("item"))
    return items

active_items = read_items(journal)
if active not in active_items:
    raise SystemExit(f"active journal should still contain item {active}; saw {active_items}")
if terminal in active_items:
    raise SystemExit(f"active journal should not contain terminal item {terminal}; saw {active_items}")

archives = sorted(archive_dir.glob("*.ndjson"))
if not archives:
    raise SystemExit("archive file was not created")
archive_items = []
for path in archives:
    archive_items.extend(read_items(path))
if terminal not in archive_items:
    raise SystemExit(f"archive should contain terminal item {terminal}; saw {archive_items}")
if active in archive_items:
    raise SystemExit(f"archive should not contain active item {active}; saw {archive_items}")
PY

python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" || \
  fail "expected replay after rotation to include archived terminal entries"

echo "PASS: Canonical journal rotation archived terminal entries, kept live entries, and remains replayable."

echo "--- Rotation on a MISSING journal with terminal board items must fail closed ---"
rm "$JOURNAL"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --rotate-journal --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected rotation with terminal items but a missing journal to exit 2, got $rc: $output"
echo "$output" | grep -q "Nothing to rotate" && \
    fail "rotation must not report lost terminal history as a successful no-op: $output"
echo "PASS: rotation refuses a missing journal when the board has terminal items."

echo "--- All journal-rotation tests passed! ---"
