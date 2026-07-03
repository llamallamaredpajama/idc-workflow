#!/bin/bash
# drain-recirc-pending.sh — the three-conjunct fixpoint verdict of idc_autorun_drain.py.
#
# The autorun drain is not at a whole-pipe fixpoint just because the BUILD lane is drained: a
# Stage=Recirculation ∧ Status=Todo inbox ticket (scope discovered mid-build, awaiting
# /idc:recirculate) or an admitted-but-unplanned Stage=Consideration ∧ Status=Todo pointer still
# owes upstream work. This scenario pins the deterministic signal: when the build lane is otherwise
# drained (no eligible build work) but either inbox is non-empty, the drain prints
# `drain: recirc-pending` and exits 4 (a DISTINCT non-zero code — 0=complete/continue, 2=unknown,
# 3=rate-limited). It also pins the two always-on count lines (`recirc_inbox:` /
# `unplanned_considerations:`) and the back-compat direction: a truly empty inbox still drains
# `complete` exit 0.
#
# Filesystem-backed (hermetic, no gh). Auto-discovered by the governance lane (phase-governance.sh);
# also runnable standalone. Red-when-broken: force the recirc-pending branch off (or the count to 0)
# in idc_autorun_drain.py and this scenario FAILs.
#
# Usage: bash tests/smoke/governance/drain-recirc-pending.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

DRAIN="$GOV_PLUGIN/scripts/idc_autorun_drain.py"
[ -f "$DRAIN" ] || fail "idc_autorun_drain.py not found at $DRAIN"

# run_drain <tracker> -> captures stdout in $OUT and the exit code in $RC (never aborts under set -e-less).
run_drain() { OUT="$(python3 "$DRAIN" --tracker "$1" 2>/dev/null)"; RC=$?; }

# ---- 1. a Stage=Recirculation ∧ Status=Todo inbox ticket -> drain: recirc-pending, exit 4 --------
# The build lane is empty (no Buildable Todo), so the only reason the pipe is not drained is the
# Recirculation inbox ticket. Red-when-broken: skip the recirc-pending branch and this drains
# `complete` exit 0 (the false fixpoint this guards).
T1="$(gov_new_tracker)" || fail "gov_new_tracker failed (case 1)"
trap 'rm -rf "$(dirname "$T1")"' EXIT
r="$(gov_seed_item "$T1" --title 'recirc: discovered mid-build scope' --stage Recirculation --status Todo)" \
  || fail "could not seed the Recirculation inbox ticket"
run_drain "$T1"
[ "$RC" -eq 4 ] \
  || fail "a Stage=Recirculation ∧ Status=Todo inbox ticket (no eligible build work) must exit 4, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: recirc-pending" \
  || fail "must print 'drain: recirc-pending' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "recirc_inbox: 1" \
  || fail "must print 'recirc_inbox: 1' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
# the ticket is NEVER eligible build work (the glass wall holds through the new verdict)
printf '%s\n' "$OUT" | grep -qE "^eligible:.*\b$r\b" \
  && fail "the Recirculation ticket $r must NEVER be eligible build work (out: $(printf '%s' "$OUT" | tr '\n' '|'))"

# ---- 2. an admitted-but-unplanned Stage=Consideration ∧ Status=Todo pointer -> recirc-pending, 4 --
# The second conjunct: a consideration sitting in the planning inbox (Todo) also blocks the
# fixpoint. Red-when-broken: drop the Consideration arm and this drains `complete` exit 0.
T2="$(gov_new_tracker)" || fail "gov_new_tracker failed (case 2)"
trap 'rm -rf "$(dirname "$T1")" "$(dirname "$T2")"' EXIT
c="$(gov_seed_item "$T2" --title 'consideration: admitted, not yet planned' --stage Consideration --status Todo)" \
  || fail "could not seed the Consideration pointer"
run_drain "$T2"
[ "$RC" -eq 4 ] \
  || fail "a Stage=Consideration ∧ Status=Todo pointer (no eligible build work) must exit 4, got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: recirc-pending" \
  || fail "case 2 must print 'drain: recirc-pending' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "unplanned_considerations: 1" \
  || fail "case 2 must print 'unplanned_considerations: 1' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"

# ---- 3. BACK-COMPAT (red-when-broken the other direction): an EMPTY inbox still drains complete ---
# A fresh board with no Recirculation/Consideration Todo item must STILL report `drain: complete`
# exit 0 and both counts 0 — the new verdict must not fire on a truly drained pipe.
T3="$(gov_new_tracker)" || fail "gov_new_tracker failed (case 3)"
trap 'rm -rf "$(dirname "$T1")" "$(dirname "$T2")" "$(dirname "$T3")"' EXIT
run_drain "$T3"
[ "$RC" -eq 0 ] \
  || fail "an empty inbox must still exit 0 (drain: complete), got $RC (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "drain: complete" \
  || fail "an empty inbox must still print 'drain: complete' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "recirc_inbox: 0" \
  || fail "an empty inbox must print 'recirc_inbox: 0' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -qx "unplanned_considerations: 0" \
  || fail "an empty inbox must print 'unplanned_considerations: 0' (out: $(printf '%s' "$OUT" | tr '\n' '|'))"

echo "PASS: three-conjunct fixpoint — a Recirculation ∧ Todo inbox ticket AND a Consideration ∧ Todo pointer each drive drain: recirc-pending exit 4 (with always-on recirc_inbox:/unplanned_considerations: counts); an empty inbox still drains complete exit 0; the glass wall holds"
