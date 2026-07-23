#!/bin/bash
# tracker-optimistic-concurrency.sh — U5 relevant-concurrency refusal.
# Proves a relevant live tracker change after freeze and before apply invalidates the frozen plan and
# no stale sanctioned mutation lands.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
TXN="$PLUGIN/scripts/idc_tracker_transaction.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$TXN" ] || fail "missing sanctioned tracker transaction helper: no optimistic-concurrency re-read exists yet"

cat > "$WORK/phase1.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
YAML

T="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md"
REPO="$(dirname "$T")"
python3 "$TXN" freeze \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --matrix "$WORK/phase1.yaml" \
  --baseline expected-red \
  --label optimistic-concurrency \
  --out "$WORK/optimistic.freeze.json" >/dev/null \
  || fail "could not freeze a valid expected-red planning bundle"

# Relevant concurrent change: the projected logical item appears/changes after freeze.
CONCURRENT_NUM="$(gov_seed_item "$T" --title alpha --stage Buildable --status Todo --wave 9 --phase "Phase 1" --domain drift)" \
  || fail "could not inject the relevant concurrent live change"
[ "$CONCURRENT_NUM" = "1" ] || fail "expected the concurrent seed to create issue #1, got #$CONCURRENT_NUM"

BEFORE="$(shasum -a 256 "$T" | awk '{print $1}')"
out="$(python3 "$TXN" apply \
  --repo "$REPO" \
  --backend filesystem \
  --tracker "$T" \
  --frozen "$WORK/optimistic.freeze.json" 2>&1)" \
  && fail "stale frozen projection was applied despite a relevant concurrent board change"
AFTER="$(shasum -a 256 "$T" | awk '{print $1}')"
[ "$BEFORE" = "$AFTER" ] \
  || fail "optimistic-concurrency refusal still changed the live tracker ($BEFORE -> $AFTER)"
[ "$(gov_field "$T" 1 Wave)" = "9" ] || fail "concurrency refusal overwrote the concurrent wave change"
[ "$(gov_field "$T" 1 Domain)" = "drift" ] || fail "concurrency refusal overwrote the concurrent domain change"
printf '%s\n' "$out" | grep -qiE 'concurr|stale|re-read|changed since freeze' \
  || fail "concurrency refusal must explain the stale freeze; got: $out"

if [ -d "$REPO/docs/workflow/planning-obligations" ] && find "$REPO/docs/workflow/planning-obligations" -type f | grep -q .; then
  fail "pre-apply concurrency refusal must not leave a partial-apply obligation behind"
fi

echo "PASS: a relevant concurrent tracker change invalidates the frozen projection before apply, leaves the concurrent edit intact, and lands no stale sanctioned mutation"