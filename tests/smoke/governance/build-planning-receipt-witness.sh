#!/bin/bash
# idc-assert-class: behavior
# build-planning-receipt-witness.sh — F7 (re-opened) + F19: a frozen Build contract borrows a
# planning receipt's graph/projection bindings ONLY when the receipt carries a machine-owned
# out-of-tree witness in the git common dir.
#
#   * F7: the receipt's own written_by + receipt_digest are IN-BAND and forgeable — a repo-local
#     actor can swap a borrowed binding AND recompute the self-digest, passing self-integrity. The
#     witness (recorded by the sanctioned transaction outside the committed working tree, keyed to the
#     receipt file's byte digest) refuses such a re-signed forgery. The sibling borrow test only
#     covers the stale-digest (lazy-edit) case; THIS test covers the re-signed forge the reopen named.
#   * F19: the witness lives in the git COMMON dir, shared across linked worktrees, so a receipt
#     written by Plan in a linked worktree is recognized by a Build contract frozen against that
#     worktree — the earlier realpath(receipt["repo"]) compare rejected it as "a different repository"
#     because freeze normalizes to the primary checkout root while the receipt records the worktree.
#
# Red-when-broken:
#   (A) with the freeze trusting only the receipt's self-digest, the re-signed forge is borrowed and
#       the assertion fires.
#   (B) with the freeze comparing realpath(receipt["repo"]) to the primary checkout root, the
#       worktree-produced receipt is refused and the borrow assertion fires.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
VC="$PLUGIN/scripts/idc_validation_contract.py"
PR="$PLUGIN/scripts/idc_planning_receipt.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper"
[ -f "$VC" ]  || fail "missing build validation-contract helper"
[ -f "$PR" ]  || fail "missing planning-receipt helper"

# receipt_of <repo> <frozen.json> -> absolute path of the receipt the apply wrote
receipt_of() {
  python3 - "$1" "$2" <<'PY'
import json, os, sys
repo, frozen = sys.argv[1:]
bundle = json.load(open(frozen, encoding='utf-8'))
print(os.path.join(repo, bundle['receipt_relpath']))
PY
}

# plan_in <repo> <tracker> <label> <freeze.json> — init tracker, freeze+apply one planning txn there.
plan_in() {
  local repo="$1" trk="$2" label="$3" out="$4"
  python3 "$GOV_TRK" --tracker "$trk" init >/dev/null || fail "could not init tracker in $repo"
  cat > "$WORK/$label.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/]
    blocks_on: []
YAML
  python3 "$TXN" freeze --repo "$repo" --backend filesystem --tracker "$trk" \
    --matrix "$WORK/$label.yaml" --baseline expected-red --label "$label" \
    --out "$out" >/dev/null || fail "could not freeze a valid planning transaction in $repo"
  python3 "$TXN" apply --repo "$repo" --backend filesystem --tracker "$trk" \
    --frozen "$out" >/dev/null || fail "could not apply the frozen planning transaction in $repo"
}

# --- (A) F7: a RE-SIGNED forge (self-digest recomputed) is refused by the witness ----------------
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
mkdir -p "$REPO/src"; printf 'x\n' > "$REPO/src/f.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

plan_in "$REPO" "$REPO/TRACKER.md" forge "$WORK/freeze-a.json"
RECEIPT="$(receipt_of "$REPO" "$WORK/freeze-a.json")"
[ -f "$RECEIPT" ] || fail "planning apply wrote no receipt at $RECEIPT"

# Sanity: the pristine receipt IS borrowable (its witness matches).
python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --planning-receipt "$RECEIPT" --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture --baseline expected-green --label ok \
  --out "$REPO/docs/workflow/build-validation/ok.json" >/dev/null \
  || fail "a pristine machine-witnessed receipt could not be borrowed"

# Forge: swap graph_digest AND recompute the self receipt_digest via the module's own helper, so
# self-integrity (written_by + receipt_digest + internal digests) PASSES. Only the out-of-tree
# witness can catch this — the file bytes no longer match what the machine wrote.
python3 - "$PR" "$RECEIPT" <<'PY'
import importlib.util, json, sys
pr_path, receipt_path = sys.argv[1:]
spec = importlib.util.spec_from_file_location("idc_planning_receipt", pr_path)
PR = importlib.util.module_from_spec(spec); spec.loader.exec_module(PR)
receipt = json.load(open(receipt_path, encoding='utf-8'))
receipt['graph_digest'] = 'd' * 64                    # forged borrowed binding
receipt['receipt_digest'] = PR._recompute_receipt_digest(receipt)   # RE-SIGN so self-integrity holds
# prove the forge is self-consistent before we hand it to the freeze
PR.verify_receipt_integrity(receipt)                  # raises if not self-consistent
with open(receipt_path, 'w', encoding='utf-8') as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True); fh.write('\n')
print("ok: re-signed forge passes self-integrity (only the witness can refuse it)")
PY

out="$(python3 "$VC" freeze --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --planning-receipt "$RECEIPT" --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture --baseline expected-green --label forge2 \
  --out "$REPO/docs/workflow/build-validation/forged.json" 2>&1)" \
  && fail "a RE-SIGNED forged receipt injected a forged graph binding into a frozen Build contract"
printf '%s\n' "$out" | grep -qiE 'anchor|witness|stale|machine' \
  || fail "re-signed-forge refusal must name the missing/stale machine anchor; got: $out"

# --- (B1) F19: a receipt written by Plan in a LINKED (nested) WORKTREE is borrowable --------------
# Real IDC worktrees are nested at .claude/worktrees/<name>. Plan runs IN THE WORKTREE, so the receipt
# records the worktree path while freeze normalizes the repo to the primary checkout root — the exact
# asymmetry the old realpath(receipt["repo"]) compare rejected as "a different repository".
WT="$REPO/.claude/worktrees/plan"
git -C "$REPO" worktree add -q "$WT" -b plan-wt
[ -d "$WT/src" ] || fail "worktree checkout is missing the src surface"

plan_in "$WT" "$WT/TRACKER.md" wtplan "$WORK/freeze-b.json"
WT_RECEIPT="$(receipt_of "$WT" "$WORK/freeze-b.json")"
[ -f "$WT_RECEIPT" ] || fail "worktree planning apply wrote no receipt at $WT_RECEIPT"
WT_GRAPH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["graph_digest"])' "$WT_RECEIPT")"

WT_CONTRACT="$WT/docs/workflow/build-validation/wt.json"
mkdir -p "$(dirname "$WT_CONTRACT")"
python3 "$VC" freeze --repo "$WT" --issue 2 --pr 402 --graph-node alpha \
  --planning-receipt "$WT_RECEIPT" --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture --baseline expected-green --label wt \
  --out "$WT_CONTRACT" >/dev/null \
  || fail "a legitimate planning receipt produced in a linked worktree was refused (F19)"
got="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8"))["graph_digest"])' "$WT_CONTRACT")"
[ "$got" = "$WT_GRAPH" ] \
  || fail "worktree contract did not borrow the receipt's graph_digest; got $got want $WT_GRAPH"

# --- (B2) F19: a receipt written in ONE checkout is borrowable from ANOTHER worktree of the repo ---
# The real Plan->Build handoff: Plan writes+commits the receipt in checkout X; a Build worker in a
# different worktree Y checks it out and borrows it. The witness (keyed by the worktree-relative
# logical path + the file's byte digest, stored in the shared common dir) must survive the git
# checkout into Y. Red-when-broken for a primary-root-relative witness key: X's and Y's keys differ.
CROSS="$WORK/cross"
git init -q -b main "$CROSS"
git -C "$CROSS" config user.email t@t
git -C "$CROSS" config user.name t
mkdir -p "$CROSS/src"; printf 'y\n' > "$CROSS/src/f.txt"
git -C "$CROSS" add -A && git -C "$CROSS" commit -qm init
plan_in "$CROSS" "$CROSS/TRACKER.md" crossplan "$WORK/freeze-c.json"
CROSS_RECEIPT_REL="$(python3 - "$WORK/freeze-c.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding='utf-8'))['receipt_relpath'])
PY
)"
git -C "$CROSS" add -A && git -C "$CROSS" commit -qm "planning receipt"   # commit so it travels
BUILD_WT="$CROSS/.claude/worktrees/build"
git -C "$CROSS" worktree add -q "$BUILD_WT" -b build-y                    # checks out the receipt
BUILD_RECEIPT="$BUILD_WT/$CROSS_RECEIPT_REL"
[ -f "$BUILD_RECEIPT" ] || fail "committed receipt did not travel into the build worktree"
python3 "$VC" freeze --repo "$BUILD_WT" --issue 3 --pr 403 --graph-node alpha \
  --planning-receipt "$BUILD_RECEIPT" --touch src/ --off-limits docs/ --verify 'true' \
  --surface cli --evidence-kind pane-capture --baseline expected-green --label cross \
  --out "$BUILD_WT/docs/workflow/build-validation/cross.json" >/dev/null \
  || fail "a receipt written in one checkout could not be borrowed from another worktree (F19 cross-worktree)"

git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
git -C "$CROSS" worktree remove --force "$BUILD_WT" 2>/dev/null || true

echo "PASS: a frozen Build contract borrows a planning receipt only when a machine-owned git-dir witness vouches for it — a re-signed forge is refused (F7), and a worktree-produced receipt is accepted both same-worktree and across a Plan->Build worktree handoff (F19)"
