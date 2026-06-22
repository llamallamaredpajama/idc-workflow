#!/usr/bin/env python3
"""idc_dag.py — plan-time dependency-DAG intelligence for the IDC phase matrix.

The "head chef" gets smart. Builds the dependency DAG from each pillar's `blocks_on` edges
(the same constrained matrix YAML `scripts/idc_matrix_check.py` already parses) and reports the
two numbers the run-time orchestrator staffs against:

  - critical_path_length — the longest dependency chain (how deep the run must serialize;
    counted in NODES, so a lone pillar is length 1, a -> b is length 2).
  - max_parallel_width   — the widest ANTICHAIN (Dilworth's theorem): the most pillars that are
    mutually independent and could, given perfect surface-disjointness, run at once. This is the
    parallel-width CEILING the orchestrator staffs against — NOT a single wave's actual width
    (which is also capped by surface collisions, checked by idc_matrix_check.py).

A `blocks_on: [X]` entry on pillar Y is the edge X -> Y (X must finish before Y). A cycle in
those edges is unschedulable (no wave assignment can put every upstream in an earlier wave), so
the tool exits non-zero and names the offending nodes.

Why an antichain, not the level-width: same-"level" nodes form an antichain, but the maximum
antichain can be strictly wider than any single level (isolated roots at level 0 join leaves at
deeper levels). Dilworth computes it exactly: max antichain = N - (max bipartite matching over
the reachability relation) = the minimum number of chains that cover the DAG.

Usage: idc_dag.py <matrix.yaml>   (exit 0 = acyclic + analyzed, 1 = cycle, 2 = usage/read error)
"""
import os
import sys

# parse_matrix is the single owner of the constrained-YAML scanner — reuse it so a second parser
# can never drift from it. idc_matrix_check imports the analysis below LAZILY (inside its check),
# so this top-level import never closes an import cycle either direction.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from idc_matrix_check import parse_matrix  # noqa: E402


def build_edges(pillars):
    """Return (ids, succ, pred) from the pillars' `blocks_on` edges.

    `blocks_on: [X]` on Y means X must precede Y, i.e. the edge X -> Y, so X is a predecessor
    (upstream) of Y and Y a successor (downstream) of X. A `blocks_on` ref to an id that is not a
    declared pillar is ignored here (a dangling edge is not a DAG node — the matrix check surfaces
    it as a defect). A SELF-edge (X blocks_on X) IS kept: it is a trivial cycle (a pillar can never
    precede itself), so the cycle check reports it rather than silently passing an unschedulable
    board."""
    ids = [p["id"] for p in pillars if p.get("id")]
    idset = set(ids)
    succ = {i: set() for i in ids}
    pred = {i: set() for i in ids}
    for p in pillars:
        y = p.get("id")
        if not y or y not in idset:
            continue
        for x in p.get("blocks_on", []):
            if x in idset:
                succ[x].add(y)
                pred[y].add(x)
    return ids, succ, pred


def find_cycle(ids, succ, pred):
    """Kahn's algorithm. Return the sorted nodes that lie ON a cycle, or [] if acyclic.

    Kahn leaves every node with positive residual indegree — but that residue is the cycle nodes
    PLUS everything merely downstream of the cycle (an acyclic tail hanging off a cycle never reaches
    indegree 0, because its upstream is stuck). Naming the whole residue would misdirect the operator
    to a pillar that is not part of the circular dependency, so narrow it to the true members: a
    residual node is ON a cycle iff it can reach itself through residual-internal edges."""
    indeg = {i: len(pred[i]) for i in ids}
    queue = [i for i in ids if indeg[i] == 0]
    seen = 0
    while queue:
        n = queue.pop()
        seen += 1
        for m in succ[n]:
            indeg[m] -= 1
            if indeg[m] == 0:
                queue.append(m)
    if seen == len(ids):
        return []
    residual = {i for i in ids if indeg[i] > 0}

    def on_cycle(start):
        stack = [m for m in succ[start] if m in residual]
        visited = set()
        while stack:
            n = stack.pop()
            if n == start:
                return True
            if n in visited:
                continue
            visited.add(n)
            stack.extend(m for m in succ[n] if m in residual)
        return False

    return sorted(i for i in residual if on_cycle(i))


def topo_order(ids, succ, pred):
    """A deterministic topological order (assumes the graph is acyclic)."""
    indeg = {i: len(pred[i]) for i in ids}
    queue = sorted(i for i in ids if indeg[i] == 0)
    order = []
    while queue:
        n = queue.pop(0)
        order.append(n)
        for m in sorted(succ[n]):
            indeg[m] -= 1
            if indeg[m] == 0:
                queue.append(m)
    return order


def critical_path(ids, succ, pred):
    """Longest chain (node count) through the DAG; returns (length, path_nodes)."""
    if not ids:
        return 0, []
    order = topo_order(ids, succ, pred)
    best = {i: 1 for i in ids}
    parent = {i: None for i in ids}
    for n in order:
        for x in pred[n]:
            if best[x] + 1 > best[n]:
                best[n] = best[x] + 1
                parent[n] = x
    end = max(ids, key=lambda i: best[i])
    path = []
    cur = end
    while cur is not None:
        path.append(cur)
        cur = parent[cur]
    path.reverse()
    return best[end], path


def reachable(ids, succ):
    """Transitive successors of each node (the node itself excluded)."""
    reach = {}
    for s in ids:
        stack = list(succ[s])
        seen = set()
        while stack:
            n = stack.pop()
            if n in seen:
                continue
            seen.add(n)
            stack.extend(succ[n])
        reach[s] = seen
    return reach


def max_antichain(ids, succ):
    """Widest antichain via Dilworth: N - (max bipartite matching over the reachability relation).

    The minimum chain cover of a DAG equals N minus the maximum matching in the bipartite graph
    whose edge (u, v) means "u reaches v" (transitive closure, so a chain may skip intermediates);
    Dilworth's theorem makes that minimum chain cover equal the maximum antichain size."""
    reach = reachable(ids, succ)
    match_r = {}  # right node -> the left node matched to it

    def augment(u, visited):
        for v in sorted(reach[u]):
            if v in visited:
                continue
            visited.add(v)
            if v not in match_r or augment(match_r[v], visited):
                match_r[v] = u
                return True
        return False

    matching = sum(1 for u in ids if augment(u, set()))
    return len(ids) - matching


def analyze(pillars):
    """Full analysis. On a cycle, the path/width fields are None (unschedulable)."""
    ids, succ, pred = build_edges(pillars)
    cyc = find_cycle(ids, succ, pred)
    if cyc:
        return {"cycle": cyc, "critical_path_length": None,
                "max_parallel_width": None, "critical_path": []}
    length, path = critical_path(ids, succ, pred)
    return {"cycle": [], "critical_path_length": length,
            "max_parallel_width": max_antichain(ids, succ), "critical_path": path}


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_dag.py <matrix.yaml>\n")
        sys.exit(2)
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        sys.stderr.write(f"idc-dag: cannot read {sys.argv[1]}: {e}\n")
        sys.exit(2)
    result = analyze(parse_matrix(text))
    if result["cycle"]:
        sys.stderr.write(
            "dag: CYCLE detected among blocks_on edges: " + ", ".join(result["cycle"]) + "\n")
        sys.stderr.write(
            "a circular dependency is unschedulable — break the cycle before waving.\n")
        sys.exit(1)
    print("dag: OK")
    print(f"critical_path_length: {result['critical_path_length']}")
    print(f"max_parallel_width: {result['max_parallel_width']}")
    print(f"critical_path: {' -> '.join(result['critical_path'])}")
    sys.exit(0)


if __name__ == "__main__":
    main()
