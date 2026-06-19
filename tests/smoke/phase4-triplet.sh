#!/bin/bash
# Phase 4 triplet smoke — Build is the explicit impl->review->finish triplet:
#   (a) agents/idc-finisher.md exists and names the /simplify + git-finalization steps, its
#       OWN /fullauto-goal fix loop, the recirculation-on-unsolvable, and the 6-element posture
#       (outcome, verification surface, constraints, boundaries, iteration policy, blocked-stop);
#   (b) agents/idc-build.md references all three roles (implementer, reviewer-agent, finisher),
#       the per-runtime session mapping (pi residents / Teams teammates / Codex threads), the
#       fallback-collapse rule, and the merge-serialization mechanism (matrix-disjoint surfaces
#       + a merge lock/queue).
# Docs slice: a structural assertion over the shipped playbooks (no runtime exec, no GitHub).
#
# Usage: bash tests/smoke/phase4-triplet.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
FIN="$PLUGIN/agents/idc-finisher.md"
BUILD="$PLUGIN/agents/idc-build.md"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b)
has() { grep -qiE "$2" "$1"; }

# ---- (a) the new finisher role ---------------------------------------------------
[ -f "$FIN" ] || fail "finisher agent not found at $FIN (not implemented yet)"
has "$FIN" '/simplify'      || fail "finisher must name the /simplify step"
has "$FIN" 'git finaliz'    || fail "finisher must name git finalization"
has "$FIN" 'merge'          || fail "finisher must name the merge step"
has "$FIN" 'tidy'           || fail "finisher must name the tidy step"
# F2b: branch cleanup must be deterministic/atomic with the merge, not a best-effort tidy — an
# orphaned build/* branch survived in the autorun e2e because deletion was soft prose.
grep -qF -- '--delete-branch' "$FIN" \
  || fail "finisher must delete the merged branch atomically (--delete-branch) — else orphaned build/* branches survive (F2b)"
has "$FIN" '/fullauto-goal' || fail "finisher must run its OWN /fullauto-goal loop"
has "$FIN" 'recirculat'     || fail "finisher must file a recirculation on the unsolvable"
# the 6-element posture: the contract's six named elements
has "$FIN" '6-element' || fail "finisher must name the 6-element posture"
for el in 'outcome' 'verification surface' 'constraints' 'boundaries' 'iteration policy' 'blocked-stop'; do
  has "$FIN" "$el" || fail "finisher 6-element posture missing element: $el"
done

# ---- (b) build.md names the three roles + session mapping + the two rules ---------
[ -f "$BUILD" ] || fail "build agent not found at $BUILD"
has "$BUILD" 'implementer'             || fail "build must reference the implementer role"
has "$BUILD" 'review-agent|reviewer'   || fail "build must reference the reviewer-agent role"
has "$BUILD" 'finisher'                || fail "build must reference the finisher role"
# per-runtime session mapping (pi residents / Teams teammates / Codex threads)
has "$BUILD" 'resident'  || fail "build must map the pi runtime -> standing residents"
has "$BUILD" 'teammate'  || fail "build must map Claude Teams -> teammates"
has "$BUILD" 'thread'    || fail "build must map Codex -> threads"
# fallback-collapse rule
has "$BUILD" 'collapse'  || fail "build must state the fallback-collapse rule (collapse)"
has "$BUILD" 'fallback'  || fail "build must state the fallback-collapse rule (fallback)"
# merge-serialization mechanism (matrix-disjoint surfaces + a merge lock/queue)
has "$BUILD" 'serializ'           || fail "build must document merge serialization"
has "$BUILD" 'matrix-disjoint|disjoint' || fail "build must name matrix-disjoint surfaces"
has "$BUILD" 'lock|queue'         || fail "build must name the merge lock/queue"

echo "PASS: finisher role + build triplet/session-mapping/merge-serialization structure green"
