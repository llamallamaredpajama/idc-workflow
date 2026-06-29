#!/bin/bash
# Phase 6 smoke — Autorun AUTONOMY: drain EVERYTHING, no mid-drain asks, one staffing gate only
# when the estimate is large, and never self-narrow to a phase. Fixes the motivating live bug: a
# real `/idc:autorun` full-drain stopped to ask questions AND narrowed itself to a single phase.
#
# Two halves, both red-when-broken:
#   A. BEHAVIOR — `idc_autorun_drain.py --width` adds a `width:` line (the max-useful parallelism =
#      the sous chefs the current frontier staffs); the ready set itself is the always-printed
#      `eligible:` line. Width is the SAME eligibility predicate as `eligible:` (blocked_by-aware,
#      Wave- and pointer-ignoring), just counted — so a blocked dependent, a glass-wall
#      Consideration/Planning pointer, and an [operator-action] gate issue never inflate it, and a
#      different Wave never partitions it. Default (no --width) output stays byte-identical (existing
#      consumers unaffected).
#   B. DOCTRINE — agents/idc-autorun.md + commands/autorun.md compute a staffing estimate, run
#      fully autonomous at/below the configurable threshold (WORKFLOW-config.yaml::
#      autorun.staffing_gate_threshold, default 10 sous chefs), emit EXACTLY ONE launch-time
#      "~N sous chefs / ~M subagents across K windows — go / scope down?" gate above it, then drain
#      ALL phases; never self-narrow (phase-scoping is the operator's explicit /idc:build --phase
#      flag); and wrap the drain in /loop so it resumes from live board state across usage windows.
#
# Usage: bash tests/smoke/phase6-autorun-autonomy.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DRAIN="$PLUGIN/scripts/idc_autorun_drain.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
AUTORUN="$PLUGIN/agents/idc-autorun.md"
CMD="$PLUGIN/commands/autorun.md"
WC="$PLUGIN/templates/WORKFLOW-config.yaml"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
T="$WORK/TRACKER.md"
fail() { echo "FAIL: $1"; exit 1; }
frontier() { python3 "$DRAIN" --tracker "$T" --width; }

[ -f "$DRAIN" ] || fail "autorun drain helper not found at $DRAIN"
[ -f "$TRK" ]   || fail "tracker helper not found at $TRK"

# ---- A. ready-frontier width = the unblocked eligible cardinality --------------------------------
# Each board state captures the drain output ONCE (consume, don't re-run the helper per assertion).
# Empty board: zero ready -> width: 0.
python3 "$TRK" --tracker "$T" init >/dev/null || fail "tracker init failed"
out="$(frontier)"
printf '%s\n' "$out" | grep -qx "width: 0" || fail "an empty board must report 'width: 0' (got: $(printf '%s' "$out" | tr '\n' '|'))"

# Three INDEPENDENT buildable issues in THREE DIFFERENT waves. Width ignores Wave: all three are
# ready in parallel, so width: 3 (not 1-per-wave). This is the anti-self-narrow signal at the
# script layer — the head chef may staff the whole antichain, not one wave at a time.
w1=$(python3 "$TRK" --tracker "$T" create --title "build one"   --wave "Wave 1")
w2=$(python3 "$TRK" --tracker "$T" create --title "build two"   --wave "Wave 2")
w3=$(python3 "$TRK" --tracker "$T" create --title "build three" --wave "Wave 3")
out="$(frontier)"
printf '%s\n' "$out" | grep -qx "width: 3" || fail "three independent ready issues across waves must report 'width: 3' (Wave-ignoring) (got: $(printf '%s' "$out" | tr '\n' '|'))"
# the ready frontier (eligible: set) lists every ready issue number
rf="$(printf '%s\n' "$out" | grep '^eligible:')"
for n in "$w1" "$w2" "$w3"; do
  printf '%s\n' "$rf" | grep -qwF "$n" || fail "ready frontier (eligible:) must list ready issue $n (got: '$rf')"
done

# A blocked DEPENDENT must NOT widen the frontier: width stays 3, not 4. (Red-when-broken: a width
# that counts blocked work, or ignores blocked_by, prints 4 here.)
b4=$(python3 "$TRK" --tracker "$T" create --title "depends on one")
python3 "$TRK" --tracker "$T" block --num "$b4" --by "$w1" >/dev/null
out="$(frontier)"
printf '%s\n' "$out" | grep -qx "width: 3" || fail "a blocked dependent must NOT inflate the frontier width (must stay 3, got: $(printf '%s' "$out" | tr '\n' '|'))"

# A glass-wall Consideration pointer (open Think PR / pending admission) must NOT inflate width.
cptr=$(python3 "$TRK" --tracker "$T" create --title "pending consideration" --stage Consideration)
out="$(frontier)"
printf '%s\n' "$out" | grep -qx "width: 3" || fail "a Stage=Consideration pointer must NOT inflate the frontier width (glass wall; must stay 3, got: $(printf '%s' "$out" | tr '\n' '|'))"

# A glass-wall Planning pointer (a consideration being planned, not yet buildable) must NOT inflate
# width either — same upstream-pointer exclusion as Consideration. (Red-when-broken: drop the
# Planning arm of the stage filter and width prints 4.)
pptr=$(python3 "$TRK" --tracker "$T" create --title "in planning" --stage Planning)
out="$(frontier)"
printf '%s\n' "$out" | grep -qx "width: 3" || fail "a Stage=Planning pointer must NOT inflate the frontier width (glass wall; must stay 3, got: $(printf '%s' "$out" | tr '\n' '|'))"

# An [operator-action] gate issue is the operator's own todo, not build work — it must NOT inflate
# width. (Red-when-broken: drop the title-prefix exclusion and width prints 4.)
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] approve the thing")
out="$(frontier)"
printf '%s\n' "$out" | grep -qx "width: 3" || fail "an [operator-action] gate issue must NOT inflate the frontier width (operator's todo, not build work; must stay 3, got: $(printf '%s' "$out" | tr '\n' '|'))"

# Back-compat: the DEFAULT invocation (no --width) must NOT print the width: line, so the existing
# drain consumers see byte-identical output. (Locks the flag-gating; ready-frontier: never existed.)
python3 "$DRAIN" --tracker "$T" | grep -qE '^width:' \
  && fail "default drain output (no --width) must NOT emit the width: line (back-compat with existing consumers)"
python3 "$DRAIN" --tracker "$T" | grep -q '^drain: continue$' \
  || fail "default drain output must still report drain: continue while ready work exists"

# ---- B1. configurable staffing threshold in WORKFLOW-config.yaml ---------------------------------
[ -f "$WC" ] || fail "templates/WORKFLOW-config.yaml missing"
grep -qE '^autorun:[[:space:]]*$' "$WC" \
  || fail "WORKFLOW-config.yaml must carry a top-level 'autorun:' section for the staffing gate"
grep -qE '^[[:space:]]+staffing_gate_threshold:[[:space:]]*10\b' "$WC" \
  || fail "WORKFLOW-config.yaml autorun: must define 'staffing_gate_threshold: 10' (the configurable default)"

# ---- B2. doctrine parity across the agent playbook AND the command entry -------------------------
# Both files must carry the SAME autonomy doctrine (the command delegates to the agent, but the
# operator may read either, so neither may silently diverge — same lock the L2-1 parity uses).
[ -f "$AUTORUN" ] || fail "agents/idc-autorun.md missing"
[ -f "$CMD" ]     || fail "commands/autorun.md missing"
for f in "$AUTORUN" "$CMD"; do
  bn="$(basename "$f")"

  # staffing estimate framed in sous chefs, read from the configurable threshold (not hardcoded)
  grep -qiE 'staffing estimate' "$f" \
    || fail "$bn must compute a staffing estimate before draining"
  grep -qiE 'sous.?chef' "$f" \
    || fail "$bn must frame the staffing estimate in sous chefs"
  grep -qiE 'staffing_gate_threshold' "$f" \
    || fail "$bn must read the threshold from WORKFLOW-config.yaml::autorun.staffing_gate_threshold (configurable, not hardcoded)"

  # at/below threshold -> fully autonomous, NO launch gate
  grep -qiE 'no (launch )?gate|fully autonomous|without (a|any) (launch )?gate' "$f" \
    || fail "$bn must state that at/below the threshold autorun runs with NO launch gate (fully autonomous)"

  # above threshold -> EXACTLY ONE launch-time gate with the 'go / scope down' shape
  grep -qiE 'exactly one|a single|one launch' "$f" \
    || fail "$bn must state EXACTLY ONE launch-time gate above the threshold"
  grep -qiE 'scope down' "$f" \
    || fail "$bn launch-time gate must offer 'go / scope down' (the >threshold cost confirmation)"
  # the two gate answers must NOT be conflated: 'scope down' means autorun STANDS DOWN (the operator
  # then runs an explicit /idc:build --phase N), it does NOT keep draining the whole repo. Guards the
  # contradiction "scope down ... Either answer, autorun then runs to completion".
  grep -qiE 'stands? down|does not drain|hand(s)? off' "$f" \
    || fail "$bn scope-down branch must state autorun STANDS DOWN / does not drain (not 'runs to completion either way')"
  grep -qiE 'either answer.{0,60}runs? to completion' "$f" \
    && fail "$bn must not claim autorun runs to completion regardless of the answer (contradicts 'scope down')"

  # never self-narrow; phase-scoping is the operator's explicit flag
  grep -qiE 'never self-narrow|not autorun.{0,40}self-narrow|never narrows? (itself )?to a (single )?phase' "$f" \
    || fail "$bn must forbid autorun self-narrowing to a phase"
  grep -qiE '/idc:build --phase' "$f" \
    || fail "$bn must state phase-scoping is the operator's explicit /idc:build --phase choice"

  # drain wrapped in /loop, resumes from live board state across usage windows
  grep -qiE '/loop' "$f" \
    || fail "$bn must wrap the drain in /loop"
  grep -qiE 'usage.window|across (usage )?windows|resume[s]? from (the )?(live )?board' "$f" \
    || fail "$bn must state the /loop drain resumes from live board state across usage windows"

  # --- pipe-ORDER doctrine: full-pipe, never a build-only loop -------------------------------------
  # The asserts above lock the AUTONOMY doctrine (no-ask / self-narrow / staffing) but nothing pinned
  # that the file still tells the executing agent (any runtime — incl. a cold Codex thread reading
  # only this prose) to drain the Recirculation inbox and plan approved considerations BEFORE
  # building. If a future edit quietly dropped those upstream stages, autorun would silently degrade
  # to a build-only drain (the build-lane helper is build-only by construction — scripts/
  # idc_autorun_drain.py:24) and no test would catch it. Flatten newlines first (markdown wraps),
  # then assert the canonical ordering sentence — "recirculate ... then plan ... then ... Buildable"
  # — survives IN ORDER. The [^.]* arms keep all three stages inside ONE sentence so scattered,
  # out-of-order mentions can't satisfy it. Red-when-broken: drop the recirculate or plan stage and
  # the ordered match fails.
  flat="$(tr '\n' ' ' < "$f" | tr -s ' ')"
  printf '%s' "$flat" | grep -qiE 'recirculate[^.]*recirculation inbox[^.]*then[^.]*plan[^.]*consideration[^.]*then[^.]*(drain|build)[^.]*buildable' \
    || fail "$bn must state the full-pipe ORDER (recirculate the inbox, THEN plan approved considerations, THEN build the Buildable waves) — the build-only-regression guard"
  # the two upstream stages must each survive as named lanes/steps (the half a build-only drain skips)
  grep -qiE 'recirculation intake' "$f" \
    || fail "$bn must carry a Recirculation-intake stage (top of the pipe, before any build work)"
  grep -qiE 'planning lane' "$f" \
    || fail "$bn must carry a Planning lane that decomposes approved considerations before the build lane"
  # the drain helper must be framed as the BUILD lane's EXIT CONDITION — never the whole autorun loop
  printf '%s' "$flat" | grep -qiE 'exit condition[^.]*(deterministic )?drain helper' \
    || fail "$bn must frame the drain helper as the build lane's exit condition, not the whole autorun loop"
done

# The launch gate is the ONE sanctioned PRE-drain ask; the no-ask invariant still forbids MID-drain
# asks. Both must coexist in the agent playbook (the bug was mid-drain asks + self-narrowing).
grep -qiE 'no-ask invariant' "$AUTORUN" \
  || fail "agents/idc-autorun.md must retain the no-ask invariant (mid-drain asks stay forbidden)"
grep -qiE 'mid-?drain' "$AUTORUN" \
  || fail "agents/idc-autorun.md must scope the AskUserQuestion prohibition to mid-drain (the launch gate is the one pre-drain exception)"

# --- the drain helper's OWN docstring must scope it to the build lane, not the whole autorun -------
# Defense for the other reader: an agent that reads scripts/idc_autorun_drain.py directly (a cold
# Codex thread, a new contributor) must not mistake the build-lane exit predicate for the full
# autorun loop and wire it as the top-level drain. The docstring explicitly disclaims the planning
# lane ("this helper covers the build lane / board-exit half"); pin that so an edit can't erase it.
grep -qiE 'this helper covers the build lane' "$DRAIN" \
  || fail "scripts/idc_autorun_drain.py docstring must scope itself to the build lane / board-exit (not the whole autorun loop)"

echo "PASS: autorun drains everything — full-pipe ORDER (recirculate→plan→build) locked in both the command and the playbook; the drain helper is the build-lane exit only; frontier width is the eligible antichain (Wave/pointer/blocked-aware); staffing gate is one pre-drain ask above a configurable threshold; never self-narrows; /loop-resumable"
