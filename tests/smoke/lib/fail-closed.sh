#!/bin/bash
# fail-closed.sh — the shared FAIL-CLOSED assertion for smoke fixtures.
#
# ── THE RULE ─────────────────────────────────────────────────────────────────────────────────────
# Every fixture assertion about a fail-closed / skip / refuse path MUST key on a DISCRIMINATING
# ARTIFACT that only that path produces — a unique stderr marker, a distinct exit code — never on
# the outcome the guarded path and some other path both produce. And it MUST carry a POSITIVE
# CONTROL: the same marker checked against the non-failing path, proving the marker is ABSENT there.
#
# Why this is a rule and not a tip: this repo has now shipped the same defect SEVEN times — a
# negative assertion whose SETUP NEVER REACHES THE GUARD. The fixture greps for an outcome (a
# non-zero exit, an ordinary refusal message) that the guarded path and the unguarded path both
# produce, so it goes green for the wrong reason and would never redden if the guard were deleted.
# Two live examples from one branch: `mv TRACKER.md TRACKER.md.hidden` is NOT a board-read failure on
# the filesystem backend (idc_file_findings._fs_state degrades a missing tracker to an empty board),
# so the fail-closed handler under test was never entered; and a whole suppression feature could be
# hard-wired off with the entire lane still green. See also the sibling lesson in
# tests/smoke/lib/stderr_census.py: a guard whose real-tree answer is silence needs a PLANTED
# POSITIVE EXAMPLE, or "no output" proves the guard ran when it only proves nothing tripped it.
#
# `assert_fail_closed` makes the right thing the easy thing: it is not callable without naming a
# discriminating marker AND supplying the positive control, it refuses a marker that also matches
# the fixture's own scaffolding (a grep must never be satisfiable by the fixture's own temp path or
# filename), and it runs BOTH commands under an explicit timeout — a neutered bound HANGS instead of
# reddening, and a hang must read as RED, never as a slow pass.
#
# ── USAGE ────────────────────────────────────────────────────────────────────────────────────────
#   . "$(dirname "$0")/../lib/fail-closed.sh"      # from tests/smoke/governance/<fixture>.sh
#
#   assert_fail_closed <description> <discriminating-marker> \
#     -- <command that MUST fail closed …> \
#     -- <positive control: the same surface on its non-failing path …>
#
# It asserts, in order:
#   1. the guarded command terminates (a timeout is RED), exits NON-ZERO, and emits <marker>;
#   2. the positive control terminates and does NOT emit <marker>.
# Both commands are run with stdout+stderr combined. A bare `--` may not appear INSIDE either
# command (it is the separator). Override the bound per fixture with FC_TIMEOUT_S. The two captures
# survive as FC_GUARDED_OUT / FC_CONTROL_OUT, so a fixture can add its own follow-up assertions
# (e.g. that the refusal named the entry it protected) without re-running anything.
#
#   fc_require_file <path> <what it is>            # hard-guard an input; never `if [ -f … ]`
#
# A fixture that wraps assertions in `if [ -f "$HELPER" ]` skips them silently the day the path is
# wrong — the assertions vanish and the fixture still prints PASS. Guard the input at the top and
# let the fixture FAIL if it is missing.
#
# The caller must define `fail()` (the fixture's message-and-exit helper) before calling these; a
# fixture that has not defined one still gets a loud message and a non-zero exit.

# The per-command bound. Generous enough for a real board read / hook invocation, finite either way.
FC_TIMEOUT_S="${FC_TIMEOUT_S:-120}"

# fc_fail <msg> — route through the fixture's own fail() when it has one, so failures read the same.
fc_fail() {
  if command -v fail >/dev/null 2>&1; then
    fail "$1"
  else
    echo "FAIL: $1"
    exit 1
  fi
  exit 1                       # belt-and-braces: a caller's fail() that returns must not continue
}

# fc_require_file <path> <what> — the anti-vacuous-skip guard. Use this INSTEAD of wrapping a block
# of assertions in `if [ -f … ]; then … fi`, which silently deletes them when the path is wrong.
fc_require_file() {
  [ -f "$1" ] || fc_fail "${2:-required input} not found at $1 (its assertions would otherwise be skipped silently)"
}

# fc_capture <command…> — run under the bound, combine stdout+stderr into FC_OUT, exit code into
# FC_RC (124 = the bound fired). errexit-safe: restores the caller's `set -e` state.
fc_capture() {
  local _fc_prev_e=0
  case "$-" in *e*) _fc_prev_e=1 ;; esac
  set +e
  FC_OUT="$(timeout "$FC_TIMEOUT_S" "$@" 2>&1)"
  FC_RC=$?
  [ "$_fc_prev_e" -eq 1 ] && set -e
  return 0
}

# fc_marker_is_discriminating <marker> — refuse a marker that cannot discriminate anything: empty,
# too short to be unique, or a substring of this fixture's own scaffolding (its path, its temp dirs).
# Corollary: an assertion whose grep can match the fixture's own filename/temp path/input proves
# nothing. Export FC_SCAFFOLD with any extra fixture-owned strings to widen the check.
fc_marker_is_discriminating() {
  local marker="$1" scaffold
  [ -n "$marker" ] \
    || fc_fail "assert_fail_closed: a fail-closed assertion must name a DISCRIMINATING marker unique to the guarded path — the empty string is not one"
  [ "${#marker}" -ge 8 ] \
    || fc_fail "assert_fail_closed: the marker '$marker' is too short to be discriminating — name the guard's own sentence, not a word both paths emit"
  scaffold="$0 ${WORK:-} ${REPO:-} ${LEDGER:-} ${FC_SCAFFOLD:-}"
  case "$scaffold" in
    *"$marker"*)
      fc_fail "assert_fail_closed: the marker '$marker' also matches this fixture's own scaffolding (its path/temp dirs) — a grep that can match the fixture's own inputs proves nothing" ;;
  esac
}

# assert_fail_closed <desc> <marker> -- <guarded cmd…> -- <positive-control cmd…>
assert_fail_closed() {
  local desc marker a seen_sep=0
  [ "$#" -ge 2 ] || fc_fail "assert_fail_closed usage: assert_fail_closed <desc> <marker> -- <guarded cmd…> -- <control cmd…>"
  desc="$1"; marker="$2"; shift 2
  [ "${1:-}" = "--" ] \
    || fc_fail "assert_fail_closed(\"$desc\"): the guarded command must follow a literal '--'"
  shift
  local guarded=() control=()
  for a in "$@"; do
    if [ "$a" = "--" ] && [ "$seen_sep" -eq 0 ]; then seen_sep=1; continue; fi
    if [ "$seen_sep" -eq 0 ]; then guarded[${#guarded[@]}]="$a"; else control[${#control[@]}]="$a"; fi
  done
  [ "$seen_sep" -eq 1 ] \
    || fc_fail "assert_fail_closed(\"$desc\"): no POSITIVE CONTROL was supplied. A fail-closed assertion is only meaningful alongside the same surface on its NON-failing path, proving the marker '$marker' is unique to the guard. Add: -- <control cmd…>"
  [ "${#guarded[@]}" -gt 0 ] || fc_fail "assert_fail_closed(\"$desc\"): the guarded command is empty"
  [ "${#control[@]}" -gt 0 ] || fc_fail "assert_fail_closed(\"$desc\"): the positive control command is empty"
  fc_marker_is_discriminating "$marker"

  # 1. the guarded path: bounded, non-zero, and carrying its OWN artifact.
  fc_capture "${guarded[@]}"
  FC_GUARDED_OUT="$FC_OUT"; FC_GUARDED_RC="$FC_RC"
  [ "$FC_RC" -ne 124 ] \
    || fc_fail "$desc: the guarded command did not terminate within ${FC_TIMEOUT_S}s — a neutered bound HANGS instead of reddening, so a timeout is RED, never a slow pass"
  [ "$FC_RC" -ne 0 ] \
    || fc_fail "$desc: the guarded path exited 0 — it did not fail closed: [$FC_OUT]"
  if ! printf '%s\n' "$FC_OUT" | grep -qF -- "$marker"; then
    fc_fail "$desc: the guarded path failed WITHOUT emitting its discriminating marker '$marker' — so the refusal came from some other path and this assertion proves nothing about the guard: [$FC_OUT]"
  fi

  # 2. the positive control: the same marker must be ABSENT off the guarded path.
  fc_capture "${control[@]}"
  FC_CONTROL_OUT="$FC_OUT"; FC_CONTROL_RC="$FC_RC"
  [ "$FC_RC" -ne 124 ] \
    || fc_fail "$desc: the positive control did not terminate within ${FC_TIMEOUT_S}s (treat a hang as RED)"
  if printf '%s\n' "$FC_OUT" | grep -qF -- "$marker"; then
    fc_fail "$desc: the positive control ALSO emitted '$marker', so the marker does not discriminate the fail-closed path from the ordinary one — pick an artifact only the guard produces: [$FC_OUT]"
  fi
  return 0
}
