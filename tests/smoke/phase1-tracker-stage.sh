#!/bin/bash
# Phase 1 smoke — board Stage field (4->5) + pointer items vs buildable goal-contracts.
#
# Grows the board schema to a 5th single-select `Stage` (Consideration | Planning | Buildable | Recirculation),
# the column-grouping field. Upstream artifacts (considerations, in-flight plans, pillars) ride
# the board as lightweight POINTER items (repo-file reference + Stage/Phase/Domain, never a copy
# of canonical content); buildable issues carry Stage=Buildable. Build queries the board by
# Stage instead of scanning the filesystem — so an upstream-staged pointer is never scooped.
#
# This is a REAL functional test driving the shipped helpers against a throwaway filesystem
# tracker (no GitHub). Failing-test-first: it fails until idc_tracker_fs.py carries Stage,
# idc_schema_check.py distinguishes a pointer from a buildable contract, and the autorun drain
# excludes pointer-stage items.
#
# Usage: bash tests/smoke/phase1-tracker-stage.sh   (exit 0 = pass)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TRK="$HERE/scripts/idc_tracker_fs.py"
SCHEMA="$HERE/scripts/idc_schema_check.py"
DRAIN="$HERE/scripts/idc_autorun_drain.py"
WORK="$(mktemp -d)"
T="$WORK/TRACKER.md"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
run()  { python3 "$TRK" --tracker "$T" "$@"; }

[ -f "$TRK" ]    || fail "tracker helper not found at $TRK"
[ -f "$SCHEMA" ] || fail "schema checker not found at $SCHEMA"

# ---- (a) Stage query: a Consideration pointer is EXCLUDED from Stage=Buildable; a buildable
#         issue is INCLUDED -------------------------------------------------------------------
run init >/dev/null || fail "init failed"
ptr="$(run create --title 'pointer: dark-mode consideration' \
         --stage Consideration --phase 'Phase 1' --domain ui)"   || fail "create pointer failed (no --stage support yet?)"
bld="$(run create --title 'Add appearance setting' \
         --stage Buildable --wave 'Wave 1' --phase 'Phase 1' --domain ui)" || fail "create buildable failed"
[ "$(run show --num "$ptr" --field Stage)" = "Consideration" ] || fail "pointer Stage should be Consideration, got '$(run show --num "$ptr" --field Stage)'"

buildables="$(run query --stage Buildable)"
echo "$buildables" | grep -qw "$bld" || fail "Stage=Buildable query must INCLUDE the buildable issue $bld (got: '$buildables')"
echo "$buildables" | grep -qw "$ptr" && fail "Stage=Buildable query must EXCLUDE the Consideration pointer $ptr (got: '$buildables')"

# ---- (a2) glass wall: autorun's build-lane drain must never scoop an upstream pointer --------
if [ -f "$DRAIN" ]; then
  elig="$(python3 "$DRAIN" --tracker "$T")" || fail "drain helper errored"
  echo "$elig" | grep -qE "(^| )$bld( |$)" || fail "buildable issue $bld should be eligible build work (got: '$elig')"
  echo "$elig" | grep -qE "(^| )$ptr( |$)" && fail "a Consideration pointer $ptr must NEVER be eligible build work — the glass wall (got: '$elig')"
fi

# ---- (a3) F5: legacy 4-field board — an issue with EMPTY/missing Stage reads as Buildable -----
#         WORKFLOW.md: "an empty Stage reads as buildable". The exact-equality filter must NOT
#         silently drop legacy Todo work that predates the 5th Stage field.
legacy="$(run create --title 'legacy todo (no stage)' --wave 'Wave 1' --phase 'Phase 1' --domain ui)" \
  || fail "create legacy issue (no --stage) failed"
[ "$(run show --num "$legacy" --field Stage)" = "" ] \
  || fail "legacy issue should have empty Stage, got '$(run show --num "$legacy" --field Stage)'"
buildables_legacy="$(run query --stage Buildable)"
echo "$buildables_legacy" | grep -qw "$legacy" \
  || fail "Stage=Buildable query must INCLUDE a legacy empty-Stage issue $legacy (empty Stage reads as buildable) (got: '$buildables_legacy')"

# ---- (a4) Recirculation Stage — the inbox is BUILD-EXCLUDED: a Stage=Recirculation item (scope
#          discovered mid-build, drained by /idc:recirculate) is never returned by --stage Buildable
#          and is never eligible build work (the glass wall) --------------------------------------
recirc="$(run create --title 'recirc: discovered mid-build scope' \
            --stage Recirculation --phase 'Phase 1' --domain ui)" \
  || fail "create Stage=Recirculation item failed (no Recirculation stage support yet?)"
[ "$(run show --num "$recirc" --field Stage)" = "Recirculation" ] \
  || fail "recirc item Stage should be Recirculation, got '$(run show --num "$recirc" --field Stage)'"
buildables_recirc="$(run query --stage Buildable)"
echo "$buildables_recirc" | grep -qw "$recirc" \
  && fail "Stage=Buildable query must EXCLUDE the Recirculation inbox item $recirc (got: '$buildables_recirc')"
if [ -f "$DRAIN" ]; then
  elig_recirc="$(python3 "$DRAIN" --tracker "$T")" || fail "drain helper errored"
  echo "$elig_recirc" | grep -qE "(^| )$recirc( |$)" \
    && fail "a Stage=Recirculation item $recirc must NEVER be eligible build work — the glass wall (got: '$elig_recirc')"
fi

# ---- (b) schema check: a pointer's shape is DISTINCT from a full buildable goal-contract ------
# A valid pointer: repo-file reference + Stage/Phase/Domain, with NO duplicated canonical content.
cat > "$WORK/pointer.md" <<'MD'
Stage: Consideration
File: docs/considerations/2026-06-12-dark-mode-considerations.md
Phase: Phase 1
Domain: ui
MD
python3 "$SCHEMA" "$WORK/pointer.md" >/dev/null || fail "a valid Consideration pointer was rejected"

# A full buildable goal-contract still validates (existing behavior; Stage=Buildable additive).
cat > "$WORK/buildable.md" <<'MD'
Stage: Buildable
GOAL: Users can toggle dark mode in Settings and it persists across sessions.
VERIFICATION SURFACE: `pnpm test settings/theme` green; theme_persist.test added red->green.
CONSTRAINTS: existing settings unchanged; no-punt — incidental fixes land here.
BOUNDARIES: touch src/settings/, src/theme/ ; off-limits src/auth/
ITERATION POLICY: record-and-vary
BLOCKED-STOP: halt after 3 failed hypotheses; surface evidence.
ASSUMPTIONS: "System" follows OS at launch (vetoable).
---
Dependencies: blocked-by #0 (none)
Trace: pillars/dark-mode-plan.md · 2026-06-12-dark-mode-considerations.md · PRD §Appearance
MD
python3 "$SCHEMA" "$WORK/buildable.md" >/dev/null || fail "a complete buildable contract was rejected"

# DISTINCTNESS: a pointer that duplicates canonical content (carries a full goal-contract) is REJECTED.
cat > "$WORK/pointer-dup.md" <<'MD'
Stage: Consideration
File: docs/considerations/2026-06-12-dark-mode-considerations.md
Phase: Phase 1
Domain: ui
GOAL: Users can toggle dark mode and it persists.
VERIFICATION SURFACE: `pnpm test settings/theme` green.
MD
python3 "$SCHEMA" "$WORK/pointer-dup.md" >/dev/null 2>&1 && fail "a pointer duplicating canonical goal-contract content must be rejected (distinctness)"

# A pointer with no repo-file reference is REJECTED.
cat > "$WORK/pointer-bad.md" <<'MD'
Stage: Planning
Phase: Phase 1
Domain: ui
MD
python3 "$SCHEMA" "$WORK/pointer-bad.md" >/dev/null 2>&1 && fail "a pointer with no repo-file reference must be rejected"

# ---- (c) Recirculation ticket schema (C2): the inbox shape is DISTINCT from pointer + contract --
# A valid Recirculation ticket carries the five required scope fields and NO goal-contract.
cat > "$WORK/recirc.md" <<'MD'
Stage: Recirculation
Discovered: build needs a shared rate-limit middleware the contract did not scope
Area: src/api/middleware
Suggested-scope: extract a reusable limiter + wire the two new routes through it
Provenance: discovered mid-build by idc-finisher on #42
PRD-TRD-impact: unknown
MD
python3 "$SCHEMA" "$WORK/recirc.md" >/dev/null || fail "a valid Recirculation ticket was rejected"

# A Recirculation ticket MISSING a required field (no Provenance) is REJECTED.
cat > "$WORK/recirc-missing.md" <<'MD'
Stage: Recirculation
Discovered: build needs a shared rate-limit middleware the contract did not scope
Area: src/api/middleware
Suggested-scope: extract a reusable limiter + wire the two new routes through it
PRD-TRD-impact: unknown
MD
python3 "$SCHEMA" "$WORK/recirc-missing.md" >/dev/null 2>&1 \
  && fail "a Recirculation ticket missing a required field (Provenance) must be rejected"

# A Recirculation ticket carrying a goal-contract marker (GOAL:) is REJECTED (anti-goal-contract).
cat > "$WORK/recirc-goal.md" <<'MD'
Stage: Recirculation
Discovered: build needs a shared rate-limit middleware the contract did not scope
Area: src/api/middleware
Suggested-scope: extract a reusable limiter + wire the two new routes through it
Provenance: discovered mid-build by idc-finisher on #42
PRD-TRD-impact: unknown
GOAL: add a rate limiter
MD
python3 "$SCHEMA" "$WORK/recirc-goal.md" >/dev/null 2>&1 \
  && fail "a Recirculation ticket carrying a GOAL: goal-contract marker must be rejected (anti-goal-contract)"

echo "PASS: Stage field (4->5) query excludes pointers + Recirculation inbox build-excluded + schema-check pointer/recirculation distinctness green"
