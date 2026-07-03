#!/bin/bash
# board-lint-empty-status.sh — governance scenario: board-lint's empty-Status rule + --fix.
#
# The bug (#255/#256, "detector blinded"): a recovery pointer created with a Stage but NO Status is
# invisible to the dropped-handoff detector — a Stage∈{Consideration,Recirculation} item that carries
# an empty/missing Status silently never gets drained. This scenario proves `idc_board_lint.py`:
#   (a) FLAGS such an item `empty-status` (enforcing the Stage∈{Consideration,Recirculation}
#       invariant that those stages MUST carry a Status), and
#   (b) under `--fix` emits the repaired record (`Status=Todo`) a caller applies to the live board.
#
# board-lint reads issue JSON on stdin and is github-only + advisory (no live board handle), so the
# `--fix` is proven HERMETICALLY: it emits the repair a caller applies — it does not itself mutate a
# board. We feed JSON arrays on stdin exactly as phase1-doctor-board-lint.sh does.
#
# Red-when-broken (the honesty guard): temporarily break the empty-Status detection line (or the
# `--fix` coercion) in idc_board_lint.py and re-run — the contrast asserts (a Status=Todo item is NOT
# flagged; a Buildable+null item is NOT empty-status flagged) plus the positive flags flip RED.
#
# Usage: bash tests/smoke/governance/board-lint-empty-status.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
LINT="$PLUGIN/scripts/idc_board_lint.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$LINT" ] || fail "board-lint helper not found at $LINT"

# run_lint <json> [extra-args…] -> sets $OUT (stdout) and $RC (exit). printf '%s' is escape-safe.
run_lint() { local j="$1"; shift; OUT="$(printf '%s' "$j" | python3 "$LINT" "$@")"; RC=$?; }
assert_out() { printf '%s' "$OUT" | grep -qE "$1" || fail "$2 — got: $OUT"; }
refute_out() { printf '%s' "$OUT" | grep -qE "$1" && fail "$2 — got: $OUT"; return 0; }

# --- 1. Recirculation + status:null -> flagged empty-status (the #255/#256 detector-blinding repro) -
run_lint '[{"number":310,"title":"recovery pointer","stage":"Recirculation","status":null,"blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "empty-status recirc: helper exit $RC (want 0 — advisory)"
assert_out '#310 .*: empty-status —' "Recirculation + null Status must be flagged empty-status"
assert_out '^board-lint: 1 flagged of 0 scanned \(0 schema, 0 prose-dep, 1 empty-status\)$' \
  "empty-status must tally (… 1 empty-status) and NOT count the pointer toward scanned (0 scanned)"

# --- 2. Consideration + status:null -> flagged empty-status (both invariant stages) ----------------
run_lint '[{"number":311,"title":"consideration pointer","stage":"Consideration","status":null,"blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "empty-status consideration: helper exit $RC (want 0)"
assert_out '#311 .*: empty-status —' "Consideration + null Status must be flagged empty-status"

# --- 3. empty-string Status -> flagged; "none" sentinel Status -> flagged --------------------------
# idc_gh_board.py OMITS absent fields and doctor's index pass re-materializes a missing Status as the
# sentinel string "none": all three (null / "" / "none") mean "no Status" and must flag.
run_lint '[{"number":312,"title":"empty-string status","stage":"Recirculation","status":"","blocked_by":[]}]'
assert_out '#312 .*: empty-status —' 'empty-string ("") Status must be flagged empty-status'
run_lint '[{"number":313,"title":"none sentinel","stage":"Consideration","status":"none","blocked_by":[]}]'
assert_out '#313 .*: empty-status —' 'the doctor "none" sentinel Status must be flagged empty-status'

# --- 4. --fix emits the repaired record (Status=Todo) a caller applies -----------------------------
# board-lint is a stdin tool with NO board handle, so --fix cannot mutate a live board; it EMITS the
# repair. Assert the --fix output names the seeded item with Status=Todo (proven hermetically).
run_lint '[{"number":310,"title":"recovery pointer","stage":"Recirculation","status":null,"blocked_by":[]}]' --fix
[ "$RC" -eq 0 ] || fail "--fix: helper exit $RC (want 0)"
assert_out '^would-fix: #310 Status=Todo$' "--fix must emit the proposed repair 'would-fix: #310 Status=Todo' (future-tense: it proposes, never mutates)"
# --fix still surfaces the finding + summary (advisory report is not suppressed by the repair emit).
assert_out '#310 .*: empty-status —' "--fix must still report the empty-status finding"

# --- 5. red-when-broken CONTRAST: a Status=Todo item in either stage is NOT flagged ----------------
# Flips RED if the rule fires on a well-formed pointer (Todo is the valid, non-flagged state). Todo
# items ride index-only (not scanned), so with no build-eligible item the board is clean (0 scanned).
run_lint '[{"number":320,"title":"good recirc","stage":"Recirculation","status":"Todo","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "todo recirc: helper exit $RC (want 0)"
assert_out '^board-lint: clean \(0 scanned\)$' "a Recirculation + Status=Todo item must NOT be flagged (red-when-broken)"
refute_out '#320' "#320 (Status=Todo) must not be flagged empty-status"
run_lint '[{"number":321,"title":"good consideration","stage":"Consideration","status":"Todo","blocked_by":[]}]'
assert_out '^board-lint: clean \(0 scanned\)$' "a Consideration + Status=Todo item must NOT be flagged (red-when-broken)"
refute_out '#321' "#321 (Status=Todo) must not be flagged empty-status"

# --- 6. scope guard: a Buildable + null status object is NOT empty-status flagged (it is index-only
# per the M1 root fix). The empty-status rule is scoped to Consideration/Recirculation ONLY, so it
# must not widen to Buildable and re-introduce a spurious flag on the null-status index object.
run_lint '[{"number":950,"stage":"Buildable","status":null,"blocked_by":[]}]'
assert_out '^board-lint: clean \(0 scanned\)$' "a Buildable + null status object must stay index-only (not empty-status flagged)"
refute_out 'empty-status' "the empty-status rule must NOT fire on a Buildable-stage object (scope guard)"

# --- 7. back-compat: zero empty-status findings keep the summary byte-for-byte identical -----------
# A clean Buildable contract must still read exactly 'board-lint: clean (1 scanned)' with NO
# empty-status clause (the phase1-doctor-board-lint.sh exact-match asserts depend on this).
C='GOAL: do a thing\nVERIFICATION SURFACE: run the suite\nCONSTRAINTS: none\nBOUNDARIES: touch x/; off-limits y/\nITERATION POLICY: record-and-vary\nBLOCKED-STOP: 3 attempts\nASSUMPTIONS: none\nDependencies: blocked-by #0 (none)\nTrace: docs/plan.md'
run_lint '[{"number":1,"title":"clean","body":"'"$C"'","blocked_by":[]}]'
assert_out '^board-lint: clean \(1 scanned\)$' "a clean Buildable board must keep the byte-identical summary (no empty-status clause when count 0)"
refute_out 'empty-status' "the zero-count summary must NOT carry an empty-status clause"

echo "PASS: board-lint flags + --fixes empty-Status Consideration/Recirculation items; Todo/Buildable not flagged; zero-count summary byte-identical"
