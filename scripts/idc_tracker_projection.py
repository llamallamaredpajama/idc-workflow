#!/usr/bin/env python3
"""idc_tracker_projection.py — frozen tracker projection + pure simulation for Plan.

Builds the expected tracker projection from the authoritative graph compiler and applies the allowed
operations to an in-memory snapshot only. This script is read-only: it never mutates the live
tracker.
"""
import argparse
import copy
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_execution_graph  # noqa: E402


def die(message, code=1):
    sys.stderr.write(f"idc-tracker-projection: {message}\n")
    sys.exit(code)


def expected_status(node, live_item):
    if live_item and live_item.get("status") in {"Done", "In Progress"}:
        return live_item.get("status")
    if live_item and live_item.get("status") == "Blocked":
        return "Blocked"
    return "Todo"


def expected_projection(graph):
    phase = graph.get("phase") or ""
    projection = []
    for node in graph.get("nodes", []):
        pid = node["id"]
        live = graph["_live_by_id"].get(pid)
        entry = {
            "logical_id": pid,
            "tracker_identity": (
                f"#{live.get('number')}" if live and live.get("number") is not None else f"pending:{pid}"
            ),
            "title": pid,
            "stage": "Buildable",
            "status": expected_status(node, live),
            "wave": node.get("derived_wave"),
            "phase": phase,
            "domain": node.get("domain") or "",
            "blocked_by": list(node.get("blocks_on", [])),
            "blocked_reasons": list(node.get("blocked_reasons", [])),
            "surfaces": list(node.get("surfaces", [])),
        }
        if live and live.get("status") == "In Progress":
            mismatches = []
            for field in ("stage", "status", "wave", "phase", "domain"):
                live_value = live.get(field if field != "stage" else "stage")
                expected_value = entry.get(field)
                if (live_value or "") != (expected_value or ""):
                    mismatches.append(f"{field}: live={live_value!r} projected={expected_value!r}")
            if mismatches:
                die(f"In Progress item '{pid}' is immutable: " + "; ".join(mismatches))
        projection.append(entry)
    return sorted(projection, key=lambda row: row["logical_id"])


def action_plan(graph, projection):
    actions = []
    live_by_id = graph["_live_by_id"]
    for entry in projection:
        pid = entry["logical_id"]
        live = live_by_id.get(pid)
        if not live:
            actions.append({
                "op": "create",
                "logical_id": pid,
                "fields": {
                    "title": entry["title"],
                    "stage": entry["stage"],
                    "status": entry["status"],
                    "wave": entry["wave"],
                    "phase": entry["phase"],
                    "domain": entry["domain"],
                },
                "blocked_by": list(entry.get("blocked_by", [])),
            })
            continue
        if live.get("status") in {"Done", "In Progress"}:
            continue
        for field, live_key in (("stage", "stage"), ("status", "status"), ("wave", "wave"),
                                ("phase", "phase"), ("domain", "domain")):
            live_value = live.get(live_key) or ""
            expected_value = entry.get(field) or ""
            if str(live_value) != str(expected_value):
                actions.append({
                    "op": "set-field",
                    "logical_id": pid,
                    "tracker_identity": entry["tracker_identity"],
                    "field": field,
                    "from": live_value,
                    "to": expected_value,
                })
        live_blocked = sorted(str(value) for value in live.get("blocked_by", []))
        expected_blocked = sorted(str(value) for value in entry.get("blocked_by", []))
        if live_blocked != expected_blocked:
            actions.append({
                "op": "set-blocked-by",
                "logical_id": pid,
                "tracker_identity": entry["tracker_identity"],
                "from": live_blocked,
                "to": expected_blocked,
            })
    return actions


def simulate(graph, projection, actions):
    state = {}
    for item in graph["_tracker_items"]:
        identity = f"#{item.get('number')}" if item.get("number") is not None else item.get("title") or "<unknown>"
        state[identity] = {
            "title": item.get("title", ""),
            "stage": item.get("stage") or "Buildable",
            "status": item.get("status") or "",
            "wave": item.get("wave") or "",
            "phase": item.get("phase") or "",
            "domain": item.get("domain") or "",
            "blocked_by": [str(value) for value in item.get("blocked_by", [])],
        }
    simulated = copy.deepcopy(state)
    for action in actions:
        if action["op"] == "create":
            simulated[f"pending:{action['logical_id']}"] = {
                **action["fields"],
                "blocked_by": [str(value) for value in action.get("blocked_by", [])],
            }
            continue
        target = simulated.get(action["tracker_identity"])
        if target is None:
            die(f"simulation target missing for {action['tracker_identity']}")
        if action["op"] == "set-field":
            target[action["field"]] = action["to"]
        elif action["op"] == "set-blocked-by":
            target["blocked_by"] = list(action["to"])
        else:
            die(f"unknown simulated op {action['op']!r}")
    return {
        "mutated_live_tracker": False,
        "items": [{"identity": identity, **row} for identity, row in sorted(simulated.items())],
        "baseline_items": len(state),
        "projected_items": len(simulated),
    }


def build_projection(matrix_path, backend, tracker, repo=".", owner=None, project=None,
                     provider_name="optional-code-evidence", provider_status="unavailable"):
    graph = idc_execution_graph.compile_graph(
        matrix_path=matrix_path,
        backend=backend,
        tracker=tracker,
        repo=repo,
        owner=owner,
        project=project,
        provider_name=provider_name,
        provider_status=provider_status,
    )
    projection = expected_projection(graph)
    actions = action_plan(graph, projection)
    simulation = simulate(graph, projection, actions)
    public = {
        "schema_version": 1,
        "graph_digest": graph["graph_digest"],
        "projection": projection,
        "action_plan": actions,
        "simulation": simulation,
    }
    public["projection_digest"] = idc_execution_graph.sha256_json(public)
    return public


def main():
    ap = argparse.ArgumentParser(description="Emit the frozen tracker projection and pure simulation.")
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

    result = build_projection(
        matrix_path=args.matrix,
        backend=args.backend,
        tracker=args.tracker,
        repo=args.repo,
        owner=args.owner,
        project=args.project,
        provider_name=args.code_provider_name,
        provider_status=args.code_provider_status,
    )
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
