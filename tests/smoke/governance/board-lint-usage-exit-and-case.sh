#!/bin/bash
# idc-assert-class: behavior
# board-lint-usage-exit-and-case.sh — governance scenario: board-lint's exit codes are
# unambiguous and its Stage/Status matching is case-insensitive (#132).
#
# The two latent robustness gaps (Phase 0 review, deferred as #132):
#   (a) argparse's default usage-error exit is 2 — the SAME code the unreadable-stdin path uses,
#       so automation reading the exit code could not tell a typo'd flag from bad input. Usage
#       errors now exit 64 (EX_USAGE); 2 stays bad-input.
#   (b) Stage/Status lane matching was case-sensitive (exact `Recirculation`/`Todo`/`Done`
#       spellings only) — a hand-edited board emitting `recirculation`/`done` silently missed
#       every rule keyed on those lanes (empty-status, retired-recirc, the scan lane itself).
#
# Red-when-broken (proven at 826f6da, the pre-fix code):
#   - (a) `printf '[]' | idc_board_lint.py --wibble` exited 2 (same as bad stdin) → the exit-64
#     assert here was RED.
#   - (b) a `{"stage":"recirculation","status":null}` item printed `board-lint: clean (0 scanned)`
#     → the empty-status assert here was RED; likewise the lowercase scan-lane and lowercase
#     retired-recirc asserts.
#
# Usage: bash tests/smoke/governance/board-lint-usage-exit-and-case.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
LINT="$PLUGIN/scripts/idc_board_lint.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$LINT" ] || fail "board-lint helper not found at $LINT"

# run_lint <json> [extra-args…] -> sets $OUT (stdout) and $RC (exit). printf '%s' is escape-safe.
run_lint() { local j="$1"; shift; OUT="$(printf '%s' "$j" | python3 "$LINT" "$@")"; RC=$?; }
assert_out() { printf '%s' "$OUT" | grep -qE "$1" || fail "$2 — got: $OUT"; }
refute_out() { printf '%s' "$OUT" | grep -qE "$1" && fail "$2 — got: $OUT"; return 0; }

# --- 1. usage error (typo'd flag) -> exit 64, NOT the bad-input 2 ----------------------------------
# The discriminating artifact is the pair (exit 64, the `usage error:` stderr sentence) — only the
# argparse path produces it. Pre-fix this exited 2, indistinguishable from unreadable stdin.
ERR="$(printf '[]' | python3 "$LINT" --wibble 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 64 ] || fail "typo'd flag must exit 64 (EX_USAGE), got $RC — a usage error is indistinguishable from bad input at exit 2"
printf '%s' "$ERR" | grep -q 'idc-board-lint: usage error:' \
  || fail "usage-error stderr must carry the 'idc-board-lint: usage error:' sentence — got: $ERR"

# --- 2. positive control: unreadable stdin still exits 2 (the documented bad-input code) -----------
ERR="$(printf 'not json' | python3 "$LINT" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] || fail "unreadable stdin must keep exit 2 (bad input), got $RC"
printf '%s' "$ERR" | grep -q 'cannot parse stdin' || fail "bad-input stderr must name the parse failure — got: $ERR"

# --- 3. positive control: a clean run still exits 0 ------------------------------------------------
run_lint '[]'
[ "$RC" -eq 0 ] || fail "clean run must exit 0, got $RC"
assert_out '^board-lint: clean \(0 scanned\)$' "clean-run summary must be byte-identical"

# --- 4. case-varied invariant stage -> empty-status still fires ------------------------------------
# Pre-fix: 'recirculation' was not in INVARIANT_STAGES (exact-case), so this printed clean.
run_lint '[{"number":610,"title":"case-varied pointer","stage":"recirculation","status":null,"blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "case-varied empty-status: helper exit $RC (want 0 — advisory)"
assert_out '#610 .*: empty-status —' "a lowercase 'recirculation' pointer with no Status must still flag empty-status"

# --- 5. case-varied build-eligible lane -> still scanned (schema rule reaches it) ------------------
# Pre-fix: {'buildable','todo'} failed the exact-case lane match, rode index-only, and the malformed
# body was never schema-scanned — 'clean (0 scanned)'.
run_lint '[{"number":611,"title":"case-varied lane","stage":"buildable","status":"todo","body":"not a contract","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "case-varied scan lane: helper exit $RC (want 0)"
assert_out '#611 .*: schema —' "a lowercase buildable+todo issue must be scanned (schema rule must reach its body)"
assert_out 'of 1 scanned' "the case-varied lane item must count toward scanned"

# --- 6. case-varied blocker lanes -> retired-recirc still fires ------------------------------------
# Pre-fix: the blocker's 'done' status read as a LIVE blocker (exact-case Done match failed), so the
# retired-recirc rule stayed silent on a spuriously-eligible paused issue.
C='GOAL: do a thing\nVERIFICATION SURFACE: run the suite\nCONSTRAINTS: none\nBOUNDARIES: touch x/; off-limits y/\nITERATION POLICY: record-and-vary\nBLOCKED-STOP: 3 attempts\nASSUMPTIONS: none\nDependencies: blocked-by #0 (none)\nTrace: docs/plan.md'
run_lint '[{"number":620,"title":"paused origin","body":"'"$C"'","blocked_by":[621]},
           {"number":621,"title":"retired recirc ticket","stage":"recirculation","status":"done"}]'
[ "$RC" -eq 0 ] || fail "case-varied retired-recirc: helper exit $RC (want 0)"
assert_out '#620 .*: retired-recirc —' "a blocker at lowercase recirculation/done must still read as a retired Recirculation ticket"

# --- 7. contrast: canonical spellings keep the exact pre-existing behavior -------------------------
run_lint '[{"number":630,"title":"good recirc","stage":"Recirculation","status":"Todo","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "canonical spellings: helper exit $RC (want 0)"
assert_out '^board-lint: clean \(0 scanned\)$' "canonical Recirculation+Todo must stay clean (no case-normalization regression)"
refute_out '#630' "#630 (canonical, well-formed) must not be flagged"

echo "PASS: board-lint usage errors exit 64 (bad input stays 2); Stage/Status matching is case-insensitive with canonical behavior unchanged"
