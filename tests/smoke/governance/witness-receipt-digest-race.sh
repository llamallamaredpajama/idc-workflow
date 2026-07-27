#!/bin/bash
# idc-assert-class: behavior
# witness-receipt-digest-race.sh — F38: recording a planning-receipt witness must take the byte-digest
# key and the receipt's self-digest from ONE locked read of the file, so a concurrent same-path rewrite
# cannot bind one version's bytes to another version's receipt_digest and leave the on-disk receipt
# un-borrowable.
#
# THE RACE (F38). `record_planning_witness` used to compute the receipt byte-digest OUTSIDE any lock
# spanning the receipt-file write. Two concurrent same-label writes to the SAME receipt path could then
# interleave: A writes bytes A; B writes bytes B and records a consistent witness (digest_B ->
# receipt_digest_B); A then digests the now-current bytes B but records ITS stale receipt_digest_A,
# OVERWRITING the bucket entry as (digest_B -> receipt_digest_A). Build borrows the on-disk bytes B,
# finds a witness for digest_B, but its stored receipt_digest is A's -> rejected at the receipt
# self-consistency check. The legitimate on-disk receipt is left un-borrowable (fail-closed availability
# loss — the very recirc-batched-Plan scenario F27 worried about).
#
# This lane reproduces the interleaving DETERMINISTICALLY (a live thread race would be flaky and this is
# a trace-level race): write A, then B clobbers the path and records, then A records last against B's
# bytes. The load-bearing INVARIANT (strategy-agnostic — a fix may refuse the losing racer OR
# self-correct its binding, both are fine): after ANY such interleaving, the receipt whose bytes are on
# disk MUST remain borrowable — the cross-binding must never poison it.
#
# Red-when-broken: revert the F38 fix (digest computed before the lock, no freshness check) and A's
# late record binds digest_B -> receipt_digest_A; the on-disk-B borrow then fails "vouches for a
# different receipt version" and this lane FAILS. Demonstrated during development.
#
# Usage: bash tests/smoke/governance/witness-receipt-digest-race.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$VC" ] || fail "missing build validation-contract helper: scripts/idc_validation_contract.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init

python3 - "$PLUGIN/scripts" "$REPO" <<'PY' || fail "the concurrent same-path witness binding poisoned the on-disk receipt (F38)"
import json, os, sys
scripts, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_validation_contract as VC

path = os.path.join(repo, "docs", "workflow", "planning-receipts", "alpha.json")
os.makedirs(os.path.dirname(path), exist_ok=True)

def write(doc):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, sort_keys=True)
        fh.write("\n")

# Two same-label receipt versions written to the SAME path, with DISTINCT self-digests.
doc_a = {"label": "alpha", "receipt_digest": "a" * 64}
doc_b = {"label": "alpha", "receipt_digest": "b" * 64}

# Interleaving: A writes A; B clobbers with B and records (consistent); A records LAST against B's bytes.
write(doc_a)
write(doc_b)
VC.record_planning_witness(os.path.abspath(path), doc_b)   # winner: digest_B -> receipt_digest_B
try:
    VC.record_planning_witness(os.path.abspath(path), doc_a)  # loser: stale doc_a vs on-disk B bytes
except VC.ValidationError:
    pass   # refusing the losing racer is one valid fix; a self-correcting fix is equally acceptable

# INVARIANT: the receipt whose bytes are ON DISK (B) must be borrowable. The cross-binding must not
# have overwritten digest_B's witness with A's receipt_digest.
on_disk = json.load(open(path, encoding="utf-8"))
problem = VC.planning_witness_problem(os.path.abspath(path), on_disk)
if problem is not None:
    print(f"POISONED: the on-disk receipt is no longer borrowable after a concurrent same-path record: {problem}")
    sys.exit(1)

# And the store must actually carry a machine witness for it (not silently absent).
cgd = VC._common_git_dir(repo)
store = VC._read_witnesses(cgd) or {}
key = VC._planning_witness_key("docs/workflow/planning-receipts/alpha.json")
container = store.get(key) or {}
if not isinstance(container.get("witnesses"), dict) or not container["witnesses"]:
    print("MISSING: no planning witness recorded for the receipt at all")
    sys.exit(1)
print("ok: the on-disk receipt stays borrowable after the concurrent same-path witness record (F38)")
PY

echo "PASS: a concurrent same-path planning-receipt witness record cannot cross-bind one version's bytes to another's receipt_digest — the on-disk receipt stays borrowable (F38)"
