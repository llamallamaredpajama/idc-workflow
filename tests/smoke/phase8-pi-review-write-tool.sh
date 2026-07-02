#!/bin/bash
# idc-assert-class: behavior
# Phase 8 smoke — the launcher's role_tools() grants build-review the `write` tool (its one
# write lane: the merge-gating verdict JSON under docs/workflow/code-reviews/**), while every
# other authoring role keeps write+edit. Regression guard for the incomplete fix that added
# `write` to build-reviewer.md + the guard allowlist (BUILD_REVIEW_ALLOWED) but left role_tools()
# stripping it — so build-review's write call returned "Tool write not found", no verdict was
# written, and build-finish's MG-B gate blocked EVERY merge.
#
# REAL seam: drives `idc-pi run <role> --dry-run` and reads the actual `--tools` value the
# launcher emits — it does NOT re-implement role_tools(), so it can't drift. The harness guard
# (phase8-pi-guard-acl.ts) already proves the path-policy allows code-reviews/**; this proves
# the TOOL that reaches that guard is actually registered.
#
# Failing-test-first: before the role_tools() fix, build-review's --tools is `read,bash,...`
# (no write) → this fails. Granting write (not edit) turns it green.
#
# Usage: bash tests/smoke/phase8-pi-review-write-tool.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN/runtime/pi/scripts/idc-pi"
RT="$PLUGIN/runtime/pi"

fail() { echo "FAIL: $1"; exit 1; }
[ -f "$LAUNCHER" ] || fail "vendored launcher missing at $LAUNCHER"

# the shell-quoted `--tools` pair the launcher emits for a role (join_shell single-quotes each
# arg, so it's '--tools' '<value>' — two tokens). Isolating the pair keeps the value check off
# any unrelated env echo.
tools_for() {
  PI_IDC_HARNESS_REPO="$RT" bash "$LAUNCHER" run "$1" --dry-run 2>/dev/null \
    | grep -oE "'--tools' '[^']+'" | head -1
}

# build-review MUST have write (verdict artifact lane) and MUST NOT have edit (least privilege)
br="$(tools_for build-review)"
[ -n "$br" ] || fail "build-review --dry-run emitted no --tools (launcher broken?)"
printf '%s' "$br" | grep -q 'read,write,' \
  || fail "build-review --tools must include write (verdict artifact lane) — got: $br"
printf '%s' "$br" | grep -q ',edit,' \
  && fail "build-review --tools must NOT include edit (least privilege — verdict is created fresh) — got: $br"

# build-impl MUST keep write+edit (full source authoring)
bi="$(tools_for build-impl)"
[ -n "$bi" ] || fail "build-impl --dry-run emitted no --tools (launcher broken?)"
printf '%s' "$bi" | grep -q 'read,write,' || fail "build-impl --tools must include write — got: $bi"
printf '%s' "$bi" | grep -q ',edit,'     || fail "build-impl --tools must include edit — got: $bi"

echo "PASS: role_tools() grants build-review write (verdict lane, no edit); build-impl keeps write+edit"
