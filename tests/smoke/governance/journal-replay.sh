#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: drives the real transition engine producer, then requires replay to consume the
# canonical docs/workflow/transition-journal.ndjson journal and fail closed on corrupt NDJSON.

. "$(dirname "$0")/lib.sh"
gov_engine_env

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

item=$(eng create-ticket --title 'journal replay lifecycle' --stage 'Buildable' --status 'Todo')
eng move --num "$item" --to-status "In Progress" >/dev/null

VERDICT_PATH="$REPO/verdict.json"
cat > "$VERDICT_PATH" <<EOF
{
  "verdict": "PASS",
  "issue": $item,
  "pr": 1,
  "merge_conditions": [
    {"id": "c1", "description": "d1", "met": true}
  ]
}
EOF
eng close --num "$item" --verdict "$VERDICT_PATH" --pr 1 >/dev/null

[ -f "$JOURNAL" ] || fail "canonical transition journal was not created at $JOURNAL"

echo "--- Test case 1: real transition lifecycle replays to an empty diff ---"
python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" || \
  fail "expected real lifecycle journal to replay cleanly"
echo "PASS: real lifecycle replay matched board."

echo "--- Test case 2: link records do not masquerade as status transitions ---"
parent=$(eng create-ticket --title 'journal replay parent' --stage 'Buildable' --status 'Todo')
child=$(eng create-ticket --title 'journal replay child' --stage 'Buildable' --status 'Todo')
eng link --parent "$parent" --child "$child" >/dev/null
python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" || \
  fail "expected link journal record to replay without status false-positive"
echo "PASS: link records are ignored by state replay."

echo "--- Test case 3: board divergence is detected ---"
python3 "$GOV_TRK" --tracker "$T" move --num "$item" --status "In Progress" >/dev/null
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "expected divergence exit 1, got $rc: $output"
echo "$output" | grep -q "Item #$item STATUS mismatch" || \
  fail "expected status mismatch for #$item, got: $output"
echo "PASS: divergence was detected."

echo "--- Test case 4: malformed journal fails closed ---"
printf '{not-json}\n' > "$JOURNAL"
set +e
output=$(python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "expected malformed journal exit 2, got $rc: $output"
echo "$output" | grep -q "Malformed journal line" || \
  fail "expected malformed-line diagnostic, got: $output"
echo "PASS: malformed journal failed closed."

echo "--- All journal-replay tests passed! ---"
