#!/bin/bash
# Phase 8 smoke — boots the VENDORED coms-net runtime under Bun and asserts the directional
# glass-wall ACL on the coms_net_send seam (issue #27, te-B1). REAL round-trip: a throwaway
# loopback hub (isolated $HOME, ephemeral port, env-supplied token — no secret file), the
# shipped install-pi.sh --check report, a /health probe, and the deny/allow send matrix via
# tests/smoke/phase8-coms-net-probe.ts. No Pi agent binary required (server + ACL are
# standalone TS). Exit 0 = pass.
#
# Failing-test-first: with the RED stub ACL the build→plan send is wrongly ALLOWED, so the
# probe fails here; the green commit wires the directional policy and this turns green.
#
# Usage: bash tests/smoke/phase8-pi-runtime.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER_TS="$PLUGIN/runtime/pi/scripts/coms-net-server.ts"
PROBE_TS="$PLUGIN/tests/smoke/phase8-coms-net-probe.ts"
INSTALL="$PLUGIN/scripts/install-pi.sh"

fail() { echo "FAIL: $1"; exit 1; }

command -v bun >/dev/null 2>&1 || fail "bun not found on PATH (required to boot the vendored runtime)"
[ -f "$SERVER_TS" ]  || fail "vendored coms-net server missing at $SERVER_TS (not vendored yet)"
[ -f "$PROBE_TS" ]   || fail "ACL probe missing at $PROBE_TS"
[ -f "$INSTALL" ]    || fail "install-pi.sh missing at $INSTALL"

SBX="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null
  rm -rf "$SBX"
}
trap cleanup EXIT

# Random loopback token so the server never writes a secret file (env token branch).
TOK="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
[ -n "$TOK" ] || fail "could not generate an auth token"
# Hub master key for per-role registration capabilities (codex round-4): the probes compute each
# role's HMAC cap from it (simulating what idc-pi hands a resident), so role registrations are
# accepted and the role-cap enforcement path is exercised.
ROLE_KEY="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
[ -n "$ROLE_KEY" ] || fail "could not generate a role hmac key"
export PI_COMS_NET_ROLE_HMAC_KEY="$ROLE_KEY"   # inherited by the probe processes below
PROJECT="default"

# Boot the hub under Bun with an isolated HOME (registry writes land in $SBX/.pi, not ~/.pi)
# and an ephemeral port (PORT=0 -> the server picks a free port and records it in server.json).
env HOME="$SBX" \
    PI_COMS_NET_AUTH_TOKEN="$TOK" \
    PI_COMS_NET_ROLE_HMAC_KEY="$ROLE_KEY" \
    PI_COMS_NET_PROJECT="$PROJECT" \
    PI_COMS_NET_HOST="127.0.0.1" \
    PI_COMS_NET_PORT="0" \
    PI_COMS_NET_LOG_QUIET="1" \
    bun "$SERVER_TS" >"$SBX/server.log" 2>&1 &
SERVER_PID=$!

SJSON="$SBX/.pi/coms-net/projects/$PROJECT/server.json"
URL=""
for _ in $(seq 1 40); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "--- server.log ---"; cat "$SBX/server.log" 2>/dev/null
    fail "coms-net server exited during startup"
  fi
  if [ -f "$SJSON" ]; then
    URL="$(sed -nE 's/.*"local_url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$SJSON" | head -1)"
    if [ -n "$URL" ] && curl -fsS --max-time 1 "$URL/health" >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 0.25
done
[ -n "$URL" ] || { echo "--- server.log ---"; cat "$SBX/server.log" 2>/dev/null; fail "server did not become healthy (no local_url/health)"; }

# (1) install-pi.sh --check — reports without mutating; must succeed (Bun + runtime present).
"$INSTALL" --check >"$SBX/check.log" 2>&1 || { echo "--- check.log ---"; cat "$SBX/check.log"; fail "install-pi.sh --check reported INCOMPATIBLE"; }
grep -q "runtime/pi    OK" "$SBX/check.log" || { cat "$SBX/check.log"; fail "install-pi.sh --check did not confirm the vendored runtime"; }

# (2) /health probe — the booted hub answers ok:true.
HEALTH="$(curl -fsS --max-time 2 "$URL/health" 2>/dev/null || true)"
case "$HEALTH" in
  *'"ok":true'*) : ;;
  *) fail "coms-net /health did not return ok:true (got: $HEALTH)" ;;
esac

# (3) the glass-wall ACL deny/allow matrix on the real send path (client gate).
bun "$PROBE_TS" "$URL" "$TOK" "$PROJECT" || fail "glass-wall ACL probe failed (upstream send not denied, or downstream/ripple not allowed)"

# (4) F2 — the HUB itself must enforce the ACL: direct POSTs to /v1/messages that bypass the
#     client gate (a compromised resident / any token holder) must be rejected server-side.
BYPASS_TS="$PLUGIN/tests/smoke/phase8-coms-net-bypass-probe.ts"
[ -f "$BYPASS_TS" ] || fail "hub-ACL bypass probe missing at $BYPASS_TS"
bun "$BYPASS_TS" "$URL" "$TOK" "$PROJECT" || fail "hub did not enforce the glass-wall ACL on a direct /v1/messages POST (server-side bypass)"

# (5) codex round-2..4 — every session-scoped endpoint (SSE, response submit, get, await,
#     heartbeat, delete) is bound to the per-session token; role identity is bound to a launcher
#     capability (role-mint rejected); duplicate role residents stay ACL-resolvable.
SESSION_AUTH_TS="$PLUGIN/tests/smoke/phase8-coms-net-session-auth-probe.ts"
[ -f "$SESSION_AUTH_TS" ] || fail "session-auth probe missing at $SESSION_AUTH_TS"
bun "$SESSION_AUTH_TS" "$URL" "$TOK" "$PROJECT" || fail "a session-scoped endpoint is not token-bound, role-mint is not blocked, or a duplicate resident can't resolve"

echo "PASS: vendored coms-net boots under Bun; install --check + /health OK; glass-wall ACL holds (client + hub); session endpoints token-bound; role identity capability-bound"
