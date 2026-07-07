#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="scripts/idc_git_janitor.py"

echo "--- Running journal-rotation.sh test ---"

# This will fail because the --rotate-journal flag does not exist yet.
python3 "$SCRIPT_PATH" --json --rotate-journal >/dev/null

echo "PASS: journal-rotation.sh"
