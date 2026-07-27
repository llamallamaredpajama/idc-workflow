#!/bin/bash
# idc-assert-class: behavior
# build-planning-witness-retention.sh — F31: the per-path planning-witness container must be BOUNDED.
#
# record_planning_witness ADDS a version per receipt byte digest so a same-label rerun does not clobber
# the version an in-flight Build still borrows (F27). But each same-projection re-apply embeds a fresh
# created_at -> new bytes -> new digest -> a NEW entry, so repeated recirc re-applies of the same label
# would grow the per-key bucket (and the store file inside .git) without limit. The fix caps the
# retained set at PLANNING_WITNESS_RETAIN, always keeping the current on-disk version, and evicts the
# oldest.
#
# Red-when-broken: with unbounded retention the bucket holds every version recorded (N), so the
# `<= RETAIN` assertion fires. The fix keeps the CURRENT receipt borrowable and refuses an evicted old
# version fail-closed (never false-accepts it).
#
# Usage: bash tests/smoke/governance/build-planning-witness-retention.sh   (exit 0 = pass)
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

python3 - "$PLUGIN/scripts" "$REPO" <<'PY' || fail "F31 retention assertions failed (see above)"
import json, os, sys
scripts, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_validation_contract as VC

RETAIN = VC.PLANNING_WITNESS_RETAIN
receipt = os.path.join(repo, "docs", "workflow", "planning-receipts", "alpha.json")
os.makedirs(os.path.dirname(receipt), exist_ok=True)
N = RETAIN + 4                                  # comfortably over the cap

digests, bodies = [], {}
for i in range(N):
    body = {"label": "alpha", "n": i, "created_at": "2000-01-01T00:00:%02dZ" % i}
    with open(receipt, "w", encoding="utf-8") as fh:
        json.dump(body, fh, sort_keys=True); fh.write("\n")
    VC.record_planning_witness(os.path.abspath(receipt), body)
    dg = VC._digest_file(receipt)               # a distinct byte digest per version
    digests.append(dg); bodies[dg] = dict(body)
last_body = body

cgd, _rid, rel = VC._planning_witness_context(os.path.abspath(receipt))
store = VC._read_witnesses(cgd)
bucket = store[VC._planning_witness_key(rel)]["witnesses"]

# (1) the bucket is BOUNDED — not one entry per record.
if len(bucket) > RETAIN:
    print("BUCKET-UNBOUNDED: %d entries retained after %d records (cap %d)" % (len(bucket), N, RETAIN))
    sys.exit(1)
if len(bucket) >= N:
    print("NO-EVICTION: %d entries for %d records — nothing was evicted" % (len(bucket), N))
    sys.exit(1)
print("ok: bucket bounded at %d <= %d after %d records" % (len(bucket), RETAIN, N))

# (2) the CURRENT on-disk receipt (last written) is still borrowable — eviction never drops the live one.
if VC.planning_witness_problem(os.path.abspath(receipt), last_body) is not None:
    print("CURRENT-NOT-BORROWABLE: eviction dropped the live version")
    sys.exit(1)
print("ok: current receipt still borrowable after eviction")

# (3) an EVICTED old version is refused fail-closed (stale), never false-accepted.
evicted = [dg for dg in digests if dg not in bucket]
if not evicted:
    print("NO-EVICTED-VERSION: expected at least one evicted digest")
    sys.exit(1)
ev = evicted[0]
with open(receipt, "w", encoding="utf-8") as fh:
    json.dump(bodies[ev], fh, sort_keys=True); fh.write("\n")
assert VC._digest_file(receipt) == ev, "test setup: restored bytes did not reproduce the evicted digest"
prob = VC.planning_witness_problem(os.path.abspath(receipt), bodies[ev])
if not (prob and "stale" in prob):
    print("EVICTED-NOT-REFUSED: an evicted version was not refused stale; got %r" % (prob,))
    sys.exit(1)
print("ok: evicted old version is refused fail-closed")
PY

echo "PASS: the planning-witness container retains a BOUNDED set (F31) — the current receipt stays borrowable and an evicted old version is refused fail-closed"
