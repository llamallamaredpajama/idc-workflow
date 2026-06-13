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
  phase1-init-doctor \
  phase1-settings-json \
  phase2-think \
  phase3-plan \
  phase4-build \
  phase5-ripple \
  phase6-autorun; do
  if bash "$HERE/$t.sh" >/dev/null 2>&1; then
    echo "  PASS  $t"
  else
    echo "  FAIL  $t"
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
