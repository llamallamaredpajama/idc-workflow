#!/bin/bash
# Phase 3 smoke — the "head chef" gets smart: plan-time dependency-DAG intelligence.
#
#   (a) scripts/idc_dag.py builds the DAG from each pillar's blocks_on edges and reports the
#       CRITICAL-PATH length (longest dependency chain) and the MAX-PARALLEL WIDTH (widest
#       antichain — Dilworth, the parallel-width ceiling the orchestrator staffs against);
#   (b) it exits non-zero when the blocks_on edges form a cycle (unschedulable);
#   (c) the analysis is wired into scripts/idc_matrix_check.py so the matrix now FAILs on a
#       blocks_on cycle and, on PASS, publishes the width ceiling plus the carved disjoint
#       surface AREAS (pillar groups that never share a file surface).
#
# Red-when-broken by construction: the fixture graph is chosen so critical-path (2),
# max-width (4), and the naive level-width (3) are all DIFFERENT integers — a level-width or
# root-count mis-implementation gives 3, a critical-path confusion gives 2, only the true
# widest antichain gives 4. Pinning the exact integers (not a grep) makes a wrong DAG go red.
#
# Failing-test-first: fails until scripts/idc_dag.py exists and matrix_check is wired to it.
#
# Usage: bash tests/smoke/phase3-dag-matrix.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
DAG="$PLUGIN/scripts/idc_dag.py"
MATRIX="$PLUGIN/scripts/idc_matrix_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$DAG" ] || fail "DAG analyzer not found at $DAG (not implemented yet)"
[ -f "$MATRIX" ] || fail "matrix checker not found at $MATRIX"

# ---- the known acyclic fixture board --------------------------------------------------------
# Edges (blocks_on => upstream must precede): pillar-a -> pillar-b, pillar-a -> pillar-e.
# pillar-c and pillar-d are isolated. Surfaces are all unique (disjoint within every wave).
#   critical path (longest chain, node count) = 2  (pillar-a -> pillar-b)
#   max parallel width (widest antichain)     = 4  ({pillar-b, pillar-c, pillar-d, pillar-e})
#   naive level-width (the WRONG answer)       = 3  (the three roots a, c, d at level 0)
cat > "$WORK/board-good.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: pillar-a
    wave: 1
    domain: core
    surfaces: [src/a/]
    blocks_on: []
  - id: pillar-b
    wave: 2
    domain: core
    surfaces: [src/b/]
    blocks_on: [pillar-a]
  - id: pillar-c
    wave: 1
    domain: core
    surfaces: [src/c/]
    blocks_on: []
  - id: pillar-d
    wave: 1
    domain: core
    surfaces: [src/d/]
    blocks_on: []
  - id: pillar-e
    wave: 2
    domain: core
    surfaces: [src/e/]
    blocks_on: [pillar-a]
MD

# ---- (a) critical-path + max-parallel-width are computed correctly --------------------------
out="$(python3 "$DAG" "$WORK/board-good.yaml")" \
  || fail "idc_dag.py errored on a valid acyclic board (exit non-zero)"
cp_len=$(printf '%s\n' "$out" | sed -n 's/^critical_path_length: //p')
width=$(printf '%s\n' "$out" | sed -n 's/^max_parallel_width: //p')
[ "$cp_len" = "2" ] \
  || fail "critical_path_length wrong: expected 2 (chain pillar-a -> pillar-b), got '$cp_len'"
[ "$width" = "4" ] \
  || fail "max_parallel_width wrong: expected 4 (antichain {b,c,d,e}), got '$width' — a level-width/root-count impl gives 3, a critical-path confusion gives 2"

# ---- (b) a blocks_on cycle is unschedulable: idc_dag.py exits non-zero -----------------------
cat > "$WORK/board-cycle.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: pillar-x
    wave: 1
    domain: core
    surfaces: [src/x/]
    blocks_on: [pillar-y]
  - id: pillar-y
    wave: 1
    domain: core
    surfaces: [src/y/]
    blocks_on: [pillar-x]
MD
if python3 "$DAG" "$WORK/board-cycle.yaml" >/dev/null 2>&1; then
  fail "idc_dag.py accepted a cyclic board (must exit non-zero on a blocks_on cycle)"
fi

# ---- (b2) the cycle diagnostic names ONLY true cycle members, never acyclic downstream nodes -----
# Graph: cyc-a -> cyc-b -> cyc-c -> cyc-a (a 3-cycle) plus cyc-tail (blocks_on cyc-b) hanging off it.
# Kahn leaves a,b,c AND tail with positive residual indegree, but only a,b,c are ON the cycle; tail
# is merely downstream of it. Red-when-broken: a raw residual-indegree dump names cyc-tail too,
# misdirecting the operator to edit a pillar that is not part of the circular dependency.
cat > "$WORK/board-cycle-tail.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: cyc-a
    wave: 1
    domain: core
    surfaces: [src/ca/]
    blocks_on: [cyc-c]
  - id: cyc-b
    wave: 1
    domain: core
    surfaces: [src/cb/]
    blocks_on: [cyc-a]
  - id: cyc-c
    wave: 1
    domain: core
    surfaces: [src/cc/]
    blocks_on: [cyc-b]
  - id: cyc-tail
    wave: 1
    domain: core
    surfaces: [src/ct/]
    blocks_on: [cyc-b]
MD
ctout="$(python3 "$DAG" "$WORK/board-cycle-tail.yaml" 2>&1)" \
  && fail "idc_dag.py must exit non-zero on the 3-cycle+tail board"
for n in cyc-a cyc-b cyc-c; do
  printf '%s\n' "$ctout" | grep -q "$n" \
    || fail "cycle diagnostic must name the true cycle member $n; got: $ctout"
done
printf '%s\n' "$ctout" | grep -q "cyc-tail" \
  && fail "cycle diagnostic must NOT name the acyclic downstream node cyc-tail (only true cycle members); got: $ctout"

# ---- (c) matrix_check is wired to the DAG analysis ------------------------------------------
# On PASS the matrix publishes the width ceiling (the 4 from above) and the carved areas;
# a blocks_on cycle is now a matrix FAIL (the surfaces in board-cycle are disjoint, so the
# ONLY reason it can fail is the cycle — proving the cycle wiring, not a surface clash).
mout="$(python3 "$MATRIX" "$WORK/board-good.yaml")" \
  || fail "matrix_check rejected a valid disjoint board"
printf '%s\n' "$mout" | grep -q "ceiling: 4" \
  || fail "matrix_check must publish the parallel-width ceiling (expected 'ceiling: 4'); got: $mout"
printf '%s\n' "$mout" | grep -qi "area" \
  || fail "matrix_check must publish the carved disjoint surface areas; got: $mout"

cout="$(python3 "$MATRIX" "$WORK/board-cycle.yaml" 2>&1)" \
  && fail "matrix_check accepted a board whose blocks_on edges form a cycle (must FAIL)"
printf '%s\n' "$cout" | grep -qi "cycle" \
  || fail "matrix_check must name the blocks_on cycle as the failure reason; got: $cout"

# ---- (d) a DANGLING blocks_on ref is a matrix FAIL (not a silently-dropped edge) -------------
# A blocks_on ref to a pillar that is not declared used to be silently ignored — a dependency typo
# then makes the pillar look independent and INFLATES the parallel-width ceiling (and could let the
# orchestrator run it before its true upstream). The matrix guardrail must FAIL on it. Surfaces are
# disjoint here, so the cycle/clash checks pass — the ONLY reason this can fail is the dangling ref.
cat > "$WORK/board-dangling.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: real-a
    wave: 1
    domain: core
    surfaces: [src/ra/]
    blocks_on: [typo-nonexistent]
  - id: real-b
    wave: 1
    domain: core
    surfaces: [src/rb/]
    blocks_on: []
MD
dout="$(python3 "$MATRIX" "$WORK/board-dangling.yaml" 2>&1)" \
  && fail "matrix_check accepted a board with a dangling blocks_on ref (must FAIL — a typo'd dependency silently inflates parallel width)"
printf '%s\n' "$dout" | grep -qiE 'dangling|undeclared|typo-nonexistent' \
  || fail "matrix_check must name the dangling blocks_on ref as the failure reason; got: $dout"

# ---- (e) a SELF blocks_on ref is unschedulable: BOTH idc_dag standalone AND matrix_check FAIL --
# `blocks_on: [self]` is a trivial cycle (a pillar can never precede itself). idc_dag KEEPS the
# self-edge so its own cycle detection reports it (standalone analysis is correct, not just the
# guardrail), and the matrix check FAILs via that same cycle path. Red-when-broken: drop the
# self-edge and idc_dag reports the board as schedulable (exit 0), hiding an unschedulable input.
cat > "$WORK/board-selfref.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: solo
    wave: 1
    domain: core
    surfaces: [src/solo/]
    blocks_on: [solo]
MD
if dsout="$(python3 "$DAG" "$WORK/board-selfref.yaml" 2>&1)"; then
  fail "idc_dag.py accepted a self-dependency board (must exit non-zero — a self-edge is a trivial cycle); got: $dsout"
fi
printf '%s\n' "$dsout" | grep -qi "solo" \
  || fail "idc_dag.py must name the self-referencing node 'solo'; got: $dsout"
sout="$(python3 "$MATRIX" "$WORK/board-selfref.yaml" 2>&1)" \
  && fail "matrix_check accepted a pillar that blocks_on itself (must FAIL — a self-dependency is unschedulable)"
printf '%s\n' "$sout" | grep -qi "solo" \
  || fail "matrix_check must name the self-dependency 'solo' as the failure reason; got: $sout"
printf '%s\n' "$sout" | grep -qiE 'cycle|unschedulable|itself|self-depend' \
  || fail "matrix_check must explain the self-dep failure (cycle/unschedulable); got: $sout"

# ---- (f) the carved disjoint surface AREAS reflect the union-find, not just the word "area" -------
# §(c) only proves the word "area" prints, and board-good has all-disjoint surfaces, so every pillar
# is its own area — the union is NEVER exercised. This fixture forces a UNION: two pillars in
# DIFFERENT waves SHARE a file surface, so the same-wave-disjoint invariant still PASSes (they are not
# in one wave) but surface_areas() must merge them into ONE area across waves; a third pillar with a
# disjoint surface stays separate. Red-when-broken: a never-unions union-find prints 3 areas (and
# splits shareA/shareB); a unions-everything one prints 1 (and pulls solo in). This is the executable
# guard for area CARVING; the area-packing DISPATCH wiring (one worker per area) is doctrine-grepped
# in agents/idc-build.md by phase4-ready-frontier.sh §B.
cat > "$WORK/board-areas.yaml" <<'MD'
phase: Phase 1
pillars:
  - id: pillar-shareA
    wave: 1
    domain: core
    surfaces: [src/shared/]
    blocks_on: []
  - id: pillar-shareB
    wave: 2
    domain: core
    surfaces: [src/shared/]
    blocks_on: []
  - id: pillar-solo
    wave: 1
    domain: core
    surfaces: [src/solo/]
    blocks_on: []
MD
aout="$(python3 "$MATRIX" "$WORK/board-areas.yaml")" \
  || fail "matrix_check rejected a valid board (a shared surface across DIFFERENT waves is wave-parallel-safe, area-merged by surface); got: $aout"
acount=$(printf '%s\n' "$aout" | sed -n 's/^disjoint surface areas.*: //p')
[ "$acount" = "2" ] \
  || fail "surface_areas must carve 2 areas (shareA+shareB share src/shared/ -> one area; solo disjoint -> separate); got count '$acount' in: $aout"
# the two surface-sharing pillars land in the SAME area line ...
shareline="$(printf '%s\n' "$aout" | grep -E '^[[:space:]]*area [0-9]+:' | grep 'pillar-shareA')"
printf '%s\n' "$shareline" | grep -q 'pillar-shareB' \
  || fail "surface-sharing pillars shareA+shareB must be carved into ONE area (union-find merge across waves); got area line: '$shareline'"
# ... and the disjoint pillar is NOT in that area
printf '%s\n' "$shareline" | grep -q 'pillar-solo' \
  && fail "disjoint pillar-solo must NOT share shareA/shareB's area (it owns a separate surface); got area line: '$shareline'"

echo "PASS: idc_dag critical-path + max-width + cycle detect green; wired into matrix_check (width ceiling + disjoint-area CARVING [union-find, red-when-broken] + cycle/dangling/self-ref FAIL)"
