#!/usr/bin/env bash
# idc-assert-class: behavior
# journal-replay-field-only.sh — a field-only journal record must NOT fabricate a reconciled state
# (Task 3, round-5 Fix 3).
#
# `set-field` (Wave/Phase/Domain) journals an item number but NO Stage/Status target `to` state. The
# replay reconstructor used to `setdefault(item, {})` for ANY resolvable item, so a Wave-only record
# for an item with NO transition history seeded an EMPTY expected-state entry that compares clean
# against any real board item — masking the fact that the item has no create/transition history at
# all. This probe pins the fix: a field-only record must not seed an expected-state entry, so replay
# reports the historyless item as a divergence (present on board, not in journal history), never as
# reconciled.
#
# Red-when-broken: restore the unconditional `setdefault(item, {})` seed → the Wave-only item compares
# clean → the assertion below (that #5 is reported as NOT reconciled) FAILs.
#
# Usage: bash tests/smoke/governance/journal-replay-field-only.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

python3 - "$GOV_PLUGIN/scripts" <<'PY' || gov_fail "journal-replay field-only probe failed (see above)"
import sys, tempfile, os, json
sys.path.insert(0, sys.argv[1])
import idc_journal_replay as R

work = tempfile.mkdtemp()
wf = os.path.join(work, "docs", "workflow")
os.makedirs(wf, exist_ok=True)
journal = os.path.join(wf, "transition-journal.ndjson")

# A single Wave-only `set-field` record for item #5, EXACTLY as journal_append writes it (op=set-field,
# item=5, NO `to` state). Item #5 has NO create/move/close record anywhere — no transition history.
rec = {"when": "2026-01-01T00:00:00Z", "who": "unattributed", "what": "set-field #5",
       "guard_evidence_hash": None, "backend": "filesystem", "repo-relative tracker": None,
       "op": "set-field", "item": 5}
with open(journal, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(rec, sort_keys=True) + "\n")

expected, err = R.reconstruct_state_from_journal(journal)
assert err is None, f"reconstruct returned an error on a well-formed journal: {err}"

# THE fix: a field-only record must NOT seed an expected-state entry for #5.
assert 5 not in expected, \
    f"a Wave-only set-field record fabricated an expected-state entry for #5: {expected!r}"
print("  ok a field-only (Wave) record seeds NO expected-state entry")

# End-to-end: an item present on the board with a REAL Stage/Status must therefore be reported as a
# divergence (present on board, not in journal history) — NOT silently reconciled by the empty seed.
actual = {5: {"stage": "Buildable", "status": "Todo"}}
diffs = R.compare_states(expected, actual)
assert any("#5" in d and "not in journal history" in d for d in diffs), \
    f"a historyless #5 with only a Wave record was reported as reconciled (no divergence): {diffs!r}"
print("  ok a historyless item with only a field-only record is reported as NOT reconciled")
PY

echo "PASS: a field-only journal record does not fabricate a reconciled state (replay flags the missing history)"
