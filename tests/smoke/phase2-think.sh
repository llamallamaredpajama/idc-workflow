#!/bin/bash
# Phase 2 smoke — Think is the requirements admission seat (v3): it crystallizes the
# consideration into a PRD+TRD draft and fires the one gate at the END of Think on the Think PR.
# Two real surfaces are checked:
#   (a) the shipped consideration checker — a function-first consideration that declares BOTH a
#       PRD impact and a TRD impact passes; one missing the TRD-impact declaration is rejected
#       (Think now drives a PRD *and* a TRD draft, so the consideration must signal both);
#   (b) command-prose invariants on commands/think.md — Think opens the Think PR + gate issue
#       (`idc:idc-gate-issue`) and authors the TRD; the gate no longer "lives in Plan".
# Failing-test-first: fails until scripts/idc_consideration_check.py exists.
#
# Usage: bash tests/smoke/phase2-think.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$PLUGIN/scripts/idc_consideration_check.py"
THINK="$PLUGIN/commands/think.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
has()  { grep -qiE "$2" "$1"; }   # file, regex

[ -f "$CHK" ] || fail "consideration checker not found at $CHK (not implemented yet)"

# ---- (a) consideration checker: PRD+TRD-driven shape ------------------------------
# a well-formed, function-first consideration (what /idc:think emits) — it drives BOTH a PRD
# draft (the user-facing *what*) and a TRD draft (the technical *how*), so it declares both.
cat > "$WORK/good.md" <<'MD'
# Dark mode toggle — Consideration

- Date: 2026-06-12
- Status: Active
- PRD impact: yes — adds a user-visible appearance setting.
- TRD impact: yes — adds a theme provider + a persisted appearance preference.

## What this does for the user

The user gets a Light / Dark / System appearance toggle in Settings. Their choice
persists across sessions and applies instantly across every screen.

## Behavior by domain

- **settings**: a new appearance control; persisted per account.
- **ui**: a theme provider that re-renders on toggle without a reload.

## Open questions

- Should "System" follow the OS at runtime, or only at launch?
MD
python3 "$CHK" "$WORK/good.md" >/dev/null || fail "valid PRD+TRD consideration was rejected by the schema check"

# a consideration that declares the PRD impact but NOT the TRD impact: Think drives a TRD draft
# too, so the check MUST reject a consideration that omits the TRD-impact declaration. This is the
# guard that proves Think authors+gates the TRD (not just the PRD) — break it (drop the TRD-impact
# requirement) and this assertion fails red.
cat > "$WORK/no-trd.md" <<'MD'
# Half-stated idea — Consideration

- Date: 2026-06-12
- Status: Active
- PRD impact: yes — adds a setting.

## What this does for the user

The user gets a new toggle.

## Open questions

- none
MD
if python3 "$CHK" "$WORK/no-trd.md" >/dev/null 2>&1; then
  fail "a consideration missing the TRD-impact declaration was accepted (Think drives a PRD+TRD draft — the check must require both)"
fi

# a malformed consideration: no function-first section, no Open questions, no impact lines
cat > "$WORK/bad.md" <<'MD'
# Some notes

Random thoughts about a feature with no structure.
MD
if python3 "$CHK" "$WORK/bad.md" >/dev/null 2>&1; then
  fail "malformed consideration was accepted (the check must reject it)"
fi

# ---- (b) command-prose invariants: Think holds the gate (v3) ----------------------
[ -f "$THINK" ] || fail "commands/think.md missing"
# The gate moved to the END of Think: Think opens the Think PR and the operator gate issue.
has "$THINK" 'Think PR' \
  || fail "think.md must open the Think PR (the requirements admission gate at the end of Think)"
has "$THINK" 'idc:idc-gate-issue' \
  || fail "think.md must fire the one gate via idc:idc-gate-issue (the gate now lives at the end of Think, not in Plan)"
has "$THINK" 'TRD' \
  || fail "think.md must author the TRD (it now crystallizes a PRD + TRD draft)"
# It must NOT punt the gate downstream to Plan any more (the v2 'the gate lives in Plan' doctrine).
if grep -qiE 'gate (lives|is) in plan|plan owns the gate' "$THINK"; then
  fail "think.md still says the gate lives in Plan — the gate moved to the end of Think"
fi

echo "PASS: Think drives a PRD+TRD-gated consideration and fires the one gate at the end of Think"
