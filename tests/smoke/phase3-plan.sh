#!/bin/bash
# Phase 3 smoke — Plan's deterministic guardrails are real and enforced, and (v3) Plan is now
# PURE DECOMPOSITION — it no longer authors the PRD/TRD or fires the gate (that moved to Think):
#   (a) the issue-body schema check accepts a complete 6-element contract, rejects a partial one;
#   (b) the matrix deconfliction check accepts disjoint same-wave surfaces, rejects a collision;
#   (c) command/agent-prose invariants: Plan sheds requirements authoring — agents/idc-plan.md
#       does NOT draft a PRD diff and does NOT run idc:idc-gate-issue; it decomposes only.
# Failing-test-first: fails until the two checkers exist.
#
# Usage: bash tests/smoke/phase3-plan.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCHEMA="$PLUGIN/scripts/idc_schema_check.py"
MATRIX="$PLUGIN/scripts/idc_matrix_check.py"
PLAN="$PLUGIN/agents/idc-plan.md"
PLAN_CMD="$PLUGIN/commands/plan.md"
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

# block-style YAML surfaces (an idiomatic hand-edit) must parse and still detect the collision —
# not silently mis-report it as "declares no surfaces"
cat > "$WORK/matrix-collide-block.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: ui
    surfaces:
      - src/theme/
    blocks_on: []
  - id: pillar-b
    wave: 1
    domain: ui
    surfaces:
      - src/theme/
    blocks_on: []
MD
out="$(python3 "$MATRIX" "$WORK/matrix-collide-block.yaml" 2>&1)" && fail "block-style colliding matrix was accepted (must reject)"
echo "$out" | grep -q "share surface" || fail "block-style collision must be detected as a shared-surface clash, not mis-reported as 'no surfaces' (got: $out)"

# ---- (c) Plan is pure decomposition — it sheds requirements authoring + the gate (v3) --------
# The requirements gate (PRD+TRD admission) moved to the END of Think. Plan must therefore NOT
# author a PRD diff and must NOT fire the gate. These are the guards that fail red if Plan's
# requirements authoring is restored.
[ -f "$PLAN" ] || fail "agents/idc-plan.md missing"
if grep -qiE 'PRD diff' "$PLAN"; then
  fail "agents/idc-plan.md still drafts a PRD diff — Plan sheds requirements authoring in v3 (the PRD+TRD are authored + gated by Think)"
fi
if grep -qF 'idc-gate-issue' "$PLAN"; then
  fail "agents/idc-plan.md still references idc:idc-gate-issue — the gate moved to the end of Think; Plan does not gate"
fi
grep -qiE 'pure decomposition|decompos' "$PLAN" \
  || fail "agents/idc-plan.md must declare Plan as pure decomposition (no requirements authoring)"
# the command surface must not advertise a PRD gate or doc-chain authoring either
[ -f "$PLAN_CMD" ] || fail "commands/plan.md missing"
if grep -qiE 'PRD gate|only the PRD' "$PLAN_CMD"; then
  fail "commands/plan.md still advertises a PRD gate — Plan no longer gates in v3"
fi

# ---- (d) F2b: the planning PR automerge deletes its branch deterministically ------------------
# An orphaned plan/* branch survived a merged plan PR (autorun e2e) because branch cleanup was an
# unstated step. The automerge must delete the branch atomically (deleteBranchOnMerge may be off).
grep -qiE 'automerge when green' "$PLAN" || fail "agents/idc-plan.md must automerge the planning PR"
grep -qF -- '--delete-branch' "$PLAN" \
  || fail "agents/idc-plan.md must delete the merged plan branch (--delete-branch) — else orphaned plan/* branches survive (F2b)"
# F2b (cont.): the merge must be a DIRECT, blocking merge — NOT GitHub --auto. Auto-merge defers the
# merge server-side and, with deleteBranchOnMerge off, would skip --delete-branch → orphan plan/*.
grep -qiE 'not[^.]*--auto|--auto[^.]*(defer|skip)' "$PLAN" \
  || fail "agents/idc-plan.md must disambiguate the plan merge as a direct blocking merge, NOT GitHub --auto (else --delete-branch no-ops under deleteBranchOnMerge=off) (F2b)"

# ---- (e) P0-2: the contract's VERIFICATION SURFACE must require an OUTCOME test ---------------
# Autorun shipped #449 inert (a DDL that parses but was never applied to a provisioned store)
# because element 2 accepted an all-static surface. Lock the prose that requires at least one
# command exercising the GOAL's observable end-state (behavioral, hybrid — NOT a schema-check
# reject). Removing the clause fails this red.
GC="$PLUGIN/skills/idc-goal-contract/SKILL.md"
[ -f "$GC" ] || fail "skills/idc-goal-contract/SKILL.md missing"
grep -qiE 'exercise the GOAL' "$GC" \
  || fail "idc-goal-contract element 2 must require a command that exercises the GOAL's observable end-state (P0-2)"
grep -qiE 'static checks' "$GC" \
  || fail "idc-goal-contract element 2 must name the static-only checks an outcome test goes beyond (P0-2)"
grep -qiE 'satisfiable without the outcome' "$GC" \
  || fail "idc-goal-contract element 2 must mark an all-static surface a Build review FAIL (P0-2)"

echo "PASS: schema check + matrix deconfliction green; Plan is pure decomposition; plan PR direct-merges (not --auto) and deletes its branch; contract requires an outcome test"
