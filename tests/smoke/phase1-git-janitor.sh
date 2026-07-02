#!/bin/bash
# Phase 1 smoke — the deterministic board↔git reconciler `scripts/idc_git_janitor.py` (#97, design §A).
#
# The FIRST real-git lifecycle smoke phase: a hermetic repo with a `git init` + a bare "origin" — real
# branches, real worktrees, real merges, real deletes, no GitHub. Exercises all four verdict tiers over
# the filesystem backend, `--apply-safe`, and the fail-closed exit contract.
#
# BEHAVIOR proven (each assertion red-when-broken — a contrast pair or a state check that a regression flips):
#   * a clean coherent repo → COHERENT, exit 0 (the e2e post-condition contract: clean repo exits 0).
#   * a merged IDC branch (local + remote) → SAFE-FIX; a clean merged IDC worktree → SAFE-FIX;
#     a board issue whose merged branch left Status≠Done (the filesystem "Done-but-open" analog) → SAFE-FIX;
#     a Done board issue whose branch merged → NO board finding (coherent — the contrast that proves the
#     coherence check fires ONLY on incoherence).
#   * a dirty IDC worktree → RISKY; an unmerged IDC branch → RISKY.
#   * a foreign (non-IDC) branch, EVEN IF merged → REPORT-ONLY, never SAFE-FIX.
#   * `--apply-safe` clears ONLY the SAFE-FIX tier (worktree removed, local+remote branch deleted, board
#     closed) and re-scan reports the delta; the dirty worktree + unmerged branch + foreign branch are
#     NOT touched (the (b) red-when-broken: an apply that reached RISKY/REPORT-ONLY flips these).
#   * an unreadable / corrupt board → exit 2, never a hollow clean (the (c) red-when-broken).
#
# Usage: bash tests/smoke/phase1-git-janitor.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
JAN="$PLUGIN/scripts/idc_git_janitor.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; R="$WORK/repo"; O="$WORK/origin.git"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "----- report -----"; echo "$2"; }; exit 1; }
gitc() { git -C "$R" "$@"; }

[ -f "$JAN" ] || fail "janitor scanner not found at $JAN"
[ -f "$TRK" ] || fail "tracker helper not found at $TRK"

# ---- hermetic repo + bare origin ------------------------------------------------------------------
git init -q -b main "$O" --bare   || fail "bare origin init failed (git too old for -b?)"
git init -q -b main "$R"          || fail "repo init failed"
gitc config user.email t@t.t; gitc config user.name t
gitc remote add origin "$O"
printf base > "$R/base.txt"; gitc add -A; gitc commit -qm base
gitc push -q -u origin main       || fail "initial push to origin failed"
python3 "$TRK" --tracker "$R/TRACKER.md" init >/dev/null || fail "tracker init failed"

# ---- BEHAVIOR 1: a clean coherent repo exits 0 (COHERENT) -----------------------------------------
out="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"; rc=$?
[ "$rc" -eq 0 ] || fail "a clean repo must exit 0 (got $rc)" "$out"
printf '%s\n' "$out" | grep -qE 'COHERENT' || fail "a clean repo must report COHERENT" "$out"

# ---- build the debris scenario --------------------------------------------------------------------
python3 "$TRK" --tracker "$R/TRACKER.md" create --title coupled --stage Buildable >/dev/null      # #1 Todo
python3 "$TRK" --tracker "$R/TRACKER.md" create --title alreadydone --stage Buildable >/dev/null  # #2
python3 "$TRK" --tracker "$R/TRACKER.md" close --num 2 >/dev/null                                 # #2 Done

mkbranch() { # $1 = branch name → a commit on it, then merge --no-ff into main (flat filename)
  local n="$1" f; f=$(printf '%s' "$n" | tr '/' '_')
  gitc checkout -q -b "$n" main
  printf x > "$R/$f.txt"; gitc add -A; gitc commit -qm "work $n"
  gitc checkout -q main; gitc merge -q --no-ff "$n" -m "merge $n"
}

mkbranch worktree-build-legacy      # merged IDC local branch, no board coupling → SAFE-FIX (branch)
mkbranch worktree-build-1           # merged + board #1 Todo → SAFE-FIX branch AND SAFE-FIX board (analog)
mkbranch worktree-build-2           # merged + board #2 Done → SAFE-FIX branch, board COHERENT (contrast)
mkbranch codex/experiment           # merged but FOREIGN → REPORT-ONLY (never SAFE-FIX)

gitc checkout -q -b worktree-build-unmerged main   # unmerged IDC branch → RISKY
printf u > "$R/u.txt"; gitc add -A; gitc commit -qm u; gitc checkout -q main

gitc worktree add -q "$WORK/wt-clean" -b worktree-build-clean main   # clean merged worktree → SAFE-FIX
( cd "$WORK/wt-clean" && printf b > b.txt && git add -A && git commit -qm "work clean" ) || fail "wt-clean commit failed"
gitc merge -q --no-ff worktree-build-clean -m "merge clean"

gitc worktree add -q "$WORK/wt-dirty" -b worktree-build-dirty main   # dirty worktree → RISKY (untouched)
( cd "$WORK/wt-dirty" && printf d > d.txt && git add -A && git commit -qm wip && printf more >> d.txt ) || fail "wt-dirty setup failed"

gitc push -q origin worktree-build-legacy   # a merged branch surviving on origin → SAFE-FIX (remote)
gitc push -q origin main

# ---- REPORT: assert each tier (red-when-broken contrast structure) --------------------------------
rep="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"; rc=$?
[ "$rc" -eq 1 ] || fail "a repo with debris must exit 1 (got $rc)" "$rep"

has()  { printf '%s\n' "$rep" | grep -qE "$1" || fail "report missing: $1" "$rep"; }
hasnt(){ printf '%s\n' "$rep" | grep -qE "$1" && fail "report should NOT contain: $1" "$rep"; return 0; }

has  'SAFE-FIX branch worktree-build-legacy'          # merged local branch
has  'SAFE-FIX (branch|remote-branch) worktree-build-legacy .*(remote|surviving)'  # both dims present
has  'SAFE-FIX remote-branch worktree-build-legacy'   # merged remote branch surviving (RC2)
has  'SAFE-FIX worktree .*wt-clean'                   # clean merged worktree
has  'SAFE-FIX board #1'                              # Done-but-open analog (Todo + merged branch)
has  'RISKY worktree .*wt-dirty'                      # dirty worktree
has  'RISKY branch worktree-build-unmerged'           # unmerged IDC branch
has  'REPORT-ONLY branch codex/experiment'            # foreign branch
# CONTRAST 1 — the coherence check fires ONLY on incoherence: board #2 is Done, its branch merged, so it
# must NOT be flagged. Red-when-broken: a check that flags every merged branch's issue would list #2.
hasnt 'board #2'
# CONTRAST 2 — a foreign branch is NEVER SAFE-FIX even though it merged. Red-when-broken: dropping the
# attribution gate would classify codex/experiment as SAFE-FIX.
hasnt 'SAFE-FIX (branch|remote-branch) codex/experiment'
# CONTRAST 3 — the dirty worktree's branch is not independently SAFE-FIX-deletable (its worktree owns it).
hasnt 'SAFE-FIX branch worktree-build-dirty'

# ---- APPLY-SAFE: clears ONLY SAFE-FIX; RISKY + REPORT-ONLY untouched ------------------------------
app="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md" --apply-safe)"; rc=$?
# after apply, RISKY + REPORT-ONLY remain → still exit 1 (findings remain).
[ "$rc" -eq 1 ] || fail "apply-safe re-scan must still exit 1 (RISKY/REPORT-ONLY remain), got $rc" "$app"
printf '%s\n' "$app" | grep -qE '0 safe-fix' || fail "delta must show 0 safe-fix remaining" "$app"

# SAFE-FIX side-effects DID happen:
[ ! -e "$WORK/wt-clean" ] || fail "SAFE-FIX worktree wt-clean was not removed" "$app"
gitc show-ref --verify --quiet refs/heads/worktree-build-legacy && fail "SAFE-FIX local branch worktree-build-legacy survived" "$app"
gitc show-ref --verify --quiet refs/heads/worktree-build-1       && fail "SAFE-FIX local branch worktree-build-1 survived" "$app"
gitc show-ref --verify --quiet refs/remotes/origin/worktree-build-legacy && fail "SAFE-FIX remote branch worktree-build-legacy survived on origin" "$app"
[ "$(python3 "$TRK" --tracker "$R/TRACKER.md" show --num 1 --field Status)" = "Done" ] || fail "SAFE-FIX board #1 was not set to Done" "$app"

# (b) RED-WHEN-BROKEN: RISKY + REPORT-ONLY were NOT touched. If apply-safe ever reaches those tiers,
# these assertions flip.
[ -e "$WORK/wt-dirty" ] || fail "apply-safe wrongly removed the RISKY dirty worktree" "$app"
gitc show-ref --verify --quiet refs/heads/worktree-build-unmerged || fail "apply-safe wrongly deleted the RISKY unmerged branch" "$app"
gitc show-ref --verify --quiet refs/heads/codex/experiment        || fail "apply-safe wrongly deleted the REPORT-ONLY foreign branch" "$app"
# #2 (already Done) stays Done — apply never regressed it.
[ "$(python3 "$TRK" --tracker "$R/TRACKER.md" show --num 2 --field Status)" = "Done" ] || fail "board #2 status changed unexpectedly" "$app"

# re-scan is idempotent: a second apply-safe finds 0 SAFE-FIX (everything already applied).
app2="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md" --apply-safe)"
printf '%s\n' "$app2" | grep -qE '0 safe-fix' || fail "second apply-safe must find 0 SAFE-FIX (not idempotent)" "$app2"

# ---- (c) RED-WHEN-BROKEN: unreadable / corrupt board → exit 2 (never a hollow clean) --------------
python3 "$JAN" --repo "$R" --tracker "$R/DOES-NOT-EXIST.md" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a missing tracker must exit 2 (fail-closed), not a hollow clean"
printf 'garbage, no state block\n' > "$WORK/corrupt.md"
python3 "$JAN" --repo "$R" --tracker "$WORK/corrupt.md" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a corrupt tracker (no state block) must exit 2 (fail-closed)"
# a non-git directory → exit 2 (cannot establish git ground truth).
python3 "$JAN" --repo "$WORK" --tracker "$R/TRACKER.md" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a non-git repo must exit 2 (cannot establish ground truth)"

echo "PASS: idc_git_janitor reconciles board↔git over a real hermetic repo — clean repo exits 0; merged branches (local+remote) + clean merged worktree + Status≠Done-with-merged-branch classified SAFE-FIX; dirty worktree + unmerged branch RISKY; foreign branch REPORT-ONLY even when merged; --apply-safe clears ONLY SAFE-FIX (RISKY/REPORT-ONLY untouched) + reports the delta; unreadable/corrupt board + non-git dir fail-closed to exit 2"
