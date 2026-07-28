#!/bin/bash
# idc-assert-class: behavior
# planning-receipt-write-witness-atomic.sh — F54: writing the planning receipt to disk and recording its
# out-of-tree witness must be ONE critical section under the witness-store lock.
#
# THE RACE. `write_receipt` used to `atomic_write_json` the receipt FIRST and only then call
# `record_planning_witness`, which takes the store lock internally. Two same-label writers could
# interleave as:
#     A: replace file with bytes A  ->  A: lock, witness bytes A, unlock
#     B: replace file with bytes B  ->  B: dies before witnessing
# leaving the FINAL on-disk bytes (B) with no witness at all, while the only recorded witness describes
# bytes that no longer exist. A later Build freeze then refuses to borrow the receipt — a Plan that
# reported success cannot be built. The F38 same-path guard cannot repair this: it acts at RECORD time
# and cannot retroactively invalidate the witness A already recorded.
#
# THE PROOF (deterministic, no sleeps racing each other). This test holds the witness-store lock in the
# parent process — standing in for a writer that is mid-critical-section — and then runs a second writer
# through the real `write_receipt`. While the lock is held the second writer MUST NOT have replaced the
# file: if the replace is inside the section it blocks at lock acquisition, so the on-disk bytes are
# still the first writer's. Releasing the lock lets it finish, after which the on-disk bytes and the
# recorded witness must agree.
#
# Red-when-broken: move the `atomic_write_json` back outside the lock (drop the `write_receipt=` callable
# and write before calling the recorder) and the "still v1 while the lock is held" assertion fails — the
# second writer replaces the file while the first is still inside its critical section.
#
# Usage: bash tests/smoke/governance/planning-receipt-write-witness-atomic.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
PR="$PLUGIN/scripts/idc_planning_receipt.py"
VC="$PLUGIN/scripts/idc_validation_contract.py"
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$PR" ] || fail "missing planning-receipt helper: scripts/idc_planning_receipt.py"
[ -f "$VC" ] || fail "missing validation-contract helper: scripts/idc_validation_contract.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init

RECEIPT="$REPO/docs/workflow/planning-receipts/alpha.json"

# Writer 1 — the baseline receipt (v1), written and witnessed normally.
python3 - "$PLUGIN/scripts" "$REPO" "$RECEIPT" <<'PY' || fail "could not write the baseline receipt"
import sys
scripts, repo, path = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_planning_receipt as PR
PR.write_receipt(repo, path, {"label": "alpha", "version": "v1"})
PY
grep -q '"v1"' "$RECEIPT" || fail "the baseline receipt was not written to $RECEIPT"

# Writer 2 — runs the REAL write_receipt for v2 while the parent holds the witness-store lock.
cat > "$WORK/writer2.py" <<'PY'
import sys
scripts, repo, path = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_planning_receipt as PR
PR.write_receipt(repo, path, {"label": "alpha", "version": "v2"})
print("writer2 done")
PY

# The parent holds the lock, releases writer 2, and samples the file while still inside the section.
python3 - "$PLUGIN/scripts" "$REPO" "$RECEIPT" "$WORK/writer2.py" <<'PY'
import os, subprocess, sys, time
scripts, repo, path, writer2 = sys.argv[1:5]
sys.path.insert(0, scripts)
import idc_validation_contract as VC

cgd = VC._common_git_dir(repo)
before = open(path, "rb").read()

with VC._witness_store_lock(cgd):                 # stand in for a writer mid-critical-section
    proc = subprocess.Popen([sys.executable, writer2, scripts, repo, path],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    time.sleep(1.5)                               # ample time to replace the file if it were unlocked
    during = open(path, "rb").read()
    still_running = proc.poll() is None

if during != before:
    print("FAIL: the second writer replaced the receipt while the witness-store lock was held — the "
          "disk write is OUTSIDE the critical section, so a crash before witnessing would leave the "
          "final bytes unwitnessed (F54)")
    proc.kill(); sys.exit(1)
if not still_running:
    print("FAIL: the second writer completed while the lock was held — it never entered the locked "
          "critical section at all (F54)")
    sys.exit(1)

out, _ = proc.communicate(timeout=60)
if proc.returncode != 0:
    print("FAIL: the second writer did not finish after the lock was released: %s" % out)
    sys.exit(1)

after = open(path, "rb").read()
if after == before:
    print("FAIL: the second writer never replaced the receipt even after the lock was released")
    sys.exit(1)

# The FINAL on-disk bytes must be the ones that are witnessed — the property the race destroyed.
store = VC._read_witnesses(cgd) or {}
import hashlib
digest = hashlib.sha256(after).hexdigest()
key = VC._planning_witness_key(VC._planning_witness_context(os.path.abspath(path))[2])
entry = store.get(key) or {}
versions = entry.get("witnesses") or {}
if digest not in versions:
    print("FAIL: the final on-disk receipt bytes have no recorded witness — a Build would refuse a Plan "
          "that reported success (F54). witnessed digests: %s" % sorted(versions))
    sys.exit(1)
print("ok: the receipt replacement is inside the witness-store lock, and the final on-disk bytes are "
      "witnessed")
PY
[ $? -eq 0 ] || fail "the receipt write and its witness are not one critical section (F54)"

echo "PASS: the planning-receipt disk write and its out-of-tree witness happen in ONE locked critical section — a concurrent same-label writer cannot replace the receipt between another writer's replace and its witness, so the final on-disk bytes are never left unwitnessed (F54)"
