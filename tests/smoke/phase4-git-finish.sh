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
  ORIGIN="$work/origin.git"; REPO="$work/repo"; BRANCH="build-501"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  echo hello > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit -qm init
  local base; base="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" push -q origin "HEAD:$base"

  WT="$REPO/.claude/worktrees/$BRANCH"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$base"
  echo change > "$WT/change.txt"
  git -C "$WT" add change.txt
  git -C "$WT" commit -qm "work"
  git -C "$WT" push -q origin "$BRANCH"

  mkdir -p "$REPO/docs/workflow"
  printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
  TRACKER="$REPO/TRACKER.md"
  python3 "$TRK" --tracker "$TRACKER" init >/dev/null
  python3 "$TRK" --tracker "$TRACKER" create --title "Test issue" >/dev/null
  python3 "$TRK" --tracker "$TRACKER" claim --num 1 --agent tester >/dev/null
}

run_finish() {
  local extra_env="$1"
  ( cd "$REPO" && \
    env PATH="$WORK/bin:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" BRANCH="$BRANCH" $extra_env \
      python3 "$SCRIPT" --pr 501 --issue 1 --worktree "$WT" --repo "$REPO" --tracker "$TRACKER" )
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

echo "PASS: idc_git_finish.py worktree/merge/branch/tracker tail + fail-closed remote-branch verify green"
