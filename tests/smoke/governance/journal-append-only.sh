#!/bin/bash
# journal-append-only.sh — governance scenario: the transition journal must be append-only.
#
# Phase-4 (journal-spine): The journal must be a reliable, immutable log. This test verifies
# that re-running operations or other actions do not truncate or overwrite the journal file.
# It asserts that the line count of the journal is monotonically increasing.
#
# Usage: bash tests/smoke/governance/journal-append-only.sh   (exit 0 = pass)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

J_PATH="$REPO/docs/workflow/transition-journal.ndjson"
mkdir -p "$(dirname "$J_PATH")" && touch "$J_PATH"

# Get initial line count
prev_lines=$(wc -l < "$J_PATH")

# Operation 1
n1=$(gov_seed_item "$T" --title 'append-only-1' --stage 'Buildable' --status 'Todo')
lines_after_1=$(wc -l < "$J_PATH")
[ "$lines_after_1" -gt "$prev_lines" ] || fail "Line count did not increase after op 1. Before: $prev_lines, After: $lines_after_1"
echo "  ok (1) line count increased after first operation"
prev_lines=$lines_after_1

# Operation 2
eng move --num "$n1" --to-status "In Progress" >/dev/null
lines_after_2=$(wc -l < "$J_PATH")
[ "$lines_after_2" -gt "$prev_lines" ] || fail "Line count did not increase after op 2. Before: $prev_lines, After: $lines_after_2"
echo "  ok (2) line count increased after second operation"
prev_lines=$lines_after_2

# Re-run an idempotent operation (query) which should NOT write to the journal
gov_query "$T" --stage Buildable >/dev/null
lines_after_query=$(wc -l < "$J_PATH")
[ "$lines_after_query" -eq "$prev_lines" ] || fail "Line count changed after a read-only query. Before: $prev_lines, After: $lines_after_query"
echo "  ok (3) read-only query did not affect journal"

# Re-running a transition that is now illegal. This should fail and not write to the journal.
set +e
eng move --num "$n1" --to-status "In Progress" >/dev/null 2>&1
set -e
lines_after_rerun=$(wc -l < "$J_PATH")
[ "$lines_after_rerun" -eq "$prev_lines" ] || fail "Line count changed after a failed, idempotent re-run. Before: $prev_lines, After: $lines_after_rerun"
echo "  ok (4) failed idempotent re-run did not affect journal"


echo "PASS: Transition journal is append-only; line count is monotonically increasing for write ops."
