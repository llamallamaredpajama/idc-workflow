#!/bin/bash
# idc-assert-class: behavior
# engine-claim-reclaim-attribution.sh — governance scenario: re-claiming an already-In Progress item
# still records the CURRENT agent and journals the (re)claim (#160).
#
# The claim idempotence early-return used to skip records_agent AND the journal entirely: a session
# resumed after a rate-limit death re-claimed its item as a silent board no-op — no claim comment
# named the resuming agent, no claim was journaled, and ownership observability went stale. The
# documented claim contract is status + ATTRIBUTION; on a reclaim only the Status write is
# redundant. This pins the fix: claim twice with two agents →
#   * the reclaim stays exit 0 (idempotent — Status untouched at In Progress);
#   * BOTH attribution comments exist on the item;
#   * BOTH claims are journaled (the reclaim record self-identifies: In Progress -> In Progress);
#   * journal replay stays clean (a reclaim record never manufactures a divergence).
#
# Red-when-broken: restore the bare early-return (drop record_owner + journal_append from the
# idempotent claim branch) → the agent-beta attribution and the second journal record vanish → the
# attribution assert and the two-records assert FAIL.
#
# Usage: bash tests/smoke/governance/engine-claim-reclaim-attribution.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

N="$(eng create-ticket --title 'reclaim: attribution survives resume' | tail -1)" \
  || fail "could not create the buildable ticket"

eng claim --num "$N" --agent agent-alpha >/dev/null || fail "first claim was refused"
[ "$(gov_field "$T" "$N" Status)" = "In Progress" ] || fail "first claim did not land In Progress"

echo "== the reclaim (same item, a DIFFERENT agent — the resumed session) stays exit 0 =="
eng claim --num "$N" --agent agent-beta >/dev/null \
  || fail "idempotent reclaim was refused — a resumed session must be able to re-claim (exit 0)"
[ "$(gov_field "$T" "$N" Status)" = "In Progress" ] || fail "the reclaim disturbed Status"
echo "  ok reclaim is idempotent on Status (In Progress, exit 0)"

echo "== BOTH attributions exist on the item (claim = status + attribution, reclaim included) =="
grep -q "claimed by agent-alpha" "$T" || fail "the first claim's attribution comment is missing"
grep -q "claimed by agent-beta" "$T" \
  || fail "the reclaim's attribution comment is missing — the early-return skipped records_agent (#160)"
echo "  ok both agents are attributed on the item"

echo "== BOTH claims are journaled; the reclaim record self-identifies =="
[ -f "$JOURNAL" ] || fail "no transition journal was written"
python3 - "$JOURNAL" "$N" <<'PY' || fail "expected TWO journaled claim records (initial + reclaim), each attributed"
import json, sys
journal, num = sys.argv[1], int(sys.argv[2])
claims = []
for line in open(journal, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    rec = json.loads(line)
    if rec.get("op") == "claim" and rec.get("item") == num:
        claims.append(rec)
assert len(claims) == 2, f"expected 2 claim records for #{num}, got {len(claims)}: {claims}"
assert claims[0].get("who") == "agent-alpha", f"first claim misattributed: {claims[0]}"
assert claims[1].get("who") == "agent-beta", f"reclaim unjournaled/misattributed: {claims[1]}"
assert "In Progress -> In Progress" in claims[1].get("what", ""), \
    f"the reclaim record does not self-identify as a reclaim: {claims[1]}"
print("  ok two claim records, both attributed; the reclaim reads In Progress -> In Progress")
PY

echo "== replay stays clean after the journaled reclaim (no false divergence) =="
python3 "$GOV_PLUGIN/scripts/idc_journal_replay.py" --journal "$JOURNAL" --tracker "$T" \
  || fail "journal replay reported a divergence after the journaled reclaim"
echo "  ok replay reconciles (the reclaim's to-state equals the board state)"

echo "PASS: a reclaim of an already-In Progress item records the current agent and journals the (re)claim, stays idempotent on Status, and replays clean"
