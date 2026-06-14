#!/bin/bash
# run-all.sh — the IDC v2 functional verification suite.
#
# Runs every per-phase smoke test (real round-trips against the shipped helpers and a
# throwaway filesystem-backend sandbox — no live GitHub). This is v2's verification surface;
# the v1 behavioral evalset harness (scripts/run-evals.sh) is retired.
#
# Usage: bash tests/smoke/run-all.sh   (exit 0 = all green)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
for t in \
  phase1-tracker-fs \
  phase1-tracker-stage \
  phase1-tracker-lease \
  phase1-init-doctor \
  phase1-settings-json \
  phase2-think \
  phase3-plan \
  phase4-build \
  phase4-review-agent \
  phase4-triplet \
  phase5-ripple \
  phase6-autorun \
  phase7-lifecycle \
  phase7-update-preserves-data \
  phase8-pi-launchable \
  phase8-pi-runtime \
  phase8-pi-fleet-secret \
  phase8-pi-fleet-failclose \
  phase8-pi-review-verdict \
  phase8-governance \
  phase8-pi-governance-gate \
  phase8-adapter-pi; do
  if out="$(bash "$HERE/$t.sh" 2>&1)"; then
    echo "  PASS  $t"
  else
    echo "  FAIL  $t"
    printf '%s\n' "$out" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
done
echo "------------------------------------------------"
if [ "$fails" -eq 0 ]; then
  echo "idc smoke: ALL GREEN"
  exit 0
fi
echo "idc smoke: $fails FAILED"
exit 1
