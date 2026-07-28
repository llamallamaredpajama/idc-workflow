#!/usr/bin/env bash
set -euo pipefail

# idc-assert-class: behavior
# Red-when-broken: drives the real transition engine producer, then requires replay to consume the
# canonical docs/workflow/transition-journal.ndjson journal and fail closed on corrupt NDJSON.

. "$(dirname "$0")/lib.sh"
gov_engine_env
CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" config user.email test@example.com >/dev/null 2>&1
git -C "$REPO" config user.name Test >/dev/null 2>&1
mkdir -p "$REPO/docs/workflow/code-reviews"

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

item=$(eng create-ticket --title 'journal replay lifecycle' --stage 'Buildable' --status 'Todo')
eng move --num "$item" --to-status "In Progress" >/dev/null

VERDICT_PATH="$REPO/docs/workflow/code-reviews/journal-replay-pass.json"
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
python3 "$CHECK" "$VERDICT_PATH" >/dev/null 2>&1 || fail "initial replay verdict did not validate"
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

echo "--- Test case 2b: a dispose (non-verdict terminal disposition) close replays to an empty diff ---"
# A drained Recirculation ticket reaches Done through the guarded `dispose --disposition drained`
# door (no review verdict). Both the engine-journaled create AND the dispose close must reconstruct,
# so replay of a lifecycle that includes a disposition close is still an empty diff (the #150
# replay-consistency requirement — otherwise the janitor's default replay would false-flag every
# drained item). The ticket is created THROUGH the engine (journaled) with the idc-recirc-source
# provenance marker the drained guard requires.
DRAIN_MARKER='<!-- idc-recirc-source: {"origin":9,"what":"x","key":"k-replay-1"} -->'
drain=$(eng recirculate-intake --title 'recirc(nit): drainable via replay' --body "$DRAIN_MARKER" 2>/dev/null)
[ -n "$drain" ] || fail "could not seed the Recirculation ticket via recirculate-intake"
eng dispose --disposition drained --num "$drain" >/dev/null 2>&1 || \
  fail "dispose --disposition drained refused a freshly filed recirc ticket"
python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" || \
  fail "expected a lifecycle including a dispose (drained) close to replay to an empty diff"
echo "PASS: a dispose (drained) close reconstructs to Done — replay stays an empty diff."

echo "--- Test case 2c: a retired pointer (Stage advanced out-of-band) replays to an empty diff ---"
# The normal Plan lifecycle: create the pointer at Consideration (journaled), advance it
# Consideration → Planning via a RAW setField (no Stage engine op → NOT journaled), link a decomposition
# child (`--kind sub` — retirement requires the DECOMPOSITION link, not a blocks-edge; codex round-13
# P2), then retire it. The terminal `dispose` must journal the FINAL Stage (Planning) so replay
# reconstructs Planning/Done — matching the board — instead of the create-time Consideration/Done that
# would false-flag every retired pointer and block the default-on replay gate (#150).
ptr=$(eng create-pointer --title 'consideration: to retire' --stage Consideration --status Todo 2>/dev/null)
[ -n "$ptr" ] || fail "could not create the consideration pointer"
python3 "$GOV_TRK" --tracker "$T" set --num "$ptr" --field Stage --value Planning >/dev/null \
  || fail "could not advance the pointer Consideration -> Planning (raw setField)"
kid=$(eng create-ticket --title 'buildable: decomposition child' --stage Buildable --status Todo 2>/dev/null)
[ -n "$kid" ] || fail "could not create the decomposition child"
eng link --parent "$ptr" --child "$kid" --kind sub >/dev/null 2>&1 || fail "could not link the decomposition child to the pointer"
eng dispose --disposition retired --num "$ptr" --child "$kid" >/dev/null 2>&1 \
  || fail "dispose --disposition retired refused the decomposed Planning pointer"
python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" || \
  fail "expected a retired-pointer lifecycle (Stage advanced out-of-band) to replay to an empty diff"
echo "PASS: a retired pointer whose Stage advanced out-of-band reconstructs to Planning/Done — replay stays an empty diff."

echo "--- Test case 2d: a close does NOT launder an out-of-band Stage drift (replay still detects it) ---"
# A build item stays Buildable; a `close` must NOT stamp the board's current Stage into the journal,
# or an out-of-band Stage mutation (whose close guards do not validate Stage) would be laundered into a
# clean reconciliation. Drift a closed-path item's Stage out-of-band, close it, and require replay to
# STILL report the Stage divergence.
bi=$(eng create-ticket --title 'buildable: drifted then closed' --stage 'Buildable' --status 'In Progress' 2>/dev/null)
[ -n "$bi" ] || fail "could not create the buildable item"
python3 "$GOV_TRK" --tracker "$T" set --num "$bi" --field Stage --value Recirculation >/dev/null \
  || fail "could not drift the item's Stage out-of-band"
VD_PATH="$REPO/docs/workflow/code-reviews/journal-replay-drift.json"
cat > "$VD_PATH" <<EOF
{"verdict":"PASS","issue":$bi,"pr":7,"findings":[]}
EOF
python3 "$CHECK" "$VD_PATH" >/dev/null 2>&1 || fail "the drift-close verdict did not validate"
eng close --num "$bi" --verdict "$VD_PATH" --pr 7 >/dev/null 2>&1 || fail "the guarded close failed"
set +e
out=$(python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a close laundered an out-of-band Stage drift — replay should have reported divergence (exit 1), got $rc"
echo "$out" | grep -q "Item #$bi STAGE mismatch" || fail "expected a Stage mismatch for #$bi, got: $out"
echo "PASS: a close does not launder an out-of-band Stage drift — replay still detects the divergence."
# Reset for the following cases: bring the drifted item back so it is not a lingering divergence.
python3 "$GOV_TRK" --tracker "$T" set --num "$bi" --field Stage --value Buildable >/dev/null

echo "--- Test case 2e: gate-approved does NOT launder an out-of-band Stage drift either ---"
# A gate-approved disposition does NOT validate the item's Stage (it checks the operator-action marker
# / approval artifact), so it must record NO Stage — else an out-of-band Stage drift on a gate would be
# laundered clean. Only a disposition whose guard VALIDATED the Stage (retired/drained) journals it.
gate=$(eng create-ticket --title '[operator-action] a gate to drift' --stage 'Buildable' --status 'Todo' 2>/dev/null)
[ -n "$gate" ] || fail "could not create the gate item"
python3 "$GOV_TRK" --tracker "$T" set --num "$gate" --field Stage --value Recirculation >/dev/null \
  || fail "could not drift the gate's Stage out-of-band"
eng dispose --disposition gate-approved --num "$gate" >/dev/null 2>&1 || fail "gate-approved dispose failed"
set +e
out=$(python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "gate-approved laundered an out-of-band Stage drift — replay should report divergence (exit 1), got $rc"
echo "$out" | grep -q "Item #$gate STAGE mismatch" || fail "expected a Stage mismatch for gate #$gate, got: $out"
echo "PASS: gate-approved (Stage NOT guard-validated) records no Stage — replay still detects the drift."
python3 "$GOV_TRK" --tracker "$T" set --num "$gate" --field Stage --value Buildable >/dev/null

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
