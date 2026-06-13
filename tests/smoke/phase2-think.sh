#!/bin/bash
# Phase 2 smoke — a function-first consideration passes the schema check; a malformed one
# fails it. REAL functional test of the shipped consideration checker. Failing-test-first:
# fails until scripts/idc_consideration_check.py exists.
#
# Usage: bash tests/smoke/phase2-think.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$PLUGIN/scripts/idc_consideration_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$CHK" ] || fail "consideration checker not found at $CHK (not implemented yet)"

# a well-formed, function-first consideration (what /idc:think emits)
cat > "$WORK/good.md" <<'MD'
# Dark mode toggle — Consideration

- Date: 2026-06-12
- Status: Active
- PRD impact: yes — adds a user-visible appearance setting.

## What this does for the user

The user gets a Light / Dark / System appearance toggle in Settings. Their choice
persists across sessions and applies instantly across every screen.

## Behavior by domain

- **settings**: a new appearance control; persisted per account.
- **ui**: a theme provider that re-renders on toggle without a reload.

## Open questions

- Should "System" follow the OS at runtime, or only at launch?
MD

python3 "$CHK" "$WORK/good.md" >/dev/null || fail "valid consideration was rejected by the schema check"

# a malformed consideration: no function-first section, no Open questions, no PRD impact
cat > "$WORK/bad.md" <<'MD'
# Some notes

Random thoughts about a feature with no structure.
MD

if python3 "$CHK" "$WORK/bad.md" >/dev/null 2>&1; then
  fail "malformed consideration was accepted (the check must reject it)"
fi

echo "PASS: consideration schema check accepts a function-first consideration and rejects a malformed one"
