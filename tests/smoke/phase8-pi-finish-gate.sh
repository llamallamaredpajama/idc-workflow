#!/bin/bash
# Phase 8 smoke — Pi build-finish must be a strict merge gate.
#
# Live Pi e2e exposed a dangerous fail-open: when coms-net was unavailable and no review verdict
# could be retrieved, build-finish assumed GREEN/PASS and merged. A first-class Pi runtime must
# refuse to merge unless it has real evidence: a durable review verdict artifact with PASS or
# PASS-WITH-NITS plus green test evidence. Missing/malformed/non-green evidence is a blocked stop,
# never an assumed green lane.
#
# Usage: bash tests/smoke/phase8-pi-finish-gate.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
FIN="$PLUGIN/runtime/pi/.pi/agents/idc/build-finisher.md"
fails=0

have() {
  if ! grep -qiE "$1" "$FIN"; then
    echo "MISSING in build-finisher.md: $2 (/$1/)"
    fails=$((fails+1))
  fi
}

# A durable verdict artifact is the primary non-LLM handoff when coms-net is absent.
have 'docs/workflow/code-reviews' 'reads the durable review artifact directory'
have 'pr-<PR-NUMBER>\.verdict\.json|pr-\$\{PR_NUMBER\}\.verdict\.json|pr-[^ ]*verdict\.json' 'names the deterministic PR verdict file'

# Missing or malformed review evidence is fail-closed and blocks merge.
have '(missing|absent|malformed|unreadable)[^.]{0,120}(verdict|review)[^.]{0,160}(do NOT merge|do not merge|must not merge|refuse|fail-closed|blocked-stop)' 'missing/malformed verdict blocks merge'

# The live failure mode: no assumed PASS/GREEN when coms-net cannot be queried.
have '(never|do not|must not)[^.]{0,80}assum(e|ed|ption)[^.]{0,120}(PASS|GREEN|green|pass)' 'explicitly forbids assumed PASS/GREEN'
have '(coms-net|coms_net)[^.]{0,120}(unavailable|fails|missing|cannot connect|no server)[^.]{0,160}(do NOT merge|do not merge|must not merge|refuse|blocked-stop|fail-closed)' 'coms-net failure is not a merge bypass'

# Merge requires both review verdict and real test evidence.
have '(PASS-WITH-NITS|PASS)[^.]{0,160}(tests|verification)[^.]{0,160}(green|pass|passed)' 'requires green test evidence in addition to a green verdict'
have 'gh pr merge' 'still performs the merge after the strict gate is satisfied'

if [ "$fails" -eq 0 ]; then
  echo "PASS: Pi build-finish is a strict merge gate — no durable PASS/PASS-WITH-NITS verdict + green tests, no merge; coms-net failure cannot become assumed green"
  exit 0
fi
echo "FAIL: $fails Pi build-finish gate invariant(s) unmet"
exit 1
