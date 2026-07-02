#!/bin/bash
# idc-assert-class: behavior
# Phase 8 smoke (F6) — the VENDORED Pi review core emits the IDC verdict ladder.
#
# The Pi review-orchestrator core (runtime/pi/extensions/review-orchestrator-core.ts) is an
# automerge gate: its emitted verdict must satisfy the IDC validator (idc_review_verdict_check.py),
# whose enum is {PASS, PASS-WITH-NITS, FAIL, FAIL-BLOCKED} with blocker→FAIL-BLOCKED, major→FAIL.
# Upstream pi-harnesses emits the invalid "FAIL/BLOCKED" and collapses blocker+major — this asserts
# the IDC-LOCAL delta that aligns the core with the validator.
#
# REAL: bun runs the actual vendored core; the verdict strings it produces are validated by the
# shipped Python checker. Failing-test-first: with the upstream enum the ladder asserts fail (red);
# the IDC-LOCAL verdict mapping turns it green.
#
# Usage: bash tests/smoke/phase8-pi-review-verdict.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CORE_TS="$PLUGIN/runtime/pi/extensions/review-orchestrator-core.ts"
HELPER_TS="$PLUGIN/tests/smoke/phase8-pi-review-verdict.ts"
VC="$PLUGIN/scripts/idc_review_verdict_check.py"

fail() { echo "FAIL: $1"; exit 1; }

command -v bun >/dev/null 2>&1 || fail "bun not found on PATH (required to run the vendored review core)"
[ -f "$CORE_TS" ]   || fail "vendored review core missing at $CORE_TS"
[ -f "$HELPER_TS" ] || fail "verdict helper missing at $HELPER_TS"
[ -f "$VC" ]        || fail "verdict validator missing at $VC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# (1) per-severity ladder via the real core (bun) — exits non-zero on any mismatch.
bun "$HELPER_TS" "$WORK" || fail "vendored core does not emit the IDC verdict ladder (blocker→FAIL-BLOCKED, major→FAIL)"

# (2) end-to-end: the verdict strings the core produced must pass the IDC validator.
[ -f "$WORK/blocker.json" ] || fail "helper did not emit blocker.json"
[ -f "$WORK/major.json" ]   || fail "helper did not emit major.json"
python3 "$VC" "$WORK/blocker.json" >/dev/null \
  || { python3 "$VC" "$WORK/blocker.json"; fail "core's blocker verdict rejected by the IDC validator (expected FAIL-BLOCKED)"; }
python3 "$VC" "$WORK/major.json" >/dev/null \
  || { python3 "$VC" "$WORK/major.json"; fail "core's major verdict rejected by the IDC validator (expected FAIL)"; }

# (3) the invalid upstream enum must be gone from executable code (comment references are fine).
grep -vE '^[[:space:]]*//' "$CORE_TS" | grep -q '"FAIL/BLOCKED"' \
  && fail "vendored core still uses the invalid 'FAIL/BLOCKED' literal in code (must be FAIL / FAIL-BLOCKED)"

echo "PASS: vendored Pi review core emits the IDC verdict ladder and passes the validator"
