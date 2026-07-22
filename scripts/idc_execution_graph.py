#!/usr/bin/env python3
"""idc_execution_graph.py — authoritative whole-horizon graph compiler for Plan.

Consumes the current Plan matrix plus a tracker snapshot (filesystem or GitHub reader only),
normalizes work/resource facts into one deterministic graph IR, derives authoritative Waves, and
emits an honest provider-coverage manifest. This is a read-only compiler: it never mutates the live
tracker.
"""
import argparse
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_dag  # noqa: E402
import idc_gh_board  # noqa: E402
import idc_matrix_check  # noqa: E402
import idc_tracker_fs  # noqa: E402

ALLOWED_PROVIDER_STATUSES = {
    "complete-for-declared-scope",
    "partial",
    "stale",
    "failed",
    "unavailable",
}
ACTIVE_STATUSES = {"Todo", "Blocked", "In Progress"}


def die(message, code=1):
    sys.stderr.write(f"idc-execution-graph: {message}\n")
    sys.exit(code)


def sha256_json(value):
    blob = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def load_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        die(f"cannot read {path}: {exc}")


def parse_phase(text):
    match = re.search(r"^phase:\s*(.+?)\s*$", text, re.M)
    return match.group(1).strip() if match else ""


def load_tracker_snapshot(backend, tracker, repo, owner, project):
    if backend == "filesystem":
        try:
            state = idc_tracker_fs.load(tracker)
        except SystemExit:
            die(f"cannot load filesystem tracker {tracker}")
        items = []
        for item in sorted(state.get("issues", []), key=lambda row: row.get("number", 0)):
            items.append({
                "number": item.get("number"),
                "title": item.get("title", ""),
                "status": item.get("status", ""),
                "stage": item.get("stage") or "Buildable",
                "wave": item.get("wave") or "",
                "phase": item.get("phase") or "",
                "domain": item.get("domain") or "",
                "blocked_by": list(item.get("blocked_by", [])),
            })
        return items
    if backend == "github":
        if not owner or not project:
            die("github backend requires --owner and --project")
        try:
            raw = idc_gh_board.fetch_items(owner, project, repo)
        except idc_gh_board.BoardReadError as exc:
            die(f"cannot read github tracker snapshot: {exc}")
        items = []
        for item in raw:
            content = item.get("content") or {}
            items.append({
                "number": content.get("number"),
                "title": item.get("title", ""),
                "status": item.get("status", ""),
                "stage": item.get("stage") or "Buildable",
                "wave": item.get("wave") or "",
                "phase": item.get("phase") or "",
                "domain": item.get("domain") or "",
                "blocked_by": [],
                "item_id": item.get("id"),
            })
        return items
    die(f"unknown backend {backend!r}")


def pillar_conflicts(left, right):
    return bool(idc_matrix_check.overlap_descriptions(left, right))


def map_tracker_items(pillars, tracker_items, phase):
    pillar_ids = {pillar["id"] for pillar in pillars if pillar.get("id")}
    by_id = {}
    active_unmapped = []
    for item in tracker_items:
        stage = item.get("stage") or "Buildable"
        status = item.get("status")
        title = (item.get("title") or "").strip()
        item_phase = item.get("phase") or ""
        if title in pillar_ids:
            if title in by_id:
                die(f"tracker snapshot maps multiple items to pillar '{title}'")
            by_id[title] = item
            continue
        if stage == "Buildable" and status in ACTIVE_STATUSES and (not phase or not item_phase or item_phase == phase):
            active_unmapped.append(item)
    if active_unmapped:
        names = ", ".join(repr(item.get("title") or f"#{item.get('number')}") for item in active_unmapped)
        die(f"live planning horizon item(s) absent from the graph: {names}")
    return by_id


def downstream_depths(pillars):
    ids, succ, pred = idc_dag.build_edges(pillars)
    if idc_dag.find_cycle(ids, succ, pred):
        die("cannot derive downstream depth from a cyclic matrix")
    order = idc_dag.topo_order(ids, succ, pred)
    depth = {pid: 1 for pid in ids}
    for pid in reversed(order):
        if succ[pid]:
            depth[pid] = 1 + max(depth[child] for child in succ[pid])
    return depth, succ, pred


def derive_waves(pillars, live_by_id):
    pillar_by_id = {pillar["id"]: pillar for pillar in pillars if pillar.get("id")}
    depth, _succ, pred = downstream_depths(pillars)
    done = {pid for pid, item in live_by_id.items() if item.get("status") == "Done"}
    occupied = {pid for pid, item in live_by_id.items() if item.get("status") == "In Progress"}
    derived = {}
    blockers = {pid: [] for pid in pillar_by_id}

    for pid in done | occupied:
        live_wave = idc_matrix_check.wave_number(live_by_id[pid].get("wave"))
        derived[pid] = live_wave

    start_wave = max((wave for pid, wave in derived.items() if pid in occupied and wave is not None), default=0) + 1
    completed = set(done)
    assigned = set()
    pending = [pid for pid in pillar_by_id if pid not in done and pid not in occupied]

    def occupied_blockers(pid):
        hits = []
        for occ in sorted(occupied):
            if pillar_conflicts(pillar_by_id[pid], pillar_by_id[occ]):
                hits.append(f"occupied:{occ}")
        return hits

    wave_no = start_wave
    while pending:
        ready = [pid for pid in pending if all(dep in completed or dep in assigned for dep in pred[pid])]
        if not ready:
            for pid in pending:
                blockers[pid] = [dep for dep in pred[pid] if dep not in completed and dep not in assigned]
            break

        free_ready = [pid for pid in ready if not occupied_blockers(pid)]
        if not free_ready:
            for pid in ready:
                blockers[pid] = occupied_blockers(pid)
            for pid in pending:
                blockers[pid] = blockers.get(pid) or [dep for dep in pred[pid] if dep not in completed and dep not in assigned]
            break

        ordered = sorted(free_ready, key=lambda pid: (-depth[pid], pid))
        chosen = []
        for pid in ordered:
            if any(pillar_conflicts(pillar_by_id[pid], pillar_by_id[other]) for other in chosen):
                continue
            chosen.append(pid)
        if not chosen:
            for pid in pending:
                blockers[pid] = blockers.get(pid) or ["resource-conflict"]
            break

        for pid in chosen:
            derived[pid] = wave_no
        assigned.update(chosen)
        pending = [pid for pid in pending if pid not in chosen]
        wave_no += 1

    for pid in pending:
        blockers[pid] = blockers.get(pid) or occupied_blockers(pid)
    return derived, blockers


def build_coverage_manifest(provider_name, provider_status):
    if provider_status not in ALLOWED_PROVIDER_STATUSES:
        die(f"invalid --code-provider-status {provider_status!r} (one of {sorted(ALLOWED_PROVIDER_STATUSES)})")
    code_complete = provider_status == "complete-for-declared-scope"
    overall = "complete-for-declared-scope" if code_complete else "partial"
    return {
        "status": overall,
        "code_evidence_complete": code_complete,
        "native_provider": {
            "name": "native",
            "status": "complete-for-declared-scope",
        },
        "providers": [{
            "name": provider_name,
            "status": provider_status,
            "authority": "provider",
        }],
    }


def compile_graph(matrix_path, backend, tracker, repo=".", owner=None, project=None,
                  provider_name="optional-code-evidence", provider_status="unavailable"):
    text = load_text(matrix_path)
    problems = idc_matrix_check.check(text)
    if problems:
        die("matrix validation failed:\n- " + "\n- ".join(problems))
    pillars = idc_matrix_check.parse_matrix(text)
    phase = parse_phase(text)
    tracker_items = load_tracker_snapshot(backend, tracker, repo, owner, project)
    live_by_id = map_tracker_items(pillars, tracker_items, phase)
    derived_waves, blockers = derive_waves(pillars, live_by_id)
    coverage_manifest = build_coverage_manifest(provider_name, provider_status)

    nodes = []
    edges = []
    pillar_by_id = {pillar["id"]: pillar for pillar in pillars if pillar.get("id")}
    for pid in sorted(pillar_by_id):
        pillar = pillar_by_id[pid]
        live = live_by_id.get(pid)
        normalized = [surface["normalized"] for surface in idc_matrix_check.normalized_surfaces(pillar)]
        node = {
            "id": pid,
            "phase": phase,
            "domain": pillar.get("domain") or "",
            "declared_wave": idc_matrix_check.wave_number(pillar.get("wave")),
            "derived_wave": derived_waves.get(pid),
            "surfaces": normalized,
            "blocks_on": sorted(pillar.get("blocks_on", [])),
            "blocked_reasons": sorted(set(blockers.get(pid, []))),
            "tracker_item": live.get("number") if live else None,
            "live_status": live.get("status") if live else None,
            "live_stage": live.get("stage") if live else None,
        }
        nodes.append(node)
        for dep in sorted(pillar.get("blocks_on", [])):
            edges.append({"kind": "BLOCKS", "from": dep, "to": pid})

    ordered_pillars = [pillar_by_id[pid] for pid in sorted(pillar_by_id)]
    for index, left in enumerate(ordered_pillars):
        for right in ordered_pillars[index + 1:]:
            overlaps = idc_matrix_check.overlap_descriptions(left, right)
            if overlaps:
                edges.append({
                    "kind": "CONFLICTS_WITH",
                    "from": left["id"],
                    "to": right["id"],
                    "overlaps": overlaps,
                })

    public = {
        "schema_version": 1,
        "phase": phase,
        "waves": {pid: derived_waves.get(pid) for pid in sorted(pillar_by_id)},
        "nodes": sorted(nodes, key=lambda node: node["id"]),
        "edges": sorted(edges, key=lambda edge: (edge["kind"], edge["from"], edge["to"])),
        "resource_areas": idc_matrix_check.surface_areas(pillars),
        "coverage_manifest": coverage_manifest,
    }
    public["graph_digest"] = sha256_json(public)
    internal = dict(public)
    internal["_pillars"] = pillars
    internal["_pillar_by_id"] = pillar_by_id
    internal["_live_by_id"] = live_by_id
    internal["_tracker_items"] = tracker_items
    return internal


def main():
    ap = argparse.ArgumentParser(description="Compile the authoritative whole-horizon execution graph.")
    ap.add_argument("--matrix", required=True, help="phase matrix YAML")
    ap.add_argument("--backend", choices=("filesystem", "github"), required=True)
    ap.add_argument("--tracker", default="TRACKER.md", help="filesystem tracker path")
    ap.add_argument("--repo", default=".", help="repo dir for github reads")
    ap.add_argument("--owner", help="github owner for github backend")
    ap.add_argument("--project", type=int, help="github project number for github backend")
    ap.add_argument("--code-provider-name", default="optional-code-evidence")
    ap.add_argument("--code-provider-status", default="unavailable")
    ap.add_argument("--json", action="store_true", help="emit JSON (default)")
    args = ap.parse_args()

    graph = compile_graph(
        matrix_path=args.matrix,
        backend=args.backend,
        tracker=args.tracker,
        repo=args.repo,
        owner=args.owner,
        project=args.project,
        provider_name=args.code_provider_name,
        provider_status=args.code_provider_status,
    )
    public = {key: value for key, value in graph.items() if not key.startswith("_")}
    json.dump(public, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
