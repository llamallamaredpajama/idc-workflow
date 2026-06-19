#!/bin/bash
# Phase 8 smoke — drives tests/smoke/phase8-pi-guard-acl.ts under Bun: the per-role guard ACL
# (evaluatePathForRole / evaluateBashForRole) holds the fail-closed file-write guarantee AND the
# pi-guard-fix locks (B1 subshell/brace, B2 git -C, BR build-review board read-only, M3 case-fold,
# the scoped git grant, force-push/merge scoping, and the MG-B review-verdict merge interlock).
#
# Usage: bash tests/smoke/phase8-pi-guard-acl.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE="$PLUGIN/tests/smoke/phase8-pi-guard-acl.ts"

fail() { echo "FAIL: $1"; exit 1; }
command -v bun >/dev/null 2>&1 || fail "bun not found on PATH (required to import the real guard module)"
[ -f "$PROBE" ] || fail "guard ACL probe missing at $PROBE"

bun "$PROBE" || fail "per-role guard ACL probe failed (see assertion lines above)"
