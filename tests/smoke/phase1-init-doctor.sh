#!/bin/bash
# Phase 1 smoke — init scaffolds the v2 tree + doctor's deterministic checks pass, on a
# throwaway filesystem-backend repo (no live GitHub). REAL artifacts + assertions:
# exercises the shipped scaffold helper, then asserts exactly what /idc:doctor checks.
# Failing-test-first: fails until scripts/idc_init_scaffold.sh exists.
#
# Usage: bash tests/smoke/phase1-init-doctor.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCAFFOLD" ] || fail "scaffold helper not found at $SCAFFOLD (not implemented yet)"

( cd "$SBX" && git init -q )

# run the real init filesystem scaffold
bash "$SCAFFOLD" "$PLUGIN" "$SBX" "Test Project" filesystem >/dev/null || fail "scaffold helper failed"

# --- assertions mirror /idc:doctor checks 3, 4, 5 ---
# scaffold files present
[ -f "$SBX/WORKFLOW.md" ]                         || fail "WORKFLOW.md not scaffolded"
[ -f "$SBX/WORKFLOW-config.yaml" ]                || fail "WORKFLOW-config.yaml not scaffolded"
[ -f "$SBX/docs/workflow/tracker-config.yaml" ]  || fail "tracker-config.yaml not scaffolded"
# token substitution happened (no leftover {{PROJECT_NAME}}; name present)
grep -q "Test Project" "$SBX/WORKFLOW.md"        || fail "PROJECT_NAME not substituted in WORKFLOW.md"
! grep -q "{{PROJECT_NAME}}" "$SBX/WORKFLOW.md" "$SBX/WORKFLOW-config.yaml" "$SBX/docs/workflow/tracker-config.yaml" \
                                                 || fail "leftover {{PROJECT_NAME}} token after scaffold"
# doctor check 4: exactly the two v2 subdirs, no v1 subdirs
[ -d "$SBX/docs/workflow/pillar-matrices" ]      || fail "docs/workflow/pillar-matrices missing"
[ -d "$SBX/docs/workflow/code-reviews" ]         || fail "docs/workflow/code-reviews missing"
for v1 in audits ledgers ripple operator-todos phase-planning pillar-conflicts handoffs diagrams plans; do
  [ -e "$SBX/docs/workflow/$v1" ] && fail "v1 subdir docs/workflow/$v1 should not be scaffolded in v2"
done
# doctor check 3: filesystem backend selected + TRACKER.md present and valid
grep -q "^backend: filesystem" "$SBX/docs/workflow/tracker-config.yaml" || fail "backend not set to filesystem"
[ -f "$SBX/TRACKER.md" ]                          || fail "filesystem backend should init TRACKER.md"
grep -q "idc-tracker-state:begin" "$SBX/TRACKER.md" || fail "TRACKER.md missing the state block"
# the tracker is actually usable post-scaffold (round-trip one op)
python3 "$PLUGIN/scripts/idc_tracker_fs.py" --tracker "$SBX/TRACKER.md" create --title "smoke" >/dev/null \
                                                 || fail "tracker unusable after scaffold"

echo "PASS: init scaffolds the v2 tree (filesystem backend) + doctor checks satisfied"
