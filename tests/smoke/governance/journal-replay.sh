#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export PYTHONPATH="$ROOT/scripts"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"

# 1. Setup initial state
mkdir -p .idc

cat > TRACKER.md <<EOF
# Project Tracker

<!-- idc-tracker-state:begin -->
\`\`\`json
{
  "issues": [
    {
      "number": 1,
      "stage": "Plan",
      "status": "Ready"
    },
    {
      "number": 2,
      "stage": "Build",
      "status": "Done"
    }
  ]
}
\`\`\`
<!-- idc-tracker-state:end -->
EOF

cat > .idc/journal.ndjson <<EOF
{"ts": "2026-07-07T00:00:00Z", "op": "create", "item": 1}
{"ts": "2026-07-07T00:01:00Z", "op": "transition", "item": 1, "to": {"stage": "Plan", "status": "Ready"}}
{"ts": "2026-07-07T00:02:00Z", "op": "create", "item": 2}
{"ts": "2026-07-07T00:03:00Z", "op": "transition", "item": 2, "to": {"stage": "Build", "status": "In Progress"}}
{"ts": "2026-07-07T00:04:00Z", "op": "transition", "item": 2, "to": {"stage": "Build", "status": "Done"}}
EOF

echo "--- Test case 1: Journal and board are in sync ---"
if ! python3 "$ROOT/scripts/idc_journal_replay.py" --tracker TRACKER.md; then
    echo "FAIL: Expected script to exit 0 for synced board."
    exit 1
fi
echo "PASS: Synced board test successful."


echo "--- Test case 2: Journal has extra item ---"
echo '{"ts": "2026-07-07T00:05:00Z", "op": "create", "item": 3}' >> .idc/journal.ndjson

if python3 "$ROOT/scripts/idc_journal_replay.py" --tracker TRACKER.md >/dev/null 2>&1; then
    echo "FAIL: Expected script to exit 1 for extra item in journal."
    exit 1
fi
echo "PASS: Extra journal item test successful."

# Reset journal
sed -i.bak '$d' .idc/journal.ndjson

echo "--- Test case 3: Board has status mismatch ---"
sed -i.bak 's/"status": "Done"/"status": "In Progress"/' TRACKER.md

output=$(python3 "$ROOT/scripts/idc_journal_replay.py" --tracker TRACKER.md 2>&1) || true
if ! echo "$output" | grep -q "Item #2 STATUS mismatch"; then
    echo "FAIL: Did not detect status mismatch."
    echo "Output was: $output"
    exit 1
fi
echo "PASS: Status mismatch test successful."

echo "--- All journal-replay tests passed! ---"
