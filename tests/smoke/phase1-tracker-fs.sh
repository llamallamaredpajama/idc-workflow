#!/bin/bash
# Phase 1 smoke — filesystem tracker backend round-trip (create / claim / block / close).
# This is a REAL functional test: it drives the shipped filesystem-tracker helper against a
# throwaway TRACKER.md and asserts the resulting state. Failing-test-first: it fails until
# scripts/idc_tracker_fs.py exists and implements the six ops + claim/block/close.
#
# Usage: bash tests/smoke/phase1-tracker-fs.sh   (exit 0 = pass)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TRK="$HERE/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"
T="$WORK/TRACKER.md"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1"; exit 1; }
run()  { python3 "$TRK" --tracker "$T" "$@"; }
field(){ python3 "$TRK" --tracker "$T" show --num "$1" --field "$2"; }

[ -f "$TRK" ] || fail "tracker helper not found at $TRK (not implemented yet)"

# init → empty board
run init >/dev/null || fail "init failed"
[ -f "$T" ] || fail "init did not create TRACKER.md"

# createTicket ×2 → numbers 1, 2
n1="$(run create --title 'Issue A' --wave 'Wave 1' --phase 'Phase 1' --domain api)"   || fail "create A failed"
n2="$(run create --title 'Issue B' --wave 'Wave 1' --phase 'Phase 1' --domain data)"  || fail "create B failed"
[ "$n1" = "1" ] || fail "first issue number should be 1, got '$n1'"
[ "$n2" = "2" ] || fail "second issue number should be 2, got '$n2'"
[ "$(field 1 Status)" = "Todo" ] || fail "new issue should default Status=Todo, got '$(field 1 Status)'"

# claim #1 (Status → In Progress + claim comment naming the agent)
run claim --num 1 --agent builder-x >/dev/null || fail "claim failed"
[ "$(field 1 Status)" = "In Progress" ] || fail "claim should set Status=In Progress, got '$(field 1 Status)'"
run show --num 1 --comments | grep -q "builder-x" || fail "claim should record a comment naming the agent"

# block #2 behind #1 (native blocked-by + Status → Blocked)
run block --num 2 --by 1 >/dev/null || fail "block failed"
[ "$(field 2 Status)" = "Blocked" ] || fail "block should set Status=Blocked, got '$(field 2 Status)'"
run show --num 2 --blocked-by | grep -qw 1 || fail "block should record blocked-by #1"

# close #1 (Status → Done)
run close --num 1 >/dev/null || fail "close failed"
[ "$(field 1 Status)" = "Done" ] || fail "close should set Status=Done, got '$(field 1 Status)'"

# query by status
[ "$(run query --status Done)" = "1" ]    || fail "query Status=Done should return '1', got '$(run query --status Done)'"
[ "$(run query --status Blocked)" = "2" ] || fail "query Status=Blocked should return '2'"

# idempotent re-close is a no-op success
run close --num 1 >/dev/null || fail "re-close should be idempotent success"

# the rendered TRACKER.md is human-readable (table present)
grep -q "^| #" "$T" || fail "TRACKER.md should render a human-readable board table"

echo "PASS: filesystem tracker round-trip (create/claim/block/close/query) green"
