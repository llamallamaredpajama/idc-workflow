#!/bin/bash
# idc-assert-class: behavior
# build-planning-witness-retention.sh — F31 + W5: the per-path planning-witness container must be
# BOUNDED, and bounding it must not evict a version an in-flight Build is still holding.
#
# record_planning_witness ADDS a version per receipt byte digest so a same-label rerun does not clobber
# the version an in-flight Build still borrows (F27). But each same-projection re-apply embeds a fresh
# created_at -> new bytes -> new digest -> a NEW entry, so repeated recirc re-applies of the same label
# would grow the per-key bucket (and the store file inside .git) without limit.
#
# The retention rule is a count+age HYBRID, and this lane proves BOTH halves:
#   * BOUNDED — the bucket never exceeds PLANNING_WITNESS_HARD_CAP, and beyond it the OLDEST versions
#     are evicted first even when every version is inside the grace window;
#   * NOT OVER-EAGER — a version inside PLANNING_WITNESS_GRACE_SECONDS survives more than
#     PLANNING_WITNESS_RETAIN newer re-applies. A pure count-N cap is measured in RE-APPLIES rather
#     than in time, and `planning_witness_problem` is consulted exactly ONCE (at Build contract
#     freeze), so a re-apply burst between a Build CLAIMING work and FREEZING it would strand a
#     LEGITIMATE receipt.
#   * and the grace window is a real WINDOW — a version older than it is still evicted, so "in grace"
#     never degenerates into "keep everything".
#
# Red-when-broken, both directions:
#   * revert to a pure count cap (drop the grace clause) -> part B's in-grace version is evicted and
#     GRACE-VERSION-EVICTED fires;
#   * drop the hard cap (grace retains unconditionally) -> part C1 keeps all CAP+10 and CAP-EXCEEDED
#     fires; keep the cap but evict newest-first and CAP-KEPT-WRONG-VERSIONS fires;
#   * drop the age test (treat every version as in-grace) -> part C2's ancient version survives and
#     STALE-VERSION-RETAINED fires.
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

python3 - "$PLUGIN/scripts" "$REPO" <<'PY' || fail "F31/W5 retention assertions failed (see above)"
import json, os, sys, time
scripts, repo = sys.argv[1], sys.argv[2]
sys.path.insert(0, scripts)
import idc_validation_contract as VC

RETAIN = VC.PLANNING_WITNESS_RETAIN
CAP = VC.PLANNING_WITNESS_HARD_CAP
GRACE = VC.PLANNING_WITNESS_GRACE_SECONDS

if CAP <= RETAIN:
    print("CONFIG-INCOHERENT: hard cap %d must exceed the count floor %d" % (CAP, RETAIN))
    sys.exit(1)

# RETAIN is PINNED, not derived. It is the pre-existing F31 count floor — the number of same-label
# re-applies a not-yet-frozen Build is guaranteed to survive — so a silent change to it is a change to
# a shipped guarantee and must fail here rather than be absorbed by a test that reads the value back
# out of the implementation.
#
# GRACE and CAP are deliberately NOT pinned: the plan introduced them as PROPOSED values, "adjustable
# with rationale", so hard-coding 7 days / 64 would contradict the contract they were added under. The
# properties that actually matter about them — the cap bounds the bucket and evicts oldest-first, the
# grace window is a real window with both ends closed — are asserted behaviourally below and hold at
# any coherent values.
if RETAIN != 8:
    print("RETAIN-CHANGED: PLANNING_WITNESS_RETAIN is %d, expected the pinned F31 count floor of 8 — "
          "if this was deliberate, update this assertion and the F31 guarantee it encodes" % RETAIN)
    sys.exit(1)

RECEIPTS = os.path.join(repo, "docs", "workflow", "planning-receipts")
os.makedirs(RECEIPTS, exist_ok=True)


def bucket_for(receipt):
    cgd, _rid, rel = VC._planning_witness_context(os.path.abspath(receipt))
    return VC._read_witnesses(cgd)[VC._planning_witness_key(rel)]["witnesses"]


def age_in_store(receipt, digest, age_seconds):
    """Rewrite one recorded version's `validated_at` to `age_seconds` ago, in the store inside .git.

    Every `record_planning_witness` call in a test stamps the SAME wall-clock second, so the
    newest-first ordering would fall through to the digest tiebreaker and 'which version is older'
    would be effectively random. Ageing the held version explicitly is what makes the count rule's
    verdict DETERMINISTIC — without it the count-only comparison this test refutes would evict the
    held version only by luck, and the red-when-broken proof would be a coin flip."""
    cgd, _rid, rel = VC._planning_witness_context(os.path.abspath(receipt))
    store = VC._read_witnesses(cgd)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - age_seconds))
    store[VC._planning_witness_key(rel)]["witnesses"][digest]["validated_at"] = stamp
    with open(VC._witness_path(cgd), "w", encoding="utf-8") as fh:
        json.dump(store, fh, sort_keys=True)


def record(receipt, i, label):
    """Write version `i` of `receipt` and witness it; return (digest, body)."""
    body = {"label": label, "n": i, "created_at": "2000-01-01T00:00:%02dZ" % (i % 60)}
    with open(receipt, "w", encoding="utf-8") as fh:
        json.dump(body, fh, sort_keys=True); fh.write("\n")
    VC.record_planning_witness(os.path.abspath(receipt), body)
    return VC._digest_file(receipt), dict(body)


# ---------------------------------------------------------------------------------------------
# (A) BOUNDEDNESS through the real write door — the bucket stays capped no matter the re-apply rate,
#     the CURRENT receipt stays borrowable, and an evicted version is refused fail-closed.
#     Every version here is written NOW, so all of them are inside the grace window: only the HARD
#     CAP can bound this bucket. That is the point — grace must not defeat F31.
# ---------------------------------------------------------------------------------------------
alpha = os.path.join(RECEIPTS, "alpha.json")
N = CAP + 4                                     # comfortably over the hard cap
digests, bodies = [], {}
for i in range(N):
    dg, body = record(alpha, i, "alpha")
    digests.append(dg); bodies[dg] = body
last_body = body

bucket = bucket_for(alpha)
if len(bucket) > CAP:
    print("CAP-EXCEEDED: %d entries retained after %d records (hard cap %d)" % (len(bucket), N, CAP))
    sys.exit(1)
if len(bucket) >= N:
    print("NO-EVICTION: %d entries for %d records — nothing was evicted" % (len(bucket), N))
    sys.exit(1)
print("ok: bucket bounded at %d <= %d after %d in-grace records" % (len(bucket), CAP, N))

# the CURRENT on-disk receipt (last written) is still borrowable — eviction never drops the live one.
if VC.planning_witness_problem(os.path.abspath(alpha), last_body) is not None:
    print("CURRENT-NOT-BORROWABLE: eviction dropped the live version")
    sys.exit(1)
print("ok: current receipt still borrowable after eviction")

# an EVICTED old version is refused fail-closed (stale), never false-accepted.
evicted = [dg for dg in digests if dg not in bucket]
if not evicted:
    print("NO-EVICTED-VERSION: expected at least one evicted digest")
    sys.exit(1)
ev = evicted[0]
with open(alpha, "w", encoding="utf-8") as fh:
    json.dump(bodies[ev], fh, sort_keys=True); fh.write("\n")
assert VC._digest_file(alpha) == ev, "test setup: restored bytes did not reproduce the evicted digest"
prob = VC.planning_witness_problem(os.path.abspath(alpha), bodies[ev])
if not (prob and "stale" in prob):
    print("EVICTED-NOT-REFUSED: an evicted version was not refused stale; got %r" % (prob,))
    sys.exit(1)
print("ok: evicted old version is refused fail-closed")

# ---------------------------------------------------------------------------------------------
# (B) GRACE SURVIVAL through the real write door — the vector W5 exists to close. A version recorded
#     inside the grace window survives MORE THAN `RETAIN` newer same-label re-applies, so a Build that
#     claimed work and has not yet frozen its contract can still borrow the receipt it holds.
#     Red-when-broken: under a pure count-`RETAIN` cap this version is the (RETAIN+5)th newest and is
#     evicted, so `planning_witness_problem` refuses a LEGITIMATE receipt.
# ---------------------------------------------------------------------------------------------
beta = os.path.join(RECEIPTS, "beta.json")
held_dg, held_body = record(beta, 0, "beta")     # the version an in-flight Build is holding
# Age it ONE HOUR — unambiguously older than every re-apply that follows (so the count rule would
# evict it) yet far inside the 7-day grace window (so the age rule must keep it). Without this the
# whole test writes inside a single second and eviction order is decided by the digest tiebreaker.
age_in_store(beta, held_dg, 3600)
HELD_AGE = 3600
if HELD_AGE >= GRACE:
    print("TEST-SETUP-INCOHERENT: the held version must be aged INSIDE the grace window")
    sys.exit(1)
NEWER = RETAIN + 4                               # strictly more re-applies than the count floor
for i in range(1, NEWER + 1):
    record(beta, i, "beta")

bucket = bucket_for(beta)
if held_dg not in bucket:
    print("GRACE-VERSION-EVICTED: a version inside the %ds grace window was evicted by %d newer "
          "re-applies (count floor %d) — an in-flight Build would be stranded"
          % (GRACE, NEWER, RETAIN))
    sys.exit(1)
# and it is genuinely BORROWABLE, not merely present in the store.
with open(beta, "w", encoding="utf-8") as fh:
    json.dump(held_body, fh, sort_keys=True); fh.write("\n")
assert VC._digest_file(beta) == held_dg, "test setup: restored bytes did not reproduce the held digest"
prob = VC.planning_witness_problem(os.path.abspath(beta), held_body)
if prob is not None:
    print("GRACE-VERSION-NOT-BORROWABLE: the in-grace version is present but refused: %r" % (prob,))
    sys.exit(1)
print("ok: an in-grace version survives %d newer re-applies and stays borrowable" % NEWER)

# ---------------------------------------------------------------------------------------------
# (C) AGE SEMANTICS, asserted directly on `_evict_stale_versions` with SYNTHETIC `validated_at`
#     stamps. The write door above cannot produce controlled ages (every record is stamped `now`), and
#     wall-clock ordering within one second is decided by the digest tiebreaker — so the two precise
#     claims (oldest-first eviction at the cap; the grace window is a WINDOW) are proven here, where
#     the timestamps are exact. `receipt_path` is a path that does not exist, so no live digest
#     perturbs the count.
# ---------------------------------------------------------------------------------------------
NOWHERE = os.path.join(RECEIPTS, "no-such-receipt.json")


def stamp(age_seconds):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - age_seconds))


# (C1) hard cap with EVERY version inside grace -> exactly CAP kept, and the kept ones are the NEWEST.
#      ages 60s, 120s, ... all far inside the 7-day window, so only the cap can bound this.
total = CAP + 10
synth = {}
for i in range(total):                          # i=0 is the NEWEST (age 60s), i=total-1 the OLDEST
    synth["d%03d" % i] = {"validated_at": stamp(60 * (i + 1))}
VC._evict_stale_versions(synth, NOWHERE)
if len(synth) != CAP:
    print("CAP-EXCEEDED: %d kept from %d all-in-grace versions (hard cap %d)" % (len(synth), total, CAP))
    sys.exit(1)
expected_newest = {"d%03d" % i for i in range(CAP)}
if set(synth) != expected_newest:
    print("CAP-KEPT-WRONG-VERSIONS: at the hard cap the OLDEST must be evicted first; kept %r"
          % (sorted(synth),))
    sys.exit(1)
print("ok: at the hard cap (%d) the oldest in-grace versions are evicted first" % CAP)

# (C2) the grace window is a WINDOW — a version OLDER than it is evicted once it falls outside the
#      newest-RETAIN set. Red-when-broken: treat every version as in-grace and the ancient one stays.
synth = {"ancient": {"validated_at": stamp(GRACE + 3600)}}      # one hour past the window
for i in range(RETAIN + 2):                                     # enough newer versions to displace it
    synth["fresh%02d" % i] = {"validated_at": stamp(60 * (i + 1))}
VC._evict_stale_versions(synth, NOWHERE)
if "ancient" in synth:
    print("STALE-VERSION-RETAINED: a version %ds past the %ds grace window survived %d newer "
          "versions — the grace clause is not bounded by age"
          % (GRACE + 3600, GRACE, RETAIN + 2))
    sys.exit(1)
print("ok: a version past the grace window is still evicted")

# (C3) an UNPARSEABLE / absent validated_at must not be treated as in-grace (fail closed toward
#      eviction, never toward unbounded growth). Both fixtures sort BELOW the well-formed stamps, so
#      neither is rescued by the newest-RETAIN clause and the grace clause is the only thing that
#      could keep them — which is exactly what this asserts it does not do.
synth = {"garbage": {"validated_at": "0000-not-a-timestamp"}, "missing": {}}
for i in range(RETAIN + 2):
    synth["fresh%02d" % i] = {"validated_at": stamp(60 * (i + 1))}
VC._evict_stale_versions(synth, NOWHERE)
if "garbage" in synth or "missing" in synth:
    print("UNPARSEABLE-TREATED-AS-GRACE: a record with an unreadable validated_at was grace-retained; "
          "kept %r" % (sorted(synth),))
    sys.exit(1)
print("ok: an unparseable/absent validated_at is not grace-retained (fail closed)")

# (C4) a FUTURE `validated_at` earns NO grace. A stamp ahead of now yields a NEGATIVE age, which
#      satisfies a bare `age <= GRACE` — so clock skew (or a hand-edited store) could park records in
#      the grace clause permanently and, worse, let them consume HARD-CAP slots ahead of legitimately
#      recent versions. A stamp in the future is not evidence of recency.
#      The fixture uses MORE future-skewed records than the count floor, so the newest-RETAIN clause
#      cannot be what bounds them — only the age test can. Red-when-broken: drop the `0 <= age` bound
#      and all 20 survive on grace.
SKEWED = RETAIN + 12
synth = {"skew%02d" % i: {"validated_at": stamp(-(3600 * (i + 1)))} for i in range(SKEWED)}
synth["legit"] = {"validated_at": stamp(60)}                    # genuinely recent -> must survive
synth["ancient"] = {"validated_at": stamp(GRACE + 3600)}        # outside the window -> must go
VC._evict_stale_versions(synth, NOWHERE)
kept_skew = [k for k in synth if k.startswith("skew")]
if len(kept_skew) > RETAIN:
    print("FUTURE-SKEW-GRACE-RETAINED: %d of %d future-dated versions survived (the count floor is "
          "%d) — a negative age is being read as 'inside the grace window'"
          % (len(kept_skew), SKEWED, RETAIN))
    sys.exit(1)
if "legit" not in synth:
    print("SKEW-DISPLACED-LEGIT: a genuinely in-grace version was evicted while future-dated ones "
          "were retained; kept %r" % (sorted(synth),))
    sys.exit(1)
if "ancient" in synth:
    print("STALE-VERSION-RETAINED: the past-window version survived the future-skew fixture")
    sys.exit(1)
print("ok: a future-dated validated_at is not grace-retained (%d of %d kept, count floor %d)"
      % (len(kept_skew), SKEWED, RETAIN))

# (C5) the live on-disk digest and the newest-RETAIN set are INDEPENDENT guarantees — the live version
#      must not consume one of the RETAIN slots. Seeding `keep` with the live digest and then filling
#      to RETAIN made the retained set `live` + newest-(RETAIN-1), so with the live receipt as the
#      OLDEST entry the RETAIN-th newest version was evicted even though the documented rule keeps it.
#      Every version here is OUTSIDE the grace window, so (c) cannot mask the difference.
synth = {}
for i in range(RETAIN + 1):                    # i=0 NEWEST ... i=RETAIN OLDEST
    synth["e%03d" % i] = {"validated_at": stamp(GRACE + 3600 * (i + 1))}
live_dg = "e%03d" % RETAIN                     # the OLDEST entry is the live on-disk one
_real_digest_file = VC._digest_file
VC._digest_file = lambda _path: live_dg
try:
    VC._evict_stale_versions(synth, NOWHERE)
finally:
    VC._digest_file = _real_digest_file
missing = [k for k in ("e%03d" % i for i in range(RETAIN)) if k not in synth]
if missing:
    print("LIVE-CONSUMED-A-RETAIN-SLOT: the live version displaced newest-RETAIN member(s) %r; kept %r"
          % (missing, sorted(synth)))
    sys.exit(1)
if live_dg not in synth:
    print("LIVE-EVICTED: the current on-disk version was evicted; kept %r" % (sorted(synth),))
    sys.exit(1)
print("ok: keep is live UNION newest-%d (%d entries), not live + newest-%d"
      % (RETAIN, len(synth), RETAIN - 1))

# (C6) WRONG-TYPE `validated_at` shapes and a NON-DICT record must not crash the eviction sort and
#      must never be grace-retained (F43 durability — this is the permanent fixture behind the
#      one-off round-5 receipt). C3 above plants an unparseable STRING and a MISSING key — both of
#      which the PRE-fix `(rec.get("validated_at") or "", dg)` key SURVIVED (falsy -> `or ""`), so
#      C3 does not cover F43 at all. The F43 crash needs a TRUTHY non-string (a nonzero number, a
#      non-empty dict/list), which compares int/dict/list against str inside `sorted()`, or a
#      non-dict RECORD, which raises AttributeError on `.get` — and it lands after the receipt was
#      already replaced on disk, leaving it unwitnessed. Red-when-broken: restore the pre-fix sort
#      key (or `.get` without the dict check) and this case CRASHES the lane red; drop only the
#      never-grace-retained half and the retention assertions fire.
synth = {
    "truthy-int":  {"validated_at": 1234567890},        # the F43 crash shape
    "truthy-list": {"validated_at": ["2026-01-01"]},
    "truthy-dict": {"validated_at": {"at": "2026"}},
    "falsy-zero":  {"validated_at": 0},                 # pre-fix survivor — kept for the grace half
    "not-a-dict":  "corrupted-record",                  # the AttributeError shape
}
for i in range(RETAIN + 2):
    synth["fresh%02d" % i] = {"validated_at": stamp(60 * (i + 1))}
try:
    VC._evict_stale_versions(synth, NOWHERE)
except (TypeError, AttributeError) as exc:
    print("F43-CRASH: a wrong-type validated_at (or non-dict record) crashed the eviction sort — "
          "the receipt is left UNWITNESSED when this happens after the on-disk replace: %r" % (exc,))
    sys.exit(1)
poisoned = [k for k in ("truthy-int", "truthy-list", "truthy-dict", "falsy-zero", "not-a-dict")
            if k in synth]
if poisoned:
    print("WRONG-TYPE-TREATED-AS-GRACE: records with unusable validated_at shapes were retained "
          "past %d fresh versions: %r" % (RETAIN + 2, poisoned))
    sys.exit(1)
# ...and boundedness holds through the real write door even with a poisoned bucket at scale.
big = {"poison%03d" % i: {"validated_at": [i]} for i in range(CAP + 20)}
big.update({"fresh%03d" % i: {"validated_at": stamp(60 * (i + 1))} for i in range(RETAIN + 2)})
try:
    VC._evict_stale_versions(big, NOWHERE)
except (TypeError, AttributeError) as exc:
    print("F43-CRASH-AT-SCALE: %r" % (exc,))
    sys.exit(1)
if len(big) > CAP:
    print("CAP-EXCEEDED-POISONED: %d entries retained in a poisoned bucket (hard cap %d)"
          % (len(big), CAP))
    sys.exit(1)
print("ok: wrong-type validated_at shapes and non-dict records evict cleanly, never crash, never "
      "grace-retain (F43)")
PY

echo "PASS: planning-witness retention is a BOUNDED count+age hybrid (F31/W5) — the hard cap holds even when every version is inside the grace window and evicts oldest-first, a version inside the grace window survives >RETAIN newer re-applies and stays borrowable, a version past the window is still evicted, an unparseable stamp is never grace-retained, the current receipt stays borrowable while an evicted version is refused fail-closed, and a WRONG-TYPE validated_at (truthy number/list/dict) or a non-dict record neither crashes the eviction sort nor earns grace (F43)"
