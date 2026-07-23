#!/bin/bash
# idc-assert-class: behavior
# pathway-github-check-local.sh — U8 exact-head GitHub pathway check contract (HERMETIC, no network).
#
# Proves the deterministic `idc/pathway-integrity` integration check (spec §2.3):
#   (1) the version-pinned workflow surfaces a check named `idc/pathway-integrity`, binds it to the
#       EXACT proposed head commit (`github.event.pull_request.head.sha`), pins the check source, and
#       runs the fixed `scripts/idc_pathway_check.py` (no LLM, no arbitrary network);
#   (2) the checker PASSES only when head + source + every protected surface all hold;
#   (3) the checker REFUSES a stale head, a wrong/stale source, and a missing protected surface.
#
# Red-when-broken: neuter the checker to always-pass and (B)/(C)/(D) fire; delete the workflow's
# head/source binding and the static asserts fire. Failing-test-first: fails until the checker +
# workflow exist (that is the intended RED, not a syntax/fixture crash).
#
# Usage: bash tests/smoke/governance/pathway-github-check-local.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$PLUGIN/scripts/idc_pathway_check.py"
WF="$PLUGIN/.github/workflows/idc-pathway-integrity.yml"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

CHECK_NAME="idc/pathway-integrity"
SOURCE="idc/pathway-integrity@v1"

# --- existence (the honest RED reason: nothing implemented yet) --------------------------------
[ -f "$CHECK" ] || fail "exact-head pathway checker not implemented yet: scripts/idc_pathway_check.py"
[ -f "$WF" ]    || fail "version-pinned pathway workflow not present yet: .github/workflows/idc-pathway-integrity.yml"

# --- static workflow contract -------------------------------------------------------------------
grep -Fq "$CHECK_NAME" "$WF" \
  || fail "workflow does not surface the required check name $CHECK_NAME"
# exact-head binding — delete this and merge-time enforcement no longer pins the proposed head:
grep -Fq 'github.event.pull_request.head.sha' "$WF" \
  || fail "workflow lost the exact PR-head binding (github.event.pull_request.head.sha)"
grep -Fq -- '--head' "$WF" \
  || fail "workflow does not pass an explicit --head binding to the checker"
# version-pinned check source — substitute a wrong source here and this fails:
grep -Fq -- '--source' "$WF" \
  || fail "workflow does not pass an explicit --source pin to the checker"
grep -Fq "$SOURCE" "$WF" \
  || fail "workflow does not pin the check source to $SOURCE"
grep -Fq 'scripts/idc_pathway_check.py' "$WF" \
  || fail "workflow does not run the fixed checker scripts/idc_pathway_check.py"

# --- hermetic behavioral contract: a real tiny git repo carrying the protected surfaces ---------
REPO="$WORK/repo"
mkdir -p "$REPO/.github/workflows" "$REPO/scripts/hooks"
cp "$WF"    "$REPO/.github/workflows/idc-pathway-integrity.yml"
cp "$CHECK" "$REPO/scripts/idc_pathway_check.py"
# the checker asserts these protected surfaces EXIST (their presence is the integrity evidence):
: > "$REPO/scripts/idc_validation_contract.py"   # validation surface
: > "$REPO/scripts/idc_receipt_check.py"          # receipt surface
: > "$REPO/scripts/hooks/idc_ledger.py"           # hook surface
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm seed
HEAD="$(git -C "$REPO" rev-parse HEAD)"

# (A) exact head + correct source + all surfaces present -> PASS
python3 "$CHECK" --repo "$REPO" --head "$HEAD" --source "$SOURCE" >/dev/null \
  || fail "checker refused a compliant repo (exact head, pinned source, all surfaces present)"

# (B) STALE head (proposed head != actual head) -> REFUSE
python3 "$CHECK" --repo "$REPO" --head "0000000000000000000000000000000000000000" --source "$SOURCE" >/dev/null 2>&1 \
  && fail "checker admitted a STALE head (proposed head != actual repo head)"

# (C) WRONG / stale source -> REFUSE
python3 "$CHECK" --repo "$REPO" --head "$HEAD" --source "idc/pathway-integrity@v0" >/dev/null 2>&1 \
  && fail "checker admitted a WRONG check source"

# (D) MISSING protected surface (receipt surface removed) -> REFUSE
rm -f "$REPO/scripts/idc_receipt_check.py"
python3 "$CHECK" --repo "$REPO" --head "$HEAD" --source "$SOURCE" >/dev/null 2>&1 \
  && fail "checker admitted a repo MISSING a protected surface (receipt surface removed)"

echo "PASS: idc/pathway-integrity binds to the exact head + pinned source, and refuses stale head / wrong source / missing protected surface"
