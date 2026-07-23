#!/bin/bash
# idc-assert-class: behavior
# Phase 4 (handoff safety) smoke — a session that dies BETWEEN the merge and the board flip must not
# corrupt the board permanently, and a FRESH session must be able to finish what it did not start.
#
# WHAT WENT WRONG (the failure this suite guards). `idc_git_finish.py`'s tail merges the PR — which
# is also what closes the linked issue, via the mandated `Closes #N` — and flips the board several
# steps later, in the same process. A session interrupted or handed off in that window left the item
# merged, closed, and still `In Progress`, with nothing recording that a close was ever underway.
# Seven items in one governed repo ended a session in exactly that state.
#
# THE MECHANISM UNDER TEST
#   scripts/idc_git_finish.py       — sets the ledger's `mid_finish:<item>` obligation BEFORE the
#                                     merge and clears it only AFTER the board flip is read back.
#   scripts/idc_finish_recover.py   — a LATER session reads the ledger UNSCOPED, asks the board
#                                     first, and completes what is still owed through the existing
#                                     idempotent `--close-only` door.
# plus their wiring into the autorun preflight (commands/autorun.md, agents/idc-autorun.md).
#
# REAL FAILURE, NOT A SIMULATION OF ONE. Section B does not stub the death: the `gh` stub performs a
# REAL merge into the base branch and then SIGKILLs the finisher process from underneath itself, so
# no exception handler, `finally`, or atexit hook can run — exactly what a kill or a context-exhausted
# handoff does. Everything after that is observed from the real artifacts the dead run left behind.
#
# RED-WHEN-BROKEN. Seven guards, each broken in the REAL source one at a time and observed to turn
# this suite red before it was committed. The edit, and the assertion it kills:
#   1. Delete the `_mid_finish_set(...)` call before `pr_merge` in idc_git_finish.py::main
#      → B2 RED: the dead session leaves no record at all, so nothing downstream can recover it.
#   2. Move `_mid_finish_clear` above the final end-state verifies in main()
#      → D2 RED: the obligation is discharged before the board flip was ever confirmed.
#   3. Disable the `close_only(...)` call in idc_finish_recover.recover
#      → C1 RED: a fresh session can no longer finish what it did not start.
#   4. Make `item_terminal` always answer "not terminal" (drop the board-first precheck)
#      → E1 RED: recovery reaches for the repair door on an item the board already shows Done.
#   5. Clear the taint and count it recovered when the door REFUSES
#      → F1 RED: an obligation that is genuinely still owed is silently dropped.
#   6/7. Remove the `idc_finish_recover.py` invocation from commands/autorun.md and from
#      agents/idc-autorun.md → G1 / G2 RED.
#
# ONE HONEST QUALIFICATION, stated rather than glossed. E2 (no second journal record) does not get
# its own mutation: the edit that would produce a double close — #4 above — trips E1 first here,
# because section E deliberately poisons `gh` so the door cannot run. E2 is a standing assertion on
# every pass (the journal is counted after C, D and E), so a regression that re-closes an already-Done
# item on a machine where the door CAN run shows up as an extra record; it is not independently
# mutation-proven, and should be read as a second lock on #4's failure rather than a separate guard.
#
# Hermetic REAL git: a bare origin, a real worktree, a real branch, real merges — no GitHub. Only
# `gh pr view` / `gh pr merge` are stubbed on PATH (a filesystem-backend tracker needs no other call).
# Usage: bash tests/smoke/phase4-mid-finish-recovery.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
FINISH="$PLUGIN/scripts/idc_git_finish.py"
RECOVER="$PLUGIN/scripts/idc_finish_recover.py"
LEDGER="$PLUGIN/scripts/hooks/idc_ledger.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
VAL="$PLUGIN/scripts/idc_validation_contract.py"
BREC="$PLUGIN/scripts/idc_build_receipt.py"
GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

for f in "$FINISH" "$RECOVER" "$LEDGER" "$TRK" "$VAL" "$BREC"; do
  [ -f "$f" ] || fail "missing helper: $f"
done
python3 "$RECOVER" --help >/dev/null 2>&1 || fail "idc_finish_recover.py --help should parse"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------------------------
# gh stub. `pr view --json headRefName|state|baseRefName`, and `pr merge --squash --delete-branch`
# which performs a REAL merge of the head branch into base in the clone, pushes it, and deletes the
# branch on the bare origin — so every git check downstream observes real git state.
#   GH_KILL_AFTER_MERGE=1   after the merge lands, SIGKILL the parent (the finisher) — the fatal
#                           window: PR merged, issue closed, board never flipped, no cleanup ran.
#   GH_KILL_ON_STATE=1      SIGKILL the parent when it asks `--json state`. In a normal finish that
#                           call comes AFTER the tracker close, so this models a death between the
#                           board flip and the obligation being discharged.
# ---------------------------------------------------------------------------------------------
mk_gh_stub() {
  mkdir -p "$1"
  cat > "$1/gh" <<'STUB'
#!/usr/bin/env python3
import os, signal, subprocess, sys
args = sys.argv[1:]
STATE_FILE = os.path.join(os.environ["WORK"], "gh-pr-merged")
BRANCH, ORIGIN, REPO, BASE = (os.environ["BRANCH"], os.environ["ORIGIN"],
                              os.environ["REPO"], os.environ.get("BASE", "main"))

def kill_parent():
    sys.stdout.flush()
    os.kill(os.getppid(), signal.SIGKILL)

if args[:2] == ["pr", "view"]:
    j = args[args.index("--json") + 1] if "--json" in args else ""
    if j == "headRefName":
        print(BRANCH)
    elif j == "state":
        print("MERGED" if os.path.exists(STATE_FILE) else "OPEN")
        if os.environ.get("GH_KILL_ON_STATE") == "1":
            kill_parent()
    elif j == "baseRefName":
        print(BASE)
    sys.exit(0)

if args[:2] == ["pr", "merge"]:
    if "--squash" not in args or "--delete-branch" not in args:
        sys.stderr.write("gh stub: pr merge missing --squash/--delete-branch\n")
        sys.exit(1)
    # A REAL merge: the work genuinely lands in base, then the head branch is deleted on origin.
    subprocess.run(["git", "-C", REPO, "checkout", "-q", BASE], capture_output=True)
    subprocess.run(["git", "-C", REPO, "merge", "-q", "--no-ff", "-m", "merge " + BRANCH, BRANCH],
                   capture_output=True)
    subprocess.run(["git", "-C", REPO, "push", "-q", "origin", BASE], capture_output=True)
    subprocess.run(["git", "-C", ORIGIN, "branch", "-D", BRANCH], capture_output=True)
    open(STATE_FILE, "w").close()
    if os.environ.get("GH_KILL_AFTER_MERGE") == "1":
        kill_parent()
    sys.exit(0)

sys.stderr.write("gh stub: unhandled " + repr(args) + "\n")
sys.exit(99)
STUB
  chmod +x "$1/gh"
}

# setup_repo <workdir> — bare origin + clone + a real worktree on `worktree-build-1` with a pushed
# commit, a governed filesystem tracker with issue #1 In Progress, and a clean PASS verdict receipt.
# Sets ORIGIN/REPO/WT/BRANCH/BASE/TRACKER.
setup_repo() {
  local work="$1"
  ORIGIN="$work/origin.git"; REPO="$work/repo"; BRANCH="worktree-build-1"
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$REPO"
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name tester
  mkdir -p "$REPO/docs/workflow/build-validation" \
           "$REPO/docs/workflow/build-validation-executions" \
           "$REPO/docs/workflow/build-receipts" \
           "$REPO/docs/workflow/code-reviews"
  echo hello > "$REPO/README.md"
  cat > "$REPO/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'green' change.txt
SH
  chmod +x "$REPO/verify.sh"
  git -C "$REPO" add README.md verify.sh
  git -C "$REPO" commit -qm init
  BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" push -q origin "HEAD:$BASE"

  WT="$REPO/.claude/worktrees/$BRANCH"
  git -C "$REPO" worktree add -q -b "$BRANCH" "$WT" "$BASE"

  printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
  TRACKER="$REPO/TRACKER.md"
  python3 "$TRK" --tracker "$TRACKER" init >/dev/null
  python3 "$TRK" --tracker "$TRACKER" create --title "Test issue" >/dev/null
  python3 "$TRK" --tracker "$TRACKER" claim --num 1 --agent tester >/dev/null

  CONTRACT="$REPO/docs/workflow/build-validation/${BRANCH}.json"
  EXECUTION="$REPO/docs/workflow/build-validation-executions/${BRANCH}.json"
  BUILD_RECEIPT="$REPO/docs/workflow/build-receipts/${BRANCH}.json"

  echo change > "$WT/change.txt"
  git -C "$WT" add change.txt
  git -C "$WT" commit -qm work
  git -C "$WT" push -q origin "$BRANCH"

  python3 "$VAL" freeze \
    --repo "$WT" \
    --issue 1 \
    --pr 501 \
    --graph-node test-issue \
    --graph-digest "$GRAPH_DIGEST" \
    --projection-digest "$PROJECTION_DIGEST" \
    --touch change.txt \
    --off-limits README.md \
    --verify 'bash verify.sh' \
    --baseline expected-red \
    --label "$BRANCH" \
    --out "$CONTRACT" >/dev/null \
    || fail "could not freeze the build validation contract for $BRANCH"

  echo green > "$WT/change.txt"
  git -C "$WT" add change.txt
  git -C "$WT" commit -qm "green"
  git -C "$WT" push -q origin "$BRANCH"

  python3 "$VAL" run --repo "$WT" --contract "$CONTRACT" --out "$EXECUTION" >/dev/null \
    || fail "could not execute the frozen validation gate for $BRANCH"
  VERDICT="$REPO/docs/workflow/code-reviews/2026-07-22-pr-501-review.json"
  python3 - "$EXECUTION" "$VERDICT" <<'PY' || exit 1
import json, sys
execution_path, verdict_path = sys.argv[1:3]
execution = json.load(open(execution_path, encoding='utf-8'))
verdict = {
    'verdict': 'PASS',
    'pr': 501,
    'issue': 1,
    'head': execution['head'],
    'diff_digest': execution['diff_digest'],
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  python3 "$CHECK" "$VERDICT" >/dev/null 2>&1 || fail "validator did not accept the clean finish verdict"
  python3 "$BREC" write \
    --repo "$WT" \
    --contract "$CONTRACT" \
    --execution "$EXECUTION" \
    --verdict "$VERDICT" \
    --graph-digest "$GRAPH_DIGEST" \
    --projection-digest "$PROJECTION_DIGEST" \
    --out "$BUILD_RECEIPT" >/dev/null \
    || fail "could not write the implementation receipt for $BRANCH"
}

# run_finish <extra env…> — the normal finish tail, as the finisher session would run it.
run_finish() {
  ( cd "$REPO" && env PATH="$BIN:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" REPO="$REPO" \
      BRANCH="$BRANCH" BASE="$BASE" CLAUDE_CODE_SESSION_ID=dead-session "$@" \
      python3 "$FINISH" --pr 501 --issue 1 --worktree "$WT" --repo "$REPO" \
        --tracker "$TRACKER" --verdict "$VERDICT" --build-receipt "$BUILD_RECEIPT" ) >/dev/null 2>&1
}

# run_recover [extra env…] — a FRESH session's recovery pass (a different session id, by design).
run_recover() {
  out="$( cd "$REPO" && env PATH="$BIN:$PATH" WORK="$WORK" ORIGIN="$ORIGIN" REPO="$REPO" \
      BRANCH="$BRANCH" BASE="$BASE" CLAUDE_CODE_SESSION_ID=fresh-session "$@" \
      python3 "$RECOVER" --repo "$REPO" --session-id fresh-session 2>/dev/null )"
  rc=$?
}

status_of() { python3 "$TRK" --tracker "$TRACKER" show --num "$1" --field Status 2>/dev/null; }
# The after-the-fact safety net, run on the AMBIENT PATH (it must see ordinary tooling, not the PR
# stub). Prevention and detection have to agree: what recovery repairs, this must then call clean.
coherence() { python3 "$PLUGIN/scripts/idc_finish_coherence.py" --repo "$REPO" --tracker "$TRACKER" 2>/dev/null; }
taints()    { python3 "$LEDGER" --cwd "$REPO" pending 2>/dev/null; }
close_records() {  # how many `close` records the transition journal holds for item #1
  python3 - "$REPO/docs/workflow/transition-journal.ndjson" <<'PY'
import json, sys
n = 0
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("op") == "close" and r.get("item") == 1:
            n += 1
except OSError:
    pass
print(n)
PY
}

echo "== A. a clean finish leaves NO obligation behind"
BIN="$WORK/bin-a"; mk_gh_stub "$BIN"
setup_repo "$WORK/a"
run_finish || fail "A: the normal finish should succeed (rc=$?)"
[ "$(status_of 1)" = "Done" ] || fail "A1: a clean finish must leave #1 Done, got '$(status_of 1)'"
taints | grep -q 'mid_finish' && fail "A2: a clean finish must leave no mid_finish obligation, got: $(taints | tr '\n' ' ')"
echo "  ok A1/A2 clean finish: board Done, ledger quiescent"

echo "== B. a session KILLED between the merge and the board flip (the real failure)"
rm -f "$WORK/gh-pr-merged"
BIN="$WORK/bin-b"; mk_gh_stub "$BIN"
setup_repo "$WORK/b"
run_finish GH_KILL_AFTER_MERGE=1 && fail "B: the killed finish must NOT report success"
# The corruption, reproduced exactly: work shipped, board never advanced.
git -C "$REPO" merge-base --is-ancestor "origin/$BRANCH" "origin/$BASE" 2>/dev/null \
  || git -C "$REPO" log --oneline "origin/$BASE" | grep -q "merge $BRANCH" \
  || fail "B1: precondition — the stub must really merge the work into base"
[ "$(status_of 1)" = "In Progress" ] \
  || fail "B1b: the board must still claim #1 In Progress after the kill, got '$(status_of 1)'"
taints | grep -qx 'mid_finish:1' \
  || fail "B2: the dead session must leave a mid_finish:1 obligation, got: $(taints | tr '\n' ' ')"
grep -q '"pr": "501"' "$REPO/.idc-session-state.json" \
  || fail "B3: the obligation must carry the PR a later session needs to complete it"
coh="$(coherence)"   # captured, not piped: the gate EXITS 1 on a finding and pipefail would eat it
[ "$coh" = 'finish-coherence: gap #1' ] \
  || fail "B4: the after-the-fact coherence gate must see the same stale item, got: $coh"
echo "  ok B1-B4 killed mid-finish: work shipped, board stale, obligation recorded, gate agrees"

echo "== C. a FRESH session recovers the interrupted finish it did not start"
run_recover
[ "$rc" = 0 ] || fail "C: recovery must be fail-soft (exit 0), got $rc"
printf '%s' "$out" | grep -qx 'recover: recovered' \
  || fail "C1: expected 'recover: recovered', got: $(printf '%s' "$out" | tr '\n' '|')"
printf '%s' "$out" | grep -qx 'recovered: 1' || fail "C1b: item #1 must be named as recovered"
[ "$(status_of 1)" = "Done" ] \
  || fail "C2: after recovery the board must show #1 Done, got '$(status_of 1)'"
taints | grep -q 'mid_finish' && fail "C3: a discharged obligation must be cleared, got: $(taints | tr '\n' ' ')"
[ "$(close_records)" = "1" ] || fail "C4: recovery must journal exactly ONE close, got $(close_records)"
coh="$(coherence)"
[ "$coh" = 'finish-coherence: ok' ] \
  || fail "C5: recovery must leave the coherence gate CLEAN, got: $coh"
echo "  ok C1-C5 fresh session completed it: board Done, obligation cleared, one journal record, gate clean"

echo "== D. repeat runs are safe; the obligation outlives the close until the flip is verified"
run_recover
printf '%s' "$out" | grep -qx 'recover: complete' \
  || fail "D1: a second pass with nothing to recover must report 'recover: complete', got: $(printf '%s' "$out" | tr '\n' '|')"
[ "$(close_records)" = "1" ] || fail "D1b: a repeat pass must not re-close (journal grew to $(close_records))"
# A death AFTER the board flip but BEFORE the obligation is discharged: the flip already landed, so
# the taint is stale — but it MUST still be there, or the clear ran before the end state was proven.
rm -f "$WORK/gh-pr-merged"
BIN="$WORK/bin-d"; mk_gh_stub "$BIN"
setup_repo "$WORK/d"
run_finish GH_KILL_ON_STATE=1 && fail "D2: the finish killed at its end-state verify must not report success"
[ "$(status_of 1)" = "Done" ] || fail "D2a: precondition — the board flip must have landed first"
taints | grep -qx 'mid_finish:1' \
  || fail "D2: the obligation must survive a death after the close but before the end-state verify"
echo "  ok D1/D2 repeat-safe; the obligation is discharged only after the end state is verified"

echo "== E. a stale obligation (its work is already complete) resolves without touching the door"
# `gh` is POISONED for this pass — it fails on every call. If recovery reached for the --close-only
# door the door would die, so a clean `cleared:` here proves the BOARD, not the ledger, decided the
# outcome. (Poisoning beats un-setting PATH: operators have a real `gh` installed, and this way the
# proof does not depend on which directories happen to be on PATH.)
BIN="$WORK/bin-e"; mkdir -p "$BIN"
printf '#!/bin/sh\necho "gh stub: recovery must not reach the door here" >&2\nexit 99\n' > "$BIN/gh"
chmod +x "$BIN/gh"
run_recover
printf '%s' "$out" | grep -qx 'cleared: 1' \
  || fail "E1: a stale obligation must be CLEARED from the board's own answer, got: $(printf '%s' "$out" | tr '\n' '|')"
taints | grep -q 'mid_finish' && fail "E1b: the stale obligation must be gone, got: $(taints | tr '\n' ' ')"
[ "$(close_records)" = "1" ] \
  || fail "E2: clearing a stale obligation must not re-close (journal has $(close_records) close records for one real close)"
echo "  ok E1/E2 stale obligation cleared from board truth; no second close, no second journal record"

echo "== F. an obligation that is genuinely still owed is NEVER silently dropped"
rm -f "$WORK/gh-pr-merged"          # the PR is OPEN — nothing shipped
BIN="$WORK/bin-f"; mk_gh_stub "$BIN"
setup_repo "$WORK/f"
python3 "$LEDGER" --cwd "$REPO" set --kind mid_finish --key 1 --session dead-session \
  --field pr=501 --field "tracker=$TRACKER" >/dev/null || fail "F: could not seed the obligation"
run_recover
[ "$rc" = 0 ] || fail "F: recovery must stay fail-soft even when it cannot finish the job, got $rc"
printf '%s' "$out" | grep -qx 'unresolved: 1' \
  || fail "F1: an undischargeable obligation must be reported unresolved, got: $(printf '%s' "$out" | tr '\n' '|')"
taints | grep -qx 'mid_finish:1' \
  || fail "F1b: an undischargeable obligation must be PRESERVED, got: $(taints | tr '\n' ' ')"
[ "$(status_of 1)" = "In Progress" ] || fail "F2: nothing shipped, so the board must not be flipped"
echo "  ok F1/F2 unfinished work stays owed: reported unresolved, taint preserved, board untouched"

echo "== G. recovery is wired into the autorun preflight (the place a handoff is picked up)"
grep -q 'scripts/idc_finish_recover.py" --repo "\$PWD"' "$PLUGIN/commands/autorun.md" \
  || fail "G1: commands/autorun.md must INVOKE idc_finish_recover.py (not merely mention it)"
grep -q 'scripts/idc_finish_recover.py" --repo "\$PWD"' "$PLUGIN/agents/idc-autorun.md" \
  || fail "G2: agents/idc-autorun.md must INVOKE idc_finish_recover.py (not merely mention it)"
echo "  ok G1/G2 both autorun playbooks run the recovery pass"

echo "PASS: phase4-mid-finish-recovery"
