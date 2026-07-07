#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="scripts/idc_journal_replay.py"

echo "--- Running journal-replay.sh test ---"

# This will fail because the script does not exist yet.
python3 "$SCRIPT_PATH" >/dev/null 2>&1

echo "PASS: journal-replay.sh"
