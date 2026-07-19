#!/bin/bash
# idc-assert-class: behavior
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
#   * a PHANTOM remote tracking ref (a branch deleted on the server but lingering in an un-pruned clone)
#     → NOT reported as a live remote branch, and --apply-safe never tries to `git push --delete` it.
#   * a SERVER-RECREATED remote branch (name reused at a NEW live commit; clone tracking ref stale @old)
#     → classified off the SERVER tip → RISKY, never SAFE-FIX; --apply-safe never deletes the live branch.
#   * `default_branch` resolves a MASTER-only repo to `master` (the stock-Linux default) with HEAD parked
#     on a third branch — the one place in the suite that proves the janitor is not main-only.
#   * an INDETERMINATE scan (exit 2) prints "INDETERMINATE", never "COHERENT".
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
# Board items are seeded directly via the tracker (no engine transitions), so create the (empty)
# transition journal explicitly: a non-empty board with a MISSING journal is indeterminate (exit 2,
# fail-closed journal dimension) and would mask this scenario's debris assertions.
mkdir -p "$R/docs/workflow" && : > "$R/docs/workflow/transition-journal.ndjson" \
  || fail "seeding the empty transition journal failed"

# ---- BEHAVIOR 1: a clean coherent repo exits 0 (COHERENT) -----------------------------------------
out="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"; rc=$?
[ "$rc" -eq 0 ] || fail "a clean repo must exit 0 (got $rc)" "$out"
printf '%s\n' "$out" | grep -qE 'COHERENT' || fail "a clean repo must report COHERENT" "$out"

# ---- build the debris scenario --------------------------------------------------------------------
python3 "$TRK" --tracker "$R/TRACKER.md" create --title coupled --stage Buildable >/dev/null      # #1 Todo
python3 "$TRK" --tracker "$R/TRACKER.md" create --title alreadydone --stage Buildable >/dev/null  # #2
python3 "$TRK" --tracker "$R/TRACKER.md" close --num 2 >/dev/null                                 # #2 Done
python3 "$TRK" --tracker "$R/TRACKER.md" create --title foreignmapped --stage Buildable >/dev/null # #3 Todo

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
mkbranch buildbot                   # FIX 2: starts with "build" but no -/ separator → NOT IDC → REPORT-ONLY
mkbranch xbuild-3                    # FIX (attribution): foreign name whose BUILD_ISSUE token maps #3 → must
                                     #   NOT drive board #3 (is_idc gate); classified REPORT-ONLY

gitc checkout -q -b worktree-build-unmerged main   # unmerged IDC branch → RISKY
printf u > "$R/u.txt"; gitc add -A; gitc commit -qm u; gitc checkout -q main

gitc worktree add -q "$WORK/wt-clean" -b worktree-build-clean main   # clean merged worktree → SAFE-FIX
( cd "$WORK/wt-clean" && printf b > b.txt && git add -A && git commit -qm "work clean" ) || fail "wt-clean commit failed"
gitc merge -q --no-ff worktree-build-clean -m "merge clean"

gitc worktree add -q "$WORK/wt-dirty" -b worktree-build-dirty main   # dirty worktree → RISKY (untouched)
( cd "$WORK/wt-dirty" && printf d > d.txt && git add -A && git commit -qm wip && printf more >> d.txt ) || fail "wt-dirty setup failed"

gitc push -q origin worktree-build-legacy   # a merged branch surviving on origin → SAFE-FIX (remote)
gitc push -q origin main

# STALE-TRACKING-REF (phantom) fixture — truthfulness on an un-pruned clone. A merged branch pushed to
# origin, then deleted ON THE SERVER (the bare origin) and locally, leaving ONLY a stale
# `origin/worktree-build-phantom` tracking ref in the clone (no `git fetch --prune`). The janitor must
# NOT report a phantom tracking ref as a live remote branch, and --apply-safe must never `git push
# --delete` it (doomed — it is already gone from the server).
mkbranch worktree-build-phantom
gitc push -q origin worktree-build-phantom                    # clone now has origin/worktree-build-phantom
gitc branch -D worktree-build-phantom                         # drop the LOCAL branch (isolate the REMOTE phantom)
git -C "$O" update-ref -d refs/heads/worktree-build-phantom   # delete on the SERVER only → tracking ref goes stale
gitc show-ref --verify --quiet refs/remotes/origin/worktree-build-phantom \
  || fail "test setup: expected a stale origin/worktree-build-phantom tracking ref (un-pruned clone)"

# SERVER-RECREATED (reused name, NEW live commits) fixture — the deletion-safety corner. A merged branch
# pushed to origin, then on the SERVER the name is deleted and RE-CREATED at a NEW live commit, while the
# clone's tracking ref stays at the OLD (merged) tip (un-pruned). Name-only + stale-local-tip logic would
# call it SAFE-FIX (old tip is merged) and --apply-safe would `git push --delete` the LIVE branch. The
# SERVER tip is the truth → it must be RISKY, never SAFE-FIX, never deleted.
mkbranch worktree-build-recreated                              # OLD commit, merged into main
old_recreated=$(gitc rev-parse worktree-build-recreated)
gitc push -q origin worktree-build-recreated                  # origin@OLD; clone tracking ref @OLD
gitc branch -D worktree-build-recreated                       # drop the LOCAL branch (isolate the remote)
gitc checkout -q -b recreate-src main                         # a NEW, UNMERGED commit (live work)
printf newlive > "$R/recreated.txt"; gitc add -A; gitc commit -qm "recreated live work"
gitc push -qf origin recreate-src:worktree-build-recreated    # server ref now @NEW (force: not a fast-forward)
gitc checkout -q main; gitc branch -D recreate-src            # drop the local side branch (no extra findings)
gitc update-ref refs/remotes/origin/worktree-build-recreated "$old_recreated"  # SIMULATE the stale clone tracking ref (@OLD)
[ "$(gitc rev-parse refs/remotes/origin/worktree-build-recreated)" = "$old_recreated" ] \
  || fail "test setup: expected stale origin/worktree-build-recreated @OLD (server is @NEW)"

# ---- REPORT: assert each tier (red-when-broken contrast structure) --------------------------------
rep="$(python3 "$JAN" --repo "$R" --tracker "$R/TRACKER.md")"; rc=$?
[ "$rc" -eq 1 ] || fail "a repo with debris must exit 1 (got $rc)" "$rep"

has()  { printf '%s\n' "$rep" | grep -qE "$1" || fail "report missing: $1" "$rep"; }
hasnt(){ printf '%s\n' "$rep" | grep -qE "$1" && fail "report should NOT contain: $1" "$rep"; return 0; }

has  'SAFE-FIX branch worktree-build-legacy'          # merged local branch
has  'SAFE-FIX (branch|remote-branch) worktree-build-legacy .*(remote|surviving)'  # both dims present
has  'SAFE-FIX remote-branch worktree-build-legacy'   # merged remote branch surviving (RC2)
# PHANTOM REFS — a stale tracking ref for a branch already deleted on the server must NOT appear at all
# (not as a live remote branch, not anywhere). Red-when-broken: without the ls-remote intersection, the
# phantom origin/worktree-build-phantom is classified SAFE-FIX remote-branch (its tip is an ancestor of main).
hasnt 'worktree-build-phantom'
# SERVER-RECREATED — the tip-match must run against the SERVER tip (@NEW), not the stale clone tracking
# ref (@OLD). @NEW is not merged → RISKY, never SAFE-FIX. Red-when-broken: using the stale local tip
# (@OLD, merged) classifies it SAFE-FIX remote-branch → the two assertions below flip.
has  'RISKY remote-branch worktree-build-recreated'
hasnt 'SAFE-FIX (branch|remote-branch) worktree-build-recreated'
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
# FIX 2 — `buildbot` starts with "build" but no -/ separator, so it is FOREIGN, not IDC. Red-when-broken:
# a bare-`build` regex classifies it IDC → (it's merged) SAFE-FIX, flipping both assertions below.
has  'REPORT-ONLY branch buildbot'
hasnt 'SAFE-FIX (branch|remote-branch) buildbot'
# ATTRIBUTION GATE — a foreign branch whose name contains a `build-<n>` token (xbuild-3 → #3) must NEVER
# drive a board mutation. Red-when-broken: dropping the fs-loop is_idc gate flags board #3 SAFE-FIX.
has  'REPORT-ONLY branch xbuild-3'
hasnt 'board #3'

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
# apply-safe must never have TOUCHED the phantom remote branch (no doomed `git push --delete`).
printf '%s\n' "$app" | grep -q 'worktree-build-phantom' && fail "apply-safe touched the phantom remote branch (should be filtered by ls-remote)" "$app"
# SERVER-RECREATED: the LIVE re-created branch must SURVIVE on the server — apply-safe classified it RISKY,
# so it was never `git push --delete`d. Red-when-broken (stale-local-tip logic): it'd be SAFE-FIX and deleted.
git -C "$O" show-ref --verify --quiet refs/heads/worktree-build-recreated \
  || fail "apply-safe DELETED the live server-recreated branch (deletion-safety regression)" "$app"

# (b) RED-WHEN-BROKEN: RISKY + REPORT-ONLY were NOT touched. If apply-safe ever reaches those tiers,
# these assertions flip.
[ -e "$WORK/wt-dirty" ] || fail "apply-safe wrongly removed the RISKY dirty worktree" "$app"
gitc show-ref --verify --quiet refs/heads/worktree-build-unmerged || fail "apply-safe wrongly deleted the RISKY unmerged branch" "$app"
gitc show-ref --verify --quiet refs/heads/codex/experiment        || fail "apply-safe wrongly deleted the REPORT-ONLY foreign branch" "$app"
gitc show-ref --verify --quiet refs/heads/buildbot                || fail "apply-safe wrongly deleted the foreign 'buildbot' branch (fix 2 attribution)" "$app"
gitc show-ref --verify --quiet refs/heads/xbuild-3                || fail "apply-safe wrongly deleted the foreign 'xbuild-3' branch" "$app"
# #2 (already Done) stays Done, #3 (foreign-mapped) stays Todo — apply never touched either.
[ "$(python3 "$TRK" --tracker "$R/TRACKER.md" show --num 2 --field Status)" = "Done" ] || fail "board #2 status changed unexpectedly" "$app"
[ "$(python3 "$TRK" --tracker "$R/TRACKER.md" show --num 3 --field Status)" = "Todo" ] || fail "board #3 wrongly Done — a foreign branch drove a board mutation" "$app"

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

# ---- BANNER NIT: an INDETERMINATE scan (exit 2) must print INDETERMINATE, never COHERENT -----------
# A clean repo whose remote can't be queried (ls-remote fails) has NO findings but IS indeterminate →
# exit 2. The stdout banner must say INDETERMINATE (the nit: it used to say COHERENT). Fresh clean repo,
# a tracking ref present, then the origin removed so ls-remote fails.
R2="$WORK/repo2"; O2="$WORK/origin2.git"
git init -q -b main "$O2" --bare && git init -q -b main "$R2"
git -C "$R2" config user.email t@t.t; git -C "$R2" config user.name t
git -C "$R2" remote add origin "$O2"
printf base > "$R2/b.txt"; git -C "$R2" add -A; git -C "$R2" commit -qm base
git -C "$R2" push -q -u origin main                # creates the origin/main tracking ref
python3 "$TRK" --tracker "$R2/TRACKER.md" init >/dev/null
rm -rf "$O2"                                        # break the remote → ls-remote now FAILS
bnr="$(python3 "$JAN" --repo "$R2" --tracker "$R2/TRACKER.md")"; brc=$?
[ "$brc" -eq 2 ] || fail "an unverifiable remote with no findings must exit 2 (fail-closed), got $brc" "$bnr"
printf '%s\n' "$bnr" | grep -qE '^janitor: INDETERMINATE$' || fail "indeterminate banner must say INDETERMINATE (the nit)" "$bnr"
printf '%s\n' "$bnr" | grep -qE 'COHERENT' && fail "an indeterminate scan must NOT print COHERENT (the nit)" "$bnr"

# ---- BEHAVIOR: default_branch resolves a master-only repo to `master` (the stock-Linux default) ----
# `idc_git_janitor.default_branch` falls back origin/HEAD → local main → local master → current branch.
# Every OTHER fixture in this suite pins `-b main`, so without this case the `master` candidate is dead,
# untested code — and the phase9 fixtures' branch pin cites THIS phase as the place branch-name
# agnosticism is covered. This case is what makes that citation true.
# HEAD is deliberately parked on a THIRD branch: if HEAD sat on master, the current-branch fallback
# would answer "master" on its own and the assertion would pass even with the candidate removed.
# Red-when-broken (verified): change the candidate tuple to ("main",) ⇒ this resolves `feature` ⇒ FAIL.
RMB="$WORK/repo-master"
git init -q -b master "$RMB"      || fail "master-only repo init failed (git too old for -b?)"
git -C "$RMB" config user.email t@t.t; git -C "$RMB" config user.name t
printf base > "$RMB/b.txt"; git -C "$RMB" add -A; git -C "$RMB" commit -qm base
git -C "$RMB" checkout -q -b feature   # HEAD ≠ master, so the current-branch fallback cannot mask this
db="$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import idc_git_janitor as J; print(J.default_branch(sys.argv[2]))' "$(dirname "$JAN")" "$RMB")" \
  || fail "default_branch raised on a master-only repo"
[ "$db" = "master" ] \
  || fail "default_branch must resolve a master-only repo to 'master' (the stock-Linux default), got '$db' — the master candidate is what makes the janitor work on a non-main repo"

# ---- github-only fixes: pure decision predicates + a fail-closed board-read (unit-tested here because
#      the hermetic repo is filesystem-backed — no live gh). Each case is red-when-broken. ----------------
JANDIR="$(dirname "$JAN")"
python3 - "$JANDIR" <<'PY' || fail "github-only unit tests failed (see assertion above)"
import sys
sys.path.insert(0, sys.argv[1])
import idc_git_janitor as J

def eq(got, want, msg):
    if got != want:
        print(f"FAIL: {msg}: got {got!r}, want {want!r}"); sys.exit(1)

# FIX 1 — pr_signal_ok: the merged-PR name signal is SAFE only when the tip STILL equals the PR head oid.
eq(J.pr_signal_ok("abc123", "abc123"), True,  "matching tip == PR head is a safe merge signal")
eq(J.pr_signal_ok("abc123", "def456"), False, "DIVERGENT tip (name reuse) is NOT a safe merge signal")
eq(J.pr_signal_ok(None,     "abc123"), False, "unresolvable PR oid is NOT a safe signal (fail-closed)")
eq(J.pr_signal_ok("abc123", ""),       False, "unresolvable local tip is NOT a safe signal (fail-closed)")

# FIX 3 — board_coherence_verdict: only genuinely-COMPLETED issues get Status=Done; not-planned → RISKY.
eq(J.board_coherence_verdict("Done", "OPEN",   "",           False)[:2], ("SAFE-FIX", "close-issue"), "Done+open → close")
eq(J.board_coherence_verdict("Todo", "CLOSED", "COMPLETED",  False)[:2], ("SAFE-FIX", "set-done"),    "closed-completed → set Done")
eq(J.board_coherence_verdict("Todo", "CLOSED", "NOT_PLANNED", False)[:2], ("RISKY",    "reconcile"),   "closed-NOT_PLANNED → RISKY, never Done")
eq(J.board_coherence_verdict("Todo", "CLOSED", "NOT_PLANNED", True)[:2],  ("SAFE-FIX", "set-done"),    "a merged PR still wins over not-planned")
eq(J.board_coherence_verdict("Todo", "OPEN",   "",           False),      None,                        "todo+open → coherent (no finding)")
eq(J.board_coherence_verdict("Done", "CLOSED", "COMPLETED",  False),      None,                        "done+closed → coherent (no finding)")

# FIX 5 — read_at_cap: a list at its --limit ceiling is possibly-partial → indeterminate.
eq(J.read_at_cap(J.PR_LIST_LIMIT,     J.PR_LIST_LIMIT),     True,  "PR list AT the cap → at-cap")
eq(J.read_at_cap(J.PR_LIST_LIMIT - 1, J.PR_LIST_LIMIT),     False, "PR list below the cap → not at-cap")
eq(J.read_at_cap(J.ISSUE_LIST_LIMIT,  J.ISSUE_LIST_LIMIT),  True,  "issue list AT the cap → at-cap")

# FIX 4 — an UNEXPECTED (non-BoardReadError) exception in the board read must fail-CLOSE to exit 2,
# never propagate as an uncaught traceback (exit 1 == our "findings" code).
import idc_gh_board
def boom(*a, **k):
    raise ValueError("simulated unexpected board-read crash")
idc_gh_board.fetch_items = boom
try:
    J.load_board_github("owner", "1", ".")
    print("FAIL: load_board_github did not exit on an unexpected error"); sys.exit(1)
except SystemExit as e:
    eq(e.code, 2, "an unexpected board-read exception must exit 2 (fail-closed)")

print("github-only unit tests: all pass")
PY

echo "PASS: idc_git_janitor reconciles board↔git over a real hermetic repo — clean repo exits 0; merged branches (local+remote) + clean merged worktree + Status≠Done-with-merged-branch classified SAFE-FIX; dirty worktree + unmerged branch RISKY; foreign branch REPORT-ONLY even when merged; 'buildbot' (no build[-/] separator) + foreign 'xbuild-3' are non-IDC and never drive a fix or a board mutation; a phantom (server-deleted) remote tracking ref on an un-pruned clone is filtered by ls-remote — never reported live, never push --delete'd; a server-recreated branch (name reused at a NEW live commit) is judged off the SERVER tip → RISKY, never deleted; default_branch resolves a master-only repo to 'master' (the stock-Linux default) even with HEAD parked on a third branch; an indeterminate scan prints INDETERMINATE (not COHERENT); --apply-safe clears ONLY SAFE-FIX (RISKY/REPORT-ONLY untouched) + reports the delta; unreadable/corrupt board + non-git dir fail-closed to exit 2; github-only predicates unit-tested (pr_signal_ok tip-match guard, board_coherence_verdict not-planned gate, read_at_cap, unexpected-board-read-crash → exit 2)"
