#!/bin/bash
# Phase 4 smoke — Build's READY-FRONTIER + AREA-PACKING dispatch (#76: dissolve the wave barriers).
#
# The kitchen runs continuously. Build dispatches off the whole-board READY FRONTIER — an issue is
# ready when every blocked_by is Done AND its file surface is free — instead of marching wave-by-wave
# behind a barrier. Wave survives ONLY as the acceptance gate's reporting scope. Two halves, both
# red-when-broken:
#
#   A. BEHAVIOR — the dispatch INPUT contract. The build loop consumes the SAME wave-blind readiness
#      helper autorun does (`idc_autorun_drain.py --frontier`; "consume, don't duplicate"). Over a
#      multi-wave board, a LATER-wave issue whose blocked_by are all Done lands in the ready frontier
#      in the SAME pass as an early-wave ready issue; a still-blocked issue does not. Red-when-broken
#      by construction: reintroduce a Wave partition into the frontier and the later-wave issue drops
#      out of the pass (assertion on `late`); drop the blocked_by check and the blocked issue / the
#      width inflate. (Distinct from phase6-autorun-autonomy.sh, which uses INDEPENDENT cross-wave
#      issues — here the proof is a cross-wave DEPENDENT whose upstream just went Done, the exact
#      case a wave barrier would wrongly hold back.)
#   B. DOCTRINE — agents/idc-build.md dispatches off the ready frontier with area-packing (one worker
#      per matrix-carved disjoint surface area), a freed sous chef immediately pulls the next ready
#      area, Wave is retained only as acceptance-gate reporting scope, and the acceptance gate
#      retriggers at per-area finish + convergence checkpoints (not only at wave-close). The existing
#      acceptance-gate prose locks (phase4-acceptance.sh) stay green — #76 ADDS retrigger points; it
#      does not change the gate logic (the B9 belt-and-suspenders pair re-asserts the gate survived).
#
# Usage: bash tests/smoke/phase4-ready-frontier.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
BUILD="$PLUGIN/agents/idc-build.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
T="$WORK/TRACKER.md"
fail() { echo "FAIL: $1"; exit 1; }
frontier() { python3 "$DRAIN" --tracker "$T" --frontier; }

[ -f "$DRAIN" ] || fail "autorun drain/frontier helper not found at $DRAIN"
[ -f "$TRK" ]   || fail "tracker helper not found at $TRK"
[ -f "$BUILD" ] || fail "agents/idc-build.md missing"

# ---- A. wave-INDEPENDENT ready frontier: a later-wave dependent dispatches with an early-wave issue
# Board:
#   up      Wave 1  -> Done                          (a cross-wave enabler)
#   early   Wave 1  Todo, no blockers                -> READY (early wave)
#   late    Wave 3  Todo, blocked_by=[up] (up Done)  -> READY (LATER wave, blockers cleared)
#   gate    Wave 1  Blocked (status), no blockers    -> excluded (not Todo)
#   blocked Wave 1  Todo, blocked_by=[gate] (!Done)  -> NOT ready
python3 "$TRK" --tracker "$T" init >/dev/null || fail "tracker init failed"
up=$(python3 "$TRK" --tracker "$T" create --title "cross-wave enabler"  --wave "Wave 1")
python3 "$TRK" --tracker "$T" close --num "$up" >/dev/null
early=$(python3 "$TRK"   --tracker "$T" create --title "early-wave ready"     --wave "Wave 1")
late=$(python3 "$TRK"    --tracker "$T" create --title "later-wave dependent" --wave "Wave 3" --blocked-by "$up")
gate=$(python3 "$TRK"    --tracker "$T" create --title "live blocker"         --wave "Wave 1")
python3 "$TRK" --tracker "$T" block --num "$gate" >/dev/null   # status -> Blocked (not Todo)
blocked=$(python3 "$TRK" --tracker "$T" create --title "still blocked"        --wave "Wave 1" --blocked-by "$gate")

rf="$(frontier | grep '^ready-frontier:')"
# THE Done-When: early (Wave 1) AND late (Wave 3) ready in the SAME pass — Wave never partitions.
printf '%s\n' "$rf" | grep -qwF "$early" \
  || fail "ready-frontier must list the early-wave ready issue $early (got: '$rf')"
printf '%s\n' "$rf" | grep -qwF "$late" \
  || fail "ready-frontier must list the LATER-wave issue $late whose blocked_by are all Done, in the SAME pass as the early-wave issue — Wave must not partition the frontier (got: '$rf')"
# the still-blocked issue and the Blocked-status gate must NOT appear
printf '%s\n' "$rf" | grep -qwF "$blocked" \
  && fail "ready-frontier must NOT list $blocked — its blocked_by ($gate) is not Done (got: '$rf')"
printf '%s\n' "$rf" | grep -qwF "$gate" \
  && fail "ready-frontier must NOT list the Blocked-status issue $gate (got: '$rf')"
# width counts exactly the two ready issues (early, late) — wave-blind, blocked-aware
frontier | grep -qx "width: 2" \
  || fail "ready frontier width must be 2 (early + later-wave dependent), wave-blind & blocked-aware (got: $(frontier | tr '\n' '|'))"

# ---- B. DOCTRINE: agents/idc-build.md dispatches off the ready frontier with area-packing ---------
# Each grep ties to a load-bearing #76 directive and is RED against the pre-#76 (wave-barrier) playbook.
# B1/B2 — Build CONSUMES the wave-blind readiness helper (consume, don't duplicate) and reads --frontier.
grep -qiE 'idc_autorun_drain\.py' "$BUILD" \
  || fail "idc-build.md must consume the wave-blind ready-frontier helper idc_autorun_drain.py (consume, don't duplicate the readiness predicate)"
grep -qiE '\-\-frontier' "$BUILD" \
  || fail "idc-build.md must read the --frontier output (the ready set + width) to drive dispatch"
# B3 — dispatch is off the READY FRONTIER, not a wave.
grep -qiE 'ready.?frontier' "$BUILD" \
  || fail "idc-build.md must dispatch off the ready frontier (not the active wave)"
# B4 — AREA-PACKING: one worker per matrix-carved disjoint surface area.
grep -qiE 'area.?pack' "$BUILD" \
  || fail "idc-build.md must describe area-packing dispatch (one triplet per disjoint surface area)"
# B5 — readiness includes a FREE file surface (the area-packing half of 'ready').
grep -qiE 'surface is free' "$BUILD" \
  || fail "idc-build.md must define ready as blocked_by-Done AND its file surface is free"
# B6 — a freed sous chef immediately pulls the NEXT READY AREA (continuous kitchen, no barrier wait).
grep -qiE 'next ready (area|surface)' "$BUILD" \
  || fail "idc-build.md must have a freed sous chef immediately take the next ready area (continuous, no wave barrier)"
grep -qiE 'freed|frees up' "$BUILD" \
  || fail "idc-build.md must describe a FREED worker pulling the next ready area (the area-packing pull)"
# B7 — Wave is demoted: it no longer gates dispatch, only scopes acceptance reporting.
grep -qiE 'wave no longer gates dispatch' "$BUILD" \
  || fail "idc-build.md must state Wave no longer gates dispatch (retained only as acceptance-gate reporting scope)"
# B8 — the acceptance gate RETRIGGERS at per-area finish + convergence checkpoints (added, not only wave-close).
grep -qiE 'per-area' "$BUILD" \
  || fail "idc-build.md must retrigger the acceptance gate at per-area finish (#76 added retrigger point)"
grep -qiE 'convergence' "$BUILD" \
  || fail "idc-build.md must retrigger the acceptance gate at convergence checkpoints (#76 added retrigger point)"
# B9 — belt-and-suspenders: #76 ADDED retrigger points; it did NOT remove the gate logic.
grep -qiE 'idc_acceptance_check\.py' "$BUILD" \
  || fail "idc-build.md must still run idc_acceptance_check.py (the gate logic is built ON, not replaced)"
grep -qiE 'every wave-close' "$BUILD" \
  || fail "idc-build.md must retain the every-wave-close acceptance retrigger (preserved from 3.0.x)"

echo "PASS: ready-frontier dispatch is wave-independent (later-wave dependent dispatches with an early-wave issue); idc-build.md describes ready-frontier + area-packing + continuous pull + per-area/convergence retrigger; acceptance gate preserved"
