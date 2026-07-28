#!/bin/bash
# idc-assert-class: behavior
# janitor-stagnation-oscillation.sh — an oscillating blocker set cannot recycle the pass counter.
#
# Spec §8: "a resurfaced seen finding cannot recycle the Janitor pass counter". The bootstrap
# convergence controller must therefore measure progress on NEW debris (plan.new_blocker_count,
# derived from the durable all-seen ledger), never on the raw blocker SET. Comparing the raw set lets
# a blocker that disappears and resurfaces look like progress and reset the stagnation counter, so an
# oscillating set burns every available pass.
#
# The fixture: both blockers are ALREADY in the durable seen ledger before the run, and the injected
# set oscillates {alpha} -> {alpha,beta} -> {alpha}. No pass discovers anything the ledger has not
# already recorded, so the run must halt on the stagnation rule at pass 2 of an allowed 3.
#
# Red-when-broken (observed): restore the set comparison
#   `stagnant = (stagnant + 1) if blockers == previous_blockers else 1` with the halt at
#   `stagnant >= max_passes` => the oscillation resets the counter every pass, the rule never fires,
#   the run burns all three passes and reports plan.passes == 3 => FAIL.
#
# CAUTION for whoever re-runs that neuter: the guard being removed is a BOUND. A bound removed can
# HANG rather than redden, and a hang reads like a slow pass — every probe here runs under an
# explicit `timeout 300` and a timeout MUST be treated as RED, not as a slow machine.
#
# Usage: bash tests/smoke/governance/janitor-stagnation-oscillation.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$JAN" ] || gov_fail "scripts/idc_git_janitor.py not found"
[ -f "$TRK" ] || gov_fail "scripts/idc_tracker_fs.py not found"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow" || gov_fail "could not create repo dirs"
git init -q -b main "$REPO" || gov_fail "git init failed"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "tracker init failed"
: > "$REPO/docs/workflow/transition-journal.ndjson"
printf base > "$REPO/app.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
cat > "$REPO/docs/workflow/reconciliation-baseline-required.json" <<'JSON'
{
  "schema_version": 1,
  "state": "baseline-pending",
  "reason": "reconciliation-baseline-required"
}
JSON

# Pre-seed the DURABLE all-seen ledger through its own fixed writer, so both blockers are resurfaced
# facts on the very first pass. The fingerprint shape is the janitor's own
# `<classification>:<root_id>` (idc_git_janitor._seen_fingerprint) for a test-stubborn finding.
python3 - "$GOV_PLUGIN" "$REPO" <<'PY' || gov_fail "could not pre-seed the durable all-seen ledger"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
import idc_reconciliation_baseline as RB
RB.record_seen_findings(sys.argv[2], [
    {"fingerprint": "test-stubborn:stagnation-alpha", "disposition": "blocker"},
    {"fingerprint": "test-stubborn:stagnation-beta", "disposition": "blocker"},
])
PY

set +e
OUT="$(IDC_JANITOR_TEST_STUBBORN_FINDING='stagnation-alpha;stagnation-alpha,stagnation-beta;stagnation-alpha' \
  timeout 300 python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --bootstrap --max-passes 3 --json)"; RC=$?
set -e
[ "$RC" -ne 124 ] || gov_fail "the janitor bootstrap loop did not terminate within 300s — a removed bound HANGS instead of reddening; treat this as RED"
[ "$RC" -eq 1 ] \
  || gov_fail "a non-converging janitor bootstrap run must exit 1 with blockers remaining, got $RC — [$OUT]"
REPORT_JSON="$OUT" python3 - <<'PY' || gov_fail "an oscillating, already-seen blocker set recycled the janitor pass counter instead of halting on the stagnation rule"
import json, os
report = json.loads(os.environ["REPORT_JSON"])
plan = report.get("plan", {})
assert plan.get("halted") is True, plan
# The blocker set never resolves, but nothing it holds is NEW, so the run must stop at the
# stagnation limit (2 consecutive passes without a previously-unseen blocker) — not burn all three.
assert plan.get("passes") == 2, plan
assert plan.get("blockers") == ["stagnation-alpha", "stagnation-beta"], plan
assert plan.get("new_blockers") == [], plan
assert plan.get("new_blocker_count") == 0, plan
assert plan.get("checkpoint_advanced") is False, plan
PY

echo "PASS: an oscillating set of already-seen blockers halts the janitor on the stagnation rule at pass 2 instead of recycling the pass counter"
