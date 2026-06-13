#!/bin/bash
# Phase 8 smoke (codex round-4 Layer 2) — the `idc-pi fleet` supervisor distributes role-cap
# secrets correctly: each resident receives ONLY its own role's cap = HMAC(K, role), and the master
# key K is NEVER leaked to any resident. This is the property the cmux/pane mode CANNOT provide (a
# per-pane K can't be both secret and cross-pane), so it must be proven on the supervised path.
#
# REAL seam: drives the actual `idc-pi fleet` with a known injected K and a fake resident
# (PI_IDC_RESIDENT_BIN) that records its environ. No pi agent / no cap match against a real LLM.
#
# Usage: bash tests/smoke/phase8-pi-fleet-secret.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN/runtime/pi/scripts/idc-pi"
FAKE="$PLUGIN/tests/smoke/fixtures/fake-pi.sh"

fail() { echo "FAIL: $1"; exit 1; }
command -v bun >/dev/null 2>&1 || fail "bun not found (required to boot the fleet hub)"
command -v openssl >/dev/null 2>&1 || fail "openssl not found (required to compute expected caps)"
[ -f "$LAUNCHER" ] || fail "launcher missing at $LAUNCHER"
[ -f "$FAKE" ] || fail "fake resident missing at $FAKE"
chmod +x "$FAKE"

SBX="$(mktemp -d)"
FLEET_PID=""
cleanup() { [ -n "$FLEET_PID" ] && kill "$FLEET_PID" >/dev/null 2>&1; pkill -f "coms-net-server.ts" >/dev/null 2>&1; rm -rf "$SBX"; }
trap cleanup EXIT

REPO="$SBX/repo"; mkdir -p "$REPO"
K="0123456789abcdef0123456789abcdef"        # known master key so the test can compute expected caps
ROLES="think plan build-impl"

# Launch the supervised fleet with the known K + the fake resident, isolated HOME + ephemeral port.
( cd "$REPO" && env HOME="$SBX" \
    PI_IDC_HARNESS_REPO="$PLUGIN/runtime/pi" \
    PI_COMS_NET_ROLE_HMAC_KEY="$K" \
    PI_IDC_RESIDENT_BIN="$FAKE" \
    PI_COMS_NET_HOST="127.0.0.1" PI_COMS_NET_PORT="0" PI_COMS_NET_LOG_QUIET="1" \
    bash "$LAUNCHER" fleet $ROLES >"$SBX/fleet.log" 2>&1 ) &
FLEET_PID=$!

OUT="$SBX/fleet-out"
cap_for() { printf '%s' "$1" | openssl dgst -sha256 -mac HMAC -macopt "key:$K" | awk '{print $NF}'; }

# Sample `ps` repeatedly DURING startup — the master key K and the per-role caps must NEVER appear
# in any process argv / command string (codex round-5 finding 1: the bash `env -i VAR=val` +
# `openssl -macopt key:` forms leaked them; the bun supervisor passes secrets via execve env maps).
PSLOG="$SBX/ps-sample.txt"; : > "$PSLOG"
ok=0
for _ in $(seq 1 60); do
  ps -eo args 2>/dev/null >> "$PSLOG" || ps -ax -o command 2>/dev/null >> "$PSLOG" || true
  if [ -f "$OUT/think.cap" ] && [ -f "$OUT/plan.cap" ] && [ -f "$OUT/build-impl.cap" ]; then ok=1; ps -eo args 2>/dev/null >> "$PSLOG" || true; break; fi
  if ! kill -0 "$FLEET_PID" >/dev/null 2>&1; then echo "--- fleet.log ---"; cat "$SBX/fleet.log" 2>/dev/null; fail "fleet exited before residents recorded their env"; fi
  sleep 0.25
done
[ "$ok" -eq 1 ] || { echo "--- fleet.log ---"; cat "$SBX/fleet.log" 2>/dev/null; fail "residents never recorded their env (fleet didn't bring them up)"; }

# (0) NO SECRET IN ARGV — K and every cap must be absent from the ps samples taken during startup.
grep -qF "$K" "$PSLOG" && fail "the master key K appeared in a process argv (ps) — secret leaked via command string"
for role in $ROLES; do
  grep -qF "$(cap_for "$role")" "$PSLOG" && fail "the $role role cap appeared in a process argv (ps) — secret leaked via command string"
done

# (1) each resident got the CORRECT cap = HMAC(K, role).
for role in $ROLES; do
  got="$(cat "$OUT/$role.cap")"
  want="$(cap_for "$role")"
  [ "$got" = "$want" ] || fail "$role got cap '$got', expected HMAC(K,$role)='$want'"
done

# (2) the master key K was NOT leaked to ANY resident (the core property the pane mode can't give).
for role in $ROLES; do
  k="$(cat "$OUT/$role.k")"
  [ "$k" = "NONE" ] || fail "$role LEAKED the master key K ('$k') — residents must never receive K"
done

# (3) caps are role-bound (pairwise distinct), not a shared secret.
think_cap="$(cat "$OUT/think.cap")"; plan_cap="$(cat "$OUT/plan.cap")"; bi_cap="$(cat "$OUT/build-impl.cap")"
[ "$think_cap" != "$plan_cap" ] && [ "$think_cap" != "$bi_cap" ] && [ "$plan_cap" != "$bi_cap" ] \
  || fail "role caps are not pairwise distinct (not role-bound)"

echo "PASS: idc-pi fleet gives each resident only its own role cap; the master key K never reaches a resident"
