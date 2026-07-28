#!/bin/bash
# idc-assert-class: behavior
# graph-done-closure.sh — F60: a prematurely `Done` node must not unlock its descendants.
#
# THE DEFECT THIS LANE LOCKS. `idc_execution_graph.derive_waves` seeds `completed` with every board
# item whose status reads `Done` and never checks that the completion was earned. For `A -> B -> C`
# with B marked `Done` while A is still `Todo`, B entered `completed`, C's only predecessor was
# therefore satisfied, and C was scheduled into a buildable wave with NO blockers recorded — while
# its transitive prerequisite A had never been built. The precondition is precisely the condition
# this compiler exists to detect (a stale, buggy, or unauthorized tracker mutation), so laundering it
# into a wave is the worst available answer: the output carries no trace that anything was wrong.
#
# What it proves:
#   A. B Done while its predecessor A is Todo -> the compiler REFUSES and names both nodes;
#   B. the same divergence refuses through the projection surface too (it compiles the same graph);
#   C. a Done node whose predecessor has no tracker item at all is divergence as well;
#   D. earned completion still compiles — A Done, B Done -> C is scheduled;
#   E. an all-Todo horizon still compiles (no false refusal);
#   F. the refusal is read-only — the tracker is byte-identical afterwards.
#
# Red-when-broken: delete the assert_done_closure call in derive_waves and A/B/C fail (the compiler
# exits 0 and hands back a wave for C). Over-tighten it into refusing earned completion and D/E fail.
#
# Usage: bash tests/smoke/governance/graph-done-closure.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
GRAPH="$PLUGIN/scripts/idc_execution_graph.py"
PROJECTION="$PLUGIN/scripts/idc_tracker_projection.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GRAPH" ] || fail "idc_execution_graph.py not found at $GRAPH"
[ -f "$PROJECTION" ] || fail "idc_tracker_projection.py not found at $PROJECTION"

# A -> B -> C, one domain, disjoint surfaces so nothing is resource-blocked and the ONLY thing that
# can schedule C is predecessor satisfaction.
cat > "$WORK/chain.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
  - id: beta
    wave: 2
    domain: core
    surfaces: [src/beta/]
    blocks_on: [alpha]
  - id: gamma
    wave: 3
    domain: core
    surfaces: [src/gamma/]
    blocks_on: [beta]
YAML

compile_chain() { timeout 60 python3 "$GRAPH" --matrix "$WORK/chain.yaml" --backend filesystem --tracker "$1" --json; }

# --- A. premature Done: B is Done while A is still Todo -------------------------------------------
T_BAD="$(gov_new_tracker)" || fail "could not init the premature-Done tracker"
gov_seed_item "$T_BAD" --title alpha --stage Buildable --status Todo --wave 1 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed alpha"
gov_seed_item "$T_BAD" --title beta --stage Buildable --status Done --wave 2 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed the prematurely-Done beta"
gov_seed_item "$T_BAD" --title gamma --stage Buildable --status Todo --wave 3 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed gamma"

before="$(shasum -a 256 "$T_BAD" | awk '{print $1}')"
out="$(compile_chain "$T_BAD" 2>&1)" \
  && fail "the compiler accepted a prematurely-Done node: an unbuilt prerequisite silently unlocked its descendants. Output was: $out"
printf '%s\n' "$out" | grep -qiE 'diverg' \
  || fail "the refusal must name the condition as tracker/graph divergence; got: $out"
printf '%s\n' "$out" | grep -q "beta" \
  || fail "the refusal must name the offending Done node (beta); got: $out"
printf '%s\n' "$out" | grep -q "alpha" \
  || fail "the refusal must name the unmet prerequisite (alpha); got: $out"

# F. read-only: a refused compilation never touches the tracker.
after="$(shasum -a 256 "$T_BAD" | awk '{print $1}')"
[ "$before" = "$after" ] \
  || fail "a refused compilation mutated the live tracker (checksum $before -> $after)"

# --- B. the same divergence refuses through the projection surface --------------------------------
out="$(timeout 60 python3 "$PROJECTION" --matrix "$WORK/chain.yaml" --backend filesystem --tracker "$T_BAD" --json 2>&1)" \
  && fail "the projection accepted a prematurely-Done node (it compiles the same graph): $out"
printf '%s\n' "$out" | grep -qiE 'diverg' \
  || fail "the projection's refusal must name tracker/graph divergence; got: $out"

# --- C. a Done node whose prerequisite has no tracker item at all ---------------------------------
T_UNTRACKED="$(gov_new_tracker)" || fail "could not init the untracked-prerequisite tracker"
gov_seed_item "$T_UNTRACKED" --title beta --stage Buildable --status Done --wave 2 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed the Done beta"
out="$(compile_chain "$T_UNTRACKED" 2>&1)" \
  && fail "the compiler treated a Done node as earned while its prerequisite has no tracker item at all: $out"
printf '%s\n' "$out" | grep -q "alpha" \
  || fail "the untracked-prerequisite refusal must name alpha; got: $out"

# --- D. earned completion still compiles, and gamma is scheduled ----------------------------------
T_GOOD="$(gov_new_tracker)" || fail "could not init the earned-completion tracker"
gov_seed_item "$T_GOOD" --title alpha --stage Buildable --status Done --wave 1 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed the Done alpha"
gov_seed_item "$T_GOOD" --title beta --stage Buildable --status Done --wave 2 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed the Done beta"
gov_seed_item "$T_GOOD" --title gamma --stage Buildable --status Todo --wave 3 --phase "Phase 1" --domain core >/dev/null \
  || fail "could not seed gamma"
compile_chain "$T_GOOD" > "$WORK/good.json" 2>"$WORK/good.err" \
  || fail "the closure check refused EARNED completion (A Done, B Done): $(cat "$WORK/good.err")"
python3 - "$WORK/good.json" <<'PY' || exit 1
import json, sys
graph = json.load(open(sys.argv[1], encoding='utf-8'))
gamma = next(n for n in graph['nodes'] if n['id'] == 'gamma')
if gamma.get('derived_wave') is None:
    raise SystemExit(f"FAIL: gamma was not scheduled despite a fully-earned predecessor closure: {gamma}")
if gamma.get('blocked_reasons'):
    raise SystemExit(f"FAIL: gamma carries blockers despite earned completion: {gamma['blocked_reasons']}")
print('ok: earned completion still unlocks descendants')
PY

# --- E. an all-Todo horizon compiles normally (no false refusal) ----------------------------------
T_TODO="$(gov_new_tracker)" || fail "could not init the all-Todo tracker"
for pid in alpha beta gamma; do
  gov_seed_item "$T_TODO" --title "$pid" --stage Buildable --status Todo --wave 1 --phase "Phase 1" --domain core >/dev/null \
    || fail "could not seed $pid"
done
compile_chain "$T_TODO" > "$WORK/todo.json" 2>"$WORK/todo.err" \
  || fail "the closure check refused an all-Todo horizon (no Done node exists to be unearned): $(cat "$WORK/todo.err")"
python3 - "$WORK/todo.json" <<'PY' || exit 1
import json, sys
graph = json.load(open(sys.argv[1], encoding='utf-8'))
waves = graph['waves']
if waves.get('alpha') is None:
    raise SystemExit(f"FAIL: alpha was not scheduled on an all-Todo horizon: {waves}")
print('ok: an all-Todo horizon still derives waves')
PY

echo "PASS: the execution graph refuses to compile waves from unearned completion (naming the Done node and its unmet prerequisite, through both the graph and projection surfaces, without touching the tracker) while earned completion and all-Todo horizons still compile"
