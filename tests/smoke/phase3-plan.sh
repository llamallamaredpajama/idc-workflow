#!/bin/bash
# Phase 3 smoke — Plan's deterministic guardrails are real and enforced:
#   (a) the issue-body schema check accepts a complete 6-element contract, rejects a partial one;
#   (b) the matrix deconfliction check accepts disjoint same-wave surfaces, rejects a collision;
#   (c) the PRD gate mechanism: a PRD-dependent issue lands Blocked behind a gate issue while
#       a non-PRD issue keeps flowing (Todo) — enacted over the real tracker.
# Failing-test-first: fails until the two checkers exist.
#
# Usage: bash tests/smoke/phase3-plan.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$PLUGIN/scripts/idc_schema_check.py"
MATRIX="$PLUGIN/scripts/idc_matrix_check.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCHEMA" ] || fail "schema checker not found at $SCHEMA (not implemented yet)"
[ -f "$MATRIX" ] || fail "matrix checker not found at $MATRIX (not implemented yet)"

# ---- (a) issue-body schema check -------------------------------------------------
cat > "$WORK/issue-good.md" <<'MD'
GOAL: Users can toggle dark mode in Settings and it persists across sessions.
VERIFICATION SURFACE: `pnpm test settings/theme` green; new test theme_persist.test added first (red→green).
CONSTRAINTS: existing settings unchanged; no new deps; no-punt — incidental fixes land here.
BOUNDARIES: touch src/settings/, src/theme/ ; off-limits src/auth/, src/billing/
ITERATION POLICY: record-and-vary
BLOCKED-STOP: halt after 3 failed hypotheses or on a missing design token; surface evidence.
ASSUMPTIONS: "System" follows OS at launch (vetoable).
---
Dependencies: blocked-by #0 (none)
Trace: pillars/dark-mode-toggle-plan.md · 2026-06-12-dark-mode-considerations.md · PRD §Appearance
MD
python3 "$SCHEMA" "$WORK/issue-good.md" >/dev/null || fail "complete contract issue was rejected"

cat > "$WORK/issue-bad.md" <<'MD'
GOAL: make settings better
BOUNDARIES: touch everything
MD
python3 "$SCHEMA" "$WORK/issue-bad.md" >/dev/null 2>&1 && fail "partial issue was accepted (must reject)"

# ---- (b) matrix deconfliction check ----------------------------------------------
cat > "$WORK/matrix-good.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: pillar-theme
    wave: 1
    domain: ui
    surfaces: [src/theme/]
    blocks_on: []
  - id: pillar-settings
    wave: 1
    domain: settings
    surfaces: [src/settings/]
    blocks_on: []
MD
python3 "$MATRIX" "$WORK/matrix-good.yaml" >/dev/null || fail "valid matrix (disjoint same-wave surfaces) was rejected"

cat > "$WORK/matrix-collide.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces: [src/theme/]
    blocks_on: []
  - id: pillar-b
    wave: 1
    domain: ui
    surfaces: [src/theme/]
    blocks_on: []
MD
python3 "$MATRIX" "$WORK/matrix-collide.yaml" >/dev/null 2>&1 && fail "colliding matrix (same wave, shared surface) was accepted (must reject)"

# ---- (c) PRD gate mechanism over the real tracker --------------------------------
T="$WORK/TRACKER.md"
python3 "$TRK" --tracker "$T" init
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] PRD change — dark mode")
prd_dep=$(python3 "$TRK" --tracker "$T" create --title "Add appearance setting (PRD-touching)")
non_prd=$(python3 "$TRK" --tracker "$T" create --title "Refactor theme util (no PRD change)")
# chain the PRD-dependent issue Blocked behind the gate; leave the non-PRD issue alone
python3 "$TRK" --tracker "$T" block --num "$prd_dep" --by "$gate" >/dev/null
[ "$(python3 "$TRK" --tracker "$T" show --num "$prd_dep" --field Status)" = "Blocked" ] || fail "PRD-dependent issue should be Blocked behind the gate"
python3 "$TRK" --tracker "$T" show --num "$prd_dep" --blocked-by | grep -qw "$gate" || fail "PRD-dependent issue should be blocked-by the gate issue"
[ "$(python3 "$TRK" --tracker "$T" show --num "$non_prd" --field Status)" = "Todo" ] || fail "non-PRD issue should keep flowing (Todo)"

echo "PASS: schema check + matrix deconfliction + PRD gate mechanism all green"
