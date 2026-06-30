#!/bin/bash
# Phase 8 smoke — the vendored Pi role prompts match the CURRENT 5-field-board IDC contract:
# they drive the board through the tracker adapter (not TRACKER.md), Plan is idempotent + sets
# the board fields + runs the matrix, Build claims before working, the finisher merges on a
# durable review verdict (behavioral) + recirculates, the reviewer is source/tracker-read-only
# but writes a scoped verdict artifact under docs/workflow/code-reviews/ and reports findings
# over coms-net when available, and NO prompt carries the RETIRED vocabulary (claim-state
# machine, bookend ceremony, the deleted recirculator verdict taxonomy / change-order files).
#
# Red-when-broken: every must-have line below is ABSENT from the pre-fix prompts (they were
# file-write-framed and delegated to non-existent codex-idc-* skills), so this fails before the
# rewrite; every must-not line is PRESENT pre-fix, so it also fails — both flip green after.
#
# Usage: bash tests/smoke/phase8-pi-prompt-alignment.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
A="$PLUGIN/runtime/pi/.pi/agents/idc"
fails=0
have() { # file regex label
  if ! grep -qiE "$2" "$A/$1"; then echo "MISSING in $1: $3 (/$2/)"; fails=$((fails+1)); fi
}
absent() { # file regex label
  if grep -qiE "$2" "$A/$1"; then echo "RETIRED-VOCAB in $1: $3 (/$2/)"; fails=$((fails+1)); fi
}

# ── Every role drives the board through the tracker adapter ─────────────────────────────────
for f in think plan sequence recirculator build-implementer build-reviewer build-finisher; do
  have "$f.md" "idc:idc-tracker-adapter" "names the tracker adapter"
done

# ── No prompt may reference the non-existent skills it used to delegate to ───────────────────
for f in think plan sequence recirculator build-implementer build-reviewer build-finisher; do
  absent "$f.md" "codex-idc-|skills/idc-workflow" "dead skill reference (codex-idc-* / idc-workflow)"
done

# ── No prompt may carry the RETIRED contract vocabulary ──────────────────────────────────────
for f in think plan sequence recirculator build-implementer build-reviewer build-finisher; do
  absent "$f.md" "claim-state|bookend" "retired claim-state/bookend vocab"
done

# ── Plan: idempotency + the five board fields + the matrix guardrail + Planning stage ────────
have "plan.md" "idempoten|duplicate|already exists" "idempotency guard"
have "plan.md" "Stage" "sets Stage"
have "plan.md" "Status" "sets Status"
have "plan.md" "Wave" "knows Wave"
have "plan.md" "Phase" "sets Phase"
have "plan.md" "Domain" "sets Domain"
have "plan.md" "idc:idc-matrix-analysis" "runs the matrix deconfliction"
have "plan.md" "Planning" "produces Planning-stage pointers"

# ── Sequence: admits to the board (Buildable + Wave), not TRACKER.md ─────────────────────────
have "sequence.md" "Buildable" "promotes Stage=Buildable"
have "sequence.md" "Wave" "owns Wave admission"

# ── Build implementer: claim-before-work eligibility ─────────────────────────────────────────
have "build-implementer.md" "Status[ =]?Todo|Status.?Todo" "queries Status=Todo"
have "build-implementer.md" "Buildable" "queries Stage=Buildable"
have "build-implementer.md" "blocked.?by" "checks blocked-by upstreams"
have "build-implementer.md" "claim" "claims the issue before working"
have "build-implementer.md" "In Progress" "flips Status to In Progress on claim"

# ── Build reviewer: source/tracker-read-only; writes a durable verdict + may report over coms-net ─
have "build-reviewer.md" "source/tracker-read-only|read-only on source and tracker" "states it is read-only on source/tracker"
have "build-reviewer.md" "docs/workflow/code-reviews" "writes the durable review artifact lane"
have "build-reviewer.md" "pr-<PR-NUMBER>\\.verdict\\.json|pr-\\$\\{PR_NUMBER\\}\\.verdict\\.json|pr-[^ ]*verdict\\.json" "names the deterministic verdict file"
have "build-reviewer.md" "coms" "reports findings over coms-net when available"
have "build-reviewer.md" "verdict" "emits a verdict"
have "build-reviewer.md" "PASS" "uses the PASS/FAIL verdict ladder"

# ── Build finisher: merge-on-verdict + recirculate-on-persistent-fail + close→Done ───────────
have "build-finisher.md" "verdict" "gates merge on the review verdict"
have "build-finisher.md" "PASS" "merges only on PASS/PASS-WITH-NITS"
have "build-finisher.md" "gh pr merge" "performs the merge"
have "build-finisher.md" "recirculat" "recirculates on persistent failure"
have "build-finisher.md" "Done" "closes the issue to Status=Done"

# ── Recirculator: binary gate model; NOT the deleted verdict taxonomy ────────────────────────
have "recirculator.md" "idc_recirculator_layers.py|gate:.?no|gate:.?yes|gated Think PR" "binary gate decision"
absent "recirculator.md" "NO_RECIRCULATION|MINOR_AUTONOMOUS|MAJOR_GATED" "deleted verdict taxonomy"

if [ "$fails" -eq 0 ]; then
  echo "PASS: Pi role prompts match the current 5-field-board IDC contract (tracker-adapter-driven; Plan idempotent+fielded+matrix; Build claims; finisher merges-on-durable-verdict (behavioral)+recirculates; reviewer is source/tracker-read-only with a scoped verdict artifact lane + optional coms-net report; no retired vocab)"
  exit 0
fi
echo "FAIL: $fails prompt-alignment invariant(s) unmet"
exit 1
