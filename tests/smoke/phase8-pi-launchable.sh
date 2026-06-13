#!/bin/bash
# Phase 8 smoke (F1) — the VENDORED Pi runtime is self-complete: every harness file that
# `idc-pi run <role>` actually loads (the `-e` extensions and the `--append-system-prompt`
# role prompt) exists under the vendored runtime/pi tree, so a fresh clone can boot.
#
# REAL seam: drives the actual launcher via `run <role> --dry-run` (which prints the exact
# command it would exec) with PI_IDC_HARNESS_REPO pinned to the vendored tree (clean-room) —
# it does NOT re-implement the path list, so it can't drift from the launcher.
#
# Failing-test-first: before vendoring, extensions/minimal.ts, extensions/theme-cycler.ts and
# the .pi/agents/idc/*.md prompt tree are missing, so the launcher references files that aren't
# there — this fails. Vendoring those files (and hardening install-pi.sh --check to verify the
# real launch set) turns it green.
#
# NOT asserted: operator-provided install-time deps that live OUTSIDE the harness tree — the
# `pi` agent binary and the role `--skill` packages — same posture as install-pi.sh (a merely
# absent Pi agent is a WARN, not a hard fail). Only harness-owned files are checked here.
#
# Usage: bash tests/smoke/phase8-pi-launchable.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN/runtime/pi/scripts/idc-pi"
RT="$PLUGIN/runtime/pi"
INSTALL="$PLUGIN/scripts/install-pi.sh"
ROLES="think plan sequence ripple build-impl build-review build-finish"

fail() { echo "FAIL: $1"; exit 1; }
[ -f "$LAUNCHER" ] || fail "vendored launcher missing at $LAUNCHER"
[ -f "$INSTALL" ]  || fail "install-pi.sh missing at $INSTALL"

# Collect every harness-rooted path the REAL launcher emits across all roles.
paths="$(for role in $ROLES; do
  PI_IDC_HARNESS_REPO="$RT" bash "$LAUNCHER" run "$role" --dry-run 2>/dev/null \
    | grep -oE "'$RT[^']*'" | tr -d "'"
done | sort -u)"
[ -n "$paths" ] || fail "launcher emitted no harness-rooted paths (is `run --dry-run` broken?)"

missing=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  if [ ! -e "$p" ]; then
    echo "  MISSING (launcher loads it, not vendored): ${p#"$PLUGIN"/}"
    missing=$((missing + 1))
  fi
done <<EOF
$paths
EOF
[ "$missing" -eq 0 ] || fail "$missing harness file(s) the launcher loads are not vendored — fresh install can't boot"

# install-pi.sh --check must pass and (after the fix) verify the real launch set fail-closed.
"$INSTALL" --check >/dev/null 2>&1 || { "$INSTALL" --check; fail "install-pi.sh --check failed (vendored runtime incomplete)"; }

echo "PASS: every harness file idc-pi run loads is vendored ($(printf '%s\n' "$paths" | grep -c .) paths verified)"
