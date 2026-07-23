#!/bin/bash
# idc-assert-class: behavior
# intake-outside-work-routing.sh — U7 outside-work preservation, source pinning, and routing.
#
# Covers both halves of the outside-path contract:
#   * the intake manifest helper accepts a pinned outside-branch source (repo/head/base/diff);
#   * Janitor preserves outside-path git work and routes it rather than deleting or blessing it:
#       - an unmerged outside branch => route to Intake / Build adoption with source pins;
#       - already-merged outside work => route to a reconciliation audit with source pins.
#
# Red-when-broken (reviewed): keep intake sources markdown-only => the helper rejects the pinned
# manifest; keep janitor on its old report-only foreign-branch posture => the route/source-pin
# assertions flip.
#
# Usage: bash tests/smoke/governance/intake-outside-work-routing.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

INTAKE="$GOV_PLUGIN/scripts/idc_intake_manifest.py"
JAN="$GOV_PLUGIN/scripts/idc_git_janitor.py"
TRK="$GOV_PLUGIN/scripts/idc_tracker_fs.py"
CMD="$GOV_PLUGIN/commands/intake.md"
AGENT="$GOV_PLUGIN/agents/idc-intake.md"
[ -f "$INTAKE" ] || gov_fail "scripts/idc_intake_manifest.py not found"
[ -f "$JAN" ] || gov_fail "scripts/idc_git_janitor.py not found"
[ -f "$TRK" ] || gov_fail "scripts/idc_tracker_fs.py not found"
[ -f "$CMD" ] || gov_fail "commands/intake.md missing"
[ -f "$AGENT" ] || gov_fail "agents/idc-intake.md missing"

# The shipped command/agent prose must document the outside-source forms and the exact pin set.
for f in "$CMD" "$AGENT"; do
  grep -q -- '--pr' "$f" || gov_fail "$(basename "$f") must document /idc:intake --pr"
  grep -q -- '--branch' "$f" || gov_fail "$(basename "$f") must document /idc:intake --branch"
  grep -qi 'source repository' "$f" || gov_fail "$(basename "$f") must name the pinned source repository"
  grep -qi 'head commit' "$f" || gov_fail "$(basename "$f") must name the pinned head commit"
  grep -qi 'base commit' "$f" || gov_fail "$(basename "$f") must name the pinned base commit"
  grep -qi 'diff digest' "$f" || gov_fail "$(basename "$f") must name the pinned diff digest"
done

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# 1. The intake helper accepts a pinned outside-branch source manifest.
SRC="$WORK/outside-source.md"
MANIFEST="$WORK/2026-07-22-outside.json"
REVIEW="$WORK/supplied-review.json"
cat > "$SRC" <<'MD'
# Drive

## U1 — Route this outside branch

Preserve it, pin it, and route it through Intake/Build adoption.
MD
SRC_SHA="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$SRC")" \
  || gov_fail "could not hash source"
DIFF_SHA="$(python3 -c 'import hashlib; print(hashlib.sha256(b"outside-diff").hexdigest())')"
HEAD_SHA="1111111111111111111111111111111111111111"
BASE_SHA="2222222222222222222222222222222222222222"
python3 - "$GOV_PLUGIN/scripts" "$MANIFEST" "$REVIEW" "$SRC_SHA" "$DIFF_SHA" "$HEAD_SHA" "$BASE_SHA" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import idc_intake_manifest as M
manifest_path, review_path, src_sha, diff_sha, head_sha, base_sha = sys.argv[2:8]
manifest = {
    "schema_version": 1,
    "intake_id": "2026-07-22-outside",
    "source": {
        "kind": "external_branch",
        "display_name": "outside-source.md",
        "repo_relative_locator": "outside-source.md",
        "sha256": src_sha,
        "source_repository": "example/outside-repo",
        "head_commit": head_sha,
        "base_commit": base_sha,
        "diff_sha256": diff_sha,
    },
    "operator_goal": {
        "verbatim_or_redacted": "Preserve and route the outside branch honestly",
        "normalized": "preserve and route the outside branch honestly",
        "redactions": [],
    },
    "runtime": {"plugin_version": "4.1.0"},
    "expected_unit_ids": ["Drive", "U1"],
    "units": [
        {
            "id": "Drive",
            "source_anchor": {"heading": "Drive", "line_start": 1, "line_end": 1},
            "summary": "Preserve and route the outside branch honestly.",
            "class": "ignored_non_execution",
            "route": "ignore",
            "dependencies": [],
            "operator_stops": [],
            "disposition": {"state": "ignored", "target_ref": None, "evidence": ["drive context"]},
        },
        {
            "id": "U1",
            "source_anchor": {"heading": "U1 — Route this outside branch", "line_start": 3, "line_end": 5},
            "summary": "Outside work must be preserved, pinned, and routed through Intake.",
            "class": "new_requirement",
            "route": "think",
            "dependencies": ["Drive"],
            "operator_stops": [],
            "disposition": {"state": "queued", "target_ref": None, "evidence": []},
        },
    ],
    "verification": {"status": "pending", "review_path": None, "source_sha256": src_sha},
}
review = {
    "schema_version": 1,
    "intake_id": manifest["intake_id"],
    "source_sha256": src_sha,
    "verdict": "PASS",
    "missing_unit_ids": [],
    "duplicate_unit_ids": [],
    "misrouted_unit_ids": [],
    "notes": [M._review_binding_note(manifest)],
}
json.dump(manifest, open(manifest_path, "w"), indent=2)
json.dump(review, open(review_path, "w"), indent=2)
PY
python3 "$INTAKE" validate --manifest "$MANIFEST" --review "$REVIEW" >/dev/null \
  || gov_fail "intake helper rejected a pinned outside-branch source manifest"

# 2. Janitor preserves and routes outside-path git work, with repo/head/base/diff pins.
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
BASELINE_HEAD="$(git -C "$REPO" rev-parse HEAD)" || gov_fail "could not read baseline head"
cat > "$REPO/docs/workflow/reconciliation-adoption.json" <<JSON
{
  "schema_version": 1,
  "state": "legacy-adopted",
  "default_branch": {"name": "main", "head": "$BASELINE_HEAD"},
  "journal_entry_count": 0,
  "legacy_items": [],
  "routed_obligations": [],
  "unresolved": []
}
JSON

# Unmerged outside branch.
git -C "$REPO" checkout -q -b feature-outside
printf branch > "$REPO/outside.txt"
git -C "$REPO" add outside.txt
git -C "$REPO" commit -qm 'outside branch work'
git -C "$REPO" checkout -q main
set +e
OUT1="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC1=$?
set -e
[ "$RC1" -eq 1 ] || gov_fail "janitor scan for unmerged outside work must exit 1 with findings, got $RC1"
REPORT_JSON="$OUT1" python3 - "$BASELINE_HEAD" <<'PY' || gov_fail "unmerged outside branch was not preserved + routed with pins"
import json, os, sys
baseline = sys.argv[1]
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings", [])
hits = [f for f in findings if f.get("classification") == "outside-unmerged-branch" and f.get("route") == "intake"]
assert hits, findings
pin = hits[0].get("source_pin") or {}
assert pin.get("repository"), pin
assert pin.get("head"), pin
assert pin.get("base") == baseline, pin
assert pin.get("diff_sha256"), pin
assert hits[0].get("preserve") is True, hits[0]
PY

# Already-merged outside work becomes a reconciliation audit, not normal build history.
git -C "$REPO" checkout -q -b feature-merged
printf merged > "$REPO/merged.txt"
git -C "$REPO" add merged.txt
git -C "$REPO" commit -qm 'outside merged work'
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff feature-merged -m 'merge outside work'
set +e
OUT2="$(python3 "$JAN" --repo "$REPO" --tracker "$REPO/TRACKER.md" --json)"; RC2=$?
set -e
[ "$RC2" -eq 1 ] || gov_fail "janitor scan for merged outside work must exit 1 with findings, got $RC2"
REPORT_JSON="$OUT2" python3 - <<'PY' || gov_fail "merged outside work was not routed to a reconciliation audit with pins"
import json, os
report = json.loads(os.environ["REPORT_JSON"])
findings = report.get("findings", [])
hits = [f for f in findings if f.get("classification") == "outside-merged-work" and f.get("route") == "reconciliation_audit"]
assert hits, findings
pin = hits[0].get("source_pin") or {}
assert pin.get("repository"), pin
assert pin.get("head"), pin
assert pin.get("base"), pin
assert pin.get("diff_sha256"), pin
assert hits[0].get("preserve") is True, hits[0]
PY

echo "PASS: outside-path work is pinned and routed; unmerged work stays preserved and merged work becomes a reconciliation audit"
