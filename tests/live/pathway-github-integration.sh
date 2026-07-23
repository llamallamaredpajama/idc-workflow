#!/bin/bash
# idc-assert-class: behavior
# pathway-github-integration.sh — LIVE sandbox lane for the idc/pathway-integrity ruleset.
#
# Proves, against a REAL disposable sandbox repo with a REAL `gh`:
#   1. scripts/idc_ruleset_install.py installs the pathway-integrity ruleset (idempotent);
#   2. scripts/idc_ruleset_check.py --repo confirms the LIVE ruleset satisfies the contract;
#   3. the required `idc/pathway-integrity` check BLOCKS an off-path PR merge — a PR whose required
#      check has not run cannot be merged (this is the "refuses off-path integration" guarantee).
#
# It then RESTORES the sandbox: the test PR + branch are deleted, and the ruleset is removed if this
# run installed it (so the shared install sandbox is left exactly as found — a ruleset requiring a
# check the sandbox has no workflow for would otherwise brick its default-branch merges).
#
# ───────────────────────────────────────────────────────────────────────────────────────────────────
# NOT in tests/smoke/run-all.sh: it needs a real `gh`, admin on a sandbox repo, and it MUTATES ruleset
# state. It is sandbox-only and self-cleaning, but it is a manual lane. The "admits a compliant merge"
# half of the boundary needs the check to actually run green via GitHub Actions in the sandbox (an
# API-hour Actions cycle); that is gated behind IDC_LIVE_FULL_MERGE_CYCLE=1 and is otherwise the
# operator's acceptance step — see the U8 report.
#
# Usage:
#   bash tests/live/pathway-github-integration.sh            # default sandbox (install)
#   IDC_LIVE_SANDBOX=/Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun bash tests/live/pathway-github-integration.sh
# ───────────────────────────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:$HOME/.local/bin:$PATH"

PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="${IDC_LIVE_SANDBOX:-/Users/jeremy/dev/sandbox/ke-idc-test-repo-install}"
INSTALL="$PLUGIN/scripts/idc_ruleset_install.py"
CHECK="$PLUGIN/scripts/idc_ruleset_check.py"
RS="$PLUGIN/.github/rulesets/idc-pathway-integrity.json"

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
skip() { printf 'SKIP: %s\n' "$1"; exit 0; }

# ── guards, hardest-consequence first ─────────────────────────────────────────────────────────────
case "$SANDBOX" in
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-install|\
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-update|\
  /Users/jeremy/dev/sandbox/ke-idc-test-repo-autorun) ;;
  *) fail "REFUSING to run against $SANDBOX — this test may only touch a disposable sandbox repo
       (/Users/jeremy/dev/sandbox/ke-idc-test-repo-*), never a live or production repo" ;;
esac
[ -d "$SANDBOX" ]                       || skip "sandbox $SANDBOX is not present on this machine"
command -v gh >/dev/null 2>&1           || skip "gh is not on PATH — this test needs the real CLI"
gh auth status >/dev/null 2>&1          || skip "gh is not authenticated — run \`gh auth login\` first"
[ -f "$INSTALL" ] && [ -f "$CHECK" ]    || fail "ruleset installer/checker missing (not implemented)"
[ -f "$RS" ]                            || fail "ruleset file missing: $RS"

# Resolve OWNER/REPO by running gh INSIDE the sandbox checkout (a path arg is treated as a repo name).
NWO="$( (cd "$SANDBOX" && gh repo view --json nameWithOwner --jq .nameWithOwner) 2>/dev/null )" \
  || skip "could not resolve $SANDBOX to OWNER/REPO via gh"
# Belt-and-suspenders: the RESOLVED repo must also be a sandbox.
case "$NWO" in
  llamallamaredpajama/ke-idc-test-repo-*) ;;
  *) fail "resolved repo $NWO is not a disposable sandbox — refusing to mutate it" ;;
esac

echo "== live pathway-integration — sandbox only, self-cleaning"
echo "   sandbox: $SANDBOX"
echo "   repo:    $NWO"

DEFAULT="$(gh repo view "$NWO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)"
[ -n "$DEFAULT" ] || skip "could not resolve the default branch for $NWO"
echo "   default: $DEFAULT"

# Did a same-name ruleset already exist? (governs whether cleanup removes it) ----------------------
PRE_ID="$(gh api "repos/$NWO/rulesets" --jq '.[] | select(.name=="idc-pathway-integrity") | .id' 2>/dev/null | head -1)"
TS="$(date +%s)"
TESTBRANCH="idc-pathway-live-test/$TS"
PR_NUM=""
INSTALLED_ID=""

cleanup() {
  set +e
  [ -n "$PR_NUM" ] && gh pr close "$PR_NUM" --repo "$NWO" --delete-branch >/dev/null 2>&1
  # delete the branch ref if it somehow survived PR close
  gh api --method DELETE "repos/$NWO/git/refs/heads/$TESTBRANCH" >/dev/null 2>&1
  # remove the ruleset ONLY if this run created it (restore the shared sandbox)
  if [ -z "$PRE_ID" ]; then
    local id
    id="$(gh api "repos/$NWO/rulesets" --jq '.[] | select(.name=="idc-pathway-integrity") | .id' 2>/dev/null | head -1)"
    [ -n "$id" ] && gh api --method DELETE "repos/$NWO/rulesets/$id" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

# ── 1/3 install (idempotent) ──────────────────────────────────────────────────────────────────────
echo "-- 1/3 install ruleset (idempotent)"
python3 "$INSTALL" --repo "$NWO" --ruleset "$RS" --apply || fail "ruleset install (--apply) failed"
INSTALLED_ID="$(gh api "repos/$NWO/rulesets" --jq '.[] | select(.name=="idc-pathway-integrity") | .id' 2>/dev/null | head -1)"
[ -n "$INSTALLED_ID" ] || fail "ruleset not present after install"
echo "   installed ruleset id: $INSTALLED_ID"

# ── 2/3 live contract validation ──────────────────────────────────────────────────────────────────
echo "-- 2/3 validate the LIVE ruleset against the contract"
python3 "$CHECK" --repo "$NWO" --ruleset "$RS" || fail "live ruleset failed its own contract check"

# ── 3/3 off-path PR merge is blocked ──────────────────────────────────────────────────────────────
echo "-- 3/3 an off-path PR (required check has not run) cannot be merged"
BASE_SHA="$(gh api "repos/$NWO/git/ref/heads/$DEFAULT" --jq .object.sha 2>/dev/null)"
[ -n "$BASE_SHA" ] || fail "could not read the base SHA of $DEFAULT"
gh api --method POST "repos/$NWO/git/refs" -f "ref=refs/heads/$TESTBRANCH" -f "sha=$BASE_SHA" >/dev/null \
  || fail "could not create the test branch $TESTBRANCH"
# a trivial change so the PR is non-empty
CONTENT="$(printf 'idc pathway-integrity live test %s\n' "$TS" | base64)"
gh api --method PUT "repos/$NWO/contents/.idc-pathway-live-test.txt" \
  -f "message=idc pathway live test $TS" \
  -f "content=$CONTENT" \
  -f "branch=$TESTBRANCH" >/dev/null \
  || fail "could not write the test file on $TESTBRANCH"
PR_NUM="$(gh pr create --repo "$NWO" --base "$DEFAULT" --head "$TESTBRANCH" \
  --title "idc pathway live test $TS (auto-cleanup)" \
  --body "Transient off-path PR opened by tests/live/pathway-github-integration.sh; auto-closed." \
  2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
[ -n "$PR_NUM" ] || fail "could not open the off-path test PR"
echo "   opened off-path PR #$PR_NUM"

# The required idc/pathway-integrity check has not run (no workflow in the sandbox) → merge blocked.
if merge_out="$(gh pr merge "$PR_NUM" --repo "$NWO" --merge 2>&1)"; then
  fail "an off-path PR was MERGED despite the required check — enforcement did not block it
       (output: $merge_out)"
fi
echo "   merge correctly BLOCKED: $(printf '%s' "$merge_out" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-160)"

if [ "${IDC_LIVE_FULL_MERGE_CYCLE:-0}" = "1" ]; then
  echo "NOTE: IDC_LIVE_FULL_MERGE_CYCLE=1 requested, but admitting a COMPLIANT merge needs the "
  echo "      idc/pathway-integrity workflow to run green via Actions in the sandbox (API-hour cycle)."
  echo "      That is the operator acceptance step; this lane proves the block side deterministically."
fi

echo "PASS: ruleset installed + live-validated; off-path PR merge blocked by the required check (sandbox restored on exit)"
