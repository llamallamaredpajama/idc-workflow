#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="scripts/idc_git_janitor.py"

echo "--- Running journal-divergence-doctor.sh test ---"

# This will fail because the --check-journal-divergence flag does not exist yet.
python3 "$SCRIPT_PATH" --json --check-journal-divergence >/dev/null

echo "PASS: journal-divergence-doctor.sh"
