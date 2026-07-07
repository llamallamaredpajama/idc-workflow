#!/bin/bash
# idc-assert-class: behavior
# Phase 9 (real-git lifecycle) smoke — the RC6 "recipe card actually cooked" phase (design §E.1).
#
# WHAT MAKES THIS DIFFERENT from phase1-git-janitor (janitor tiers in isolation) and phase4-git-finish
# (the finish tail in isolation): this is the INTEGRATION of the two shipped deterministic reconcilers
# over ONE real lifecycle. It drives a real build triplet through `scripts/idc_git_finish.py` (the
# finisher's git-finalization tail) and then asserts `scripts/idc_git_janitor.py` certifies the
# resulting end-state COHERENT (exit 0). The load-bearing claim: a properly-finished build leaves
# NOTHING the janitor would flag — the two scripts AGREE. That is the exact assurance the pre-#103
# suite could not give (it proofread the recipe; it never cooked it).
#
# Hermetic REAL git — a `git init --bare` local "origin", a real worktree, a real branch, a real
# server-side merge, real pushes/deletes; no GitHub. Only `gh pr view`/`gh pr merge` are stubbed on
# PATH, and the stub does a FAITHFUL server-side squash-merge (merges the branch into origin/main in a
# throwaway clone, then deletes the remote branch) so the janitor's `is_ancestor`/merged classification
# observes REAL git ancestry, not a canned answer. After the tail, a `git fetch --prune` models the
# operator repo catching up to the merged reality (advances origin/main, prunes the deleted branch's
# stale tracking ref) — exactly what any real repo does on its next fetch.
#
# BEHAVIOR proven (each assertion drives real execution; the headline pair is red-when-broken BY
# CONSTRUCTION — undo one cleanup step and the SAME janitor scan flips exit 0 → exit 1):
#   * a clean finished lifecycle → janitor COHERENT, exit 0, JSON verdict "coherent" (the e2e
#     post-condition contract: a coherent repo exits 0).
#   * RED-WHEN-BROKEN: recreate the merged build branch that the finisher deleted (models a skipped
#     branch-delete step) → the SAME scan flips to exit 1 with `SAFE-FIX branch build-1`. Proves the
#     COHERENT verdict is load-bearing, not vacuous.
#   * debris injection → exit 1 with correct tiering: a clean merged IDC worktree → SAFE-FIX; an
#     unmerged IDC branch → RISKY; a foreign branch (even merged) → REPORT-ONLY. (Lean — complements,
#     not duplicates, phase1-git-janitor's full tier matrix.)
#
# Usage: bash tests/smoke/phase9-realgit-lifecycle.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
FIN="$PLUGIN/scripts/idc_git_finish.py"
JAN="$PLUGIN/scripts/idc_git_janitor.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && { echo "----- report -----"; echo "$2"; }; exit 1; }
gitc() { git -C "$REPO" "$@"; }

[ -f "$FIN" ] || fail "idc_git_finish.py not found at $FIN"
[ -f "$JAN" ] || fail "idc_git_janitor.py not found at $JAN"
[ -f "$TRK" ] || fail "idc_tracker_fs.py not found at $TRK"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ORIGIN="$WORK/origin.git"; REPO="$WORK/repo"; BRANCH="build-1"

# ---- gh stub: pr view + a FAITHFUL server-side merge on `pr merge --squash --delete-branch` --------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env python3
import os, subprocess, sys, tempfile
args = sys.argv[1:]
STATE = os.path.join(os.environ["WORK"], "gh-pr-merged")
BRANCH = os.environ["BRANCH"]; ORIGIN = os.environ["ORIGIN"]

if args[:2] == ["pr", "view"]:
    j = args[args.index("--json") + 1] if "--json" in args else ""
    print(BRANCH if j == "headRefName" else ("MERGED" if os.path.exists(STATE) else "OPEN"))
    sys.exit(0)

if args[:2] == ["pr", "merge"]:
    if "--delete-branch" not in args:
        sys.stderr.write("gh stub: pr merge missing --delete-branch\n"); sys.exit(1)
    # Model a real server-side merge: in a throwaway clone, merge BRANCH into main and push it back,
    # then delete the remote branch on ORIGIN. origin/main now genuinely contains the branch's work.
    tmp = tempfile.mkdtemp()
    def g(*a): subprocess.run(list(a), check=True, capture_output=True)
    pr = next((a for a in args if a.isdigit()), "0")
    g("git", "clone", "-q", ORIGIN, tmp)
    g("git", "-C", tmp, "config", "user.email", "bot@example.com")
    g("git", "-C", tmp, "config", "user.name", "merge-bot")
    g("git", "-C", tmp, "merge", "--no-ff", "-m", "Merge PR #" + pr, "origin/" + BRANCH)
    g("git", "-C", tmp, "push", "-q", "origin", "HEAD:main")
    g("git", "-C", ORIGIN, "branch", "-D", BRANCH)
    open(STATE, "w").close()
    sys.exit(0)

sys.stderr.write("gh stub: unhandled " + repr(args) + "\n"); sys.exit(99)
STUB
chmod +x "$WORK/bin/gh"

# ---- hermetic repo + bare origin + a real build triplet -------------------------------------------
git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" 2>/dev/null
gitc config user.email t@example.com; gitc config user.name tester
echo hello > "$REPO/README.md"; gitc add -A; gitc commit -qm init
BASE="$(gitc symbolic-ref --short HEAD)"
gitc push -q origin "HEAD:$BASE"
mkdir -p "$REPO/docs/workflow"; printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
TRACKER="$REPO/TRACKER.md"
python3 "$TRK" --tracker "$TRACKER" init >/dev/null                          || fail "tracker init failed"
python3 "$TRK" --tracker "$TRACKER" create --title "buildable feature" >/dev/null  # #1
# Claim through the TRANSITION ENGINE (not the raw tracker) so the claim is JOURNALED — the real
# lifecycle shape. The janitor's journal-replay dimension must still certify the finished lifecycle
# COHERENT below, which requires the finisher's tracker-close to land in the same journal
# (red-when-broken: an unjournaled finisher close leaves the journal at In Progress vs board Done
# → a false RISKY divergence, exit 1).
ENG="$PLUGIN/scripts/idc_transition.py"
python3 "$ENG" --repo "$REPO" --backend filesystem --tracker "$TRACKER" claim --num 1 --agent tester >/dev/null \
  || fail "engine claim failed"

WT="$REPO/.claude/worktrees/$BRANCH"
gitc worktree add -q -b "$BRANCH" "$WT" "$BASE"                              || fail "worktree add failed"
echo change > "$WT/feature.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "implement feature"
BUILD_TIP="$(git -C "$WT" rev-parse HEAD)"
git -C "$WT" push -q origin "$BRANCH"                                        || fail "push of build branch failed"

# ---- run the finisher's deterministic git-finalization tail ---------------------------------------
# Receipt gate: a clean PASS verdict owning PR #1 / issue #1 (no nits to route, no merge_conditions),
# so the tail runs its real git mechanics — this phase certifies the git/janitor end-state, not the gate.
printf '{"verdict":"PASS","pr":1,"issue":1,"findings":[]}\n' > "$REPO/verdict.json"
finish_out="$( cd "$REPO" && env PATH="$WORK/bin:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" BRANCH="$BRANCH" \
  python3 "$FIN" --pr 1 --issue 1 --worktree "$WT" --repo "$REPO" --tracker "$TRACKER" \
    --verdict "$REPO/verdict.json" 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] || fail "the finish tail must succeed on a real lifecycle (got exit $rc)" "$finish_out"
printf '%s\n' "$finish_out" | grep -qx 'finish: ok' || fail "finish must print 'finish: ok'" "$finish_out"

# The finish tail's OWN end-state (worktree/branch cleanup + tracker close BOTH halves — on filesystem
# Status IS the state, so Status=Done is the closed issue).
[ -d "$WT" ] && fail "finish must remove the build worktree: $WT"
[ -z "$(gitc branch --list "$BRANCH")" ] || fail "finish must delete the local build branch"
[ -z "$(gitc ls-remote --heads origin "$BRANCH")" ] || fail "finish must delete the remote build branch"
[ "$(python3 "$TRK" --tracker "$TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "finish must close the tracker issue (Status=Done)"
grep -q '"item": 1.*"op": "close"' "$REPO/docs/workflow/transition-journal.ndjson" \
  || fail "finish must journal its tracker-close (an op=close record for #1) — an unjournaled close makes replay report a false divergence"

# Model the operator repo catching up to the merged reality (advances origin/main to include the
# merge, prunes the deleted branch's stale tracking ref) — what any real repo does on its next fetch.
gitc fetch -q --prune origin
gitc merge-base --is-ancestor "$BUILD_TIP" origin/main \
  || fail "test invariant: the build work must genuinely be in origin/main after the merge"

# ================================================================================================
# HEADLINE (design §E.1): the janitor certifies the finished end-state COHERENT — the two shipped
# reconcilers AGREE. A finished build leaves nothing to flag.
# ================================================================================================
# --check-journal-divergence (doctor Row 10's surface): the COHERENT verdict below also proves the
# journal replays to exactly the finished board end-state (engine claim + journaled finisher close).
clean="$(python3 "$JAN" --repo "$REPO" --tracker "$TRACKER" --check-journal-divergence)"; rc=$?
[ "$rc" -eq 0 ] || fail "a cleanly-finished lifecycle must exit 0 (COHERENT), got $rc" "$clean"
printf '%s\n' "$clean" | grep -qx 'janitor: COHERENT' || fail "expected the COHERENT banner" "$clean"
cj="$(python3 "$JAN" --repo "$REPO" --tracker "$TRACKER" --check-journal-divergence --json)"
printf '%s\n' "$cj" | grep -qF '"verdict": "coherent"' \
  || fail "JSON verdict must be 'coherent' (the exit-gate and the machine-readable report must agree)" "$cj"

# ================================================================================================
# RED-WHEN-BROKEN BY CONSTRUCTION (design §E.1): undo exactly one cleanup step — recreate the merged
# build branch the finisher deleted — and the SAME scan flips exit 0 → exit 1. Proves the COHERENT
# verdict above is load-bearing, not a vacuous pass.
# ================================================================================================
gitc branch "$BRANCH" "$BUILD_TIP"                                          # skipped-branch-delete debris
broke="$(python3 "$JAN" --repo "$REPO" --tracker "$TRACKER")"; rc=$?
[ "$rc" -eq 1 ] || fail "a surviving merged build branch must flip the scan to exit 1 (got $rc)" "$broke"
printf '%s\n' "$broke" | grep -qF "SAFE-FIX branch $BRANCH" \
  || fail "the recreated merged branch must be flagged SAFE-FIX (the skipped-branch-delete debris)" "$broke"
gitc branch -D "$BRANCH" >/dev/null                                         # restore the coherent state
python3 "$JAN" --repo "$REPO" --tracker "$TRACKER" >/dev/null \
  || fail "removing the injected branch must return the repo to COHERENT (exit 0)"

# ================================================================================================
# DEBRIS INJECTION → EXIT 1 WITH CORRECT TIERING (brief item 2). One artifact per tier, on top of
# the clean end-state — complements phase1-git-janitor's exhaustive matrix, proves the tiers still
# fire at the pipeline end-state.
# ================================================================================================
# SAFE-FIX: a clean IDC worktree whose branch is merged into origin/main.
gitc worktree add -q "$WORK/wt-merged" -b "worktree-build-9" "$BUILD_TIP"    # tip already in origin/main → merged
# RISKY: an unmerged IDC branch (a fresh commit not in main). Stage ONLY u.txt — a `git add -A` here
# would sweep the untracked TRACKER.md into build-7's commit, and switching back to BASE would then
# delete TRACKER.md from the working tree (tracked on build-7, absent on BASE) → a spurious exit 2.
gitc branch "build-7" main; gitc checkout -q build-7 2>/dev/null
printf u > "$REPO/u.txt"; gitc add u.txt; gitc commit -qm "wip unmerged"; gitc checkout -q "$BASE"
# REPORT-ONLY: a foreign branch, even though its tip is merged.
gitc branch "codex/experiment" "$BUILD_TIP"

deb="$(python3 "$JAN" --repo "$REPO" --tracker "$TRACKER")"; rc=$?
[ "$rc" -eq 1 ] || fail "injected debris must exit 1 (got $rc)" "$deb"
printf '%s\n' "$deb" | grep -qF "SAFE-FIX worktree" \
  || fail "a clean merged IDC worktree must be SAFE-FIX" "$deb"
printf '%s\n' "$deb" | grep -qF "RISKY branch build-7" \
  || fail "an unmerged IDC branch must be RISKY" "$deb"
printf '%s\n' "$deb" | grep -qF "REPORT-ONLY branch codex/experiment" \
  || fail "a foreign branch must be REPORT-ONLY even when its tip is merged" "$deb"

echo "PASS: a real build triplet driven through idc_git_finish.py leaves an end-state idc_git_janitor.py certifies COHERENT (exit 0, JSON verdict coherent); recreating the merged branch the finisher deleted flips the SAME scan to exit 1 (SAFE-FIX) — red-when-broken by construction; injected debris exits 1 with correct SAFE-FIX/RISKY/REPORT-ONLY tiering"
