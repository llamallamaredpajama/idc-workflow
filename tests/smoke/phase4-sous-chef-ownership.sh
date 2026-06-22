#!/bin/bash
# Phase 4 sous-chef-ownership smoke — the durable-worker pair (idc-implementer + idc-finisher)
# is promoted from a "last-resort collapse" to the INTENDED sous-chef structure (issue sb-77):
#   (A) each sous-chef owns its AREA END-TO-END with heavy INTERNAL BOUNDED FAN-OUT (line cooks)
#       whose own cooks NEVER share a file surface (disjoint), and this is the *intended* posture,
#       not merely the collapse fallback;
#   (B) the ROLE-AUTHORITY PARTITION still holds — red-when-broken: the finisher REFUSES to fix or
#       merge an area that LACKS an INDEPENDENT review verdict (no verdict -> no fix, no merge), so a
#       sous-chef can never self-review/self-approve its own area.
# Docs slice: a structural assertion over the shipped playbooks (no runtime exec, no GitHub) — the
# same shape as phase4-triplet.sh. Removing either the fan-out structure (A) or the partition guard
# (B) from the agent markdown must turn this test red.
#
# Usage: bash tests/smoke/phase4-sous-chef-ownership.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
IMPL="$PLUGIN/agents/idc-implementer.md"
FIN="$PLUGIN/agents/idc-finisher.md"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b)
has() { grep -qiE "$2" "$1"; }

[ -f "$IMPL" ] || fail "implementer agent not found at $IMPL"
[ -f "$FIN" ]  || fail "finisher agent not found at $FIN"

# ---- (A) sous-chef area-owners with INTENDED internal bounded fan-out (line cooks) ----------
for f in "$IMPL" "$FIN"; do
  name="$(basename "$f")"
  has "$f" 'sous-chef'        || fail "$name must frame the durable worker as a sous-chef area-owner"
  has "$f" 'area'             || fail "$name must name end-to-end AREA ownership"
  has "$f" 'end-to-end'       || fail "$name must say the area is owned END-TO-END"
  has "$f" 'line cook'        || fail "$name must name the internal bounded fan-out workers (line cooks)"
  has "$f" 'fan-out|fan out'  || fail "$name must name the internal bounded FAN-OUT"
  # the promotion: this is the INTENDED structure, not merely the last-resort collapse fallback
  has "$f" 'intended'         || fail "$name must mark the sous-chef fan-out as the INTENDED structure (promotion), not just a fallback"
done

# internal cooks own DISJOINT file surfaces — each sous-chef guarantees its OWN cooks never share a
# surface (the matrix-disjoint guarantee, applied INSIDE the area, not only across waves).
has "$IMPL" 'disjoint'                          || fail "implementer must guarantee its internal cooks own DISJOINT file surfaces"
has "$IMPL" 'never share|share[^.]*surface'     || fail "implementer must state its OWN cooks NEVER share a file surface"

# ---- (B) role-authority partition — red-when-broken ----------------------------------------
# Load-bearing invariant: the finisher must REFUSE to fix or merge an area that lacks an
# INDEPENDENT review verdict. Deleting this guard from idc-finisher.md must turn this test red.
has "$FIN" 'refuses? to (fix|merge)' \
  || fail "finisher must REFUSE to fix/merge without an independent verdict (role-authority partition)"
has "$FIN" '(lack|lacking|without|no)[^.]*independent[^.]*verdict|independent[^.]*verdict[^.]*(before|first|exist)' \
  || fail "finisher must require an INDEPENDENT review verdict before it fixes or merges (red-when-broken)"
# a sous-chef never self-reviews / self-approves its own area
has "$FIN" 'self-review|self-approv|never review[^.]*own' \
  || fail "finisher must state a sous-chef never self-reviews/self-approves its own area"

echo "PASS: sous-chef area-ownership + internal fan-out + role-authority partition green"
