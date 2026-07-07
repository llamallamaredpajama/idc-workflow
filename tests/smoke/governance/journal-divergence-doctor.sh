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

cat > TRACKER.md <<EOF
# Project Tracker
<!-- idc-tracker-state:begin -->
\`\`\`json
{
  "issues": [
    {"number": 1, "status": "In Progress"}
  ]
}
\`\`\`
<!-- idc-tracker-state:end -->
EOF

cat > .idc/journal.ndjson <<EOF
{"item": 1, "op": "transition", "to": {"status": "In Progress"}}
EOF

echo "--- Test case 1: Synced state, expect no journal findings ---"
output=$(python3 "$ROOT/scripts/idc_git_janitor.py" --json --check-journal-divergence --tracker TRACKER.md)
if echo "$output" | grep '"dim": "journal"'; then
    echo "FAIL: Found journal divergence in synced state."
    echo "$output"
    exit 1
fi
echo "PASS: No divergence found in synced state."


echo "--- Test case 2: Divergent state, expect finding ---"
# Introduce divergence: change status in TRACKER.md
sed -i.bak 's/"status": "In Progress"/"status": "Done"/' TRACKER.md

output=$(python3 "$ROOT/scripts/idc_git_janitor.py" --json --check-journal-divergence --tracker TRACKER.md) || true
if ! echo "$output" | grep '"dim": "journal"' | grep "Status mismatch"; then
    echo "FAIL: Did not find expected journal divergence."
    echo "$output"
    exit 1
fi
echo "PASS: Divergence found in divergent state."

echo "--- All journal-divergence tests passed! ---"

