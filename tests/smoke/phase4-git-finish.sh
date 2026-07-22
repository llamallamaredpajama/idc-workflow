#!/bin/bash
# idc-assert-class: behavior
# Phase 4 (git-finish) smoke — scripts/idc_git_finish.py is the finisher's deterministic
# git-finalization tail (design §B.1, RC1/RC2/RC3): remove worktree -> merge --delete-branch ->
# verify the remote branch is ACTUALLY gone (git ls-remote) -> delete local branch -> tracker close
# -> re-verify the full end state. Fail-closed: a step that cannot be verified exits non-zero with a
# `finish: <step> failed` line, never a silent pass.
#
# Hermetic REAL git: a bare `git init --bare` origin, a real worktree, a real branch, real pushes —
# no GitHub. Only `gh pr view`/`gh pr merge` are stubbed on PATH (a filesystem-backend tracker needs
# no other `gh` call). The stub's `pr merge --delete-branch` mutates the bare origin directly, so the
# script's `git ls-remote` check observes REAL git state, not a canned answer.
# Usage: bash tests/smoke/phase4-git-finish.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$PLUGIN/scripts/idc_git_finish.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCRIPT" ] || fail "idc_git_finish.py not found (not implemented yet)"

python3 "$SCRIPT" --help >/dev/null 2>&1 || fail "--help should parse"

# ---------------------------------------------------------------------------------------------
# gh stub: `gh pr view <n> --json headRefName -q .headRefName` / `--json state -q .state`, and
# `gh pr merge <n> --squash --delete-branch`. On merge, deletes the branch on the ORIGIN repo
# (env ORIGIN) UNLESS GH_SKIP_REMOTE_DELETE=1 (models the audit's exact observed bug: the flag is
# passed but the remote branch survives).
# ---------------------------------------------------------------------------------------------
make_gh_stub() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
STATE_FILE = os.path.join(os.environ["WORK"], "gh-pr-merged")
BRANCH = os.environ["BRANCH"]
ORIGIN = os.environ["ORIGIN"]

if args[:2] == ["pr", "view"]:
    j = args[args.index("--json") + 1] if "--json" in args else ""
    if j == "headRefName":
        print(BRANCH)
    elif j == "state":
        print("MERGED" if os.path.exists(STATE_FILE) else "OPEN")
    elif j == "baseRefName":
        print(os.environ.get("BASE", "main"))
    sys.exit(0)

if args[:2] == ["pr", "merge"]:
    if "--squash" not in args or "--delete-branch" not in args:
        sys.stderr.write("gh stub: pr merge missing --squash/--delete-branch\n")
        sys.exit(1)
    open(STATE_FILE, "w").close()
    if os.environ.get("GH_SKIP_REMOTE_DELETE") != "1":
        subprocess.run(["git", "-C", ORIGIN, "branch", "-D", BRANCH], capture_output=True)
    sys.exit(0)

sys.stderr.write("gh stub: unhandled " + repr(args) + "\n")
sys.exit(99)
STUB
  chmod +x "$bindir/gh"
}

# ---------------------------------------------------------------------------------------------
# setup_repo <workdir> — bare origin + a real clone + a real worktree on a real branch with a real
# commit pushed to origin, plus a filesystem tracker with one In-Progress issue. Sets globals
# ORIGIN/REPO/WT/BRANCH/TRACKER.
# ---------------------------------------------------------------------------------------------
setup_repo() {
  local work="$1"
  # BRANCH defaults to the REAL claude-adapter naming `worktree-build-<n>` (skills/idc-adapter-claude) —
  # the item number is a standalone token Stage D's strict regex MISSES but the close-only ownership
  # accident-guard resolves to issue #1 (reviewer P2-1). Pass $2 to override (e.g. an ambiguous name).
  # Normal finish ignores naming.
  ORIGIN="$work/origin.git"; REPO="$work/repo"; BRANCH="${2:-worktree-build-1}"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm init
  BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"   # the default/base branch (global — the gh stub's baseRefName)
  git -C "$REPO" push -q origin "HEAD:$BASE"

  WT="$REPO/.claude/worktrees/$BRANCH"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE"
  echo change > "$WT/change.txt"
  git -C "$WT" add change.txt
  git -C "$WT" commit -qm "work"
  git -C "$WT" push -q origin "$BRANCH"

  mkdir -p "$REPO/docs/workflow/code-reviews"
  printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
  TRACKER="$REPO/TRACKER.md"
  python3 "$TRK" --tracker "$TRACKER" init >/dev/null
  python3 "$TRK" --tracker "$TRACKER" create --title "Test issue" >/dev/null
  python3 "$TRK" --tracker "$TRACKER" claim --num 1 --agent tester >/dev/null
  # The finish tail is a receipt gate: a clean PASS verdict owning PR #501 / issue #1, no nits (so
  # nothing to route) and no merge_conditions — the git-mechanics scenarios exercise the tail past it.
  VERDICT="$REPO/docs/workflow/code-reviews/2026-07-22-pr-501-review.json"
  printf '{"verdict":"PASS","pr":501,"issue":1,"findings":[]}\n' > "$VERDICT"
  python3 "$CHECK" "$VERDICT" >/dev/null 2>&1 || fail "validator did not accept the clean finish verdict"
}

run_finish() {
  local extra_env="$1"
  ( cd "$REPO" && \
    env PATH="$WORK/bin:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" BRANCH="$BRANCH" BASE="$BASE" $extra_env \
      python3 "$SCRIPT" --pr 501 --issue 1 --worktree "$WT" --repo "$REPO" --tracker "$TRACKER" \
        --verdict "$VERDICT" )
}

# land_branch — represent a MERGED PR: actually merge the head branch's work INTO base + push, so the
# work is provably in base (the close-only containment gate verifies this on real git). Leaves the
# branch + worktree intact and the tracker In-Progress (the "board never advanced" shape).
land_branch() {
  git -C "$REPO" checkout -q "$BASE"
  git -C "$REPO" merge -q --no-ff "$BRANCH" -m "merge $BRANCH (represents the merged PR)"
  git -C "$REPO" push -q origin "$BASE"
}

# ============ Scenario A (green): the full tail succeeds end to end =============================
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
make_gh_stub "$WORK/bin"
setup_repo "$WORK"

out="$(run_finish "" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "expected success, got exit $rc: $out"
printf '%s\n' "$out" | grep -q '^finish: ok$' || fail "expected 'finish: ok', got: $out"

[ -d "$WT" ] && fail "worktree directory should have been removed: $WT"
git -C "$REPO" worktree list --porcelain | grep -qF "$WT" && fail "worktree should no longer be registered"
[ -z "$(git -C "$REPO" branch --list "$BRANCH")" ] || fail "local branch '$BRANCH' should have been deleted"
[ -z "$(git -C "$REPO" ls-remote --heads origin "$BRANCH")" ] || fail "remote branch '$BRANCH' should have been deleted"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "tracker issue #1 should be Status=Done after tracker-close"

# ============ Scenario B (red-when-broken proof): the merge stub's --delete-branch is a no-op ====
# Models the audit's exact observed production bug: the flag is passed, but the branch survives.
# The helper's explicit `git ls-remote` verify must catch it and exit non-zero.
WORK2="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2"' EXIT
make_gh_stub "$WORK2/bin"
OLDWORK="$WORK"; WORK="$WORK2"
setup_repo "$WORK2"

out="$(run_finish "GH_SKIP_REMOTE_DELETE=1" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "a surviving remote branch after --delete-branch must exit non-zero (got 0): $out"
printf '%s\n' "$out" | grep -qE '^finish: verify-remote-branch failed' \
  || fail "expected a 'finish: verify-remote-branch failed' line, got: $out"
[ -n "$(git -C "$REPO" ls-remote --heads origin "$BRANCH")" ] \
  || fail "test setup bug: the remote branch should still exist in this scenario"
WORK="$OLDWORK"

# ============ Scenario C (--close-only): recover an ALREADY-MERGED PR whose board never advanced =====
# The phantom-idle synthesized-complete shape (v4 Phase 3 Stage E4): the work is already merged, so the
# normal `gh pr merge` would hard-fail — --close-only SKIPS the merge, VERIFIES the merged state as its
# receipt (no --verdict needed), then runs the SAME cleanup + tracker-close tail. Must be idempotent.
WORK3="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3"' EXIT
make_gh_stub "$WORK3/bin"
OLDWORK="$WORK"; WORK="$WORK3"
setup_repo "$WORK3"
land_branch                    # the head branch's work is actually IN base (a real merged PR)
touch "$WORK3/gh-pr-merged"    # the PR is ALREADY MERGED (out-of-band) — the stub now reports MERGED

# run_close_only [issue] [--no-worktree] — close-only invocation; issue defaults to 1 (matches BRANCH).
# --no-worktree omits --worktree so the finisher's own worktree auto-detection is exercised (P2b).
run_close_only() {
  local iss=1 wt_arg=(--worktree "$WT")
  [ $# -ge 1 ] && [ "$1" != "--no-worktree" ] && { iss="$1"; shift; }
  [ "${1:-}" = "--no-worktree" ] && wt_arg=()
  ( cd "$REPO" && \
    env PATH="$WORK/bin:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" BRANCH="$BRANCH" BASE="$BASE" \
      python3 "$SCRIPT" --pr 501 --issue "$iss" ${wt_arg[@]+"${wt_arg[@]}"} --repo "$REPO" --tracker "$TRACKER" --close-only )
}
out="$(run_close_only 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(C) --close-only on a merged PR must succeed, got exit $rc: $out"
printf '%s\n' "$out" | grep -q '^finish: ok (close-only)$' || fail "(C) expected 'finish: ok (close-only)', got: $out"
[ -d "$WT" ] && fail "(C) worktree should have been removed: $WT"
[ -z "$(git -C "$REPO" branch --list "$BRANCH")" ] || fail "(C) local branch '$BRANCH' should have been deleted"
[ -z "$(git -C "$REPO" ls-remote --heads origin "$BRANCH")" ] || fail "(C) remote branch '$BRANCH' should be gone (close-only best-effort delete)"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "(C) tracker issue #1 should be Status=Done after --close-only tracker-close"
# IDEMPOTENT re-run: item already Done, branch/worktree already gone → must STILL succeed, no error.
out="$(run_close_only 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(C) --close-only must be idempotent (re-run on an already-recovered item), got exit $rc: $out"
printf '%s\n' "$out" | grep -q '^finish: ok (close-only)$' || fail "(C) idempotent re-run expected 'finish: ok (close-only)', got: $out"
WORK="$OLDWORK"

# ============ Scenario D (red-when-broken): --close-only REFUSES when the PR is NOT actually merged ==
# The merged state IS the receipt — so close-only must fail-closed when `gh pr view --json state` is not
# MERGED (here the STATE_FILE is absent ⇒ the stub reports OPEN). Proves the receipt is enforced: a
# not-really-merged item can never be closed by close-only. Neuter `verify_pr_merged` ⇒ this goes RED.
WORK4="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4"' EXIT
make_gh_stub "$WORK4/bin"
OLDWORK="$WORK"; WORK="$WORK4"
setup_repo "$WORK4"
# NOTE: STATE_FILE ($WORK4/gh-pr-merged) intentionally NOT created ⇒ the stub reports state=OPEN.
out="$(run_close_only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(D) --close-only on a NON-merged PR must fail-closed (got exit 0): $out"
printf '%s\n' "$out" | grep -qE '^finish: verify-pr-merged failed' \
  || fail "(D) expected 'finish: verify-pr-merged failed' (the merged-state receipt), got: $out"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" != "Done" ] \
  || fail "(D) a non-merged item must NOT be closed by --close-only (receipt not satisfied)"
[ -n "$(git -C "$REPO" branch --list "$BRANCH")" ] || fail "(D) test bug: the local branch should still exist (nothing should have been cleaned)"
WORK="$OLDWORK"

# ============ Scenario E (red-when-broken): --close-only REFUSES when the PR's branch owns a DIFFERENT item
# close-only skips the verdict receipt gate, so the head-branch→item linkage is the ownership accident-
# guard (codex P1b). A merged PR whose head branch (worktree-build-1) links to item 1 must NOT be
# allowed to close --issue 999. Neuter the ownership check ⇒ it would close the wrong item ⇒ RED.
WORK5="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5"' EXIT
make_gh_stub "$WORK5/bin"
OLDWORK="$WORK"; WORK="$WORK5"
setup_repo "$WORK5"
touch "$WORK5/gh-pr-merged"    # PR is merged, but its head branch (worktree-build-1) links to item 1, not 999
out="$(run_close_only 999 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(E) --close-only must refuse when the PR's head branch links to a DIFFERENT item than --issue (got exit 0): $out"
printf '%s\n' "$out" | grep -qE '^finish: close-only-ownership failed' \
  || fail "(E) expected 'finish: close-only-ownership failed' (head links item 1, not 999), got: $out"
printf '%s\n' "$out" | grep -qE 'resolves to item 1 .* not --issue 999' \
  || fail "(E) the refusal must name the resolved item (1) vs --issue 999, got: $out"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" != "Done" ] \
  || fail "(E) item #1 must NOT be closed by a close-only aimed at a stranger item [drop the ownership check ⇒ RED]"
WORK="$OLDWORK"

# ============ Scenario F: --close-only completes even when the branch is STILL CHECKED OUT in a worktree
# The recovery command may omit --worktree, but a branch still checked out in the idle teammate's
# worktree would make `git branch -D` fail mid-recovery (codex P2b). The finisher auto-detects that
# worktree (git worktree list) and removes it first (safe — branch is proven merged + ownership-verified).
# Red-when-broken: drop the auto-worktree removal ⇒ branch-delete-local fails on the checked-out branch ⇒ RED.
WORK6="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5" "$WORK6"' EXIT
make_gh_stub "$WORK6/bin"
OLDWORK="$WORK"; WORK="$WORK6"
setup_repo "$WORK6"
land_branch                    # the work is IN base (real merged PR); the WT stays checked out on BRANCH
touch "$WORK6/gh-pr-merged"    # PR merged; the WT (on BRANCH) is left checked out; we pass NO --worktree
[ -d "$WT" ] || fail "(F) test setup: the worktree on $BRANCH should exist"
out="$(run_close_only --no-worktree 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(F) --close-only must auto-remove the checked-out worktree and still complete, got exit $rc: $out"
printf '%s\n' "$out" | grep -q '^finish: ok (close-only)$' || fail "(F) expected 'finish: ok (close-only)', got: $out"
[ -d "$WT" ] && fail "(F) the checked-out worktree should have been auto-removed: $WT"
[ -z "$(git -C "$REPO" branch --list "$BRANCH")" ] || fail "(F) local branch '$BRANCH' should have been deleted after auto-worktree-removal [drop auto-worktree ⇒ RED here]"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "(F) tracker issue #1 should be Done after close-only with an auto-removed worktree"
WORK="$OLDWORK"

# ============ Scenario G (red-when-broken): --close-only REFUSES an AMBIGUOUS head branch (P2-A) ======
# A head branch with multiple numbers and no supported shape (`cleanup-1-2`) resolves to NO single item
# — closing --issue 1 on it would be a guess. The ownership guard must fail closed, naming the numbers.
# Neuter the resolution back to widened set-membership (1 ∈ {1,2}) ⇒ it would accept ⇒ RED.
WORK7="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5" "$WORK6" "$WORK7"' EXIT
make_gh_stub "$WORK7/bin"
OLDWORK="$WORK"; WORK="$WORK7"
setup_repo "$WORK7" "cleanup-1-2"    # an AMBIGUOUS head branch: numbers 1 and 2, no supported shape
touch "$WORK7/gh-pr-merged"          # PR is merged
out="$(run_close_only 1 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(G) --close-only must refuse an AMBIGUOUS head branch (got exit 0): $out"
printf '%s\n' "$out" | grep -qE '^finish: close-only-ownership failed' \
  || fail "(G) expected 'finish: close-only-ownership failed' for an ambiguous head, got: $out"
printf '%s\n' "$out" | grep -qE 'resolves to item None .*standalone numbers \[1, 2\]' \
  || fail "(G) the refusal must show the head resolved to NO item (numbers [1, 2]), got: $out"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" != "Done" ] \
  || fail "(G) an ambiguous head must NOT close item #1 [revert to set-membership ⇒ RED]"
WORK="$OLDWORK"

# ============ Scenario H (red-when-broken): --close-only REFUSES a head branch ADVANCED past the merge
# A MERGED PR state only proves the OLD tip merged; if the head branch was ADVANCED / REUSED since (new
# commits not in base), deleting it drops that unmerged work (codex P1). The containment gate must fail
# closed BEFORE any deletion, leaving the branch + item intact. Neuter it ⇒ the branch is deleted / item
# closed ⇒ RED.
WORK8="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5" "$WORK6" "$WORK7" "$WORK8"' EXIT
make_gh_stub "$WORK8/bin"
OLDWORK="$WORK"; WORK="$WORK8"
setup_repo "$WORK8"
land_branch                    # the ORIGINAL tip merged into base (the PR that merged)
echo "new work" > "$WT/advance.txt"; git -C "$WT" add advance.txt   # then the branch ADVANCES with NEW,
git -C "$WT" commit -qm "post-merge advance (unmerged work)"        #   unmerged work (in the live worktree)
touch "$WORK8/gh-pr-merged"    # the (old) PR still reports MERGED
out="$(run_close_only 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(H) --close-only must refuse a head branch ADVANCED past the merged PR (got exit 0): $out"
printf '%s\n' "$out" | grep -qE '^finish: close-only-advanced failed' \
  || fail "(H) expected 'finish: close-only-advanced failed' (branch advanced), got: $out"
printf '%s\n' "$out" | grep -qE "has advanced past the merged PR #501 \(1 unmerged commit" \
  || fail "(H) the refusal must report the unmerged-commit count, got: $out"
[ -n "$(git -C "$REPO" branch --list "$BRANCH")" ] \
  || fail "(H) the advanced branch must be INTACT (not deleted) after the refusal [drop the containment gate ⇒ RED]"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" != "Done" ] \
  || fail "(H) an advanced branch must NOT close the item [drop the containment gate ⇒ RED]"
WORK="$OLDWORK"

# ============ Scenario I (red-when-broken): --close-only accepts a PER-COMMIT (rebase/cherry-pick) landing
# The synth classifies a multi-commit rebase/cherry-pick landing as synthesized-complete via per-commit
# `git cherry`; the containment gate must accept the SAME (all ahead-commits patch-equivalent) or it
# would refuse the very branch the synth steered here — stranding the item (codex P2-1).
# Red-when-broken: drop the per-commit cherry acceptance ⇒ this lands via 2 separate base commits (no
# single-commit aggregate match) ⇒ the gate refuses ⇒ RED (close-only-advanced).
WORK9="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5" "$WORK6" "$WORK7" "$WORK8" "$WORK9"' EXIT
make_gh_stub "$WORK9/bin"
OLDWORK="$WORK"; WORK="$WORK9"
setup_repo "$WORK9"
# a SECOND commit on the branch, then land BOTH per-commit via cherry-pick onto base (not a merge/squash).
echo more > "$WT/change2.txt"; git -C "$WT" add change2.txt; git -C "$WT" commit -qm "work 2"
git -C "$REPO" checkout -q "$BASE"
# an intervening base commit so the cherry-picks get NEW shas (a real per-commit landing, deterministically
# NOT a fast-forward — else identical author/committer/tree/parent could collapse to the same shas).
echo unrelated > "$REPO/base-note.txt"; git -C "$REPO" add base-note.txt; git -C "$REPO" commit -qm "unrelated base commit"
git -C "$REPO" cherry-pick "${BASE}..${BRANCH}" >/dev/null 2>&1 || fail "(I) cherry-pick landing failed"
git -C "$REPO" push -q origin "$BASE"
# proof this is the per-commit shape (NOT ancestry, NOT single-commit aggregate): cherry shows all landed.
[ "$(git -C "$REPO" cherry "$BASE" "$BRANCH" | grep -c '^-')" -eq 2 ] || fail "(I) precondition: both commits must be patch-equivalent in base"
git -C "$REPO" merge-base --is-ancestor "$BRANCH" "$BASE" && fail "(I) precondition: a cherry-pick landing must leave BRANCH non-ancestor"
touch "$WORK9/gh-pr-merged"
out="$(run_close_only 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(I) --close-only must accept a per-commit (rebase/cherry-pick) landing, got exit $rc: $out [drop the cherry acceptance ⇒ RED as close-only-advanced]"
printf '%s\n' "$out" | grep -q '^finish: ok (close-only)$' || fail "(I) expected 'finish: ok (close-only)', got: $out"
[ -z "$(git -C "$REPO" branch --list "$BRANCH")" ] || fail "(I) the branch should be deleted after a clean per-commit-landing recovery"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "(I) tracker issue #1 should be Done after a per-commit-landing close-only"
WORK="$OLDWORK"

# ============ Scenario J (red-when-broken, DATA-SAFETY): the LIVE remote tip advanced since the last fetch
# refuse_if_head_advanced only sees the possibly-STALE remote-tracking ref. If the remote branch was
# advanced elsewhere (pushed since the last fetch), a `push --delete` would destroy LIVE unmerged work.
# The live-remote-tip guard reads `git ls-remote` and, when the live tip is unknown/uncontained, SKIPS
# the remote delete (warn) while completing the close (codex round-8 P1). Red: drop the live-tip check ⇒
# the advanced remote branch is destroyed ⇒ RED.
WORK10="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5" "$WORK6" "$WORK7" "$WORK8" "$WORK9" "$WORK10"' EXIT
make_gh_stub "$WORK10/bin"
OLDWORK="$WORK"; WORK="$WORK10"
setup_repo "$WORK10"
land_branch                    # the ORIGINAL tip is merged into base (the merged PR); origin BRANCH = old tip
# Advance the remote branch from a SEPARATE clone and do NOT fetch it into REPO — REPO's origin/BRANCH is
# now stale and the new commit object is UNKNOWN locally.
CLONE2="$WORK10/clone2"; git clone -q "$ORIGIN" "$CLONE2" 2>/dev/null
git -C "$CLONE2" config user.email t@example.com; git -C "$CLONE2" config user.name tester
git -C "$CLONE2" checkout -q "$BRANCH"
echo "remote advance, unmerged" > "$CLONE2/remote-work.txt"; git -C "$CLONE2" add remote-work.txt
git -C "$CLONE2" commit -qm "remote advance (unmerged, pushed elsewhere)"
LIVE_TIP="$(git -C "$CLONE2" rev-parse "$BRANCH")"
git -C "$CLONE2" push -q origin "$BRANCH"
git -C "$REPO" rev-parse --verify --quiet "${LIVE_TIP}^{commit}" >/dev/null 2>&1 \
  && fail "(J) precondition: the advanced live tip must be UNKNOWN in REPO (no fetch)"
touch "$WORK10/gh-pr-merged"
out="$(run_close_only 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(J) --close-only must still COMPLETE (the merged-PR receipt holds), got exit $rc: $out"
printf '%s\n' "$out" | grep -q '^finish: ok (close-only)$' || fail "(J) expected 'finish: ok (close-only)', got: $out"
printf '%s\n' "$out" | grep -qE "live remote tip .* unknown locally|leaving the remote branch" \
  || fail "(J) the skipped remote delete must WARN (observability), got: $out"
[ -n "$(git -C "$REPO" ls-remote --heads origin "$BRANCH")" ] \
  || fail "(J) the LIVE advanced remote branch must SURVIVE (not destroyed) [drop the live-tip check ⇒ RED]"
[ "$(git -C "$REPO" ls-remote --heads origin "$BRANCH" | awk '{print $1}')" = "$LIVE_TIP" ] \
  || fail "(J) the surviving remote branch must still point at the advanced live tip"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "(J) the item should still be closed (the merged-PR receipt holds)"
WORK="$OLDWORK"

# ============ Scenario K (red-when-broken): a DATE-PREFIXED head resolves to the UNIT for ownership ===
# `2026-07/worktree-build-1` must resolve to item 1 (the adapter unit), NOT 2026 (the strict date
# prefix) — consulting strict first would resolve 2026 and REFUSE a correct --issue 1 (round-8 micro-fix).
# Red-when-broken: restore strict-first ⇒ resolves 2026 ≠ 1 ⇒ ownership refuses the correct close ⇒ RED.
WORK11="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$WORK3" "$WORK4" "$WORK5" "$WORK6" "$WORK7" "$WORK8" "$WORK9" "$WORK10" "$WORK11"' EXIT
make_gh_stub "$WORK11/bin"
OLDWORK="$WORK"; WORK="$WORK11"
setup_repo "$WORK11" "2026-07/worktree-build-1"    # a DATE-PREFIXED adapter head branch; the unit is 1
land_branch
touch "$WORK11/gh-pr-merged"
out="$(run_close_only 1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(K) --close-only --issue 1 must ACCEPT a date-prefixed head that resolves to unit 1 (adapter shape), got exit $rc: $out [restore strict-first ⇒ RED: resolves 2026, refuses]"
printf '%s\n' "$out" | grep -q '^finish: ok (close-only)$' || fail "(K) expected 'finish: ok (close-only)', got: $out"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "(K) tracker issue #1 should be Done (the head resolved to the correct unit)"
WORK="$OLDWORK"

echo "PASS: idc_git_finish.py worktree/merge/branch/tracker tail + fail-closed remote-branch verify + --close-only recovery (green/idempotent + merged-state-receipt fail-closed + unambiguous head-branch ownership gate [adapter-first] + advanced-branch containment gate [ancestry/per-commit/squash] + live-remote-tip data-safety + auto-worktree removal) green"
