#!/usr/bin/env python3
"""idc_matrix_check.py — the matrix deconfliction check (`WORKFLOW.md §4.2`).

Plan's pairwise clash analysis produces a phase matrix under docs/workflow/pillar-matrices/.
This is the executable guardrail that enforces the matrix's load-bearing invariant:
**pillars in the same wave must own disjoint surfaces** — that is what makes a wave
parallel-safe. It also checks each pillar declares an id, a wave, and its owned surfaces.

The matrix is a constrained YAML subset (machine-emitted by the matrix-analysis skill), so
this parser is a small line scanner — no third-party YAML dependency:

    phase: Phase 1
    pillars:
      - id: <pillar-trace-key>
        wave: 1
        domain: <domain>
        surfaces: [path/a, path/b]
        blocks_on: [<other-id>, ...]

Usage: idc_matrix_check.py <matrix.yaml>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import posixpath
import re
import sys


def parse_list(val):
    val = val.strip()
    if val.startswith("[") and val.endswith("]"):
        inner = val[1:-1].strip()
        return [x.strip() for x in inner.split(",") if x.strip()] if inner else []
    return [val] if val else []


def parse_matrix(text):
    pillars = []
    cur = None
    in_pillars = False
    block_key = None  # a list key (surfaces|blocks_on) currently collecting a YAML block sequence
    for raw in text.splitlines():
        if re.match(r"^pillars:\s*$", raw):
            in_pillars = True
            continue
        if not in_pillars:
            continue
        m = re.match(r"^\s*-\s*id:\s*(.+?)\s*$", raw)
        if m:
            cur = {"id": m.group(1).strip(), "wave": None, "surfaces": [], "blocks_on": []}
            pillars.append(cur)
            block_key = None
            continue
        if cur is None:
            continue
        m = re.match(r"^\s*-\s*(.+?)\s*$", raw)
        if m and block_key is not None:
            cur[block_key].append(m.group(1).strip())
            continue
        m = re.match(r"^\s*(wave|domain|surfaces|blocks_on):\s*(.*)$", raw)
        if m:
            key, val = m.group(1), m.group(2).strip()
            block_key = None
            if key in ("surfaces", "blocks_on"):
                cur[key] = parse_list(val)
                if not val:
                    block_key = key
            else:
                cur[key] = val
    return pillars


def wave_number(value):
    text = str(value).strip() if value is not None else ""
    return int(text) if re.fullmatch(r"[1-9][0-9]*", text) else None


def normalize_surface(raw):
    text = str(raw or "").strip()
    if not text:
        raise ValueError("surface is empty")
    is_dir = text.endswith("/")
    text = text.replace("\\", "/")
    text = re.sub(r"/+/", "/", text)
    if text.startswith("/"):
        text = text[1:]
    norm = posixpath.normpath(text)
    if norm in ("..", "") or norm.startswith("../"):
        raise ValueError("surface escapes repository root")
    if is_dir:
        normalized = "./" if norm == "." else norm.rstrip("/") + "/"
    else:
        normalized = norm
    key = normalized.rstrip("/") if normalized != "./" else "."
    return {"raw": str(raw), "normalized": normalized, "key": key, "is_dir": is_dir}


def normalized_surfaces(pillar):
    return [normalize_surface(raw) for raw in pillar.get("surfaces", [])]


def _contains(dir_key, other_key):
    if dir_key == ".":
        return True
    return other_key == dir_key or other_key.startswith(dir_key + "/")


def surfaces_overlap(left, right):
    if left["key"] == right["key"]:
        return True
    if left["is_dir"] and _contains(left["key"], right["key"]):
        return True
    if right["is_dir"] and _contains(right["key"], left["key"]):
        return True
    return False


def overlap_descriptions(left_pillar, right_pillar):
    hits = []
    for left in normalized_surfaces(left_pillar):
        for right in normalized_surfaces(right_pillar):
            if not surfaces_overlap(left, right):
                continue
            relation = "alias" if left["key"] == right["key"] else "containment"
            hits.append(f"{left['normalized']} ~ {right['normalized']} ({relation})")
    return sorted(set(hits))


def surface_areas(pillars):
    """Carve pillars into disjoint AREAS: groups linked by overlapping normalized surfaces.

    Two pillars are in the same area when their owned surfaces overlap directly or transitively
    after normalization (alias or directory/file containment). Pillars in DIFFERENT areas never
    touch the same normalized file surface, so they are parallel-safe regardless of wave — the
    run-time orchestrator can staff independent writers per area. Returns a list of sorted
    id-lists, ordered by each area's smallest id."""
    ids = [p["id"] for p in pillars if p.get("id")]
    parent = {pid: pid for pid in ids}

    def find(node):
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    def union(a, b):
        parent[find(a)] = find(b)

    for i in range(len(pillars)):
        left = pillars[i]
        if not left.get("id"):
            continue
        for j in range(i + 1, len(pillars)):
            right = pillars[j]
            if not right.get("id"):
                continue
            if overlap_descriptions(left, right):
                union(left["id"], right["id"])
    groups = {}
    for pid in ids:
        groups.setdefault(find(pid), []).append(pid)
    return sorted((sorted(group) for group in groups.values()), key=lambda group: group[0])


def check(text):
    problems = []
    if not re.search(r"^pillars:\s*$", text, re.M):
        return ["missing top-level `pillars:` list"]
    pillars = parse_matrix(text)
    if not pillars:
        return ["`pillars:` is empty (a matrix must declare at least one pillar)"]

    seen_ids = {}
    by_wave = {}
    for pillar in pillars:
        pid = pillar.get("id")
        if not pid:
            problems.append("a pillar is missing `id`")
        else:
            seen_ids.setdefault(pid, 0)
            seen_ids[pid] += 1
        wave = pillar.get("wave")
        if not wave:
            problems.append(f"pillar '{pid}' is missing `wave`")
        elif wave_number(wave) is None:
            problems.append(
                f"pillar '{pid}' has invalid `wave` {wave!r} — use a positive integer")
        if not pillar.get("surfaces"):
            problems.append(
                f"pillar '{pid}' declares no `surfaces` (ownership is the deconfliction output)")
        else:
            for raw in pillar.get("surfaces", []):
                try:
                    normalize_surface(raw)
                except ValueError as exc:
                    problems.append(
                        f"pillar '{pid}' surface {raw!r} is invalid after normalization: {exc}")
        by_wave.setdefault(wave_number(wave) or wave, []).append(pillar)

    for pid, count in sorted(seen_ids.items()):
        if count > 1:
            problems.append(
                f"duplicate pillar id '{pid}' — every logical work node must appear exactly once")

    for wave, members in by_wave.items():
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                overlaps = overlap_descriptions(members[i], members[j])
                if overlaps:
                    problems.append(
                        f"wave {wave}: '{members[i]['id']}' and '{members[j]['id']}' "
                        f"share surface(s) {overlaps} — not parallel-safe "
                        f"(sequence them into different waves)")

    declared = {pillar["id"] for pillar in pillars if pillar.get("id")}
    for pillar in pillars:
        pid = pillar.get("id")
        if not pid:
            continue
        for dep in pillar.get("blocks_on", []):
            if dep != pid and dep not in declared:
                problems.append(
                    f"pillar '{pid}' blocks_on undeclared pillar '{dep}' — dangling dependency "
                    f"(fix the ref or declare the pillar; a silent drop inflates parallel width)")

    if not any("duplicate pillar id" in problem for problem in problems):
        import idc_dag
        cyc = idc_dag.analyze(pillars).get("cycle")
        if cyc:
            problems.append(
                f"blocks_on edges form a cycle among {cyc} — unschedulable "
                f"(break the cycle before waving)")
    return problems


def publish(text):
    """The plan-time intelligence printed on a PASS: the parallel-width CEILING + critical-path
    depth (from idc_dag) and the carved disjoint surface areas (the run-time orchestrator staffs
    independent writers against these)."""
    pillars = parse_matrix(text)
    import idc_dag
    analysis = idc_dag.analyze(pillars)
    print(f"parallel-width ceiling: {analysis['max_parallel_width']} "
          f"(critical path: {analysis['critical_path_length']})")
    areas = surface_areas(pillars)
    print(f"disjoint surface areas (never share a file surface): {len(areas)}")
    for index, area in enumerate(areas, 1):
        print(f"  area {index}: {', '.join(area)}")


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_matrix_check.py <matrix.yaml>\n")
        sys.exit(2)
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write(f"idc-matrix-check: cannot read {sys.argv[1]}: {exc}\n")
        sys.exit(2)
    problems = check(text)
    if problems:
        print("matrix check: FAIL")
        for problem in problems:
            print(f"  - {problem}")
        sys.exit(1)
    print("matrix check: PASS")
    publish(text)
    sys.exit(0)


if __name__ == "__main__":
    main()
