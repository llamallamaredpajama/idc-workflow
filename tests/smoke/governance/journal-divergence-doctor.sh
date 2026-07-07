#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: janitor/doctor reconciliation must read the same canonical journal produced by
# idc_transition.py, and must report a board↔journal mismatch after hand-injected divergence.

. "$(dirname "$0")/lib.sh"
gov_engine_env

git -C "$REPO" init -b main >/dev/null 2>&1
git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
git -C "$REPO" config user.name "Test" >/dev/null 2>&1
git -C "$REPO" commit --allow-empty -m "initial commit" >/dev/null 2>&1

echo "--- Test case 0: Missing journal in a fresh repo is not divergence ---"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --check-journal-divergence --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected fresh repo without journal to exit 0, got $rc: $output"
if echo "$output" | grep '"dim": "journal"'; then
    echo "FAIL: Missing journal in fresh repo produced a false journal divergence."
    echo "$output"
    exit 1
fi
echo "PASS: Missing fresh journal does not warn."

item=$(eng create-ticket --title 'journal divergence' --stage 'Buildable' --status 'Todo')
eng move --num "$item" --to-status "In Progress" >/dev/null

echo "--- Test case 1: Synced canonical journal, expect no journal findings ---"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --check-journal-divergence --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected synced janitor exit 0, got $rc: $output"
if echo "$output" | grep '"dim": "journal"'; then
    echo "FAIL: Found journal divergence in synced state."
    echo "$output"
    exit 1
fi
echo "PASS: No divergence found in synced state."


echo "--- Test case 2: Legacy empty Stage is not a false divergence ---"
legacy=$(python3 "$GOV_TRK" --tracker "$T" create --title 'legacy no stage' --status "Todo")
eng move --num "$legacy" --to-status "In Progress" >/dev/null
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --check-journal-divergence --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "expected legacy empty-stage janitor exit 0, got $rc: $output"
if echo "$output" | grep '"dim": "journal"'; then
    echo "FAIL: Empty legacy Stage produced a false journal divergence."
    echo "$output"
    exit 1
fi
echo "PASS: Empty legacy Stage preserved without false divergence."


echo "--- Test case 3: Missing actual Stage is normalized before comparison ---"
python3 - "$GOV_PLUGIN/scripts" <<'PY'
import json
import os
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
from idc_git_janitor import check_journal_divergence

repo = tempfile.mkdtemp()
os.makedirs(os.path.join(repo, "docs", "workflow"), exist_ok=True)
journal = os.path.join(repo, "docs", "workflow", "transition-journal.ndjson")
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"op": "move", "item": 1, "to": {"stage": "", "status": "Todo"}}) + "\n")
findings = []
check_journal_divergence({"board": [{"number": 1, "stage": None, "status": "Todo"}]}, findings, journal)
if findings:
    raise SystemExit(f"missing actual Stage should not diverge from journal empty Stage: {findings}")
PY
echo "PASS: Missing actual Stage normalized."


echo "--- Test case 4: Divergent state, expect journal finding ---"
python3 "$GOV_TRK" --tracker "$T" move --num "$item" --status "Done" >/dev/null

set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --check-journal-divergence --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected divergent janitor exit 1, got $rc: $output"
if ! echo "$output" | grep '"dim": "journal"' | grep "Status mismatch"; then
    echo "FAIL: Did not find expected journal divergence."
    echo "$output"
    exit 1
fi
echo "PASS: Divergence found in divergent state."


echo "--- Test case 5: Default janitor run includes journal reconciliation ---"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected default janitor to report journal divergence exit 1, got $rc: $output"
if ! echo "$output" | grep '"dim": "journal"' | grep "Status mismatch"; then
    echo "FAIL: default janitor run did not include journal divergence."
    echo "$output"
    exit 1
fi
echo "PASS: default janitor includes journal reconciliation."


echo "--- Test case 6: Divergence survives --apply-safe re-scan ---"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --check-journal-divergence --apply-safe --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected apply-safe divergent janitor exit 1, got $rc: $output"
if ! echo "$output" | grep '"dim": "journal"' | grep "Status mismatch"; then
    echo "FAIL: apply-safe re-scan dropped journal divergence."
    echo "$output"
    exit 1
fi
echo "PASS: apply-safe re-scan preserves journal divergence."


echo "--- Test case 7: Corrupt journal is indeterminate, not advisory debris ---"
printf '{bad}\n' > "$REPO/docs/workflow/transition-journal.ndjson"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected corrupt journal exit 2, got $rc: $output"
echo "$output" | grep -q '"verdict": "indeterminate"' || \
    fail "expected indeterminate verdict for corrupt journal, got: $output"
echo "PASS: corrupt journal fails closed as indeterminate."

echo "--- Test case 8: Missing journal on a NON-EMPTY board is indeterminate, not clean ---"
rm "$REPO/docs/workflow/transition-journal.ndjson"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected missing journal on non-empty board to exit 2, got $rc: $output"
echo "$output" | grep -q '"verdict": "indeterminate"' || \
    fail "expected indeterminate verdict for missing journal on non-empty board, got: $output"
echo "PASS: missing journal on non-empty board fails closed as indeterminate."

echo "--- Test case 9: board-only item ABOVE the create watermark is flagged; legacy items below stay tolerated ---"
# Rebirth the journal through the engine: the create record for the new item becomes the derived
# adoption watermark (item numbers are monotonic on both backends). Items #1/#2 predate it (legacy,
# tolerated); an item created AFTER it through the RAW tracker (bypassing the engine) has no journal
# history it should have — lost/bypassed history must surface, not read as clean.
wm=$(eng create-ticket --title 'journal watermark' --stage 'Buildable' --status 'Todo')
rogue=$(python3 "$GOV_TRK" --tracker "$T" create --title 'rogue post-journal create' --status "Todo")
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected a post-watermark board-only item to be a finding (exit 1), got $rc: $output"
echo "$output" | grep '"dim": "journal"' | grep -q "#$rogue" || \
    fail "expected a journal finding for the post-watermark board-only item #$rogue, got: $output"
if echo "$output" | grep '"dim": "journal"' | grep -qE "#1|#2"; then
    fail "legacy items below the create watermark must stay tolerated, got: $output"
fi
echo "PASS: post-watermark board-only item flagged; pre-watermark legacy items tolerated."

echo "--- Test case 10: findings + an indeterminate dimension keep the shipped exit-1 contract ---"
# The shipped janitor contract (autorun/doctor read it): exit 1 = findings present (actionable NOW,
# whatever else is unknown); exit 2 = the scan would OTHERWISE be clean but a dimension was
# indeterminate. A SAFE-FIX finding (merged IDC build branch, item not Done) + a corrupt journal
# (indeterminate) must therefore exit 1 with verdict "findings", not report "could not determine".
git -C "$REPO" branch "build-2" >/dev/null    # #2 is In Progress; tip == main HEAD → merged → SAFE-FIX
printf '{bad}\n' > "$REPO/docs/workflow/transition-journal.ndjson"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_git_janitor.py" --repo "$REPO" --json --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected findings to win over an indeterminate dimension (exit 1), got $rc: $output"
echo "$output" | grep -q '"verdict": "findings"' || \
    fail "expected verdict 'findings' when findings coexist with an indeterminate dimension, got: $output"
echo "$output" | grep -q '"dim": "board"' || \
    fail "expected the SAFE-FIX board finding to be reported alongside the indeterminate journal, got: $output"
echo "PASS: findings keep the exit-1 contract when a dimension is indeterminate."

echo "--- All journal-divergence tests passed! ---"
