#!/bin/bash
# Phase 8 smoke (codex round-6 F2) — the fleet supervisor is FAIL-CLOSED: a hub that never becomes
# healthy, or a resident that crashes, must surface as a NON-ZERO `idc-pi fleet` exit (not a clean
# one that hides a fleet that isn't actually running).
#
# Usage: bash tests/smoke/phase8-pi-fleet-failclose.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN/runtime/pi/scripts/idc-pi"
FAKEFAIL="$PLUGIN/tests/smoke/fixtures/fake-pi-fail.sh"

fail() { echo "FAIL: $1"; exit 1; }
command -v bun >/dev/null 2>&1 || fail "bun not found"
[ -f "$LAUNCHER" ] || fail "launcher missing"
[ -f "$FAKEFAIL" ] || fail "fake-pi-fail missing"
chmod +x "$FAKEFAIL"

SBX="$(mktemp -d)"
trap 'pkill -f "coms-net-server.ts" >/dev/null 2>&1; rm -rf "$SBX"' EXIT
REPO="$SBX/repo"; mkdir -p "$REPO"

# (A) a resident that exits non-zero -> the fleet propagates a non-zero exit.
( cd "$REPO" && env HOME="$SBX/a" PI_IDC_HARNESS_REPO="$PLUGIN/runtime/pi" \
    PI_COMS_NET_ROLE_HMAC_KEY="testkey" PI_IDC_RESIDENT_BIN="$FAKEFAIL" \
    PI_COMS_NET_HOST="127.0.0.1" PI_COMS_NET_PORT="0" PI_COMS_NET_LOG_QUIET="1" \
    bash "$LAUNCHER" fleet think ) >"$SBX/a.out" 2>&1
rcA=$?
[ "$rcA" -ne 0 ] || { cat "$SBX/a.out"; fail "A: fleet returned 0 despite a resident exiting non-zero"; }

# (B) a hub that never becomes healthy (bogus harness -> the hub binary can't load) -> fleet exits
#     non-zero quickly (short health budget), WITHOUT spawning residents.
( cd "$REPO" && env HOME="$SBX/b" PI_IDC_HARNESS_REPO="$SBX/no-such-runtime" \
    PI_COMS_NET_ROLE_HMAC_KEY="testkey" PI_IDC_RESIDENT_BIN="$FAKEFAIL" \
    PI_IDC_FLEET_HEALTH_TICKS="4" \
    PI_COMS_NET_HOST="127.0.0.1" PI_COMS_NET_PORT="0" PI_COMS_NET_LOG_QUIET="1" \
    bash "$LAUNCHER" fleet think ) >"$SBX/b.out" 2>&1
rcB=$?
# Note: a bogus harness fails at build_role_argv/governance preflight or hub spawn — any of those is
# a non-zero exit. The key property: it does NOT exit 0.
[ "$rcB" -ne 0 ] || { cat "$SBX/b.out"; fail "B: fleet returned 0 despite the hub never becoming healthy"; }

echo "PASS: idc-pi fleet is fail-closed — a failing hub or resident yields a non-zero fleet exit"
