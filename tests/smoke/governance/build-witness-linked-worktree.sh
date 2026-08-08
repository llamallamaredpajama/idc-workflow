#!/bin/bash
# build-witness-linked-worktree.sh — issue #197: the build witness chain must work in the LINKED
# WORKTREE a durable worker actually runs in, must survive that worktree's deletion, and — the part
# this fixture drives END TO END — the REAL finish tail must be able to complete there.
#
# Build ALWAYS runs in a linked worktree by design (agents/idc-build.md: one pre-created worktree per
# durable worker; skills/idc-adapter-claude/SKILL.md creates them under `.claude/worktrees/<name>`;
# agents/idc-implementer.md freezes with `--repo "$PWD"`). Two halves, one lifecycle:
#
# HALF 1 — THE WITNESS KEY (#197). It was derived from `git rev-parse --git-common-dir`, which in a
# linked worktree resolves to the PRIMARY checkout, so every artifact was measured against a root it
# does not live under: a worktree OUTSIDE the primary checkout was refused at freeze ("must live under
# the governed repo root"), and one INSIDE it keyed the witness by `.claude/worktrees/<name>/docs/…`,
# a key that dies with the worktree. Fixed by keying every witness on the artifact's path relative to
# ITS OWN worktree root — the stable LOGICAL repo path, identical in every worktree and after a merge.
#
# HALF 2 — THE FINISH TAIL. Keying the witness durably is not enough if the FILES still die with the
# worktree, and the real tail had no way through. The freeze → run → review → receipt chain writes its
# four artifacts inside the build worktree, and:
#   * COMMITTING them after the receipt is sealed advances the branch head, so
#     `idc_git_finish.enforce_build_receipt` (which binds `head_ref=<branch>`) refuses the finish with
#     "stale build receipt refused";
#   * the SHIPPED `docs/workflow/code-reviews/.gitignore` ignores `*`, so the review VERDICT cannot be
#     committed at all (`git add` refuses it without `-f`) — the receipt's `verdict_path` would dangle
#     even if the head problem were solved;
#   * leaving them UNCOMMITTED makes the tail's plain (non-force) `git worktree remove` refuse —
#     "contains modified or untracked files".
# So the finish died either way, and the artifact the post-merge Build closeout re-verifies
# (`idc_command_contract._valid_build_receipt` re-reads `docs/workflow/build-receipts/<file>.json`
# from the governed repo) died with the worktree. `idc_git_finish.persist_build_witness_artifacts`
# relocates the four artifacts onto their durable LOGICAL paths in the governed checkout before the
# removal and RE-VERIFIES the receipt there — nothing committed, the sealed head untouched, the
# removal still non-force. That only works because half 1 made the witness key logical.
#
# What this fixture pins, in the shapes production actually takes:
#   A — a build worktree BESIDE the primary checkout: freeze → run → receipt all succeed and re-verify.
#   B — a build worktree UNDER it (`.claude/worktrees/<branch>`), artifacts written INSIDE it, driven
#       through the REAL `scripts/idc_git_finish.py` (real bare origin, real branch, real pushes,
#       filesystem tracker, the shipped code-reviews/.gitignore; only `gh pr view`/`gh pr merge` are
#       stubbed, and the stub enforces --match-head-commit exactly as GitHub does). The finish must
#       reach `finish: ok`, and the durable artifacts must then pass the SAME `verify_receipt` the
#       Build closeout runs after the merge.
#   D — no gate was loosened to get there: an unrelated untracked file in the build worktree still
#       stops the finish with git's own non-force refusal, before any mutation.
#   C — no widening: a contract carried into a FOREIGN repository is still refused.
#
# RED-WHEN-BROKEN, OBSERVED. Each fix point reds this fixture on its own:
#   1. idc_validation_contract.py::_repo_context — replace `worktree_root = _worktree_toplevel(parent)`
#      with `os.path.realpath(os.path.dirname(common_git_dir))`: case A reds at freeze,
#      "…/build-wt-sibling/docs/workflow/build-validation/sibling.json must live under its worktree
#      root …/primary-a".
#   2. idc_build_receipt.py::_artifact_root — replace `root = VC._worktree_toplevel(anchor)` with
#      `VC._repo_identity(repo)`: case A reds at the implementation-receipt write, "must live under
#      the governed repo root".
#   3. idc_review_verdict_check.py::_code_reviews_context — return `top` (this worktree's toplevel)
#      instead of the primary checkout identity: case B reds at the tail's re-verification, "the
#      validator witness for docs/workflow/code-reviews/… names repo '…/.claude/worktrees/…', not
#      this repo".
#   4. idc_git_finish.py::main — delete the `persist_build_witness_artifacts(...)` call: case B reds
#      at the REAL tail, "finish: worktree-remove failed: … contains modified or untracked files,
#      use --force to delete it" — the pre-fix production behavior, verbatim.
#   5. idc_git_finish.worktree_remove — drop the loop that drops the relocated SOURCES: case B reds
#      with the same non-force refusal (the copies alone do not clean the tree).
#   6. idc_git_finish.worktree_remove — drop the loop that RESTORES those sources when the removal is
#      refused anyway: case D2 reds, "the refused finish consumed the very verdict its command line
#      names — the operator cannot re-run it".
#
# ONE GUARD IS DELIBERATELY NOT REDDENABLE ALONE, and saying so is part of the record. Neutering the
# durable-path RE-VERIFY at the end of persist_build_witness_artifacts (`return verified_head,
# relocated` instead of re-running `enforce_build_receipt`) leaves this fixture GREEN, because with
# the rest of the chain correct the copied bytes are identical and their witness key is unchanged, so
# there is nothing for it to catch. Its value is ORDERING, and probe 3 shows it: with the
# verdict-witness break in place, the re-verify turns the failure into a PRE-merge refusal ("finish:
# build-receipt failed: the validator witness … names repo '…/.claude/worktrees/…'"); without it the
# same break is not caught until case B4 — after the merge and the board close. Removing it does not
# change WHETHER a witness-keying regression is caught, only whether it is caught before or after the
# point of no return, which is the entire point of a fail-closed tail.
# On the pre-#197 code case B also reds earlier, with "no source-owned validation witness is recorded
# for docs/workflow/build-validation/nested.json" — verbatim the 2026-08-02 e2e's complaint.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
FIN="$PLUGIN/scripts/idc_git_finish.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
GITIGNORE_SRC="$PLUGIN/templates/docs-tree/code-reviews/.gitignore"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
. "$(dirname "$0")/../lib/fail-closed.sh"

fc_require_file "$VC" "the build validation-contract helper (scripts/idc_validation_contract.py)"
fc_require_file "$BR" "the implementation-receipt helper (scripts/idc_build_receipt.py)"
fc_require_file "$CHECK" "the review-verdict validator (scripts/idc_review_verdict_check.py)"
fc_require_file "$FIN" "the deterministic finish tail (scripts/idc_git_finish.py)"
fc_require_file "$TRK" "the filesystem tracker backend (scripts/idc_tracker_fs.py)"
fc_require_file "$GITIGNORE_SRC" "the SHIPPED code-reviews gitignore (templates/docs-tree/code-reviews/.gitignore)"

GD='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PD='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
digest_of() { shasum -a 256 < "$1" | cut -d' ' -f1; }
# The ticket under test is #197, but the filesystem tracker numbers its items sequentially from 1 and
# case B closes a REAL tracker item through the REAL finish tail — so the item, the frozen contract
# and the verdict must all agree on ONE number, and that number is the tracker's.
ISSUE=1

# --- a governed primary checkout, ready for a build worktree -------------------------------------
# `origin` is a REAL bare repo (the finish tail proves remote-branch deletion with `git ls-remote`, so
# a fake remote would make case B prove nothing), and the SHIPPED code-reviews/.gitignore is copied in
# exactly as `/idc:init` scaffolds it — that ignore rule is one of the three horns above.
setup_primary() {
  local repo="$1" origin="$1.git"
  git init -q --bare "$origin" || fail "could not init the bare origin"
  git clone -q "$origin" "$repo" 2>/dev/null || fail "could not clone the primary checkout"
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
  mkdir -p "$repo/src/allowed" "$repo/src/blocked" "$repo/docs/workflow/code-reviews"
  cp "$GITIGNORE_SRC" "$repo/docs/workflow/code-reviews/.gitignore"
  cat > "$repo/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
  chmod +x "$repo/verify.sh"
  printf 'old behavior\n' > "$repo/src/allowed/feature.txt"
  printf 'do not touch\n' > "$repo/src/blocked/guard.txt"
  printf '# repo\n' > "$repo/README.md"
  printf '.claude/\n' > "$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  git -C "$repo" push -q origin main || fail "could not seed the bare origin"
}

freeze_in() {                       # freeze_in <worktree> <pr> <label> <out>
  python3 "$VC" freeze \
    --surface cli \
    --repo "$1" \
    --issue "$ISSUE" \
    --pr "$2" \
    --graph-node alpha \
    --graph-digest "$GD" \
    --projection-digest "$PD" \
    --touch src/allowed/ \
    --off-limits src/blocked/ \
    --verify 'bash verify.sh' \
    --baseline expected-red \
    --label "$3" \
    --out "$4"
}

make_verdict() {                    # make_verdict <execution receipt> <verdict out> <pr>
  python3 - "$1" "$2" "$3" "$ISSUE" <<'PY'
import json, sys
exec_path, verdict_path, pr, issue = sys.argv[1:5]
receipt = json.load(open(exec_path, encoding='utf-8'))
doc = {
    'verdict': 'PASS',
    'pr': int(pr),
    'issue': int(issue),
    'head': receipt['head'],
    'diff_digest': receipt['diff_digest'],
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  python3 "$CHECK" "$2" >/dev/null 2>&1 || fail "the review-verdict validator rejected a well-formed PASS verdict"
}

# ==================================================================================================
# CASE A — a build worktree OUTSIDE the primary checkout: the whole freeze → run → receipt chain.
# ==================================================================================================
PRIMARY_A="$WORK/primary-a"
setup_primary "$PRIMARY_A"
WT="$WORK/build-wt-sibling"
git -C "$PRIMARY_A" worktree add -q -b build/sibling "$WT" \
  || fail "could not create the sibling build worktree"

CONTRACT_A="$WT/docs/workflow/build-validation/sibling.json"
EXEC_A="$WT/docs/workflow/build-validation-executions/sibling.json"
VERDICT_A="$WT/docs/workflow/code-reviews/2026-08-08-pr-900-sibling.json"
RECEIPT_A="$WT/docs/workflow/build-receipts/sibling.json"
mkdir -p "$(dirname "$VERDICT_A")" "$(dirname "$RECEIPT_A")"

out="$(freeze_in "$WT" 900 sibling "$CONTRACT_A" 2>&1)" \
  || fail "freeze refused a build worktree outside the primary checkout (#197): $out"
out="$(python3 "$VC" check-surface --contract "$CONTRACT_A" 2>&1)" \
  || fail "the contract frozen in a linked worktree does not re-verify against its own witness: $out"

printf 'new behavior\n' > "$WT/src/allowed/feature.txt"
git -C "$WT" add src/allowed/feature.txt
git -C "$WT" commit -qm 'implement the allowed surface'

out="$(python3 "$VC" run --repo "$WT" --contract "$CONTRACT_A" --out "$EXEC_A" 2>&1)" \
  || fail "run refused to record an execution receipt in a linked worktree (#197): $out"
make_verdict "$EXEC_A" "$VERDICT_A" 900
out="$(python3 "$BR" write --repo "$WT" --contract "$CONTRACT_A" --execution "$EXEC_A" \
        --verdict "$VERDICT_A" --graph-digest "$GD" --projection-digest "$PD" \
        --out "$RECEIPT_A" 2>&1)" \
  || fail "the implementation receipt could not be written in a linked worktree (#197): $out"
out="$(python3 "$BR" verify --repo "$WT" --receipt "$RECEIPT_A" 2>&1)" \
  || fail "the implementation receipt written in a linked worktree did not re-verify there: $out"

# ==================================================================================================
# CASE B — the REAL production shape, driven through the REAL finish tail.
# ==================================================================================================
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env python3
"""The only two gh calls a filesystem-backend finish makes. `pr merge` mutates the REAL bare origin,
so the tail's own `git ls-remote` verification observes real git state; it enforces
--match-head-commit exactly as GitHub does server-side (F62), and RECORDS the head it was asked to
merge so the fixture can prove the merge landed the sealed head and nothing else."""
import os, subprocess, sys
args = sys.argv[1:]
STATE = os.path.join(os.environ["WORK_B"], "gh-merged-head-%s" % args[2])
BRANCH, ORIGIN = os.environ["BRANCH_B"], os.environ["ORIGIN_B"]
if args[:2] == ["pr", "view"]:
    j = args[args.index("--json") + 1] if "--json" in args else ""
    if j == "headRefName":
        print(BRANCH)
    elif j == "state":
        print("MERGED" if os.path.exists(STATE) else "OPEN")
    elif j == "baseRefName":
        print("main")
    sys.exit(0)
if args[:2] == ["pr", "merge"]:
    if "--match-head-commit" not in args:
        sys.stderr.write("gh stub: pr merge is not bound to the verified receipt head (F62)\n")
        sys.exit(1)
    claimed = args[args.index("--match-head-commit") + 1]
    tip = subprocess.run(["git", "-C", ORIGIN, "rev-parse", "refs/heads/" + BRANCH],
                         capture_output=True, text=True).stdout.strip()
    if not tip or claimed != tip:
        sys.stderr.write("gh stub: head %r does not match --match-head-commit %r\n" % (tip, claimed))
        sys.exit(1)
    with open(STATE, "w") as fh:
        fh.write(claimed)
    subprocess.run(["git", "-C", ORIGIN, "branch", "-D", BRANCH], capture_output=True)
    sys.exit(0)
sys.stderr.write("gh stub: unhandled " + repr(args) + "\n")
sys.exit(99)
STUB
chmod +x "$WORK/bin/gh"

# build_case_b <tag> <pr> — a complete, ISOLATED case-B fixture: its own bare origin, primary
# checkout, nested build worktree, filesystem tracker, and all four witness artifacts written INSIDE
# the worktree. Sets B_PRIMARY / B_WT / B_BRANCH / B_CONTRACT / B_EXEC / B_VERDICT / B_RECEIPT /
# B_TRACKER, and writes an EXECUTABLE runner at $WORK/run-finish-<tag>.sh, because assert_fail_closed
# drives real commands (a shell function cannot be run under `timeout`).
build_case_b() {
  local tag="$1" pr="$2" out
  B_PRIMARY="$WORK/primary-$tag"; B_BRANCH="worktree-build-197"
  setup_primary "$B_PRIMARY"
  B_WT="$B_PRIMARY/.claude/worktrees/$B_BRANCH"
  git -C "$B_PRIMARY" worktree add -q -b "$B_BRANCH" "$B_WT" \
    || fail "could not create the nested build worktree ($tag)"

  printf 'backend: filesystem\n' > "$B_PRIMARY/docs/workflow/tracker-config.yaml"
  B_TRACKER="$B_PRIMARY/TRACKER.md"
  python3 "$TRK" --tracker "$B_TRACKER" init >/dev/null || fail "could not init the tracker ($tag)"
  python3 "$TRK" --tracker "$B_TRACKER" create --title "linked-worktree build" >/dev/null \
    || fail "could not seed the tracker item ($tag)"
  python3 "$TRK" --tracker "$B_TRACKER" claim --num 1 --agent tester >/dev/null \
    || fail "could not claim the tracker item ($tag)"

  # EVERY artifact inside the ephemeral build worktree — the shape the 2026-08-02 e2e recorded.
  B_CONTRACT="$B_WT/docs/workflow/build-validation/nested.json"
  B_EXEC="$B_WT/docs/workflow/build-validation-executions/nested.json"
  B_VERDICT="$B_WT/docs/workflow/code-reviews/2026-08-08-pr-$pr-nested.json"
  B_RECEIPT="$B_WT/docs/workflow/build-receipts/nested.json"
  mkdir -p "$(dirname "$B_CONTRACT")" "$(dirname "$B_EXEC")" \
           "$(dirname "$B_VERDICT")" "$(dirname "$B_RECEIPT")"

  out="$(freeze_in "$B_WT" "$pr" nested "$B_CONTRACT" 2>&1)" \
    || fail "freeze failed in a nested build worktree ($tag): $out"
  printf 'new behavior\n' > "$B_WT/src/allowed/feature.txt"
  git -C "$B_WT" add src/allowed/feature.txt
  git -C "$B_WT" commit -qm 'implement the allowed surface'
  git -C "$B_WT" push -q origin "$B_BRANCH" || fail "could not push the build branch ($tag)"
  out="$(python3 "$VC" run --repo "$B_WT" --contract "$B_CONTRACT" --out "$B_EXEC" 2>&1)" \
    || fail "run failed in a nested build worktree ($tag): $out"
  make_verdict "$B_EXEC" "$B_VERDICT" "$pr"
  out="$(python3 "$BR" write --repo "$B_WT" --contract "$B_CONTRACT" --execution "$B_EXEC" \
          --verdict "$B_VERDICT" --graph-digest "$GD" --projection-digest "$PD" \
          --out "$B_RECEIPT" 2>&1)" \
    || fail "the implementation receipt could not be written in a nested build worktree ($tag): $out"

  cat > "$WORK/run-finish-$tag.sh" <<RUNNER
#!/bin/bash
cd "$B_PRIMARY" || exit 97
export PATH="$WORK/bin:\$PATH" WORK_B="$WORK" ORIGIN_B="$B_PRIMARY.git" BRANCH_B="$B_BRANCH"
exec python3 "$FIN" --pr $pr --issue $ISSUE --worktree "$B_WT" --repo "$B_PRIMARY" \\
  --tracker "$B_TRACKER" --verdict "$B_VERDICT" --build-receipt "$B_RECEIPT"
RUNNER
  chmod +x "$WORK/run-finish-$tag.sh"
}

build_case_b b 901

# --- B0: the constraints are REAL in this fixture, not assumed -----------------------------------
# Without these the case could pass for the wrong reason — against a repo whose gitignore never
# shipped, or one where something quietly committed the artifacts and moved the head after the seal.
git -C "$B_WT" check-ignore -q "$B_VERDICT" \
  || fail "the shipped code-reviews/.gitignore is not in force in the build worktree — case B would not be exercising the real constraint (the verdict must be uncommittable)"
[ -n "$(git -C "$B_WT" status --porcelain -- docs/workflow/build-receipts)" ] \
  || fail "the sealed implementation receipt is not an untracked file in the build worktree — case B would not be exercising the non-force `git worktree remove` constraint"
SEALED_HEAD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$B_RECEIPT")"
[ "$SEALED_HEAD" = "$(git -C "$B_PRIMARY" rev-parse "$B_BRANCH")" ] \
  || fail "the fixture advanced the branch past the sealed receipt head before the finish — that is the OTHER horn, and it would mask the one under test"
SEALED_CONTRACT_D="$(digest_of "$B_CONTRACT")"
SEALED_EXEC_D="$(digest_of "$B_EXEC")"
SEALED_VERDICT_D="$(digest_of "$B_VERDICT")"
SEALED_RECEIPT_D="$(digest_of "$B_RECEIPT")"
VERDICT_BASENAME="$(basename "$B_VERDICT")"

# --- B1: the REAL finish tail completes ----------------------------------------------------------
out="$(bash "$WORK/run-finish-b.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  || fail "the REAL finish tail cannot complete a build whose witness artifacts live in the linked worktree it is about to delete (#197): exit $rc: $out"
printf '%s\n' "$out" | grep -qx 'finish: ok' \
  || fail "the finish tail did not report 'finish: ok': $out"

# --- B2: it really finished — worktree, branches and board --------------------------------------
[ ! -d "$B_WT" ] || fail "the build worktree directory was not removed — case B would prove nothing"
git -C "$B_PRIMARY" worktree list --porcelain | grep -qF "$B_WT" \
  && fail "the build worktree is still registered in the worktree list"
[ -z "$(git -C "$B_PRIMARY" branch --list "$B_BRANCH")" ] \
  || fail "the local build branch survived the finish"
[ -z "$(git -C "$B_PRIMARY" ls-remote --heads origin "$B_BRANCH")" ] \
  || fail "the remote build branch survived the finish"
[ "$(python3 "$TRK" --tracker "$B_TRACKER" show --num 1 --field Status)" = "Done" ] \
  || fail "the tracker item was not closed by the finish tail"

# --- B3: the artifacts outlived the worktree, byte-identical, at their DURABLE logical paths -----
DUR_CONTRACT="$B_PRIMARY/docs/workflow/build-validation/nested.json"
DUR_EXEC="$B_PRIMARY/docs/workflow/build-validation-executions/nested.json"
DUR_VERDICT="$B_PRIMARY/docs/workflow/code-reviews/$VERDICT_BASENAME"
DUR_RECEIPT="$B_PRIMARY/docs/workflow/build-receipts/nested.json"
for f in "$DUR_CONTRACT" "$DUR_EXEC" "$DUR_VERDICT" "$DUR_RECEIPT"; do
  [ -f "$f" ] \
    || fail "the finish tail deleted the build worktree without persisting $f — the durable artifact the Build closeout re-verifies died with the worktree (#197)"
done
[ "$(digest_of "$DUR_RECEIPT")" = "$SEALED_RECEIPT_D" ] \
  || fail "the persisted implementation receipt is not byte-identical to the sealed one"
[ "$(digest_of "$DUR_VERDICT")" = "$SEALED_VERDICT_D" ] \
  || fail "the persisted review verdict is not byte-identical to the sealed one"
[ "$(digest_of "$DUR_CONTRACT")" = "$SEALED_CONTRACT_D" ] \
  || fail "the persisted validation contract is not byte-identical to the sealed one"
[ "$(digest_of "$DUR_EXEC")" = "$SEALED_EXEC_D" ] \
  || fail "the persisted execution receipt is not byte-identical to the sealed one"

# --- B4: the POST-MERGE Build closeout re-verification passes ------------------------------------
# Exactly what idc_command_contract._valid_build_receipt runs once the PR is merged: the receipt read
# from the governed repo by its repo-relative path, re-verified for this issue/PR, with no --head-ref
# (the branch is gone by then). This is the assertion the old fixture could not make.
out="$(python3 "$BR" verify --repo "$B_PRIMARY" --receipt "$DUR_RECEIPT" --issue "$ISSUE" --pr 901 2>&1)" \
  || fail "the durable implementation receipt does not survive the Build closeout's own re-verification after the merge (#197): $out"

# --- B5: nothing was committed, and nothing but the sealed head was merged -----------------------
[ "$(cat "$WORK/gh-merged-head-901")" = "$SEALED_HEAD" ] \
  || fail "the merge was bound to a head other than the sealed/reviewed one — an artifact commit slipped in ahead of it"
git -C "$B_PRIMARY" check-ignore -q "$DUR_VERDICT" \
  || fail "the persisted verdict is no longer covered by the shipped code-reviews/.gitignore — machine review artifacts must never become committable"
git -C "$B_PRIMARY" ls-files --error-unmatch "$DUR_RECEIPT" >/dev/null 2>&1 \
  && fail "the implementation receipt was COMMITTED — the tail must persist it as a working file, never advance the sealed branch"

# --- B6: the witness keys are the durable LOGICAL paths, nothing ephemeral -----------------------
COMMON_B="$(git -C "$B_PRIMARY" rev-parse --path-format=absolute --git-common-dir)"
python3 - "$COMMON_B/idc-build-validation-witnesses.json" "$(cd "$B_PRIMARY" && pwd -P)" <<'PY' \
  || exit 1
import json, os, sys
store, primary = sys.argv[1:3]
try:
    data = json.load(open(store, encoding='utf-8'))
except OSError as exc:
    print("FAIL: the witness store is unreadable after teardown (%s)" % exc); sys.exit(1)
expected = {
    'docs/workflow/build-validation/nested.json': 'contract',
    'docs/workflow/build-validation-executions/nested.json': 'execution',
    'docs/workflow/build-receipts/nested.json': 'build-receipt',
}
for key, kind in expected.items():
    rec = data.get(key)
    if not isinstance(rec, dict):
        print("FAIL: no %s witness is keyed by the durable logical path %r; store holds %r"
              % (kind, key, sorted(data))); sys.exit(1)
    if rec.get('kind') != kind:
        print("FAIL: witness %r is for kind %r, not %r" % (key, rec.get('kind'), kind)); sys.exit(1)
    # No widening: the witness still binds THIS repository's stable identity (the primary checkout),
    # not whichever ephemeral worktree happened to record it.
    if os.path.realpath(rec.get('repo_root') or '') != os.path.realpath(primary):
        print("FAIL: witness %r binds repo_root %r, not the primary checkout %r"
              % (key, rec.get('repo_root'), primary)); sys.exit(1)
for key in data:
    if '.claude/worktrees' in key or 'build-wt' in key:
        print("FAIL: witness key %r bakes in an ephemeral worktree path — it dies with the worktree"
              % key); sys.exit(1)
PY

# ==================================================================================================
# CASE D — nothing was loosened to get case B through. The tail still removes the build worktree with
# a plain, NON-FORCE `git worktree remove`: an untracked file it was never asked to persist still
# stops the finish with git's own refusal, before any mutation. The positive control is a FRESH,
# identical fixture without that file — not the already-finished case-B one, which would fail for an
# unrelated reason and never reach the removal at all.
# ==================================================================================================
build_case_b ctl 902
build_case_b d 903
printf 'a stray note the finisher was never told about\n' > "$B_WT/stray-note.txt"
D_WT="$B_WT"; D_TRACKER="$B_TRACKER"; D_PRIMARY="$B_PRIMARY"
D_VERDICT_SRC="$B_VERDICT"; D_RECEIPT_SRC="$B_RECEIPT"

assert_fail_closed \
  "an unrelated untracked file in the build worktree still stops the finish (the removal is non-force)" \
  "contains modified or untracked files" \
  -- bash "$WORK/run-finish-d.sh" \
  -- bash "$WORK/run-finish-ctl.sh"

[ "$FC_CONTROL_RC" -eq 0 ] \
  || fail "the positive control must be the SUCCEEDING path (the same finish on an otherwise-clean build worktree), but it exited $FC_CONTROL_RC: $FC_CONTROL_OUT"
[ -d "$D_WT" ] \
  || fail "the refused finish still removed the build worktree — a non-force removal failure must stop the tail before any mutation"
[ "$(python3 "$TRK" --tracker "$D_TRACKER" show --num "$ISSUE" --field Status)" = "In Progress" ] \
  || fail "the refused finish still closed the tracker item"

# --- D2: that refusal is RECOVERABLE — the SAME command line still works --------------------------
# The refusal landed after the artifacts had already been copied to their durable paths, and the
# tail's whole recovery contract is "nothing has shipped yet — fix it and re-run this finish". So the
# in-worktree originals the command line NAMES must still be there, and the identical invocation must
# now complete. Red-when-broken: make persist_build_witness_artifacts MOVE instead of copy (delete the
# source in `_copy_artifact`, drop the restore loop in `worktree_remove`) → this run dies with
# "finish: verdict failed: verdict receipt …/.claude/worktrees/… does not exist", i.e. a finish that
# refused once can never be retried.
[ -f "$D_VERDICT_SRC" ] \
  || fail "the refused finish consumed the very verdict its command line names — the operator cannot re-run it"
[ -f "$D_RECEIPT_SRC" ] \
  || fail "the refused finish consumed the very build receipt its command line names — the operator cannot re-run it"
rm -f "$D_WT/stray-note.txt"
out="$(bash "$WORK/run-finish-d.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  || fail "the finish is not re-runnable after a refusal that had already relocated the build artifacts — the operator is left with a finish that can never complete: exit $rc: $out"
printf '%s\n' "$out" | grep -qx 'finish: ok' \
  || fail "the retried finish did not report 'finish: ok': $out"
out="$(python3 "$BR" verify --repo "$D_PRIMARY" \
        --receipt "$D_PRIMARY/docs/workflow/build-receipts/nested.json" --issue "$ISSUE" --pr 903 2>&1)" \
  || fail "the artifacts persisted by the FIRST (refused) attempt do not verify after the retry completed: $out"

# ==================================================================================================
# CASE C — no widening. A contract carried into a FOREIGN repository is still refused: the witness
# lives in THIS repo's shared git common dir, so the foreign checkout has nothing vouching for it.
# ==================================================================================================
FOREIGN="$WORK/foreign"
setup_primary "$FOREIGN"
mkdir -p "$FOREIGN/docs/workflow/build-validation"
cp "$DUR_CONTRACT" "$FOREIGN/docs/workflow/build-validation/nested.json"

assert_fail_closed \
  "a frozen contract carried into a foreign repository is refused" \
  "no source-owned validation witness is recorded" \
  -- python3 "$VC" check-surface --contract "$FOREIGN/docs/workflow/build-validation/nested.json" \
  -- python3 "$VC" check-surface --contract "$DUR_CONTRACT"

[ "$FC_CONTROL_RC" -eq 0 ] \
  || fail "the positive control must be the SUCCEEDING path (the legitimately witnessed durable contract), but it exited $FC_CONTROL_RC: $FC_CONTROL_OUT"

echo "PASS: the build witness chain freezes, runs and finishes inside a linked build worktree; the REAL finish tail persists its artifacts onto durable logical repo paths that still pass the post-merge closeout re-verification; the worktree removal stays non-force; and a foreign-repo contract is still refused"
