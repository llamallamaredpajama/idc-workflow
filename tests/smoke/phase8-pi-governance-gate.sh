#!/bin/bash
# Phase 8 smoke (F4) — the launcher gates role-resident startup on the governance sidecar,
# fail-closed. A long-lived resident consults the compiled sidecar
# (docs/workflow/idc-governance-contract.yaml) instead of re-reading WORKFLOW.md, so idc-pi must
# prove (scripts/idc_governance_check.py) that the sidecar still matches the governed sources on
# disk BEFORE it execs a resident — otherwise a resident boots on governance it cannot prove.
#
# REAL seam: drives the actual `idc-pi run <role>` exec path with a FAKE `pi` on PATH (the
# resident "boots" harmlessly and prints a marker) against a throwaway governed sandbox repo.
#   A) matching sidecar      -> resident runs
#   B) drift after compile   -> launch BLOCKED before the resident (fail-closed)
#   C) PI_IDC_GOVERNANCE_CHECK=off -> resident runs despite drift (explicit bypass)
#
# Failing-test-first: without the preflight, a drifted sidecar still launches the resident (B
# fails). Wiring the fail-closed gate into command_run turns it green.
#
# Usage: bash tests/smoke/phase8-pi-governance-gate.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN/runtime/pi/scripts/idc-pi"
COMPILE="$PLUGIN/scripts/idc_governance_compile.py"
RT="$PLUGIN/runtime/pi"
SIDECAR_REL="docs/workflow/idc-governance-contract.yaml"

fail() { echo "FAIL: $1"; exit 1; }
[ -f "$LAUNCHER" ] || fail "launcher missing at $LAUNCHER"
[ -f "$COMPILE" ]  || fail "governance compiler missing at $COMPILE"

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
REPO="$SBX/repo"; mkdir -p "$REPO/docs/workflow"

cat > "$REPO/WORKFLOW.md" <<'EOF'
# WORKFLOW.md — governance gate test
## 1. Canonical chain
Think -> Plan -> Build; Ripple is the only retrograde path.
EOF
cat > "$REPO/WORKFLOW-config.yaml" <<'EOF'
workflow:
  schema: idc
  version: 2
project:
  name: gate-test
EOF
cat > "$REPO/docs/workflow/tracker-config.yaml" <<'EOF'
backend: filesystem
EOF

# Fake `pi`: the resident "boots", prints a marker, exits 0 — no real agent/network needed.
BIN="$SBX/bin"; mkdir -p "$BIN"
printf '#!/bin/bash\necho "FAKE-PI-RAN"\nexit 0\n' > "$BIN/pi"
chmod +x "$BIN/pi"

OUT="$SBX/out"
run_role() {  # $1 optional env assignment; combined output -> $OUT; returns the launcher's rc
  local extra_env="${1:-}"
  ( cd "$REPO" && env PATH="$BIN:$PATH" PI_IDC_HARNESS_REPO="$RT" $extra_env \
      bash "$LAUNCHER" run think ) >"$OUT" 2>&1
  return $?
}

# Compile a sidecar matching the current sources.
python3 "$COMPILE" --repo "$REPO" --out "$REPO/$SIDECAR_REL" >/dev/null || fail "governance compile failed"

# (A) matching sidecar -> resident launches.
run_role; rcA=$?
grep -q "FAKE-PI-RAN" "$OUT" || { cat "$OUT"; fail "A: resident did not launch with a matching sidecar"; }
[ "$rcA" -eq 0 ] || { cat "$OUT"; fail "A: launcher exited $rcA with a matching sidecar"; }

# (B) drift a governed source AFTER compile -> launch must be blocked before the resident.
echo "## 2. drift" >> "$REPO/WORKFLOW.md"
run_role; rcB=$?
grep -q "FAKE-PI-RAN" "$OUT" && { cat "$OUT"; fail "B: resident launched despite governance DRIFT (gate missing or not fail-closed)"; }
[ "$rcB" -ne 0 ] || { cat "$OUT"; fail "B: launcher returned 0 despite governance drift"; }

# (C) explicit bypass -> resident launches even with drift present.
run_role "PI_IDC_GOVERNANCE_CHECK=off"; rcC=$?
grep -q "FAKE-PI-RAN" "$OUT" || { cat "$OUT"; fail "C: bypass (PI_IDC_GOVERNANCE_CHECK=off) did not let the resident launch"; }

# (D) the SUPERVISED `idc-pi fleet` is gated too (codex round-5 finding 2) — drift still present, so
#     the fleet must fail-closed BEFORE spawning the hub/residents.
fleet_out="$SBX/fleet.out"
( cd "$REPO" && env PATH="$BIN:$PATH" PI_IDC_HARNESS_REPO="$RT" PI_IDC_RESIDENT_BIN="$BIN/pi" \
    PI_COMS_NET_ROLE_HMAC_KEY="testkey" PI_COMS_NET_HOST="127.0.0.1" PI_COMS_NET_PORT="0" PI_COMS_NET_LOG_QUIET="1" \
    bash "$LAUNCHER" fleet think ) >"$fleet_out" 2>&1
rcD=$?
grep -q "FAKE-PI-RAN" "$fleet_out" && { cat "$fleet_out"; fail "D: fleet spawned residents despite governance DRIFT (fleet bypasses the gate)"; }
[ "$rcD" -ne 0 ] || { cat "$fleet_out"; fail "D: fleet returned 0 despite governance drift"; }

echo "PASS: governance gate blocks drift (fail-closed) for both idc-pi run AND idc-pi fleet; allows a matching sidecar; honors the bypass"
