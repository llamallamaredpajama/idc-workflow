#!/bin/bash
# Phase 4 smoke — e2e LAYERING (staging-default) + the COMMUTATIVE DISJOINT-SURFACE MERGE TRAIN
# (issue sb-79). Builds on #76 (ready-frontier/area-packing) + #77 (sous-chef area ownership).
#
# Two halves, both red-when-broken (the same shape as phase4-ready-frontier.sh):
#
#   A. BEHAVIOR — the merge train's load-bearing substrate, proven against the REAL lease primitive
#      (`idc_tracker_fs.py` lease-acquire/release/show). The merge lease is keyed by SURFACE AREA, so:
#        * two DISJOINT-surface areas acquire DISTINCT lease names -> BOTH hold concurrently
#          (they merge without contending for one global lease — THE Done-When);
#        * two areas sharing a surface acquire the SAME lease name -> the second is REFUSED
#          (only conflicting surfaces serialize).
#      A global-lease contrast pair anchors it: same name DOES serialize, distinct names DO NOT —
#      so neither an always-grant nor an always-global regression can stay green.
#
#   B. DOCTRINE — agents/idc-build.md + agents/idc-finisher.md describe (1) e2e layering: the STAGING
#      branch runs the full observed e2e by DEFAULT (once, before main); per-teammate-worktree e2e
#      only under LARGE EFFORT (then staging runs its own final e2e); e2e is rate-limited -> the LONG
#      POLE -> scheduled SERIALIZED. (2) the merge lane scales from one global lease to a COMMUTATIVE
#      disjoint-surface MERGE TRAIN: the lease is keyed per surface/area, disjoint areas merge without
#      one global lease, only conflicting/overlapping surfaces serialize — fail-closed preserved.
#   The pre-existing locks (phase4-triplet / phase4-acceptance / phase4-ready-frontier) stay green —
#   #79 ADDS the staging/merge-train doctrine on top of the single-lease + matrix-disjoint guarantees.
#
# Usage: bash tests/smoke/phase4-e2e-merge-train.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
BUILD="$PLUGIN/agents/idc-build.md"
FIN="$PLUGIN/agents/idc-finisher.md"
WORK="$(mktemp -d)"; T="$WORK/TRACKER.md"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
lease() { python3 "$TRK" --tracker "$T" "$@"; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b, no PCRE)
has() { grep -qiE "$2" "$1"; }
# whitespace-flattened phrase check: markdown soft-wraps, so an ordered chain could span lines and
# dodge a line-based grep. Flatten newlines to spaces first, then match (BSD/GNU-portable: tr only).
hasflat() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }

[ -f "$TRK" ]   || fail "tracker helper not found at $TRK"
[ -f "$BUILD" ] || fail "agents/idc-build.md missing"
[ -f "$FIN" ]   || fail "agents/idc-finisher.md missing"
lease init >/dev/null || fail "tracker init failed"

# ---- A. the commutative merge train over the real surface-keyed lease primitive -------------------
# A1. global-lease CONTRAST: one shared lease name DOES serialize (the old single-global behavior).
gtok="$(lease lease-acquire --lease merge --owner finisher-G1 --ttl 60)" \
  || fail "acquire on a free global lease failed (no lease primitive?)"
[ -n "$gtok" ] || fail "global acquire returned an empty token"
lease lease-acquire --lease merge --owner finisher-G2 --ttl 60 >/dev/null 2>&1 \
  && fail "a second holder acquired the SAME lease name 'merge' — same surface must serialize"
lease lease-release --lease merge --token "$gtok" >/dev/null || fail "global release failed"

# A2. THE Done-When: two DISJOINT-surface areas hold DISTINCT lease names CONCURRENTLY — the merge
#     train. Under one global lease this second acquire would be refused; keyed per area it succeeds.
atok="$(lease lease-acquire --lease merge:areaA --owner finisher-A --ttl 60)" \
  || fail "acquire on disjoint area lease merge:areaA failed"
btok="$(lease lease-acquire --lease merge:areaB --owner finisher-B --ttl 60)" \
  || fail "two DISJOINT-surface areas must merge concurrently — merge:areaB was refused while merge:areaA held (collapsed to one global lease?)"
[ -n "$atok" ] && [ -n "$btok" ] || fail "disjoint-area acquires returned empty tokens"
[ "$atok" != "$btok" ] || fail "disjoint-area leases returned the SAME token (not independent leases)"
lease lease-show --lease merge:areaA | grep -q '"held": true' \
  || fail "merge:areaA must report held while finisher-A owns it"
lease lease-show --lease merge:areaB | grep -q '"held": true' \
  || fail "merge:areaB must report held concurrently while finisher-B owns it"

# A3. only CONFLICTING surfaces serialize: a third worker on areaA's SAME surface is refused.
lease lease-acquire --lease merge:areaA --owner finisher-C --ttl 60 >/dev/null 2>&1 \
  && fail "a same-surface area (merge:areaA) was granted while held — conflicting surfaces must serialize"

# A4. releasing areaA must NOT disturb areaB (independent leases), and areaA frees for reuse.
lease lease-release --lease merge:areaA --token "$atok" || fail "release of merge:areaA failed"
lease lease-show --lease merge:areaB | grep -q '"held": true' \
  || fail "releasing merge:areaA wrongly dropped the independent merge:areaB lease"
rtok="$(lease lease-acquire --lease merge:areaA --owner finisher-D --ttl 60)" \
  || fail "merge:areaA did not free for reuse after release"
lease lease-release --lease merge:areaA --token "$rtok" >/dev/null || true
lease lease-release --lease merge:areaB --token "$btok" >/dev/null || true

# ---- B. DOCTRINE: staging-default e2e layering + commutative merge train --------------------------
# Each grep ties to a load-bearing #79 directive and is RED against the pre-#79 (single-lease, no
# staging-e2e) playbooks. Belt-and-suspenders re-asserts the pre-existing fail-closed + disjoint locks.

# B1 — e2e layering lives in BOTH the build orchestrator AND the finisher (staging branch + e2e).
for f in "$BUILD" "$FIN"; do
  name="$(basename "$f")"
  has "$f" 'staging'      || fail "$name must describe the STAGING branch in the e2e layering"
  has "$f" 'e2e'          || fail "$name must name the e2e layer"
done
# B2 — DEFAULT is staging-only e2e (run once, before main), NOT per-worktree by default.
has "$BUILD" 'staging[^.]*e2e|e2e[^.]*staging' \
  || fail "idc-build.md must run the full e2e on the staging branch (staging-default e2e)"
has "$BUILD" 'default[^.]*staging|staging[^.]*default' \
  || fail "idc-build.md must make staging-only e2e the DEFAULT (anchored to staging, not a bare 'by default')"
has "$BUILD" 'once[^.]*(before|prior)[^.]*main|before[^.]*main' \
  || fail "idc-build.md must run the staging e2e ONCE before main (not per-worktree by default)"
# B3 — LARGE EFFORT adds per-teammate/worktree e2e BEFORE staging, THEN staging runs its own final e2e.
has "$FIN" 'large[ -]effort' \
  || fail "idc-finisher.md must gate per-worktree e2e behind LARGE EFFORT (not the default)"
has "$FIN" 'worktree[^.]*e2e|e2e[^.]*worktree|per-teammate[^.]*e2e' \
  || fail "idc-finisher.md must run per-teammate-worktree e2e under large effort (before merging to staging)"
has "$FIN" 'final e2e|staging[^.]*final|final[^.]*staging' \
  || fail "idc-finisher.md must have staging run its OWN final e2e (staging-anchored, not a bare 'then staging')"
# B4 — e2e is rate-limited -> the LONG POLE -> scheduled SERIALIZED (why default is staging-only).
has "$BUILD" 'rate.?limit' \
  || fail "idc-build.md must explain e2e is GitHub rate-limited (the reason it is serialized)"
has "$BUILD" 'long pole' \
  || fail "idc-build.md must call serialized e2e the long pole"
has "$BUILD" 'serial[a-z]*[^.]*e2e|e2e[^.]*serial' \
  || fail "idc-build.md must schedule e2e SERIALIZED (rate-limited long pole)"

# B5 — the merge lane scales from one global lease to a COMMUTATIVE disjoint-surface MERGE TRAIN.
for f in "$BUILD" "$FIN"; do
  name="$(basename "$f")"
  has "$f" 'merge train' \
    || fail "$name must describe the commutative disjoint-surface MERGE TRAIN (not just one global lease)"
done
# B6 — the lease is keyed PER SURFACE/AREA, not one single global lease (the train's mechanism).
has "$BUILD" '(per-surface|per-area|surface-keyed|keyed[^.]*(surface|area))' \
  || fail "idc-build.md must key the merge lease per surface/area (the merge-train mechanism)"
# Require a NEGATION governing 'global ... lease' — a bare 'global lease' would pass on the OLD wording
# ('a single global lease'), the opposite of the scaling. Red-when-broken: drop the not/no/without.
has "$BUILD" '(not|no|without|never|rather than|instead of)[^.]*(single |one )?global[^.]*lease' \
  || fail "idc-build.md must state disjoint areas merge WITHOUT one global lease (negation required, not bare 'global lease')"
# B7 — ONLY conflicting/overlapping surfaces serialize (the precise commutative property).
#      hasflat: markdown soft-wraps 'only' away from 'serialize', so flatten before matching.
hasflat "$BUILD" 'only[^.]*(conflict|overlap)[a-z]*[^.]*serial|serial[a-z]*[^.]*only[^.]*(conflict|overlap)' \
  || fail "idc-build.md must state ONLY conflicting/overlapping surfaces serialize (the merge train serializes only contended surfaces)"

# B7b — the lease KEY is the diff's actual FILE SURFACE (the paths it touches), NOT an opaque area id.
#       This is the precondition that makes "only overlapping surfaces serialize" sound: an area-id key
#       would let two PARTIALLY-overlapping areas hold distinct names and race. Red-when-broken: the
#       pre-fix wording ('keyed per surface area') does NOT mention the file surface / paths / area id.
for f in "$BUILD" "$FIN"; do
  name="$(basename "$f")"
  hasflat "$f" 'file surface|surface[^.]*(the )?(path|file)|(path|file)[^.]*(it touches|the diff)' \
    || fail "$name must key the merge lease by the diff's actual FILE SURFACE (paths), not an opaque area id"
  hasflat "$f" 'area id' \
    || fail "$name must contrast surface-keying against an opaque area id (the partial-overlap pitfall)"
done
# B7c — partial overlap IS handled: two diffs that SHARE a path collide on the SAME lease and serialize.
hasflat "$FIN" 'shar[a-z]*[^.]*path[^.]*(same|one)[^.]*lease[^.]*serial|shar[a-z]*[^.]*path[^.]*collide[^.]*serial' \
  || fail "idc-finisher.md must state two diffs sharing a path collide on the SAME lease and serialize (partial overlap handled, not raced)"
# B7d — the shared-ref ADVANCE never silently races: serial on single-merger runtimes, and an atomic
#       fast-forward that rejects/retries on a moved base under pi's concurrent residents (fail-closed
#       at the git layer). The pre-fix wording claimed the lease 'serializes the integration-ref update' —
#       which is FALSE once disjoint surfaces use distinct leases; this asserts the corrected reconciliation.
hasflat "$BUILD" 'fast.forward|non.fast.forward|reject[a-z]*[^.]*(retr|moved base)|moved base' \
  || fail "idc-build.md must reconcile the shared-ref advance (atomic fast-forward / reject-and-retry on a moved base — never a silent race)"
# B7e — single-merger runtimes COLLAPSE the train to structural serialization; concurrency is realized on pi.
for f in "$BUILD" "$FIN"; do
  name="$(basename "$f")"
  hasflat "$f" 'collapse[a-z]*[^.]*(structural |serial)|structural[ -]serial' \
    || fail "$name must state the single-merger runtimes COLLAPSE the train to structural serialization (not literal concurrency)"
  hasflat "$f" 'concurrent[a-z]*[^.]*pi|pi[^.]*(multi.resident|concurrent)' \
    || fail "$name must state genuine concurrency is realized on pi's multi-resident pool"
done

# B8 — belt-and-suspenders: #79 ADDS the train; it must NOT drop the fail-closed lease or the
#      matrix-disjoint primary defense (the pre-existing two-layer guarantee survives).
for f in "$BUILD" "$FIN"; do
  name="$(basename "$f")"
  has "$f" 'fail-closed'            || fail "$name must preserve the fail-closed lease (no lease -> no merge)"
  has "$f" 'matrix-disjoint|disjoint' || fail "$name must preserve the matrix-disjoint areas primary defense"
done

echo "PASS: surface-keyed lease proves the commutative merge train (disjoint areas concurrent, conflicting surfaces serialize); idc-build.md + idc-finisher.md describe staging-default e2e layering + serialized long-pole e2e + the merge train; fail-closed + matrix-disjoint locks preserved"
