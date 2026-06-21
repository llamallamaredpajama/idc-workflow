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

# ---- P0-1: no-ask invariant — the sanctioned stops are exhaustive (autorun audit Defect 1) ------
# Autorun's first live run improvised four AskUserQuestion gates its playbook never sanctioned. The
# fix is an explicit enumerated invariant in BOTH the autorun and build agent playbooks: never ask
# how-autonomous, never re-confirm chosen scope, never turn a deterministic drain:continue into a
# question, never call AskUserQuestion. Removing the clause from EITHER agent file fails this red.
BUILD="$PLUGIN/agents/idc-build.md"
[ -f "$BUILD" ] || fail "agents/idc-build.md missing"
for f in "$AUTORUN" "$BUILD"; do
  bn="$(basename "$f")"
  grep -qiE 'no-ask invariant' "$f" \
    || fail "$bn must carry the enumerated no-ask invariant (P0-1)"
  grep -qiE 'never[[:space:]]+calls?[[:space:]]+.?AskUserQuestion' "$f" \
    || fail "$bn no-ask invariant must forbid calling AskUserQuestion (P0-1)"
  grep -qiE 'how autonomous' "$f" \
    || fail "$bn no-ask invariant must forbid asking how-autonomous-to-be (P0-1)"
  # the no-ask invariant must name the operator-decision strategic gate as a SANCTIONED board-state
  # gate — else a model treats it as unsanctioned and may ignore it or improvise a prompt (Codex review)
  grep -qiE 'operator-decision' "$f" \
    || fail "$bn no-ask invariant must name the operator-decision strategic gate as sanctioned (else it reads as unsanctioned)"
done

# ---- L2-1: the exit report's working-tree claim is sourced from a FINAL post-build git status ---
# The L2 e2e exit report under-counted untracked artifacts (claimed 2, actual 10) because the
# working-tree view was a session-START snapshot taken before the build lane wrote files. The exit
# report must reconcile the tree at EXIT (post-build), not from a stale snapshot.
grep -qiE 'post-build .*git status' "$AUTORUN" \
  || fail "idc-autorun.md exit report must source its working-tree state from a post-build git status, not a start-of-run snapshot (L2-1)"
grep -qiE 'start-of-run snapshot' "$AUTORUN" \
  || fail "idc-autorun.md must warn against a start-of-run working-tree snapshot in the exit report (L2-1)"
# M1 (L2 review): commands/autorun.md carries the SAME post-build reconciliation prose — lock it too
# so the command entry can't silently diverge from the (authoritative) agent file it delegates to.
CMD="$PLUGIN/commands/autorun.md"
[ -f "$CMD" ] || fail "commands/autorun.md missing"
grep -qiE 'post-build .*git status' "$CMD" \
  || fail "commands/autorun.md exit report must source its working-tree state from a post-build git status (L2-1 parity)"
grep -qiE 'start-of-run snapshot' "$CMD" \
  || fail "commands/autorun.md must warn against a start-of-run working-tree snapshot in the exit report (L2-1 parity)"

echo "PASS: autorun drain predicate green; exit report reconciles the working tree post-build, agent + command in parity (L2-1)"
