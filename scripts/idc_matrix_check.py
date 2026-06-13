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
        # a block-sequence item ("  - value") feeds the most recent list key (block style)
        m = re.match(r"^\s*-\s*(.+?)\s*$", raw)
        if m and block_key is not None:
            cur[block_key].append(m.group(1).strip())
            continue
        m = re.match(r"^\s*(wave|domain|surfaces|blocks_on):\s*(.*)$", raw)
        if m:
            key, val = m.group(1), m.group(2).strip()
            block_key = None
            if key in ("surfaces", "blocks_on"):
                # inline `[a, b]` populates now; a bare `key:` opens a block sequence
                cur[key] = parse_list(val)
                if not val:
                    block_key = key
            else:
                cur[key] = val
    return pillars


def check(text):
    problems = []
    if not re.search(r"^pillars:\s*$", text, re.M):
        return ["missing top-level `pillars:` list"]
    pillars = parse_matrix(text)
    if not pillars:
        return ["`pillars:` is empty (a matrix must declare at least one pillar)"]
    by_wave = {}
    for p in pillars:
        if not p["id"]:
            problems.append("a pillar is missing `id`")
        if not p.get("wave"):
            problems.append(f"pillar '{p['id']}' is missing `wave`")
        if not p["surfaces"]:
            problems.append(f"pillar '{p['id']}' declares no `surfaces` (ownership is the deconfliction output)")
        by_wave.setdefault(p.get("wave"), []).append(p)
    # parallel-safety: same-wave pillars must own disjoint surfaces
    for wave, members in by_wave.items():
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                shared = set(members[i]["surfaces"]) & set(members[j]["surfaces"])
                if shared:
                    problems.append(
                        f"wave {wave}: '{members[i]['id']}' and '{members[j]['id']}' "
                        f"share surface(s) {sorted(shared)} — not parallel-safe "
                        f"(sequence them into different waves)")
    return problems


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_matrix_check.py <matrix.yaml>\n")
        sys.exit(2)
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        sys.stderr.write(f"idc-matrix-check: cannot read {sys.argv[1]}: {e}\n")
        sys.exit(2)
    problems = check(text)
    if problems:
        print("matrix check: FAIL")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    print("matrix check: PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
