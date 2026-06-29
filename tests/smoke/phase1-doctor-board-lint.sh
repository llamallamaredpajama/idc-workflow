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

# --- 4b. degraded mode: prose-dep body + blocked_by null (lookup FAILED) -> NOT prose-flagged ----
# FINDING 3: a FAILED `gh api …/dependencies/blocked_by` lookup must arrive as null (UNKNOWN), never
# coerced to [] — the helper can't tell [] (confirmed no link) from a failed call, and a prose dep we
# could not disprove must NOT be flagged. Load-bearing red-when-broken assertion: it FAILs if the
# helper regresses to treating null as "no link" (drops the `if blocked_by is None` guard / re-adds
# the `or []` coercion), which would falsely flag this exactly like test #3. (The summary itself now
# carries the M1 degraded-mode clause — asserted in section 4c — so this guards the not-flagged half.)
run_lint '[{"number":482,"title":"repro","body":"'"$PROSE"'","blocked_by":null}]'
[ "$RC" -eq 0 ] || fail "null blocked_by: helper exit $RC (want 0)"
refute_out '#482' "prose dep with blocked_by=null (lookup FAILED, UNKNOWN) must NOT be prose-flagged (red-when-broken, FINDING 3)"

# --- 4c. M1 degraded-mode visibility: blocked_by=null surfaces the indeterminate count ----------
# A FAILED dependencies lookup arrives as null (UNKNOWN). Pre-M1 the helper printed a bare
# `clean (N scanned)`, so a board-wide dependencies-API outage (every issue → null → nothing
# flagged) masqueraded as a true all-clear. M1: the summary appends `; <U> dependency lookups
# indeterminate` *inside* the parens whenever U>0, making the degraded state visible. Each assert
# below goes RED if that clause is dropped (red-when-broken).

# (a) single null issue -> the clean summary now carries '1 dependency lookup indeterminate' (singular).
run_lint '[{"number":482,"title":"repro","body":"'"$PROSE"'","blocked_by":null}]'
[ "$RC" -eq 0 ] || fail "single null: helper exit $RC (want 0)"
assert_out '^board-lint: clean \(1 scanned; 1 dependency lookup indeterminate\)$' \
  "single blocked_by=null must surface '1 dependency lookup indeterminate' (M1 degraded-mode visibility)"

# (b) board-wide outage: EVERY issue null -> clean, but the count exposes the degradation (no silent all-clear).
run_lint '[{"number":1,"title":"a","body":"'"$C"'","blocked_by":null},{"number":2,"title":"b","body":"'"$C"'","blocked_by":null}]'
[ "$RC" -eq 0 ] || fail "board-wide null: helper exit $RC (want 0)"
assert_out '^board-lint: clean \(2 scanned; 2 dependency lookups indeterminate\)$' \
  "board-wide degraded lookup must surface '2 dependency lookups indeterminate' (no silent all-clear)"

# (c) flagged AND degraded: the clause rides inside the flagged summary's parens too (not just clean).
run_lint '[{"number":3,"title":"bad","body":"GOAL: do\njust prose","blocked_by":null}]'
[ "$RC" -eq 0 ] || fail "flagged+null: helper exit $RC (want 0)"
assert_out '^board-lint: 1 flagged of 1 scanned \(1 schema, 0 prose-dep; 1 dependency lookup indeterminate\)$' \
  "a flagged summary must also carry the indeterminate clause when U>0"

# (d) back-compat: with zero null issues the summary is byte-for-byte the pre-M1 form (no clause).
run_lint '[{"number":1,"title":"clean","body":"'"$C"'","blocked_by":[]}]'
assert_out '^board-lint: clean \(1 scanned\)$' "U==0 must leave the clean summary unchanged (no indeterminate clause)"
refute_out 'indeterminate' "U==0 summary must NOT carry the indeterminate clause"

# --- 5. blocks-on:#N fallback line present, empty blocked_by -> NOT flagged ---------------------
FB="$C"'\n\nblocks-on:#200'
run_lint '[{"number":5,"title":"fallback","body":"'"$FB"'","blocked_by":[]}]'
assert_clean "documented blocks-on:#N fallback line must count as a recorded link (not flagged)"

# --- 6. [operator-action] issue -> skipped (not counted, not flagged) ---------------------------
run_lint '[{"number":1,"title":"clean","body":"'"$C"'","blocked_by":[]},{"number":9,"title":"[operator-action] approve","body":"junk","blocked_by":[]}]'
assert_clean "[operator-action] issue must be skipped (scanned count excludes it)"
refute_out '#9' "[operator-action] issue #9 must not be flagged"

# --- 6b. retired-recirc rule: a Buildable eligible ONLY via a retired (Done) Recirculation ticket -
# The paused-issue re-link (idc-plan Phase 4) re-points a paused origin issue OFF its retired recirc
# ticket onto the real new unblockers. If that step is skipped, the paused issue stays blocked_by a
# Stage=Recirculation ticket that has since gone Done — its last blocker satisfied, so it goes
# SPURIOUSLY eligible (the premature-eligibility / infinite-recirc trap). The rule needs each
# blocker's stage+status, supplied by OPTIONAL "stage"/"status" fields on the (index-only) blocker
# object; absent → the rule stays silent (the thin-shape fixtures #1–#6 above prove back-compat).

# (a) positive: a clean Buildable (#700) blocked_by a Done Recirculation ticket (#701) -> flagged.
#     #701 carries stage=Recirculation/status=Done so it is INDEX-ONLY (supplies the blocker's lane,
#     never scanned as a contract — its non-contract body must not false-flag, nor inflate `scanned`).
run_lint '[{"number":700,"title":"paused origin","body":"'"$C"'","blocked_by":[701]},{"number":701,"title":"retired recirc ticket","stage":"Recirculation","status":"Done","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "retired-recirc: helper exit $RC (want 0 — advisory)"
assert_out '#700 .*: retired-recirc —' "a Buildable eligible only via a retired Done Recirculation ticket must be flagged retired-recirc"
assert_out '^board-lint: 1 flagged of 1 scanned \(0 schema, 0 prose-dep, 1 retired-recirc\)$' \
  "retired-recirc must tally (… 1 retired-recirc) and NOT scan the index-only ticket (1 scanned, not 2)"

# (b) red-when-broken control: SAME shape but the blocker (#702) is a Done NORMAL issue (Stage=
#     Buildable), not a Recirculation ticket -> NOT flagged. Flips RED if the rule fires on any Done
#     blocker instead of specifically a retired Recirculation ticket.
run_lint '[{"number":700,"title":"paused origin","body":"'"$C"'","blocked_by":[702]},{"number":702,"title":"normal done dep","stage":"Buildable","status":"Done","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "retired-recirc control (Done normal): helper exit $RC (want 0)"
assert_clean "a Buildable blocked_by a Done NORMAL issue must NOT be flagged retired-recirc (red-when-broken)"
refute_out '#700' "#700 must not be flagged when its blocker is a Done normal issue (not a Recirculation ticket)"

# (c) red-when-broken control: re-linked onto a LIVE unblocker (#703 Stage=Buildable/Status=Todo —
#     the post-re-link desired state) -> NOT flagged. Both #700 and #703 are valid contracts, so the
#     clean count is 2. Flips RED if the rule fires whenever ANY blocker is present.
run_lint '[{"number":700,"title":"paused origin","body":"'"$C"'","blocked_by":[703]},{"number":703,"title":"live unblocker","body":"'"$C"'","stage":"Buildable","status":"Todo","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "retired-recirc control (live unblocker): helper exit $RC (want 0)"
assert_out '^board-lint: clean \(2 scanned\)$' "a paused issue re-linked onto a live Todo unblocker must NOT be flagged (post-re-link desired state)"
refute_out '#700' "#700 must not be flagged once re-linked onto a live unblocker"

# (d) back-compat: a thin blocker (#701, no stage/status) can't resolve to a Done Recirculation
#     ticket -> rule silent. Proves the rule fires ONLY when the blocker's stage/status are present.
run_lint '[{"number":700,"title":"paused origin","body":"'"$C"'","blocked_by":[701]},{"number":701,"title":"thin blocker","body":"'"$C"'","blocked_by":[]}]'
[ "$RC" -eq 0 ] || fail "retired-recirc back-compat (thin blocker): helper exit $RC (want 0)"
assert_out '^board-lint: clean \(2 scanned\)$' "a thin blocker (no stage/status) must leave the retired-recirc rule silent (optional-fields back-compat)"

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
# FINDING 3: Row 9 must distinguish an API failure from confirmed-no-link — on empty `gh api` stdout
# it sets the UNKNOWN sentinel (bb='null'), never unconditionally '[]'. Goes RED if it regresses to
# coercing a failed lookup to an empty list (the degraded-mode false-flag).
grep -qE "bb='null'" "$DOCTOR" \
  || fail "doctor.md Row 9 must set bb='null' (UNKNOWN) on gh-api failure, not '[]' (FINDING 3)"
# M1: Row 9 must map the helper's degraded-mode summary clause to a PASS-with-⚠ note (still PASS,
# never FAIL) so a board-wide dependencies-API outage can't read as a silent all-clear. Goes RED if
# the indeterminate handling is dropped from doctor.md.
printf '%s' "$DFLAT" | grep -qiE 'dependency lookups indeterminate' \
  || fail "doctor.md Row 9 must handle the 'dependency lookups indeterminate' degraded-mode summary (M1)"

# doctor stays read-only (also guarded by phase7-command-prose-invariants.sh; assert here too).
grep -qi 'read-only' "$DOCTOR" || fail "doctor.md must remain declared read-only"

# Board-read failure must SKIP, never a hollow clean: Row 9 reads the board via the paginating
# idc_gh_board.py and must CAPTURE it + guard the exit, so a failed/empty read can't pipe straight
# into a `board-lint: clean (0 scanned)` PASS (the silent-all-clear masking a board outage). Goes RED
# if Row 9 regresses to piping the unguarded read into the lint.
grep -q 'idc_gh_board\.py' "$DOCTOR" \
  || fail "doctor.md Row 9 must read the board via the paginating idc_gh_board.py (gh project item-list truncates at 30)"
grep -qE 'if ! board=\$\(python3 "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/idc_gh_board\.py"' "$DOCTOR" \
  || fail "doctor.md Row 9 must CAPTURE the idc_gh_board read + guard its exit — a failed read must SKIP, not a hollow 'clean (0 scanned)' PASS (no silent all-clear)"
# The failure branch must EMIT an explicit SKIP marker — a bare `:` no-op emits nothing and still
# reads as a silent all-clear (codex MAJOR). Goes RED if the marker echo is dropped/regressed.
grep -qE 'echo "board-lint: SKIP — github board unreadable' "$DOCTOR" \
  || fail "doctor.md Row 9 failure branch must EMIT an explicit 'board-lint: SKIP — github board unreadable' marker (not a silent ':' no-op)"
printf '%s' "$DFLAT" | grep -qiE 'no silent all-clear' \
  || fail "doctor.md Row 9 must state a board-read failure SKIPs (no silent all-clear)"

# --- 8b. LIVE wiring (5b): Row 9 feeds board-lint the whole-board {number,stage,status} INDEX -------
# The retired-recirc rule (helper sections 6b above) needs each blocker's lane to resolve a blocker
# number -> "Done Recirculation ticket". Section 6b proves board-lint FIRES on the index shape; this
# proves doctor EMITS it — without the index emission the rule is tested-but-dormant in production.
# Red-when-broken: delete the index-emission jq pass (or its non-Buildable exclusion) and these flip
# RED. The index pass is a SECOND jq over the already-captured $board (not a second board read), and
# it EXCLUDES the Buildable+Todo lane already emitted as rich objects so nothing is double-scanned
# (in_scan_lane() treats a stage≠Buildable / status≠Todo object as index-only).
grep -qE 'stage:[[:space:]]*\(\.stage[[:space:]]*//[[:space:]]*"Buildable"\),[[:space:]]*status:[[:space:]]*\.status' "$DOCTOR" \
  || fail "doctor.md Row 9 must emit whole-board {number,stage,status} INDEX objects so the retired-recirc rule can resolve a blocker (5b live wiring; the rule is dormant without it)"
printf '%s' "$DFLAT" | grep -qE 'and \(\.stage[[:space:]]*//[[:space:]]*"Buildable"\)=="Buildable"\)[[:space:]]*\|[[:space:]]*not\)' \
  || fail "doctor.md Row 9 index pass must EXCLUDE the Buildable+Todo lane already emitted as rich objects (| not) — no double-scan (5b)"
# the index pass must read the ALREADY-CAPTURED \$board, never a SECOND board read (no extra paginated
# fetch): the idc_gh_board.py INVOCATION appears exactly once (both jq passes share the one capture).
[ "$(grep -cE 'python3 "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/idc_gh_board\.py"' "$DOCTOR")" = "1" ] \
  || fail "doctor.md Row 9 must read the board ONCE — the index pass reuses the captured \$board, not a second idc_gh_board.py fetch (5b)"

# --- 8c. pass (i) guards draft project items (content:null) — symmetric with pass (ii) (5c) -------
# A *draft* project item has content:null, so `.content.number` yields the string "null"; pass (i)'s
# `[ -n "$n" ]` guard catches empty but NOT the literal "null", so without this guard Row 9 would run
# `gh issue view null`. Pass (ii) (the index pass) already carries `select(.content.number != null)`;
# pass (i) (the rich Buildable+Todo scan) must carry it too. Assert it on the SINGLE rich-pass jq line
# — the one carrying BOTH `select(.status=="Todo")` AND `select((.stage // "Buildable")=="Buildable")`
# — so the guard is proven present on PASS (I) specifically, not merely somewhere in the file.
# Red-when-broken: delete the guard from pass (i) and this flips RED. A global
# `grep -c 'select(.content.number != null)'` would NOT (the string also appears in pass (ii) + this
# comment), which is exactly why the assertion is anchored to the three-select rich-pass line.
grep -qE 'select\(\.status=="Todo"\).*select\(\(\.stage // "Buildable"\)=="Buildable"\).*select\(\.content\.number != null\)' "$DOCTOR" \
  || fail "doctor.md Row 9 pass (i) must guard draft items: its rich-pass jq line (status==Todo + stage==Buildable) must ALSO carry select(.content.number != null) (5c)"

# --- 9. Row 9 loop is shell-agnostic (zsh word-split hardening; the doctor.md plumbing) ----------
# FINDING 1: the real /idc:doctor Bash-tool shell is zsh (repo CLAUDE.md), where an unquoted
# `$nums` is NOT word-split — so a `nums=$(…); for n in $nums` loop runs ONCE over the whole
# newline blob, the helper gets `108\n109\n111` as one token, and Row 9 falsely reports
# `clean (0 scanned)`. Section #8 proves the helper directly; this section proves the doctor.md
# SHELL SNIPPET that builds the helper's input iterates per-issue under zsh too.

# (a) static guard, tied to commands/doctor.md — goes RED if Row 9 regresses to the word-split form.
grep -q '| while IFS= read -r n' "$DOCTOR" \
  || fail "doctor.md Row 9 must pipe the issue-number list into a 'while IFS= read -r n' loop (shell-agnostic)"
# Anchor to a real loop line (leading whitespace then `for`), so a prose/comment mention of the
# pattern can't trip it — this tests the CODE, not the surrounding text.
if grep -qE '^[[:space:]]*for n in \$nums' "$DOCTOR"; then
  fail "doctor.md Row 9 must NOT use 'for n in \$nums' — unquoted word-split is a no-op under zsh (FINDING 1)"
fi

# (b) functional guard — encode the contrast under zsh. The fixed pipe-into-while-read form iterates
# per line (3); the legacy `for n in $nums` form collapses (zsh does not word-split an unquoted
# newline blob). Hermetic (no live GitHub); `printf '%s\n'` mirrors jq's trailing newline so `read`
# sees all three lines. zsh-absent → SKIP (not FAIL): static guard 9a is the always-on protection, so
# this functional cross-check is best-effort and must not break the suite on a bash-only host.
if command -v zsh >/dev/null 2>&1; then
  wc_while="$(zsh -c 'printf "%s\n" 108 109 111 | while IFS= read -r n; do [ -n "$n" ] && echo x; done | wc -l | tr -d " "')"
  [ "$wc_while" = "3" ] \
    || fail "the while-read form must iterate 3x under zsh over a 3-issue list — got '$wc_while' (Row 9 fix ineffective)"
  # The buggy `for n in $nums` form must NOT iterate per line under zsh (it collapses the blob).
  # Assert "not 3" rather than "exactly 1" so an exotic SH_WORD_SPLIT-enabled zsh can't false-FAIL.
  wc_for="$(zsh -c 'nums=$(printf "%s\n" 108 109 111); c=0; for n in $nums; do c=$((c+1)); done; echo $c')"
  [ "$wc_for" != "3" ] \
    || fail "the legacy 'for n in \$nums' form iterated 3x under zsh — the word-split bug this guards appears absent (got '$wc_for')"
else
  echo "SKIP: zsh absent — Row 9 functional shell-contrast skipped (static guard 9a still enforced)"
fi

echo "PASS: board-lint helper classifies schema/prose-dep/retired-recirc/link/operator/skip + doctor Row 9 advisory + shell-agnostic guards hold"
