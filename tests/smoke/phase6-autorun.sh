#!/bin/bash
# Phase 6 smoke — Autorun's drain predicate (the one-shot exit condition):
#   eligible build work = Status=Todo issues that are NOT operator-action gate issues and
#   whose every blocked-by upstream is Done. Autorun keeps draining while eligible work
#   exists and exits when nothing actionable remains (only Done + PRD-gated Blocked + the
#   operator's own gate issue left).
# Failing-test-first: fails until scripts/idc_autorun_drain.py exists.
#
# Usage: bash tests/smoke/phase6-autorun.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
T="$WORK/TRACKER.md"
fail() { echo "FAIL: $1"; exit 1; }
drain() { python3 "$DRAIN" --tracker "$T"; }

[ -f "$DRAIN" ] || fail "autorun drain helper not found at $DRAIN (not implemented yet)"

# empty board -> nothing actionable -> drain complete
python3 "$TRK" --tracker "$T" init
drain | grep -q "^drain: complete$" || fail "empty board should drain complete"

# add a buildable Todo issue -> actionable
a=$(python3 "$TRK" --tracker "$T" create --title "Build me" --wave "Wave 1")
drain | grep -q "^drain: continue$" || fail "a Todo issue should make autorun continue"
drain | grep -qE "^eligible:.* $a( |$)" || fail "issue $a should be eligible"

# add the operator gate + a PRD-dependent issue blocked behind it
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] PRD change — x")
b=$(python3 "$TRK" --tracker "$T" create --title "PRD-dependent")
python3 "$TRK" --tracker "$T" block --num "$b" --by "$gate" >/dev/null
# still actionable because of issue a; gate + blocked b are NOT eligible
drain | grep -q "^drain: continue$" || fail "still actionable while issue a is Todo"
drain | grep -qE "(^| )$gate( |$)" && fail "the operator-action gate must not be eligible build work"
drain | grep -qE "(^| )$b( |$)" && fail "a Blocked PRD-dependent issue must not be eligible"

# build issue a to Done -> only the gate (operator) + Blocked b remain -> drain complete
python3 "$TRK" --tracker "$T" claim --num "$a" --agent idc-implementer >/dev/null
python3 "$TRK" --tracker "$T" close --num "$a" >/dev/null
drain | grep -q "^drain: complete$" || fail "with only a gate + a Blocked dependent left, autorun should exit (complete)"

echo "PASS: autorun drain predicate (eligible build work vs PRD-gated/operator-only) green"
