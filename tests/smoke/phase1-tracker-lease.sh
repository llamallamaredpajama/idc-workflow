#!/bin/bash
# Phase 1 smoke (F3) — the board-backed merge lease primitive (filesystem backend).
#
# The pi adapter's merge-serialization promises a "single-holder merge lease" but the tracker
# exposed no lease primitive — two finisher residents had no atomic way to prove exclusive
# ownership before touching the integration ref. This drives the real primitive:
#   acquire-if-empty-or-expired -> token; release-by-token; expiry re-acquire; and TRUE
#   cross-process mutual exclusion (two concurrent acquirers -> exactly one winner).
#
# Failing-test-first: fails until idc_tracker_fs.py gains lease-acquire/lease-release.
#
# Usage: bash tests/smoke/phase1-tracker-lease.sh   (exit 0 = pass)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TRK="$HERE/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; T="$WORK/TRACKER.md"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
run() { python3 "$TRK" --tracker "$T" "$@"; }

[ -f "$TRK" ] || fail "tracker helper not found at $TRK"
run init >/dev/null || fail "init failed"

# (a) acquire on a free lease returns a token.
tokA="$(run lease-acquire --lease merge --owner finisher-A --ttl 60)" || fail "acquire on a free lease failed (no lease primitive?)"
[ -n "$tokA" ] || fail "acquire returned an empty token"

# (b) a second acquire WHILE HELD is rejected — fail-closed, never two holders.
run lease-acquire --lease merge --owner finisher-B --ttl 60 >/dev/null 2>&1 \
  && fail "a second acquire succeeded while the lease was held (two holders!)"

# (c) release with the WRONG token is rejected.
run lease-release --lease merge --token deadbeefdeadbeef >/dev/null 2>&1 \
  && fail "release-by-wrong-token was accepted"

# (d) release with the correct token succeeds; the lease can then be re-acquired.
run lease-release --lease merge --token "$tokA" || fail "release-by-correct-token failed"
tokB="$(run lease-acquire --lease merge --owner finisher-B --ttl 60)" || fail "re-acquire after release failed"
[ -n "$tokB" ] && [ "$tokB" != "$tokA" ] || fail "re-acquire did not return a fresh token"
run lease-release --lease merge --token "$tokB" || fail "cleanup release failed"

# (e) expiry: a short-lived lease can be re-acquired after it expires.
tokC="$(run lease-acquire --lease merge --owner finisher-C --ttl 1)" || fail "short-ttl acquire failed"
sleep 2
tokD="$(run lease-acquire --lease merge --owner finisher-D --ttl 60)" || fail "re-acquire after expiry failed (expiry not honored)"
[ "$tokC" != "$tokD" ] || fail "expired re-acquire returned the same token"
run lease-release --lease merge --token "$tokD" >/dev/null || true

# (f) CONCURRENCY: two simultaneous acquirers must yield EXACTLY ONE winner (cross-process lock).
run lease-acquire --lease merge --owner X --ttl 60 >"$WORK/x.out" 2>/dev/null &
run lease-acquire --lease merge --owner Y --ttl 60 >"$WORK/y.out" 2>/dev/null &
wait
winners=0
[ -s "$WORK/x.out" ] && winners=$((winners + 1))
[ -s "$WORK/y.out" ] && winners=$((winners + 1))
[ "$winners" -eq 1 ] || fail "concurrent acquire: expected exactly 1 winner, got $winners (two finishers could both merge)"

echo "PASS: merge-lease primitive — single-holder, release-by-token, expiry, concurrency-safe"
