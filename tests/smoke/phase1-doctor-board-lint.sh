#!/bin/bash
# Phase 1 smoke — /idc:doctor's advisory board-lane lint (Row 9) + the shipped helper
# scripts/idc_board_lint.py. Hermetic: real round-trips feed JSON on stdin, no live GitHub.
#
# The schema check (idc_schema_check.py) is Plan's gate — it runs once, at issue creation. An
# issue that bypassed Plan can sit build-eligible (Status=Todo, Stage=Buildable) while malformed
# and/or carrying a prose-only dependency. Row 9 re-scans that lane read-only and flags it. This
# test exercises the helper's classifications + the doctor.md static guards that keep the row
# advisory and reusing (not duplicating) the schema check.
#
# Failing-test-first: the doctor static guards below fail until commands/doctor.md gains Row 9.
#
# Usage: bash tests/smoke/phase1-doctor-board-lint.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$PLUGIN/scripts/idc_board_lint.py"
DOCTOR="$PLUGIN/commands/doctor.md"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$LINT" ] || fail "board-lint helper not found at $LINT (not implemented yet)"

# A valid Buildable goal-contract body (all CONTRACT_REQUIRED elements; GOAL/VS non-empty;
# BOUNDARIES declares touch + off-limits). `\n` here is a literal JSON string escape — printf '%s'
# does NOT expand it (unlike echo), so the JSON stays a single valid line.
C='GOAL: do a thing\nVERIFICATION SURFACE: run the suite\nCONSTRAINTS: none\nBOUNDARIES: touch x/; off-limits y/\nITERATION POLICY: record-and-vary\nBLOCKED-STOP: 3 attempts\nASSUMPTIONS: none\nDependencies: blocked-by #0 (none)\nTrace: docs/plan.md'

# run_lint <json-array> -> sets $OUT (stdout) and $RC (helper exit). printf '%s' is escape-safe.
run_lint()     { OUT="$(printf '%s' "$1" | python3 "$LINT")"; RC=$?; }
# assertion helpers (sibling phase1-lint-rules.sh establishes this expect_* pattern).
assert_out()   { printf '%s' "$OUT" | grep -qE "$1" || fail "$2 — got: $OUT"; }
refute_out()   { printf '%s' "$OUT" | grep -q  "$1" && fail "$2 — got: $OUT"; return 0; }
assert_clean() { assert_out '^board-lint: clean \(1 scanned\)$' "$1"; }

# --- 1. clean Buildable contract -> not flagged ------------------------------------------------
run_lint '[{"number":1,"title":"clean","body":"'"$C"'","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "clean contract: helper exit $RC (want 0)"
assert_clean "clean contract should report 'board-lint: clean (1 scanned)'"
refute_out '#1' "clean contract should not flag #1"

# --- 2. malformed body -> flagged schema -------------------------------------------------------
run_lint '[{"number":2,"title":"malformed","body":"GOAL: do\njust prose","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "malformed: helper exit $RC (want 0 — advisory)"
assert_out '#2 .*: schema —' "malformed body should be flagged 'schema'"
assert_out '^board-lint: 1 flagged of 1 scanned \(1 schema, 0 prose-dep\)$' "malformed should tally (1 schema, 0 prose-dep)"

# --- 3. prose-dep body, empty blocked_by -> flagged prose-dep (the #482 repro) ------------------
PROSE="$C"'\n\nThis is blocked on the upstream refactor.'
run_lint '[{"number":482,"title":"repro","body":"'"$PROSE"'","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "prose-dep: helper exit $RC (want 0)"
assert_out '#482 .*: prose-dep —' "prose dep with empty blocked_by should be flagged 'prose-dep'"
assert_out '^board-lint: 1 flagged of 1 scanned \(0 schema, 1 prose-dep\)$' "prose-dep should tally (0 schema, 1 prose-dep)"

# --- 4. red-when-broken: SAME prose-dep body but native blocked_by present -> NOT flagged -------
# Fails red if link-awareness regresses (per "tests aren't trusted until red-when-broken").
run_lint '[{"number":482,"title":"repro","body":"'"$PROSE"'","blocked_by":[99]}]'
[ "$RC" -eq 0 ] || fail "linked prose-dep: helper exit $RC (want 0)"
assert_clean "prose dep WITH native blocked_by must NOT be flagged (red-when-broken)"

# --- 5. blocks-on:#N fallback line present, empty blocked_by -> NOT flagged ---------------------
FB="$C"'\n\nblocks-on:#200'
run_lint '[{"number":5,"title":"fallback","body":"'"$FB"'","blocked_by":[]}]'
assert_clean "documented blocks-on:#N fallback line must count as a recorded link (not flagged)"

# --- 6. [operator-action] issue -> skipped (not counted, not flagged) ---------------------------
run_lint '[{"number":1,"title":"clean","body":"'"$C"'","blocked_by":[]},{"number":9,"title":"[operator-action] approve","body":"junk","blocked_by":[]}]'
assert_clean "[operator-action] issue must be skipped (scanned count excludes it)"
refute_out '#9' "[operator-action] issue #9 must not be flagged"

# --- 7. unparseable stdin -> exit 2 (doctor reads this as 'could not determine' -> SKIP) --------
printf '%s' 'not json {{' | python3 "$LINT" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "unparseable stdin must exit 2 so doctor SKIPs (never FAIL)"

# --- 8. static guards on commands/doctor.md ----------------------------------------------------
[ -f "$DOCTOR" ] || fail "commands/doctor.md missing"
grep -q 'idc_board_lint\.py' "$DOCTOR" \
  || fail "doctor.md must reference the idc_board_lint.py helper (Row 9 not added yet)"
# Row 9 must be advisory: the prose must say so, never a hard FAIL. (Whitespace-normalize so a
# wrapped phrase still matches.)
DFLAT="$(tr '\n' ' ' < "$DOCTOR" | tr -s ' ')"
printf '%s' "$DFLAT" | grep -qiE 'build-lane hygiene' \
  || fail "doctor.md must add a 'Build-lane hygiene' row (Row 9)"
printf '%s' "$DFLAT" | grep -qiE 'advisory' \
  || fail "doctor.md Row 9 must declare itself advisory"
printf '%s' "$DFLAT" | grep -qiE 'never FAIL' \
  || fail "doctor.md Row 9 must state it never FAILs"
# github-only / filesystem-SKIP scope is the load-bearing backend finding from the plan.
printf '%s' "$DFLAT" | grep -qiE 'filesystem' \
  || fail "doctor.md Row 9 must note the filesystem backend SKIP (github-only scan)"
# doctor stays read-only (also guarded by phase7-command-prose-invariants.sh; assert here too).
grep -qi 'read-only' "$DOCTOR" || fail "doctor.md must remain declared read-only"

echo "PASS: board-lint helper classifies schema/prose-dep/link/operator/skip + doctor Row 9 advisory guards hold"
