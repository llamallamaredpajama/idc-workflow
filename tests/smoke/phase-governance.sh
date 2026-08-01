#!/bin/bash
# idc-assert-class: behavior
# phase-governance.sh — the glob-driven governance-eval lane (deterministic-core refactor, Phase 0).
#
# The governance lane holds seeded-board scenarios that assert IDC's DETERMINISTIC signals are
# truthful — each is red-when-broken (break the enforcing line → the scenario FAILs). Rather than
# hardcode each scenario into run-all.sh's phase list (4 parallel authors would collide on that one
# file), this ONE phase file AUTO-DISCOVERS every `tests/smoke/governance/*.sh` scenario. A new unit
# just drops a uniquely-named scenario file into governance/ — zero edits here, zero edits to
# run-all.sh.
#
# What counts as a runnable scenario: every `governance/*.sh` EXCEPT `lib.sh` (the sourced seed
# helper) and any `_*.sh` (underscore-prefixed helpers, incl. the self-check run separately below).
#
# Honesty guard (an empty lane that silently passes is a false green): the permanent self-check
# `governance/_lane-selfcheck.sh` is MANDATORY and is run first — it proves the harness executes and
# can distinguish pass from fail. If it is missing or fails, this phase FAILs regardless of the rest.
# Zero *real* scenarios is tolerated (the state right after the lane is first scaffolded) ONLY because
# the self-check still proves the lane works; it is never a silent empty pass.
#
# Exit non-zero if the self-check is missing/fails OR any discovered scenario fails.
#
# ── FIXTURE RULES (read before adding or editing a scenario) ─────────────────────────────────────
# 1. RED-WHEN-BROKEN, PROVEN. A scenario is not "coverage" until it has been observed to FAIL with
#    the line it guards deleted. Record that probe in the file header, in terms a reader can re-run.
#
# 2. A FAIL-CLOSED / SKIP / REFUSE ASSERTION MUST KEY ON A DISCRIMINATING ARTIFACT — an artifact
#    ONLY that path produces (a unique stderr sentence, a distinct exit code) — never on the outcome
#    the guarded path and some ordinary path both produce. And it MUST carry a POSITIVE CONTROL
#    showing that artifact is ABSENT off the guarded path.
#    Use `. "$(dirname "$0")/../lib/fail-closed.sh"` and `assert_fail_closed`, which will not run
#    without both. This is a rule, not a preference: the same defect — a negative assertion whose
#    SETUP NEVER REACHES THE GUARD — has shipped SEVEN times here. Two of them looked like this:
#    hiding TRACKER.md to simulate an unreadable board (the filesystem backend degrades a missing
#    tracker to an EMPTY board, so the fail-closed handler was never entered and the test passed on
#    the ordinary refusal), and a whole suppression feature that could be hard-wired off with all
#    150 scenarios still green. The sibling lesson lives in tests/smoke/lib/stderr_census.py: a
#    guard whose real-tree answer is silence needs a PLANTED POSITIVE EXAMPLE.
#
# 3. NO VACUOUS SKIPS. Never wrap assertions in `if [ -f "$HELPER" ]; then … fi` — the day the path
#    is wrong the assertions vanish and the scenario still prints PASS. Hard-guard every input at the
#    top with `fc_require_file <path> <what>` (or `[ -f … ] || fail`).
#
# 4. NO SELF-SATISFYING GREPS. An assertion whose pattern can match the fixture's own filename, temp
#    path, input, or scaffolding proves nothing. `assert_fail_closed` refuses such a marker outright.
#
# 5. BOUND EVERY PROBE. A neutered bound HANGS rather than reddens, and a hang reads as a slow pass.
#    Run each probe under an explicit `timeout` and treat exit 124 as RED (`assert_fail_closed`
#    does this for you).
#
# Usage: bash tests/smoke/phase-governance.sh   (exit 0 = all green)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GOV="$HERE/governance"

fails=0

# --- honesty anchor: the self-check is mandatory ---------------------------------------------------
SELFCHECK="$GOV/_lane-selfcheck.sh"
if [ ! -f "$SELFCHECK" ]; then
  echo "  FAIL  governance/_lane-selfcheck.sh (MISSING — the lane cannot verify itself; refusing a silent empty pass)"
  echo "governance lane: 1 FAILED (self-check missing)"
  exit 1
fi
if out="$(bash "$SELFCHECK" 2>&1)"; then
  echo "  PASS  governance/_lane-selfcheck.sh"
else
  echo "  FAIL  governance/_lane-selfcheck.sh"
  printf '%s\n' "$out" | sed 's/^/        /'
  fails=$((fails + 1))
fi

# --- discovered scenarios (every governance/*.sh except lib.sh and _*.sh) --------------------------
real=0
for s in "$GOV"/*.sh; do
  [ -e "$s" ] || continue                     # no matches → the glob stays literal; skip it
  base="$(basename "$s")"
  case "$base" in
    lib.sh) continue ;;                       # sourced helper, not a scenario
    _*)     continue ;;                       # underscore-prefixed helper (incl. the self-check)
  esac
  real=$((real + 1))
  if out="$(bash "$s" 2>&1)"; then
    echo "  PASS  governance/$base"
  else
    echo "  FAIL  governance/$base"
    printf '%s\n' "$out" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
done

echo "------------------------------------------------"
if [ "$real" -eq 0 ]; then
  echo "governance lane: only the self-check present (no real scenarios yet) — tolerated (lane proven working)"
fi
if [ "$fails" -eq 0 ]; then
  echo "governance lane: ALL GREEN ($real real scenario(s) + self-check)"
  exit 0
fi
echo "governance lane: $fails FAILED"
exit 1
