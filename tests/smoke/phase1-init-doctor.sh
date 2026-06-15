#!/bin/bash
# Phase 1 smoke — init scaffolds the v2 tree + doctor's deterministic checks pass, on a
# throwaway filesystem-backend repo (no live GitHub). REAL artifacts + assertions:
# exercises the shipped scaffold helper, then asserts exactly what /idc:doctor checks.
# Also statically guards the github-backend link-step ordering in commands/init.md (the
# hermetic suite has no live GitHub, so this is a line-order assertion, not a round-trip).
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

# --- static guard: github-backend link-step ordering (no live GitHub in this hermetic suite) ---
# Codex adversarial review (PR 40): `gh project link` mutates repo-visible GitHub state, so it
# must run only AFTER the destructive Status-options gate — otherwise an existing populated board
# with incompatible Status options gets linked to the repo and THEN STOPs half-provisioned. Assert
# the link invocation sits below the **STOP** gate line in commands/init.md.
INIT_MD="$PLUGIN/commands/init.md"
link_ln=$(grep -nF 'gh project link "$TRACKER_PROJECT_NUMBER"' "$INIT_MD" | head -1 | cut -d: -f1)
stop_ln=$(grep -nF '**STOP**' "$INIT_MD" | head -1 | cut -d: -f1)
[ -n "$link_ln" ] || fail "init.md: gh project link invocation not found"
[ -n "$stop_ln" ] || fail "init.md: destructive Status **STOP** gate not found"
[ "$link_ln" -gt "$stop_ln" ] \
  || fail "init.md: gh project link (line $link_ln) must run AFTER the Status **STOP** gate (line $stop_ln)"

echo "PASS: init scaffolds the v2 tree (filesystem backend) + doctor checks satisfied + link-step ordering guarded"
