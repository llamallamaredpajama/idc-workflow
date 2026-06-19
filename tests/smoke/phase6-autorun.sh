#!/bin/bash
# Phase 6 smoke — Autorun's drain predicate (the one-shot exit condition) and its v3 autonomy
# boundary: with the gate at the END of Think, Autorun only decomposes/builds APPROVED
# considerations and treats an OPEN Think PR exactly like an open requirements gate (report + skip).
#   eligible build work = Status=Todo issues that are NOT operator-action gate issues, NOT an
#   upstream pointer (Stage=Consideration/Planning — a consideration pending admission behind the
#   Think PR), and whose every blocked-by upstream is Done. Autorun keeps draining while eligible
#   work exists and exits when nothing actionable remains (only Done + requirements-gated Blocked +
#   the operator's own gate issue + un-admitted considerations left).
# Failing-test-first: fails until scripts/idc_autorun_drain.py exists.
#
# Usage: bash tests/smoke/phase6-autorun.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
AUTORUN="$PLUGIN/agents/idc-autorun.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
T="$WORK/TRACKER.md"
fail() { echo "FAIL: $1"; exit 1; }
drain() { python3 "$DRAIN" --tracker "$T"; }

[ -f "$DRAIN" ] || fail "autorun drain helper not found at $DRAIN (not implemented yet)"

# empty board -> nothing actionable -> drain complete
python3 "$TRK" --tracker "$T" init || fail "tracker init failed"
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

# add a consideration pointer that is Todo but NOT YET ADMITTED (an open Think PR / pending the
# end-of-Think gate). Build must NEVER scoop it — Autorun only builds APPROVED considerations.
# This is the guard that fails red if the drain predicate stops skipping a Stage=Consideration
# pointer (i.e. lets Autorun proceed past an open Think PR).
c=$(python3 "$TRK" --tracker "$T" create --title "Pending consideration (open Think PR)" --stage Consideration)
drain | grep -qE "(^| )$c( |$)" && fail "a Stage=Consideration pointer (open Think PR / pending admission) must not be eligible build work"

# build issue a to Done -> only the gate (operator) + Blocked b + the un-admitted consideration
# remain -> drain complete (nothing the autorun may build without operator admission)
python3 "$TRK" --tracker "$T" claim --num "$a" --agent idc-implementer >/dev/null
python3 "$TRK" --tracker "$T" close --num "$a" >/dev/null
drain | grep -q "^drain: complete$" || fail "with only a gate + a Blocked dependent + a pending consideration left, autorun should exit (complete)"

# ---- prose invariant: the planning lane only plans APPROVED considerations (v3) ---------------
[ -f "$AUTORUN" ] || fail "agents/idc-autorun.md missing"
grep -qiE 'Think PR' "$AUTORUN" \
  || fail "idc-autorun.md must treat an open Think PR like an open gate (report + skip) — the planning lane only plans approved considerations"
grep -qiE 'approved consideration' "$AUTORUN" \
  || fail "idc-autorun.md must state Autorun only decomposes/builds approved considerations"

# ---- L2-1: the exit report's working-tree claim is sourced from a FINAL post-build git status ---
# The L2 e2e exit report under-counted untracked artifacts (claimed 2, actual 10) because the
# working-tree view was a session-START snapshot taken before the build lane wrote files. The exit
# report must reconcile the tree at EXIT (post-build), not from a stale snapshot.
grep -qiE 'post-build .*git status' "$AUTORUN" \
  || fail "idc-autorun.md exit report must source its working-tree state from a post-build git status, not a start-of-run snapshot (L2-1)"
grep -qiE 'start-of-run snapshot' "$AUTORUN" \
  || fail "idc-autorun.md must warn against a start-of-run working-tree snapshot in the exit report (L2-1)"

echo "PASS: autorun drain predicate green; exit report reconciles the working tree post-build (L2-1)"
