#!/bin/bash
# idc-assert-class: behavior
# adoption-baseline-pending.sh — U7 adoption baseline + baseline-pending gate.
#
# Proves three things on a hermetic filesystem-backend repo:
#   1. a durable `reconciliation-baseline-required` marker blocks ordinary mutators at command entry
#      while leaving doctor/update/janitor available;
#   2. autorun's drain predicate refuses a false clean `complete` while the repo is baseline-pending;
#   3. once a legacy adoption receipt exists, pre-boundary legacy items are tolerated but a
#      post-boundary raw tracker mutation is detected as unreceipted.
#
# Red-when-broken (reviewed): make the entry gate ignore the baseline marker => the ordinary-mutator
# block assertion flips; make the drain ignore baseline state => the `drain: baseline-pending` check
# flips; skip the post-boundary tracker check => the final janitor assertion flips.
#
# Usage: bash tests/smoke/governance/adoption-baseline-pending.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ENTRY_GATE="$GOV_PLUGIN/scripts/hooks/idc_command_entry_gate.py"
DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
[ -f "$ENTRY_GATE" ] || gov_fail "scripts/hooks/idc_command_entry_gate.py not found"
[ -f "$DRAIN" ] || gov_fail "scripts/idc_autorun_drain.py not found"
[ -f "$JAN" ] || gov_fail "scripts/idc_git_janitor.py not found"
[ -f "$TRK" ] || gov_fail "scripts/idc_tracker_fs.py not found"

PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$GOV_PLUGIN/.claude-plugin/plugin.json")" \
  || gov_fail "could not read plugin version"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow" || gov_fail "could not create repo dirs"
git init -q -b main "$REPO" || gov_fail "git init failed"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'receipt_version: 2\nplugin_version: %s\nfingerprint_method: sha256\nwritten_by: test\nfiles: []\n' "$PLUGIN_VERSION" \
  > "$REPO/docs/workflow/install-receipt.yaml"
python3 "$TRK" --tracker "$REPO/TRACKER.md" init >/dev/null || gov_fail "tracker init failed"
mkdir -p "$REPO/docs/workflow" && : > "$REPO/docs/workflow/transition-journal.ndjson"

MARKER="$REPO/docs/workflow/reconciliation-baseline-required.json"
ADOPTION="$REPO/docs/workflow/reconciliation-adoption.json"

emit_expansion() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
print(json.dumps({
    "session_id": sys.argv[4],
    "cwd": sys.argv[3],
    "hook_event_name": "UserPromptExpansion",
    "expansion_type": "command",
    "command_name": sys.argv[1],
    "command_args": sys.argv[2],
    "command_source": "plugin",
    "prompt": "/" + sys.argv[1] + (" " + sys.argv[2] if sys.argv[2] else ""),
}))
PY
}

write_marker() {
  cat > "$MARKER" <<'JSON'
{
  "schema_version": 1,
  "state": "baseline-pending",
  "reason": "reconciliation-baseline-required"
}
JSON
}

write_marker

# 1. baseline-pending blocks ordinary mutators but still allows doctor/update/janitor.
OUT="$(emit_expansion idc:think 'Drive first' "$REPO" S-baseline | python3 "$ENTRY_GATE" "$GOV_PLUGIN")"
printf '%s' "$OUT" | grep -q '"decision": "block"' \
  || gov_fail "ordinary mutator /idc:think was not blocked on a baseline-pending repo"
printf '%s' "$OUT" | grep -qi 'baseline-pending' \
  || gov_fail "baseline-pending refusal did not name the baseline-pending state"
printf '%s' "$OUT" | grep -q '/idc:janitor' \
  || gov_fail "baseline-pending refusal did not direct the operator to /idc:janitor"
printf '%s' "$OUT" | grep -q '/idc:update' \
  || gov_fail "baseline-pending refusal did not direct the operator to /idc:update"
for CMD in idc:doctor idc:update idc:janitor; do
  OUT="$(emit_expansion "$CMD" '' "$REPO" S-baseline | python3 "$ENTRY_GATE" "$GOV_PLUGIN")"
  printf '%s' "$OUT" | grep -q 'additionalContext' \
    || gov_fail "$CMD was not allowed while the repo is baseline-pending"
done

# 2. baseline-pending also blocks a false drain:complete.
DOUT="$(cd "$REPO" && python3 "$DRAIN" --tracker "$REPO/TRACKER.md" 2>/dev/null)"; DRC=$?
[ "$DRC" -eq 4 ] \
  || gov_fail "baseline-pending drain must exit 4 (non-terminal), got $DRC — [$DOUT]"
printf '%s\n' "$DOUT" | grep -qx 'drain: baseline-pending' \
  || gov_fail "baseline-pending repo must surface drain: baseline-pending, got: [$DOUT]"

# 3. Pre-boundary legacy items are tolerated, but a post-boundary raw tracker mutation is detected.
legacy="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'legacy buildable' --stage Buildable)" \
  || gov_fail "legacy item create failed"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)" || gov_fail "could not read repo head"
cat > "$ADOPTION" <<JSON
{
  "schema_version": 1,
  "state": "legacy-adopted",
  "default_branch": {"name": "main", "head": "$HEAD_SHA"},
  "journal_entry_count": 0,
  "legacy_items": [
    {"number": $legacy, "stage": "Buildable", "status": "Todo", "evidence_class": "legacy-adopted", "historical_verification": "not-claimed"}
  ],
  "routed_obligations": [],
  "unresolved": []
}
JSON
rm -f "$MARKER"
raw="$(python3 "$TRK" --tracker "$REPO/TRACKER.md" create --title 'raw post-boundary item' --stage Buildable)" \
  || gov_fail "post-boundary raw create failed"
JOUT="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)" \
  || gov_fail "janitor json scan exited non-zero"
REPORT_JSON="$JOUT" python3 - "$raw" "$legacy" <<'PY' || gov_fail "post-boundary unreceipted tracker mutation was not detected correctly"
import json, os, sys
raw = int(sys.argv[1]); legacy = int(sys.argv[2])
report = json.loads(os.environ["REPORT_JSON"])
assert report.get("baseline", {}).get("state") == "legacy-adopted", report
findings = report.get("findings", [])
raw_hits = [f for f in findings if f.get("classification") == "post-boundary-unreceipted-tracker" and f.get("number") == raw]
assert raw_hits, findings
legacy_hits = [f for f in findings if f.get("number") == legacy and f.get("classification") == "post-boundary-unreceipted-tracker"]
assert not legacy_hits, findings
PY

echo "PASS: baseline-pending blocks mutators, drain stays non-terminal, and post-boundary raw tracker drift is detected"
