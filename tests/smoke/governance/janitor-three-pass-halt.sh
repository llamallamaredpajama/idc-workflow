#!/bin/bash
# idc-assert-class: behavior
# janitor-three-pass-halt.sh — U7 bounded convergence.
#
# A non-converging Janitor run must stop after exactly three passes, name the blockers, and refuse to
# advance the durable checkpoint past unresolved facts.
#
# The stubborn finding is injected through a deterministic test hook owned by the Janitor script itself;
# that makes the run reproducible without mutating a live tracker or depending on timing.
#
# Usage: bash tests/smoke/governance/janitor-three-pass-halt.sh
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
mkdir -p "$REPO/docs/workflow" && : > "$REPO/docs/workflow/transition-journal.ndjson"
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

OUT="$(IDC_JANITOR_TEST_STUBBORN_FINDING='named-stubborn-blocker' \
  python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --bootstrap --max-passes 3 --json)"; RC=$?
[ "$RC" -eq 1 ] \
  || gov_fail "a three-pass non-converging janitor run must exit 1 with blockers remaining, got $RC — [$OUT]"
REPORT_JSON="$OUT" python3 - "$REPO/docs/workflow/reconciliation-checkpoint.json" <<'PY' || gov_fail "janitor did not halt after three passes with exact blockers and a held checkpoint"
import json, os, sys
checkpoint_path = sys.argv[1]
report = json.loads(os.environ["REPORT_JSON"])
plan = report.get("plan", {})
assert plan.get("halted") is True, plan
assert plan.get("passes") == 3, plan
assert plan.get("blockers") == ["named-stubborn-blocker"], plan
assert plan.get("checkpoint_advanced") is False, plan
if os.path.exists(checkpoint_path):
    checkpoint = json.load(open(checkpoint_path))
    assert "named-stubborn-blocker" not in set(checkpoint.get("resolved_root_ids") or []), checkpoint
PY

echo "PASS: Janitor halts after three non-converging passes and names the exact blocker without advancing the checkpoint"
