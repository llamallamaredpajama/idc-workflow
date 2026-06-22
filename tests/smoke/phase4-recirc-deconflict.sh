#!/bin/bash
# Phase 4 smoke — NARROW the recirculation trigger + add build-time MECHANICAL DECONFLICTION
# (issue sb-80). Builds on #76 (ready-frontier/area-packing), #77 (sous-chef area ownership),
# #79 (commutative disjoint-surface merge train).
#
# The doctrine this proves, as a red-when-broken structural assertion over the shipped playbooks
# (no runtime exec, no GitHub — the same shape as phase4-sous-chef-ownership.sh / phase4-triplet.sh):
#
#   A. MECHANICAL conflicts deconflict IN-KITCHEN and NEVER recirculate. A purely mechanical
#      conflict — an overlapping-file / git-merge / worktree clash with a peer area — is resolved
#      on the kitchen floor, in-place by the area owner (sous-chef) / line cook, via Build's
#      BUILD-TIME MECHANICAL-DECONFLICTION step (a bounded deconfliction specialist). It NEVER
#      spawns a recirculation. Asserted in idc-build.md (the step) + idc-implementer.md +
#      idc-finisher.md (each routes a mechanical conflict in-kitchen, never to the Recirculator).
#
#   B. SCOPE/MENU defects STILL recirculate. Only a genuine scope/menu defect — the work no longer
#      fits the plan, or an undeclared real dependency that changes the plan (plus the existing
#      pillar/upstream/acceptance-gap classes) — reaches the Recirculator. commands/recirculate.md
#      + agents/idc-recirculator.md narrow the trigger to scope/menu (requirements/plan) drift and
#      state a mechanical conflict does NOT reach there. The Recirculator's ROLE is unchanged —
#      only the upstream trigger is narrowed (belt-and-suspenders so the doc-sync role survives).
#
# Red-when-broken: every negation-governed grep is RED against the pre-#80 wording (which has no
# 'mechanical-deconfliction' step, no 'in-kitchen' routing, no 'scope/menu' scoping, and never ties
# 'mechanical' to a negated 'recirculat'). Dropping the carve-out from any file turns this red.
#
# Usage: bash tests/smoke/phase4-recirc-deconflict.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$PLUGIN/agents/idc-build.md"
IMPL="$PLUGIN/agents/idc-implementer.md"
FIN="$PLUGIN/agents/idc-finisher.md"
RECIRC="$PLUGIN/agents/idc-recirculator.md"
RCMD="$PLUGIN/commands/recirculate.md"
fail() { echo "FAIL: $1"; exit 1; }
# case-insensitive extended-regex substring assertion (BSD/GNU grep safe — no \b, no PCRE).
has() { grep -qiE "$2" "$1"; }
# whitespace-flattened phrase check: markdown soft-wraps, so an ordered chain could span lines and
# dodge a line-based grep. Flatten newlines to spaces first, then match (BSD/GNU-portable: tr only).
hasflat() { tr '\n' ' ' < "$1" | tr -s ' ' | grep -qiE "$2"; }

for f in "$BUILD" "$IMPL" "$FIN" "$RECIRC" "$RCMD"; do
  [ -f "$f" ] || fail "missing shipped file: $f"
done

# ---- A. the BUILD-TIME mechanical-deconfliction step (in-kitchen, never recirculate) --------------
# A1 — idc-build.md adds a BUILD-TIME MECHANICAL-DECONFLICTION step (the formal in-kitchen specialist).
hasflat "$BUILD" 'build.?time[^.]*mechanical.deconflict|mechanical.deconflict[^.]*(step|specialist)' \
  || fail "idc-build.md must add a BUILD-TIME mechanical-deconfliction step (the in-kitchen specialist)"
# A2 — it enumerates the MECHANICAL conflict types (overlapping-file / git-merge / worktree).
hasflat "$BUILD" 'overlapping.file[^.]*git.merge|mechanical[^.]*(overlapping.file|git.merge|worktree)' \
  || fail "idc-build.md must enumerate the mechanical conflict types (overlapping-file / git-merge / worktree)"
# A3 — the conflict resolves IN-KITCHEN / ON THE KITCHEN FLOOR, IN-PLACE by the area owner / line cook.
has "$BUILD" 'in.kitchen|kitchen floor' \
  || fail "idc-build.md must resolve the mechanical conflict IN-KITCHEN (on the kitchen floor)"
hasflat "$BUILD" 'in.place[^.]*(area owner|sous.chef|line cook)|(area owner|sous.chef|line cook)[^.]*in.place' \
  || fail "idc-build.md must resolve it IN-PLACE by the area owner (sous-chef) / line cook"
# A4 — it is a BOUNDED deconfliction specialist (à la a Deconflict teammate), not an upstream hop.
hasflat "$BUILD" 'bounded[^.]*deconflict|deconflict[^.]*specialist|bounded[^.]*specialist' \
  || fail "idc-build.md must frame the in-kitchen deconfliction as a BOUNDED specialist (not an upstream recirculation)"

# A5 — THE Done-When negation: a MECHANICAL conflict NEVER recirculates. Asserted in all three Build
#      playbooks. RED against pre-#80 (none tie 'mechanical' to a negated 'recirculat'). The negation
#      is REQUIRED — a bare 'mechanical ... recirculat' would pass on the opposite (wrong) routing.
for f in "$BUILD" "$IMPL" "$FIN"; do
  name="$(basename "$f")"
  hasflat "$f" 'mechanical[^.]*(never|not|no|without|rather than|instead of|don.t|do not)[^.]*recirculat' \
    || fail "$name must state a MECHANICAL conflict NEVER recirculates (negation required, not bare 'mechanical ... recirculat')"
done
# A6 — and the implementer + finisher ROUTE a mechanical conflict in-kitchen (to the build-time step),
#      not upstream. Each names the in-kitchen deconfliction path.
for f in "$IMPL" "$FIN"; do
  name="$(basename "$f")"
  hasflat "$f" 'mechanical[^.]*(in.kitchen|deconflict)|(in.kitchen|deconflict)[^.]*mechanical' \
    || fail "$name must route a mechanical conflict IN-KITCHEN (the build-time mechanical-deconfliction step), not to the Recirculator"
  hasflat "$f" 'build.?time[^.]*deconflict|mechanical.deconflict' \
    || fail "$name must reference Build's build-time mechanical-deconfliction step as the in-kitchen path"
done

# ---- B. SCOPE/MENU defects STILL recirculate; mechanical conflicts do NOT reach the Recirculator ---
# B1 — the implementer + finisher still route a SCOPE/MENU defect to a recirculation (the live half).
for f in "$IMPL" "$FIN"; do
  name="$(basename "$f")"
  has "$f" 'scope.menu' \
    || fail "$name must name the SCOPE/MENU defect class (the work that still recirculates)"
  hasflat "$f" 'scope.menu[^.]*recirculat|recirculat[^.]*scope.menu' \
    || fail "$name must still route a SCOPE/MENU defect to a recirculation (the narrowed-but-live trigger)"
done
# B1b — the scope/menu defect is defined as 'no longer fits the plan' / 'undeclared real dependency
#       that changes the plan' (the issue's precise menu defect), not a vague 'divergence'.
hasflat "$IMPL" "(no longer|doesn.t|does not)[^.]*fit[^.]*plan|undeclared[^.]*depend[^.]*plan|depend[^.]*chang[^.]*plan" \
  || fail "idc-implementer.md must define the scope/menu defect (work no longer fits the plan / undeclared real dependency that changes the plan)"

# B2 — commands/recirculate.md + idc-recirculator.md NARROW the trigger to scope/menu (requirements/
#      plan) drift, and state a MECHANICAL conflict does NOT reach there (negation required).
for f in "$RCMD" "$RECIRC"; do
  name="$(basename "$f")"
  has "$f" 'scope.menu' \
    || fail "$name must narrow the Recirculator trigger to SCOPE/MENU (requirements/plan) drift"
  hasflat "$f" 'mechanical[^.]*(never|not|no|don.t|do not)[^.]*(reach|recirculat|here|come)|(never|not|no)[^.]*mechanical[^.]*(reach|recirculat)' \
    || fail "$name must state a MECHANICAL conflict does NOT reach the Recirculator (negation required) — it deconflicts in-kitchen"
  hasflat "$f" 'build.?time[^.]*deconflict|mechanical.deconflict' \
    || fail "$name must point a mechanical conflict at Build's build-time mechanical-deconfliction step (the in-kitchen path)"
done

# B3 — belt-and-suspenders: the Recirculator's ROLE is UNCHANGED — only the upstream trigger is
#      narrowed. The doc-sync / retrograde role must survive the narrowing (don't gut the role).
has "$RECIRC" 'retrograde' \
  || fail "idc-recirculator.md must preserve the Recirculator's retrograde doc-sync role (only the trigger is narrowed)"
hasflat "$RECIRC" 'role[^.]*unchanged|unchanged[^.]*role|only the upstream trigger|trigger[^.]*narrow' \
  || fail "idc-recirculator.md must state the ROLE is unchanged — only the upstream trigger is narrowed"

echo "PASS: build-time mechanical-deconfliction step (in-kitchen, bounded, never recirculate) in idc-build.md + idc-implementer.md + idc-finisher.md; scope/menu defects still recirculate; commands/recirculate.md + idc-recirculator.md narrow the trigger to scope/menu and exclude mechanical conflicts; recirculator role unchanged"
