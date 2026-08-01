#!/bin/bash
# _lane-selfcheck.sh — the governance lane's permanent honesty anchor.
#
# Underscore-prefixed, so phase-governance.sh runs it SEPARATELY (never via the real-scenario glob)
# and treats it as mandatory: if it is missing or fails, the whole lane FAILs. Its job is to prove
# the harness itself works — that a scenario can PASS and, crucially, can FAIL — so an empty lane can
# never masquerade as a true green. It also exercises the shared seed helper (lib.sh) so a broken
# helper is caught here, before any real scenario relies on it.
#
# It does the same for `../lib/fail-closed.sh`, the shared fail-closed assertion. A helper whose job
# is to catch inert fixtures is worthless if IT is inert, so section 3 below proves every one of its
# refusals actually fires — including the ones a fixture author would hit by mistake (no positive
# control, a marker that also matches the fixture's own scaffolding, a guarded command that hangs).
#
# It ends by exiting 0 (a passing scenario). To see the lane's fail path actually fire, flip the
# `expect_fail false` assertion below to `expect_fail true` — the self-check then FAILs and
# phase-governance.sh goes red (the red-when-broken proof for the harness itself).
#
# Usage: bash tests/smoke/governance/_lane-selfcheck.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }

# 1. The harness can tell PASS from FAIL — a true command "passes", a false command "fails".
#    If bash's exit-status detection were broken, one of these two asserts would trip.
expect_pass() { "$@" || fail "expected command to succeed: $*"; }
expect_fail() { "$@" && fail "expected command to FAIL but it succeeded: $*"; return 0; }
expect_pass true
expect_fail false

# 2. The shared seed helper works: init a throwaway fs board, seed one item at a chosen Stage+Status,
#    and read it back. Proves the primitive the four writers reuse is functional.
T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
trap 'rm -rf "$(dirname "$T")"' EXIT
n="$(gov_seed_item "$T" --title 'selfcheck seed' --stage Recirculation --status Todo)" \
  || fail "gov_seed_item could not seed an item"
[ -n "$n" ] || fail "gov_seed_item returned an empty issue number"
[ "$(gov_field "$T" "$n" Stage)"  = "Recirculation" ] || fail "seeded Stage did not round-trip"
[ "$(gov_field "$T" "$n" Status)" = "Todo" ]          || fail "seeded Status did not round-trip"
echo "$(gov_query "$T" --stage Recirculation --status Todo)" | grep -qw "$n" \
  || fail "gov_query did not enumerate the seeded item"

# 3. The shared FAIL-CLOSED assertion works — and, more to the point, REFUSES. `assert_fail_closed`
#    exists because seven fixtures in a row asserted a fail-closed path without a discriminating
#    artifact; a version of it that quietly accepted a misuse would just move the same defect one
#    level up. Each case below runs in its own subshell (the helper exits on a violation).
FC_LIB="$(dirname "$0")/../lib/fail-closed.sh"
[ -f "$FC_LIB" ] || fail "the shared fail-closed assertion is missing at $FC_LIB"
# shellcheck source=../lib/fail-closed.sh
. "$FC_LIB"

MARK='SELFCHECK-DISCRIMINATING-MARKER'
# <expect: ok|refused> <desc> <because: the refusal text that must appear, or ''> <assert args…>
# The `because` is what stops THIS self-check from being the next inert fixture: several misuses are
# refused by more than one of the helper's checks, so "it refused" alone would not prove the check
# under test is the one that fired.
fc_case() {
  local expect="$1" desc="$2" because="$3"; shift 3
  local out rc
  out="$( ( set -uo pipefail; . "$FC_LIB"; FC_TIMEOUT_S=5
            fail() { echo "FAIL: $1"; exit 1; }
            assert_fail_closed "$@" ) 2>&1 )"; rc=$?
  case "$expect" in
    ok)      [ "$rc" -eq 0 ] || fail "assert_fail_closed rejected a WELL-FORMED assertion ($desc): $out" ;;
    refused) [ "$rc" -ne 0 ] || fail "assert_fail_closed ACCEPTED a misuse it must refuse ($desc) — the helper is inert" ;;
  esac
  if [ -n "$because" ]; then
    printf '%s' "$out" | grep -qF -- "$because" \
      || fail "assert_fail_closed refused '$desc' for the WRONG reason (expected it to say \"$because\"): $out"
  fi
}
fc_case ok "a real guard + a clean control" '' \
  "selfcheck" "$MARK" \
  -- bash -c "echo $MARK >&2; exit 2" \
  -- bash -c 'echo an ordinary, non-guard outcome; exit 0'
fc_case refused "no positive control supplied" 'no POSITIVE CONTROL was supplied' \
  "selfcheck" "$MARK" -- bash -c "echo $MARK >&2; exit 2"
fc_case refused "a marker too short to discriminate" 'too short to be discriminating' \
  "selfcheck" "seen" -- bash -c 'echo seen >&2; exit 2' -- bash -c 'exit 0'
fc_case refused "the guarded path exited 0" 'exited 0 — it did not fail closed' \
  "selfcheck" "$MARK" -- bash -c "echo $MARK >&2; exit 0" -- bash -c 'exit 0'
fc_case refused "the guarded path failed without its own marker" 'failed WITHOUT emitting its discriminating marker' \
  "selfcheck" "$MARK" -- bash -c 'echo some other refusal >&2; exit 2' -- bash -c 'exit 0'
fc_case refused "the control emits the marker too (not discriminating)" 'the positive control ALSO emitted' \
  "selfcheck" "$MARK" -- bash -c "echo $MARK >&2; exit 2" -- bash -c "echo $MARK; exit 0"
# The hang case pins its own message on purpose: with the rc-124 check deleted the assertion still
# refuses (an empty capture carries no marker), so only the message proves the BOUND is what fired.
fc_case refused "the guarded command HANGS (a hang is RED, not a slow pass)" 'did not terminate within 5s' \
  "selfcheck" "$MARK" -- bash -c 'sleep 30' -- bash -c 'exit 0'
# a marker that also matches the fixture's own scaffolding must be refused (corollary (c))
( set -uo pipefail; . "$FC_LIB"; FC_TIMEOUT_S=5
  fail() { echo "FAIL: $1"; exit 1; }
  WORK=/tmp/selfcheck-scaffold-marker
  assert_fail_closed "selfcheck" 'selfcheck-scaffold-marker' \
    -- bash -c 'echo selfcheck-scaffold-marker >&2; exit 2' -- bash -c 'exit 0' ) >/dev/null 2>&1 \
  && fail "assert_fail_closed accepted a marker that also matches the fixture's own scaffolding"
# fc_require_file: passes on a real path, FAILS on a missing one (the anti-vacuous-skip guard)
( set -uo pipefail; . "$FC_LIB"; fail() { echo "FAIL: $1"; exit 1; }
  fc_require_file "$FC_LIB" "the shared helper" ) >/dev/null 2>&1 \
  || fail "fc_require_file rejected a file that exists"
( set -uo pipefail; . "$FC_LIB"; fail() { echo "FAIL: $1"; exit 1; }
  fc_require_file "/nonexistent/idc-selfcheck-path" "a missing input" ) >/dev/null 2>&1 \
  && fail "fc_require_file accepted a missing input — a fixture could still skip its assertions silently"

echo "PASS: governance lane self-check — harness distinguishes pass/fail; lib.sh seeds + reads a fs board; assert_fail_closed refuses every misuse that would make a fail-closed fixture inert"
