#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
git init -b main >/dev/null 2>&1
git config user.email "test@example.com" >/dev/null 2>&1
git config user.name "Test" >/dev/null 2>&1
git commit --allow-empty -m "initial commit" >/dev/null 2>&1

# 1. Setup initial state
mkdir -p .idc
mkdir -p docs/workflow/journal-archive # Pre-create to check permissions

cat > TRACKER.md <<EOF
# Project Tracker
<!-- idc-tracker-state:begin -->
\`\`\`json
{
  "issues": [
    {"number": 1, "status": "In Progress"},
    {"number": 2, "status": "Done"},
    {"number": 3, "status": "Done"}
  ]
}
\`\`\`
<!-- idc-tracker-state:end -->
EOF

cat > .idc/journal.ndjson <<EOF
{"item": 1, "op": "transition", "to": {"status": "In Progress"}}
{"item": 2, "op": "transition", "to": {"status": "In Progress"}}
{"item": 2, "op": "transition", "to": {"status": "Done"}}
{"item": 3, "op": "transition", "to": {"status": "Done"}}
EOF

# 2. Run rotation
python3 "$ROOT/scripts/idc_git_janitor.py" --rotate-journal --tracker TRACKER.md

# 3. Verify journal file
if ! grep -q '{"item": 1' .idc/journal.ndjson; then
    echo "FAIL: Journal should still contain item 1."
    exit 1
fi
if grep -q '{"item": 2' .idc/journal.ndjson || grep -q '{"item": 3' .idc/journal.ndjson; then
    echo "FAIL: Journal should not contain items 2 or 3."
    cat .idc/journal.ndjson
    exit 1
fi
echo "PASS: Active journal file is correct."

# 4. Verify archive file
ARCHIVE_FILE=$(find docs/workflow/journal-archive -name "*.ndjson")
if [ -z "$ARCHIVE_FILE" ]; then
    echo "FAIL: Archive file not created."
    exit 1
fi
if ! grep -q '{"item": 2' "$ARCHIVE_FILE" || ! grep -q '{"item": 3' "$ARCHIVE_FILE"; then
    echo "FAIL: Archive file does not contain items 2 and 3."
    cat "$ARCHIVE_FILE"
    exit 1
fi
if grep -q '{"item": 1' "$ARCHIVE_FILE"; then
    echo "FAIL: Archive file should not contain item 1."
    exit 1
fi
echo "PASS: Archive file is correct."

echo "--- All journal-rotation tests passed! ---"
