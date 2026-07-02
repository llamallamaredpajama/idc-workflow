#!/bin/bash
# idc-assert-class: behavior
# Phase 4 smoke — the larger loop's RUNAWAY GUARD: a per-issue recirc ceiling + a cascade-depth cap.
# A recirc fix can surface a deeper recirc event; unbounded that churns recirc->plan->build->recirc
# all night. scripts/idc_recirc_caps.py is the deterministic verdict: PARK (for the operator) once an
# issue has recirculated >= the ceiling, or a recirc cascade reaches the depth cap; CONTINUE otherwise.
#
# Red-when-broken: each PARK case is paired with a just-under CONTRAST that must stay CONTINUE — if a
# boundary regressed (>= vs >, off-by-one) one of the pair flips RED. Fail-closed: a bad/negative count
# exits 2 (the orchestrator treats that as park+surface, never churn).
# Usage: bash tests/smoke/phase4-recirc-caps.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$PLUGIN/scripts"
CAPS="$SCRIPTS/idc_recirc_caps.py"
BUILD="$PLUGIN/agents/idc-build.md"
fail() { echo "FAIL: $1"; exit 1; }
has() { grep -qiE "$2" "$1"; }
hasflat() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }

[ -f "$CAPS" ] || fail "scripts/idc_recirc_caps.py is missing (the runaway guard)"

# ── A. the pure decide() brain (recirc_count, cascade_depth, ceiling, cascade_cap) ──
dec() {
python3 - "$SCRIPTS" "$1" "$2" "$3" "$4" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import idc_recirc_caps as m
print(m.decide(int(sys.argv[2]), int(sys.argv[3]), ceiling=int(sys.argv[4]), cascade_cap=int(sys.argv[5])))
PY
}
# args: recirc_count cascade_depth ceiling cascade_cap
[ "$(dec 1 1 2 3)" = "continue" ] || fail "below both limits must CONTINUE"
[ "$(dec 2 1 2 3)" = "park" ]     || fail "recirc_count at ceiling must PARK"
[ "$(dec 1 1 2 3)" = "continue" ] || fail "RED-control: ceiling-1 must CONTINUE (pins the recirc-ceiling guard)"
[ "$(dec 0 3 2 3)" = "park" ]     || fail "cascade_depth at cap must PARK"
[ "$(dec 0 2 2 3)" = "continue" ] || fail "RED-control: cap-1 must CONTINUE (pins the cascade-depth guard)"
[ "$(dec 5 5 2 3)" = "park" ]     || fail "both over limits must PARK"

# ── B. the CLI verdict + fail-closed ──
out="$(python3 "$CAPS" --recirc-count 2 --cascade-depth 0 --ceiling 2 --cascade-cap 3 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "valid caps invocation must exit 0 (got $rc)"
echo "$out" | grep -qiE 'verdict:[[:space:]]*park' || fail "count at ceiling -> verdict: park"
out="$(python3 "$CAPS" --recirc-count 0 --cascade-depth 0 --ceiling 2 --cascade-cap 3 2>/dev/null)"
echo "$out" | grep -qiE 'verdict:[[:space:]]*continue' || fail "fresh issue -> verdict: continue"

co_rc() { python3 "$CAPS" "$@" >/dev/null 2>&1; echo $?; }
[ "$(co_rc --recirc-count -1 --cascade-depth 0)" = "2" ] || fail "negative recirc-count must fail-closed (exit 2)"
[ "$(co_rc --recirc-count x  --cascade-depth 0)" = "2" ] || fail "non-int recirc-count must fail-closed (exit 2)"
[ "$(co_rc --cascade-depth 0)" = "2" ]                   || fail "missing recirc-count must fail-closed (exit 2)"

# ── C. wiring prose: build consults the caps + documents the PARK behavior + how counts are tracked ──
has "$BUILD" 'idc_recirc_caps' \
  || fail "agents/idc-build.md must consult the caps helper (idc_recirc_caps)"
hasflat "$BUILD" 'per-issue recirc ceiling' \
  || fail "agents/idc-build.md must name the per-issue recirc ceiling"
hasflat "$BUILD" 'cascade-depth cap|cascade depth cap' \
  || fail "agents/idc-build.md must name the cascade-depth cap"
hasflat "$BUILD" 'park[^.]*(operator|human|blocked)|(operator|human|blocked)[^.]*park' \
  || fail "agents/idc-build.md must park a capped issue for the operator (not retry forever)"

echo "PASS: caps decide() PARKs at ceiling/cap and CONTINUEs just under (red-when-broken pairs) + CLI verdict + fail-closed on bad counts; build consults idc_recirc_caps and parks a capped issue for the operator"
