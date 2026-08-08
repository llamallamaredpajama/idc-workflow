#!/bin/bash
# build-witness-linked-worktree.sh — issue #197: the build witness chain must work in the LINKED
# WORKTREE a durable worker actually runs in, and must survive that worktree's deletion.
#
# Build ALWAYS runs in a linked worktree by design (agents/idc-build.md: one pre-created worktree per
# durable worker; skills/idc-adapter-claude/SKILL.md creates them under `.claude/worktrees/<name>`;
# agents/idc-implementer.md freezes with `--repo "$PWD"`). The witness key, however, was derived from
# `git rev-parse --git-common-dir`, which in a linked worktree resolves to the PRIMARY checkout — so
# the artifact's path was measured against a root it does not live under. Two symptoms, one cause:
#
#   (A) a worktree OUTSIDE the primary checkout → freeze exits 2, "must live under the governed repo
#       root <primary>", and no witness is ever recorded (the whole gate dies);
#   (B) a worktree INSIDE it (`.claude/worktrees/<name>`) → freeze succeeds but keys the witness as
#       `.claude/worktrees/<name>/docs/workflow/...`. That key dies with the worktree: once the branch
#       merges and the worktree is removed, the durable artifact at `docs/workflow/...` has no
#       witness. This is the "manual bridging from the (deleted) build worktree to the durable receipt
#       path" the 2026-08-02 triage e2e recorded.
#
# What this fixture pins: the witness key is the artifact's path relative to ITS OWN worktree root
# (the stable logical repo path, identical in every worktree and after every merge), while the
# recorded repo IDENTITY stays the primary checkout root — so nothing is widened: a receipt from a
# foreign repo is still refused (case C), because the store still lives in this repo's shared git
# common dir and still binds this repo's identity.
#
# RED-WHEN-BROKEN, OBSERVED. Each of the three fix points reds this fixture on its own:
#   1. idc_validation_contract.py::_repo_context — replace `worktree_root = _worktree_toplevel(parent)`
#      with `os.path.realpath(os.path.dirname(common_git_dir))`: case A reds at freeze,
#      "…/build-wt-sibling/docs/workflow/build-validation/sibling.json must live under its worktree
#      root …/primary-a".
#   2. idc_build_receipt.py::_artifact_root — replace `root = VC._worktree_toplevel(anchor)` with
#      `VC._repo_identity(repo)`: case A reds at the implementation-receipt write, "must live under
#      the governed repo root".
#   3. idc_review_verdict_check.py::_code_reviews_context — return `top` (this worktree's toplevel)
#      instead of the primary checkout identity: case B reds after teardown, "the validator witness
#      for docs/workflow/code-reviews/… names repo '…/.claude/worktrees/w1', not this repo".
# On the pre-fix code case B reds with "no source-owned validation witness is recorded for
# docs/workflow/build-validation/nested.json" — verbatim the 2026-08-02 e2e's complaint.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
. "$(dirname "$0")/../lib/fail-closed.sh"

fc_require_file "$VC" "the build validation-contract helper (scripts/idc_validation_contract.py)"
fc_require_file "$BR" "the implementation-receipt helper (scripts/idc_build_receipt.py)"
fc_require_file "$CHECK" "the review-verdict validator (scripts/idc_review_verdict_check.py)"

GD='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PD='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

# --- a governed primary checkout, ready for a build worktree -------------------------------------
setup_primary() {
  local repo="$1"
  git init -q -b main "$repo" || fail "could not init the primary checkout"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
  mkdir -p "$repo/src/allowed" "$repo/src/blocked"
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
}

freeze_in() {                       # freeze_in <worktree> <pr> <label> <out>
  python3 "$VC" freeze \
    --surface cli \
    --repo "$1" \
    --issue 197 \
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
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
exec_path, verdict_path, pr = sys.argv[1:4]
receipt = json.load(open(exec_path, encoding='utf-8'))
doc = {
    'verdict': 'PASS',
    'pr': int(pr),
    'issue': 197,
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
# CASE A — a build worktree OUTSIDE the primary checkout: the whole freeze → run → finish chain.
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
# CASE B — a build worktree INSIDE the primary checkout (`.claude/worktrees/<name>`, the shape
# skills/idc-adapter-claude/SKILL.md creates): the witness must survive the merge + teardown and
# still vouch for the artifact at its DURABLE path in the primary checkout.
# ==================================================================================================
PRIMARY_B="$WORK/primary-b"
setup_primary "$PRIMARY_B"
NEST="$PRIMARY_B/.claude/worktrees/w1"
git -C "$PRIMARY_B" worktree add -q -b build/nested "$NEST" \
  || fail "could not create the nested build worktree"

CONTRACT_B="$NEST/docs/workflow/build-validation/nested.json"
EXEC_B="$NEST/docs/workflow/build-validation-executions/nested.json"
VERDICT_B="$NEST/docs/workflow/code-reviews/2026-08-08-pr-901-nested.json"
RECEIPT_B="$NEST/docs/workflow/build-receipts/nested.json"
mkdir -p "$(dirname "$VERDICT_B")" "$(dirname "$RECEIPT_B")"

out="$(freeze_in "$NEST" 901 nested "$CONTRACT_B" 2>&1)" \
  || fail "freeze failed in a nested build worktree: $out"
printf 'new behavior\n' > "$NEST/src/allowed/feature.txt"
git -C "$NEST" add src/allowed/feature.txt
git -C "$NEST" commit -qm 'implement the allowed surface'
out="$(python3 "$VC" run --repo "$NEST" --contract "$CONTRACT_B" --out "$EXEC_B" 2>&1)" \
  || fail "run failed in a nested build worktree: $out"
make_verdict "$EXEC_B" "$VERDICT_B" 901
out="$(python3 "$BR" write --repo "$NEST" --contract "$CONTRACT_B" --execution "$EXEC_B" \
        --verdict "$VERDICT_B" --graph-digest "$GD" --projection-digest "$PD" \
        --out "$RECEIPT_B" 2>&1)" \
  || fail "the implementation receipt could not be written in a nested build worktree: $out"

# The real lifecycle: the branch merges and the ephemeral build worktree is torn down.
git -C "$NEST" add docs
git -C "$NEST" commit -qm 'record the build artifacts'
git -C "$PRIMARY_B" merge -q --no-edit build/nested \
  || fail "could not merge the build branch into the primary checkout"
git -C "$PRIMARY_B" worktree remove --force "$NEST" \
  || fail "could not tear down the build worktree"
[ ! -d "$NEST" ] || fail "the build worktree was not actually removed — case B would prove nothing"

DUR_CONTRACT="$PRIMARY_B/docs/workflow/build-validation/nested.json"
DUR_EXEC="$PRIMARY_B/docs/workflow/build-validation-executions/nested.json"
DUR_RECEIPT="$PRIMARY_B/docs/workflow/build-receipts/nested.json"
for f in "$DUR_CONTRACT" "$DUR_EXEC" "$DUR_RECEIPT"; do
  [ -f "$f" ] || fail "the merge did not land the durable artifact $f — case B would prove nothing"
done

out="$(python3 "$VC" check-surface --contract "$DUR_CONTRACT" --execution "$DUR_EXEC" 2>&1)" \
  || fail "the witness did not survive the build worktree's deletion — the durable contract/execution at docs/workflow/ is unwitnessed (#197): $out"
out="$(python3 "$BR" verify --repo "$PRIMARY_B" --receipt "$DUR_RECEIPT" 2>&1)" \
  || fail "the durable implementation receipt does not verify from the primary checkout after teardown (#197): $out"

# The keys are the LOGICAL repo paths — nothing ephemeral (a worktree subdir) is baked in.
COMMON_B="$(git -C "$PRIMARY_B" rev-parse --path-format=absolute --git-common-dir)"
python3 - "$COMMON_B/idc-build-validation-witnesses.json" "$(cd "$PRIMARY_B" && pwd -P)" <<'PY' \
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

echo "PASS: the build witness chain freezes, runs and finishes inside a linked build worktree, keys every witness by its durable logical repo path, and still refuses a foreign-repo contract"
