#!/bin/bash
# idc-assert-class: behavior
# witness-store-concurrent-write.sh — F30: the shared witness store's read-modify-write must be
# serialized, so a concurrent write cannot DROP a just-recorded witness.
#
# The store is ONE file in the git COMMON dir, written by stages that run concurrently in different
# linked worktrees of the same repo: a Plan recording a PLANNING-receipt witness while a Build freeze
# records a CONTRACT witness. Each recorder does read-whole-store -> mutate one key -> os.replace.
# os.replace makes the final swap atomic, but the read->mutate is not, so two writers that both read
# the pre-image lose-update (whole-file last-writer-wins) and one witness vanishes — leaving a receipt
# witness-less so a later Build borrow fails closed with "no machine-owned witness". The fix holds an
# exclusive lock across the whole read->write.
#
# This test forces the race deterministically: two processes, one recording each witness kind to the
# SAME common-git-dir store, are released together by a go-file and each SLEEPS after reading the store
# (a monkeypatch that only widens the recorder's existing read->write window — it changes no store
# logic). Under the lock the second writer blocks at acquire (before its read), so it reads the first
# writer's result and BOTH keys survive. Without the lock both read the empty pre-image and one key is
# lost.
#
# Red-when-broken: make _witness_store_lock a no-op and this lane fails — one of the two witnesses is
# missing from the store.
#
# Usage: bash tests/smoke/governance/witness-store-concurrent-write.sh   (exit 0 = pass)
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

GO="$WORK/go"

# A worker: monkeypatch _read_witnesses to sleep AFTER reading (widening the RMW window), wait at the
# go-barrier BEFORE touching the lock/store, then record its witness. role = planning | contract.
cat > "$WORK/worker.py" <<'PY'
import json, os, sys, time
scripts, repo, role, ready, go = sys.argv[1:6]
sys.path.insert(0, scripts)
import idc_validation_contract as VC

_orig_read = VC._read_witnesses
def slow_read(common_git_dir):
    data = _orig_read(common_git_dir)
    time.sleep(0.5)                 # widen the read->write window so an unlocked race is deterministic
    return data
VC._read_witnesses = slow_read

if role == "planning":
    path = os.path.join(repo, "docs", "workflow", "planning-receipts", "alpha.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"label": "alpha"}, fh); fh.write("\n")
    record = lambda: VC.record_planning_witness(os.path.abspath(path), {"label": "alpha"})
else:
    path = os.path.join(repo, "docs", "workflow", "build-validation", "contract.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"issue": 1}, fh); fh.write("\n")
    record = lambda: VC._record_witness("contract", os.path.abspath(path), {"issue": 1, "pr": 1})

# barrier: signal ready, then wait for `go` BEFORE entering the recorder, so both processes reach the
# lock within milliseconds of each other (the barrier is OUTSIDE the lock, so the lock cannot deadlock).
open(ready, "w").close()
while not os.path.exists(go):
    time.sleep(0.005)

record()
print(role + " recorded")
PY

python3 "$WORK/worker.py" "$PLUGIN/scripts" "$REPO" planning "$WORK/ready_p" "$GO" &
PP=$!
python3 "$WORK/worker.py" "$PLUGIN/scripts" "$REPO" contract "$WORK/ready_c" "$GO" &
PC=$!

# release both once each has reached the barrier
for _ in $(seq 1 400); do
  [ -f "$WORK/ready_p" ] && [ -f "$WORK/ready_c" ] && break
  sleep 0.01
done
[ -f "$WORK/ready_p" ] && [ -f "$WORK/ready_c" ] || fail "a witness worker never reached the barrier"
: > "$GO"

wait "$PP"; rc_p=$?
wait "$PC"; rc_c=$?
[ "$rc_p" -eq 0 ] || fail "the planning-witness worker crashed (exit $rc_p)"
[ "$rc_c" -eq 0 ] || fail "the contract-witness worker crashed (exit $rc_c)"

# both witnesses must survive the concurrent write
python3 - "$PLUGIN/scripts" "$REPO" <<'PY' || fail "a concurrent write dropped a witness (F30)"
import sys
scripts, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_validation_contract as VC
cgd = VC._common_git_dir(repo)
store = VC._read_witnesses(cgd) or {}
keys = list(store)
has_planning = any(k.startswith(VC.PLANNING_WITNESS_KIND + ":") for k in keys)
has_contract = any(isinstance(v, dict) and v.get("kind") == "contract" for v in store.values())
if not has_planning:
    print("MISSING: the planning-receipt witness was dropped by the concurrent contract write")
    sys.exit(1)
if not has_contract:
    print("MISSING: the contract witness was dropped by the concurrent planning write")
    sys.exit(1)
print("ok: both the planning and contract witnesses survived the concurrent write (%d keys)" % len(keys))
PY

echo "PASS: concurrent witness recorders serialize under an exclusive store lock — neither a planning nor a contract witness is dropped (F30)"
