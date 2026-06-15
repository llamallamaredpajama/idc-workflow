#!/bin/bash
# Phase 7 (update staleness guard) smoke — fix/update-data-config-preserve.
#
# /idc:update Phase 0 must halt when the running command body is OLDER than the newest plugin
# version in Claude Code's version-keyed cache (a mid-session update leaves the session running
# stale logic against a newer install — the trap that re-introduces just-fixed bugs). This tests
# scripts/idc_plugin_freshness.py against a fabricated cache tree. Hermetic; no GitHub, no network.
#
# Usage: bash tests/smoke/phase7-update-staleness-guard.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_plugin_freshness.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "freshness helper not found at $HELPER"

# Fabricate a version-keyed cache: .../idc/{2.1.3,2.1.4}, each with a manifest stating its version.
CACHE="$SBX/cache/idc-workflow/idc"
for v in 2.1.3 2.1.4 2.1.10; do
  mkdir -p "$CACHE/$v/.claude-plugin"
  printf '{\n  "name": "idc",\n  "version": "%s"\n}\n' "$v" > "$CACHE/$v/.claude-plugin/plugin.json"
done

verdict() { python3 "$HELPER" --plugin-root "$1"; }

# 1. Running an OLD version while newer ones are cached -> stale, exit 4.
out="$(verdict "$CACHE/2.1.3")"; rc=$?
[ "$rc" -eq 4 ] || fail "running 2.1.3 with 2.1.4/2.1.10 cached must exit 4 (stale); got $rc — [$out]"
printf '%s' "$out" | grep -q 'verdict stale' || fail "expected 'verdict stale'; got [$out]"
# 2.1.10 must sort ABOVE 2.1.3 numerically (not lexically) as installed-max.
printf '%s' "$out" | grep -q 'installed-max 2.1.10' || fail "version compare must be numeric (max 2.1.10); got [$out]"

# 2. Running the NEWEST cached version -> current, exit 0.
out="$(verdict "$CACHE/2.1.10")"; rc=$?
[ "$rc" -eq 0 ] || fail "running the newest cached version must exit 0 (current); got $rc — [$out]"
printf '%s' "$out" | grep -q 'verdict current' || fail "expected 'verdict current'; got [$out]"

# 3. A --plugin-dir-style dev root (no version siblings) -> unknown, exit 0 (never block dev runs).
DEV="$SBX/devcheckout"; mkdir -p "$DEV/.claude-plugin"
printf '{\n  "name": "idc",\n  "version": "9.9.9"\n}\n' > "$DEV/.claude-plugin/plugin.json"
out="$(verdict "$DEV")"; rc=$?
[ "$rc" -eq 0 ] || fail "a dev checkout with no cache siblings must exit 0 (unknown); got $rc — [$out]"
printf '%s' "$out" | grep -q 'verdict unknown' || fail "expected 'verdict unknown' for a dev root; got [$out]"

# 4. The real shipped helper resolves its own version from this checkout's manifest (smoke that
#    read_version works against a real manifest); verdict is current/unknown, never stale/error.
out="$(verdict "$PLUGIN")"; rc=$?
[ "$rc" -ne 2 ] || fail "freshness helper usage error against the real plugin root: [$out]"

echo "PASS: idc_plugin_freshness.py flags a stale-session load (numeric compare) and never blocks dev/unknown"
