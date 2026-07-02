#!/bin/bash
# idc-assert-class: behavior
# Phase 8 smoke — the PI_IDC_MODEL umbrella: one provider-qualified model var fills every role
# unless a per-role PI_IDC_<ROLE>_MODEL overrides it (precedence: per-role > umbrella > stock).
# This kills the 7-pin ceremony — the stock defaults otherwise span three providers
# (Anthropic/DeepSeek/OpenAI) no single install has API keys for, so a fresh `idc-pi run` fails
# closed on every role without either the umbrella or 7 per-role vars.
#
# REAL seam: drives `idc-pi run think --dry-run` and reads the actual `--model` value the
# launcher emits — it does NOT re-implement role_model(), so it can't drift.
#
# Failing-test-first: before the umbrella, PI_IDC_MODEL is unread → think falls back to its
# stock default (claude-opus-4-7) → the flash assertion fails. Wiring the umbrella turns it green.
#
# Usage: bash tests/smoke/phase8-pi-model-umbrella.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCHER="$PLUGIN/runtime/pi/scripts/idc-pi"
RT="$PLUGIN/runtime/pi"

fail() { echo "FAIL: $1"; exit 1; }
[ -f "$LAUNCHER" ] || fail "vendored launcher missing at $LAUNCHER"

# the umbrella alone fills think's model. `env -u PI_IDC_THINK_MODEL` keeps this hermetic:
# operators often carry a per-role PI_IDC_*_MODEL in their shell profile (per-role WINS over the
# umbrella), which would otherwise mask the umbrella and false-fail this assertion. join_shell
# single-quotes each arg, so --model + value are separate tokens ('--model' '<value>').
umb="$(env -u PI_IDC_THINK_MODEL PI_IDC_HARNESS_REPO="$RT" PI_IDC_MODEL=google/gemini-2.5-flash \
       bash "$LAUNCHER" run think --dry-run 2>/dev/null | grep -oE "'--model' '[^']+'" | head -1)"
[ -n "$umb" ] || fail "think --dry-run emitted no --model (launcher broken?)"
printf '%s' "$umb" | grep -q -- 'google/gemini-2.5-flash' \
  || fail "PI_IDC_MODEL umbrella should set think's model to google/gemini-2.5-flash — got: $umb"

# a per-role var STILL WINS over the umbrella (precedence: per-role > umbrella)
per="$(PI_IDC_HARNESS_REPO="$RT" PI_IDC_MODEL=google/gemini-2.5-flash PI_IDC_THINK_MODEL=google/gemini-2.5-pro \
       bash "$LAUNCHER" run think --dry-run 2>/dev/null | grep -oE "'--model' '[^']+'" | head -1)"
printf '%s' "$per" | grep -q -- 'google/gemini-2.5-pro' \
  || fail "per-role PI_IDC_THINK_MODEL must WIN over the umbrella — got: $per"
printf '%s' "$per" | grep -q -- 'google/gemini-2.5-flash' \
  && fail "per-role must win over umbrella (the umbrella flash leaked through) — got: $per"

echo "PASS: PI_IDC_MODEL umbrella fills every role; per-role PI_IDC_<ROLE>_MODEL wins over it"
