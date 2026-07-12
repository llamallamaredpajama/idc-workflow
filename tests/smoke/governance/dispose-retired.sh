#!/bin/bash
# dispose-retired.sh — governance scenario: the `retired` terminal disposition (#150 door unification).
#
# A decomposed Consideration/Planning pointer is a NON-verdict terminal disposition: once Plan has
# broken it into real buildable child issues the pointer is retired, but it has no review verdict, so
# the verdict-guarded `close` cannot close it and before #150 it was retired through a RAW tracker
# close that bypassed the engine + journal. The new guarded op `dispose --disposition retired` mints
# Done ONLY when the `pointer-decomposition-record` guard passes: the item is a Consideration OR
# Planning pointer (Plan advances Consideration → Planning before retiring), AND a named `--child` is
# a real Buildable decomposition result on the board that references the pointer through the engine's
# own kind=sub DECOMPOSITION link — child.parent == pointer on filesystem (codex round-13 P2). A
# `--kind blocks` edge lands in child.blocked_by and is a DEPENDENCY (gate chaining, ordering), never
# a decomposition, so it must NEVER retire the pointer (before round-13 the guard also accepted
# blocked_by, so an unrelated blocks-edge could retire an undecomposed pointer).
#
# NOTE: these items are RAW-seeded (idc_tracker_fs create, not the engine), so no create record is
# journaled — the retire rides the pre-journal-legacy carve-out and ONLY the BOARD check is active
# here (the journal-corroboration layer + the kind=sub journal predicate are proven in
# dispose-journal-corroboration.sh). That makes case 2b a clean red-when-broken for the BOARD conjunct.
#
# Red-when-broken (the mutation proof): neuter check_retired (return without raising) → an unlinked
# child, a non-pointer item, or a non-Buildable child closes to Done → this FAILs. Widen the fs
# board conjunct back to `... or int(num) in (c_it.get("blocked_by") or [])` → case 2b (a blocks-edge
# child) retires → case 2b FAILs.
#
# Usage: bash tests/smoke/governance/dispose-retired.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# ── 1. HAPPY PATH (Consideration): a decomposed pointer with a linked buildable child retires ───────
p="$(gov_seed_item "$T" --title 'consideration: admitted idea' --stage Consideration --status Todo)" \
  || fail "could not seed the Consideration pointer"
c="$(gov_seed_item "$T" --title 'buildable: decomposition child' --stage Buildable --status Todo)" \
  || fail "could not seed the buildable child"
# Record the decomposition link through the engine's single write door (pointer blocks child ⇒
# child.blocked_by ∋ pointer — the child now references the pointer being retired).
eng link --parent "$p" --child "$c" --kind sub >/dev/null 2>&1 || fail "could not link the decomposition child to the pointer"
eng dispose --disposition retired --num "$p" --child "$c" >/dev/null 2>&1 \
  || fail "dispose --disposition retired refused a decomposed Consideration pointer with a linked buildable child"
[ "$(gov_field "$T" "$p" Status)" = "Done" ] || fail "retired disposition did not drive the pointer to Done"
echo "  ok (1) a Consideration pointer with a linked buildable child retires to Done"

# ── 1b. HAPPY PATH (Planning): the SAME after Plan advances the pointer Consideration → Planning ────
# The documented Plan flow advances the pointer to Planning before retiring it (agents/idc-plan.md).
pp="$(gov_seed_item "$T" --title 'planning: in-flight decomposition' --stage Planning --status Todo)" \
  || fail "could not seed the Planning pointer"
cc="$(gov_seed_item "$T" --title 'buildable: decomposition child (planning)' --stage Buildable --status Todo)" \
  || fail "could not seed the buildable child"
eng link --parent "$pp" --child "$cc" --kind sub >/dev/null 2>&1 || fail "could not link the child to the Planning pointer"
eng dispose --disposition retired --num "$pp" --child "$cc" >/dev/null 2>&1 \
  || fail "dispose --disposition retired refused a Stage=Planning pointer — the normal Plan lifecycle advances Consideration → Planning before retiring"
[ "$(gov_field "$T" "$pp" Status)" = "Done" ] || fail "retired disposition did not drive the Planning pointer to Done"
echo "  ok (1b) a Planning pointer (the normal post-advance lifecycle) with a linked buildable child retires to Done"

# ── 2. DENY: a pointer whose named child does NOT reference it is refused (no decomposition record) ─
p2="$(gov_seed_item "$T" --title 'consideration: not yet decomposed' --stage Consideration --status Todo)" \
  || fail "could not seed the un-decomposed pointer"
orphan="$(gov_seed_item "$T" --title 'buildable: unrelated work' --stage Buildable --status Todo)" \
  || fail "could not seed the unrelated buildable"
if eng dispose --disposition retired --num "$p2" --child "$orphan" 2>/dev/null; then
  fail "retired closed a pointer whose --child does NOT reference it (no decomposition link — guard bypassed)"
fi
[ "$(gov_field "$T" "$p2" Status)" != "Done" ] || fail "denied retired still drove the un-decomposed pointer to Done"
echo "  ok (2) a pointer whose --child does not reference it is REFUSED (no decomposition record)"

# ── 2b. DENY: a child linked to the pointer by a BLOCKS edge (a dependency, not a decomposition) ────
# `link --kind blocks` records child.blocked_by ∋ pointer — a dependency/ordering edge, NOT a
# decomposition (`--kind sub`, which sets child.parent == pointer). A blocks-edge must never serve as
# the retirement receipt (codex round-13 P2): the child #cb IS a Buildable, and IS engine-linked to
# the pointer, but only as a blocks-dependency — retirement must still be refused.
pb="$(gov_seed_item "$T" --title 'consideration: blocks-linked, not decomposed' --stage Consideration --status Todo)" \
  || fail "could not seed the blocks-linked pointer"
cb="$(gov_seed_item "$T" --title 'buildable: a mere blocks-dependency' --stage Buildable --status Todo)" \
  || fail "could not seed the blocks-linked child"
eng link --parent "$pb" --child "$cb" --kind blocks >/dev/null 2>&1 || fail "could not blocks-link the child"
if eng dispose --disposition retired --num "$pb" --child "$cb" 2>/dev/null; then
  fail "retired closed a pointer whose child is only a kind=blocks DEPENDENCY (not a kind=sub decomposition)"
fi
[ "$(gov_field "$T" "$pb" Status)" != "Done" ] || fail "denied retired still drove the blocks-linked pointer to Done"
echo "  ok (2b) a child linked by a BLOCKS edge (not kind=sub) is REFUSED (a dependency is not a decomposition)"

# ── 3. DENY: a NON-pointer (Buildable) item is refused (build work closes via a verdict-guarded close)
w="$(gov_seed_item "$T" --title 'buildable: real work' --stage Buildable --status 'In Progress')" \
  || fail "could not seed the buildable work item"
wc="$(gov_seed_item "$T" --title 'buildable: its child' --stage Buildable --status Todo)" \
  || fail "could not seed the child"
eng link --parent "$w" --child "$wc" --kind sub >/dev/null 2>&1 || fail "could not link the child"
if eng dispose --disposition retired --num "$w" --child "$wc" 2>/dev/null; then
  fail "retired closed a Stage=Buildable item (build work must close via the verdict-guarded close, not retire)"
fi
[ "$(gov_field "$T" "$w" Status)" != "Done" ] || fail "denied retired still drove the Buildable item to Done"
echo "  ok (3) a Stage=Buildable item is REFUSED (retire is confined to Consideration/Planning pointers)"

# ── 4. DENY: a linked but NON-Buildable --child is refused (the child must be a real build result) ──
# A pointer P linked to another pointer/inbox item Q (not a Buildable) is NOT a decomposition — an
# unrelated Consideration/Recirculation issue must not serve as the retirement receipt.
p4="$(gov_seed_item "$T" --title 'consideration: fake decomposition' --stage Consideration --status Todo)" \
  || fail "could not seed the pointer"
q4="$(gov_seed_item "$T" --title 'consideration: another pointer, not build work' --stage Consideration --status Todo)" \
  || fail "could not seed the non-Buildable child"
eng link --parent "$p4" --child "$q4" --kind sub >/dev/null 2>&1 || fail "could not link"
if eng dispose --disposition retired --num "$p4" --child "$q4" 2>/dev/null; then
  fail "retired closed a pointer using a NON-Buildable linked child (a real build result is required)"
fi
[ "$(gov_field "$T" "$p4" Status)" != "Done" ] || fail "denied retired still drove the pointer to Done"
echo "  ok (4) a linked but non-Buildable --child is REFUSED (the receipt must be a real build result)"

# ── 5. DENY: a Blocked (un-admitted, gate-parked) pointer is refused — never terminalize behind a gate
# A consideration still Blocked behind an unmerged Think gate is un-admitted; retiring it mints a
# terminal Done the later gate-unblock can never advance, silently dropping the pending consideration.
p5="$(gov_seed_item "$T" --title 'consideration: un-admitted (open Think PR)' --stage Consideration --status Blocked)" \
  || fail "could not seed the Blocked pointer"
c5="$(gov_seed_item "$T" --title 'buildable: premature child' --stage Buildable --status Todo)" \
  || fail "could not seed the child"
eng link --parent "$p5" --child "$c5" --kind sub >/dev/null 2>&1 || fail "could not link"
if eng dispose --disposition retired --num "$p5" --child "$c5" 2>/dev/null; then
  fail "retired terminalized a Blocked (gate-parked, un-admitted) pointer — the later gate-unblock can never advance a Done item"
fi
[ "$(gov_field "$T" "$p5" Status)" != "Done" ] || fail "denied retired still drove the Blocked pointer to Done"
echo "  ok (5) a Blocked (un-admitted) pointer is REFUSED (never terminalized behind its Think gate)"

echo "PASS: dispose --disposition retired mints Done ONLY for a non-Blocked Consideration/Planning pointer whose named --child is a Buildable decomposition result referencing it via the engine's kind=sub link (child.parent == pointer); an unlinked child, a kind=blocks dependency edge, a non-pointer item, a non-Buildable child, and a gate-parked Blocked pointer are all fail-closed"
