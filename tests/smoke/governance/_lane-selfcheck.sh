#!/bin/bash
# _lane-selfcheck.sh — the governance lane's permanent honesty anchor.
#
# Underscore-prefixed, so phase-governance.sh runs it SEPARATELY (never via the real-scenario glob)
# and treats it as mandatory: if it is missing or fails, the whole lane FAILs. Its job is to prove
# the harness itself works — that a scenario can PASS and, crucially, can FAIL — so an empty lane can
# never masquerade as a true green. It also exercises the shared seed helper (lib.sh) so a broken
# helper is caught here, before any real scenario relies on it.
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

echo "PASS: governance lane self-check — harness distinguishes pass/fail; lib.sh seeds + reads a fs board"
