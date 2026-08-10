#!/bin/bash
# idc-assert-class: behavior
# pathway-stanza-undeclared.sh — an ABSENT pathway_enforcement stanza is its own reported fact.
#
# The runtime Path Gate answers `off` for "explicitly off", "declares no mode", and "cannot read the
# config" alike. That is the right fail-closed default for enforcement, and it is also how a
# fully-governed github-backed repo ran with EVERY Path Gate denial downgraded to an advisory while its
# operator believed it was enforcing: a WORKFLOW-config.yaml written before the stanza existed reads
# exactly like a deliberate `mode: off`, and nothing anywhere said so. This proves the DIAGNOSTIC door
# tells those apart, and that the runtime downgrade now names its own cause.
#
# Proves, on hermetic throwaway repos:
#   1. github backend + no stanza            -> the doctor door exits 3 (UNDECLARED) and prints the
#                                               stanza to paste, plus that IDC will not write it;
#   2. github backend + explicit `mode: off` -> exit 0; a DECLARED posture is a choice, still a pass;
#   3. github backend + a typo'd mode        -> exit 2; malformed stays INDETERMINATE (F10), not 3;
#   4. filesystem backend + no stanza        -> exit 0; no integration boundary, so silence is right;
#   5. a downgraded denial names the cause   -> the `observe` string says the stanza is ABSENT.
#
# Red-when-broken (reviewed): make classify() fall through to EXIT_HONEST for an absent stanza => 1
# flips; drop the `!= FILESYSTEM_BACKEND` guard => 4 flips; move the UNDECLARED check above the
# UNKNOWN_MODE check => 3 flips; make pathway_mode_state() report "declared" for a missing key => 1
# and 5 flip; drop the _observe_cause() suffix from evaluate_request => 5 flips.
#
# Usage: bash tests/smoke/governance/pathway-stanza-undeclared.sh
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DOOR="$GOV_PLUGIN/scripts/idc_doctor_pathway_check.py"
[ -f "$DOOR" ] || gov_fail "scripts/idc_doctor_pathway_check.py not found"

WORK="$(mktemp -d)" || gov_fail "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# seed <name> <tracker-backend> [workflow-config line...] -> echoes the repo root.
# With no config lines the WORKFLOW-config.yaml carries NO pathway_enforcement stanza at all.
seed() {
  local name="$1" backend="$2" r
  shift 2
  r="$WORK/$name"
  mkdir -p "$r/docs/workflow" || return 1
  printf 'backend: %s\n' "$backend" > "$r/docs/workflow/tracker-config.yaml" || return 1
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$r/WORKFLOW-config.yaml" || return 1
  else
    printf 'backend: %s\ntracker:\n  project: 5\n' "$backend" > "$r/WORKFLOW-config.yaml" || return 1
  fi
  printf '%s' "$r"
}

# run_door <repo> -> echoes the exit code; stdout/stderr land in $WORK/out and $WORK/err.
run_door() {
  python3 "$DOOR" --repo "$1" >"$WORK/out" 2>"$WORK/err"
  echo "$?"
}

# ── 1. github + absent stanza => UNDECLARED, carrying the remedy ───────────────────────────────────
R="$(seed gh-absent github)" || gov_fail "could not seed the absent-stanza repo"
code="$(run_door "$R")"
[ "$code" = "3" ] || gov_fail "github repo with no pathway_enforcement stanza: expected exit 3 (UNDECLARED), got $code (stderr: $(cat "$WORK/err"))"
grep -q 'pathway_enforcement:' "$WORK/err" || gov_fail "the UNDECLARED row does not print the stanza to paste"
grep -q 'mode: controlled' "$WORK/err" || gov_fail "the UNDECLARED row does not name the mode to adopt"
grep -qi 'operator data' "$WORK/err" || gov_fail "the UNDECLARED row does not say IDC will never write the stanza"
grep -qi 'idc/pathway-integrity' "$WORK/err" || gov_fail "the UNDECLARED row does not name what adopting controlled requires"
[ -s "$WORK/out" ] && gov_fail "an UNDECLARED verdict must not print an honest-looking line on stdout"

# ── 2. a DECLARED off posture is a deliberate choice and stays a pass ──────────────────────────────
R="$(seed gh-off github 'backend: github' 'pathway_enforcement:' '  mode: off')" \
  || gov_fail "could not seed the declared-off repo"
code="$(run_door "$R")"
[ "$code" = "0" ] || gov_fail "github repo declaring mode: off: expected exit 0, got $code (stderr: $(cat "$WORK/err"))"

# ── 3. a MALFORMED mode is still INDETERMINATE, never the new UNDECLARED answer (F10) ─────────────
R="$(seed gh-typo github 'backend: github' 'pathway_enforcement:' '  mode: contolled')" \
  || gov_fail "could not seed the typo'd-mode repo"
code="$(run_door "$R")"
[ "$code" = "2" ] || gov_fail "github repo with a typo'd mode: expected exit 2 (INDETERMINATE), got $code"

# ── 4. filesystem has no integration boundary to enforce; absent stays quiet ───────────────────────
R="$(seed fs-absent filesystem 'backend: filesystem')" || gov_fail "could not seed the filesystem repo"
code="$(run_door "$R")"
[ "$code" = "0" ] || gov_fail "filesystem repo with no stanza: expected exit 0, got $code (stderr: $(cat "$WORK/err"))"

# ── 5. the runtime downgrade must say WHY it is only observing ─────────────────────────────────────
R="$(seed gh-observe github)" || gov_fail "could not seed the observe-cause repo"
observe="$(PYTHONPATH="$GOV_PLUGIN/scripts" python3 - "$R" <<'PY'
import sys
import idc_path_gate as PG
decision = PG.evaluate_request(sys.argv[1], "", {"action": "write", "paths": ["TRACKER.md"]})
print(decision.get("observe") or "")
PY
)" || gov_fail "could not drive evaluate_request against the absent-stanza repo"
[ -n "$observe" ] || gov_fail "an absent-stanza repo did not downgrade the protected-surface denial to observe"
case "$observe" in
  *ABSENT*) : ;;
  *) gov_fail "the observe string does not name the absent stanza as the cause: $observe" ;;
esac
case "$observe" in
  *"Path Gate denied"*) : ;;
  *) gov_fail "the observe string dropped the underlying would-be-denial reason: $observe" ;;
esac

echo "PASS: pathway-stanza-undeclared"
