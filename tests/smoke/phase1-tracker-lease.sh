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
run lease-release --lease merge --token "$(cat "$WORK/x.out" "$WORK/y.out")" >/dev/null 2>&1 || true

# (g) CLOBBER REGRESSION (codex round-2 F3): the lease must NOT live in the racy TRACKER.md blob,
#     or an ordinary unlocked tracker write that loaded a STALE copy can erase a live lease.
#     Reproduce the exact race: snapshot TRACKER.md (a writer's pre-lease view), acquire a lease,
#     then write the stale snapshot back (the writer saving its stale state). The lease must survive.
run create --title 'unrelated work' >/dev/null || fail "setup create failed"
cp "$T" "$WORK/stale.md"                                   # writer X's pre-lease view of TRACKER.md
tokE="$(run lease-acquire --lease merge --owner finisher-E --ttl 60)" || fail "acquire (clobber test) failed"
grep -q "$tokE" "$T" && fail "lease token is stored inside TRACKER.md — any tracker write can clobber it"
cp "$WORK/stale.md" "$T"                                   # writer X saves its stale state (the clobber)
run lease-show --lease merge | grep -q '"held": true' \
  || fail "a stale TRACKER.md overwrite ERASED a held lease (lease must live in its own sidecar)"
# and an ordinary mutation while held leaves the lease intact
run comment --num 1 --body "ordinary write while lease held" >/dev/null || fail "comment failed"
run lease-show --lease merge | grep -q '"held": true' || fail "an ordinary tracker write dropped the held lease"
run lease-release --lease merge --token "$tokE" || fail "final release failed"

# (h) MALFORMED state is fail-closed (codex round-7): a corrupt lease sidecar is UNKNOWN lock state,
#     not "free" — acquire/show must fail rather than grant a lease over an unreadable file.
printf 'not json {{' > "$WORK/TRACKER.md.leases.json"
run lease-acquire --lease merge --owner finisher-Z --ttl 60 >/dev/null 2>&1 \
  && fail "lease-acquire granted a lease over a CORRUPT sidecar (fail-open) — must fail-closed"
run lease-show --lease merge >/dev/null 2>&1 \
  && fail "lease-show succeeded over a corrupt sidecar — must fail-closed"

echo "PASS: merge-lease primitive — single-holder, release-by-token, expiry, concurrency-safe, clobber-proof, corrupt-state fail-closed"
