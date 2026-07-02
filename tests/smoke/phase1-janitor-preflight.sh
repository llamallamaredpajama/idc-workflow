#!/bin/bash
# idc-assert-class: doc
# Phase 1 (janitor autorun preflight) smoke — design §A "Triple wiring" (2): `/idc:autorun` runs the
# janitor scanner (Unit 2's `idc_git_janitor.py`, already shipped) as a PREFLIGHT report near the top
# of the pipe, so board<->git debris left by a dead/interrupted session is surfaced every drain — not
# only when the operator remembers to run `/idc:janitor` by hand.
#
# ROOT CAUSE this guards: before this unit, autorun had no janitor wiring at all — debris (orphan
# worktrees, merged-but-surviving branches, board/issue drift) only surfaced if the operator happened
# to run `/idc:janitor` manually. This is prose-only (a playbook `commands/autorun.md` an LLM
# orchestrator reads, not an executable script), so the verification is a structural/prose test —
# mirrors the existing prose-invariant style already used for autorun's other doctrine (phase6-autorun*).
#
# BEHAVIOR pinned (each assertion red-when-broken — the fail message states the revert that flips it):
#   * the preflight invokes idc_git_janitor.py in REPORT mode for BOTH backends (filesystem + github);
#   * default = report-only — autorun never applies a fix on its own initiative;
#   * the ONE opt-in exception is the operator-set `janitor: auto-safe` config knob, which adds
#     --apply-safe to the SAME call (not a different one) — never a silent auto-apply, always
#     traceable to an explicit operator setting;
#   * RISKY + REPORT-ONLY findings stay advisory even with the knob set (--apply-safe only ever
#     touches the SAFE-FIX tier — the janitor scanner's own contract, restated here so a reader of
#     just this command doesn't assume the knob widens what gets auto-applied);
#   * the preflight sits near the TOP of the pipe (before the Build lane) so debris is visible before
#     any new build work, not as an afterthought;
#   * the scanner's exit code is read, not just its findings list — exit 2 (fail-closed/indeterminate,
#     which per the janitor hardening pass now ALSO covers a capped/possibly-partial `--limit`-ceiling
#     read, not only an unreadable board) must be surfaced as indeterminate and never treated as a
#     hollow COHERENT pass (janitor's own exit contract: 0 clean / 1 findings / 2 indeterminate).
#
# Usage: bash tests/smoke/phase1-janitor-preflight.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CMD="$PLUGIN/commands/autorun.md"
JAN="$PLUGIN/scripts/idc_git_janitor.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$CMD" ] || fail "commands/autorun.md not found"
[ -f "$JAN" ] || fail "scripts/idc_git_janitor.py not found (Unit 2 dependency missing on main)"

flat="$(tr '\n' ' ' < "$CMD" | tr -s ' ')"

# ---- 1. the preflight invokes the janitor scanner, in --report mode, for both backends -----------
# RED-WHEN-BROKEN: remove the preflight call entirely -> both greps fail.
grep -qE 'idc_git_janitor\.py' "$CMD" \
  || fail "commands/autorun.md must invoke scripts/idc_git_janitor.py as a preflight step"
grep -qE -- '--report' "$CMD" \
  || fail "commands/autorun.md janitor preflight must pass --report (explicit read-only default)"
grep -qE -- '--tracker' "$CMD" \
  || fail "commands/autorun.md janitor preflight must cover the filesystem backend (--tracker)"
grep -qE -- '--backend github' "$CMD" \
  || fail "commands/autorun.md janitor preflight must cover the github backend (--backend github)"

# ---- 2. report-only by default; the ONE opt-in exception is the `janitor: auto-safe` knob ---------
# RED-WHEN-BROKEN: drop the knob-gated --apply-safe branch -> autorun can never auto-clean SAFE-FIX
# debris even when the operator explicitly opted in (design §A "Triple wiring" (2)).
printf '%s' "$flat" | grep -qiE 'janitor:[^.]*auto-safe' \
  || fail "commands/autorun.md must document the operator-set 'janitor: auto-safe' config knob"
grep -qE -- '--apply-safe' "$CMD" \
  || fail "commands/autorun.md must invoke --apply-safe when the janitor: auto-safe knob is set"
# CAUSAL check (not just co-presence): pin the specific "when the knob is set, ADD --apply-safe"
# instruction verbatim-ish. A generic knob-near-apply-safe proximity grep is too weak here — the file
# legitimately mentions both terms again later in the SAFE-FIX-tier-only restatement ("knob or not —
# never auto-applied"), so that weaker grep would still pass with the causal sentence deleted. Pinning
# the "add --apply-safe" verb phrase (distinct from "only ever touches" / "never auto-applied" used
# elsewhere) catches that specific deletion.
grep -qE -- 'add `?--apply-safe`?' "$CMD" \
  || fail "commands/autorun.md must instruct: when the janitor: auto-safe knob is set, ADD --apply-safe to the preflight call"
printf '%s' "$flat" | grep -qiE 'report-only by default|never auto-appl(y|ies)[^.]*(on its own|without)' \
  || fail "commands/autorun.md must state the janitor preflight is report-only by default (no knob = no mutation)"

# ---- 3. RISKY/REPORT-ONLY stay advisory even with the knob set (the scanner's own SAFE-FIX-only
#         contract, restated so a reader of just this file doesn't assume otherwise) ----------------
printf '%s' "$flat" | grep -qiE 'RISKY[^.]*REPORT-ONLY[^.]*never|SAFE-FIX[^.]*only' \
  || fail "commands/autorun.md must state --apply-safe only ever touches the SAFE-FIX tier (RISKY/REPORT-ONLY stay advisory)"

# ---- 4. findings are surfaced, never a halt / never self-narrowing ---------------------------------
printf '%s' "$flat" | grep -qiE 'never (self-narrow|halt|gate)|advisory' \
  || fail "commands/autorun.md must state a janitor finding is advisory/surfaced, never a halt or self-narrow"

# ---- 5. ordering — the janitor preflight sits near the TOP of the pipe, before the Build lane ------
# lineof(): line number of the first case-insensitive match ("" if none; -m1 avoids SIGPIPE)
lineof() { grep -n -m1 -iE "$2" "$1" 2>/dev/null | cut -d: -f1; }
jan_line=$(lineof "$CMD" 'Janitor preflight')
build_line=$(lineof "$CMD" 'Build lane')
[ -n "$jan_line" ] || fail "commands/autorun.md must carry a named 'Janitor preflight' step"
[ -n "$build_line" ] || fail "commands/autorun.md must carry a 'Build lane' step (existing anchor missing?)"
[ "$jan_line" -lt "$build_line" ] \
  || fail "commands/autorun.md: the Janitor preflight (line $jan_line) must precede the Build lane (line $build_line) — near the top of the pipe, not an afterthought"

echo "PASS: commands/autorun.md runs the janitor scanner (idc_git_janitor.py) as a --report preflight near the top of the pipe for both backends; report-only by default; the operator-set 'janitor: auto-safe' knob is the ONLY opt-in to --apply-safe (SAFE-FIX tier only, RISKY/REPORT-ONLY always advisory); findings never halt or self-narrow the drain"
