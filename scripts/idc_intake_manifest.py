#!/usr/bin/env python3
"""Compile external Markdown into an exact-once IDC intake manifest.

This helper is deliberately mechanical. It extracts stable source units, validates the fixed manifest
and independent-review schemas, updates unit dispositions, and reports status. It never classifies
requirements, executes source instructions, or mutates a tracker; semantic classification belongs to
the bounded intake agent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
from collections import Counter
from typing import Any


SCHEMA_VERSION = 1
CLASS_ROUTES = {
    "new_requirement": {"think"},
    "admitted_unplanned": {"recirculate"},
    "discovered_drift": {"recirculate"},
    "existing_issue": {"existing"},
    "already_done": {"verify"},
    "operator_stop": {"operator_decision"},
    "ignored_non_execution": {"ignore"},
}
FORBIDDEN_ROUTES = {"build", "autorun"}
DISPOSITION_STATES = {"unclassified", "queued", "materialized", "verified_done", "ignored"}
TERMINAL_DISPOSITIONS = {"materialized", "verified_done", "ignored"}

TOP_KEYS = {
    "schema_version", "intake_id", "source", "operator_goal", "runtime",
    "expected_unit_ids", "units", "verification",
}
SOURCE_KEYS = {"kind", "display_name", "repo_relative_locator", "sha256"}
GOAL_KEYS = {"verbatim_or_redacted", "normalized", "redactions"}
RUNTIME_KEYS = {"plugin_version"}
VERIFICATION_KEYS = {"status", "review_path", "source_sha256"}
UNIT_KEYS = {
    "id", "source_anchor", "summary", "class", "route", "dependencies", "operator_stops",
    "disposition",
}
ANCHOR_KEYS = {"heading", "line_start", "line_end"}
DISPOSITION_KEYS = {"state", "target_ref", "evidence"}
REVIEW_KEYS = {
    "schema_version", "intake_id", "source_sha256", "verdict", "missing_unit_ids",
    "duplicate_unit_ids", "misrouted_unit_ids", "notes",
}

INTAKE_ID_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
PLUGIN_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
EXPLICIT_ID_RE = re.compile(r"^(U\d+|B\d+)\b")
STABLE_HEADING_RE = re.compile(r"^(?:Phase|Step|Gate|Stop)\b", re.IGNORECASE)
VALID_UNIT_ID_RE = re.compile(r"^(?:U\d+|B\d+|L\d+|Drive)$")


class IntakeError(Exception):
    """A deterministic extraction, shape, binding, or write failure."""


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _expect_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise IntakeError(f"{label} must be a JSON object")
    return value


def _expect_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise IntakeError(f"{label} keys differ (missing={missing}, extra={extra})")


def _expect_string_list(value: Any, label: str, *, allow_empty: bool = True) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
        raise IntakeError(f"{label} must be a list of non-empty strings")
    if not allow_empty and not value:
        raise IntakeError(f"{label} must not be empty")
    return value


def _safe_relative(value: Any, label: str, *, allow_none: bool) -> str | None:
    if value is None and allow_none:
        return None
    if not isinstance(value, str) or not value.strip():
        raise IntakeError(f"{label} must be a non-empty relative path" + (" or null" if allow_none else ""))
    raw = value.strip()
    if os.path.isabs(raw) or raw.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:[\\/]", raw):
        raise IntakeError(f"{label} must never be absolute")
    parts = [part for part in re.split(r"[\\/]", raw) if part not in ("", ".")]
    if not parts or any(part == ".." for part in parts):
        raise IntakeError(f"{label} must stay within the repository")
    return "/".join(parts)


def _source_locator(argument: str) -> str | None:
    if os.path.isabs(argument):
        return None
    try:
        return _safe_relative(argument, "source locator", allow_none=True)
    except IntakeError:
        return None


def _review_locator(argument: str) -> str:
    if os.path.isabs(argument):
        return os.path.basename(os.path.normpath(argument))
    return _safe_relative(argument, "review path", allow_none=False) or os.path.basename(argument)


def _natural_key(value: str) -> tuple[tuple[int, Any], ...]:
    parts: list[tuple[int, Any]] = []
    for part in re.split(r"(\d+)", value):
        if not part:
            continue
        parts.append((1, int(part)) if part.isdigit() else (0, part.casefold()))
    return tuple(parts)


def _load_json(path: str, label: str) -> dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except OSError as exc:
        raise IntakeError(f"could not read {label} {path}: {exc}") from exc
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise IntakeError(f"could not parse {label} {path}: {exc}") from exc
    return _expect_object(value, label)


def _atomic_write_json(path: str, value: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    fd = -1
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(prefix=".idc-intake-", suffix=".json", dir=parent)
        if os.path.exists(path):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        tmp = ""
    except OSError as exc:
        raise IntakeError(f"could not safely write {path}: {exc}") from exc
    finally:
        if fd != -1:
            os.close(fd)
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _normalize_goal(goal: str) -> str:
    value = re.sub(r"\s+", " ", goal).strip()
    if re.fullmatch(r"execute the whole program\s*;\s*Drive first", value, re.IGNORECASE):
        return "execute the complete program in dependency order with Drive first"
    return re.sub(r"\bwhole\b", "complete", value, flags=re.IGNORECASE)


def _explicit_id(heading: str) -> str | None:
    match = EXPLICIT_ID_RE.match(heading)
    if match:
        return match.group(1)
    if re.match(r"^Drive\b", heading):
        return "Drive"
    return None


def _strip_optional_bold(value: str) -> str:
    value = value.strip()
    if value.startswith("**") and value.endswith("**") and len(value) >= 4:
        return value[2:-2].strip()
    return value


def _candidate(line: str, line_no: int) -> tuple[str, str] | None:
    atx = re.match(r"^\s{0,3}#{1,6}[ \t]+(.+?)\s*$", line)
    if atx:
        heading = re.sub(r"\s+#+\s*$", "", atx.group(1)).strip()
        unit_id = _explicit_id(heading)
        if unit_id:
            return unit_id, heading
        if STABLE_HEADING_RE.match(heading):
            return f"L{line_no}", heading
        return None

    bold = re.match(r"^\s*\*\*(.+?)\*\*\s*$", line)
    if bold:
        heading = bold.group(1).strip()
        unit_id = _explicit_id(heading)
        return (unit_id, heading) if unit_id else None

    numbered = re.match(r"^\s*\d+[.)][ \t]+(.+?)\s*$", line)
    if numbered:
        heading = _strip_optional_bold(numbered.group(1))
        unit_id = _explicit_id(heading)
        return (unit_id, heading) if unit_id else None

    checklist = re.match(r"^\s*[-*+][ \t]+\[[ \t]\][ \t]+(.+?)\s*$", line)
    if checklist:
        return f"L{line_no}", checklist.group(1).strip()
    return None


def _summary(heading: str, unit_id: str) -> str:
    remainder = heading[len(unit_id):] if heading.startswith(unit_id) else heading
    remainder = re.sub(r"^[\s:—–-]+", "", remainder).strip()
    return remainder or heading


def _extract_units(text: str) -> tuple[list[str], list[dict[str, Any]]]:
    lines = text.splitlines()
    anchors: list[dict[str, Any]] = []
    seen: dict[str, int] = {}
    for line_no, line in enumerate(lines, 1):
        found = _candidate(line, line_no)
        if not found:
            continue
        unit_id, heading = found
        if unit_id in seen:
            raise IntakeError(
                f"duplicate source unit id {unit_id!r} at lines {seen[unit_id]} and {line_no}")
        seen[unit_id] = line_no
        anchors.append({"id": unit_id, "heading": heading, "line_start": line_no})

    if not anchors:
        raise IntakeError("source contains no intake unit anchors")

    units: list[dict[str, Any]] = []
    for index, anchor in enumerate(anchors):
        next_line = anchors[index + 1]["line_start"] if index + 1 < len(anchors) else len(lines) + 1
        units.append({
            "id": anchor["id"],
            "source_anchor": {
                "heading": anchor["heading"],
                "line_start": anchor["line_start"],
                "line_end": max(anchor["line_start"], next_line - 1),
            },
            "summary": _summary(anchor["heading"], anchor["id"]),
            "class": None,
            "route": None,
            "dependencies": [],
            "operator_stops": [],
            "disposition": {"state": "unclassified", "target_ref": None, "evidence": []},
        })
    return sorted(seen, key=_natural_key), units


def _intake_id_from_output(path: str) -> str:
    name = os.path.basename(path)
    if not name.endswith(".json"):
        raise IntakeError("manifest output must end in .json")
    intake_id = name[:-5]
    if not INTAKE_ID_RE.fullmatch(intake_id):
        raise IntakeError("manifest filename must be <YYYY-MM-DD>-<lowercase-slug>.json")
    return intake_id


def extract_manifest(source_path: str, out_path: str, goal: str, plugin_version: str) -> dict[str, Any]:
    if not PLUGIN_VERSION_RE.fullmatch(plugin_version):
        raise IntakeError("plugin version must be exactly X.Y.Z")
    try:
        with open(source_path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        raise IntakeError(f"could not read Markdown source {source_path}: {exc}") from exc
    try:
        parsed_text = raw.decode("utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError as exc:
        raise IntakeError(f"Markdown source must be UTF-8: {exc}") from exc

    source_hash = hashlib.sha256(raw).hexdigest()
    expected, units = _extract_units(parsed_text)
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "intake_id": _intake_id_from_output(out_path),
        "source": {
            "kind": "external_markdown",
            "display_name": os.path.basename(os.path.normpath(source_path)),
            "repo_relative_locator": _source_locator(source_path),
            "sha256": source_hash,
        },
        "operator_goal": {
            "verbatim_or_redacted": goal,
            "normalized": _normalize_goal(goal),
            "redactions": [],
        },
        "runtime": {"plugin_version": plugin_version},
        "expected_unit_ids": expected,
        "units": units,
        "verification": {"status": "pending", "review_path": None, "source_sha256": source_hash},
    }
    _atomic_write_json(out_path, manifest)
    return manifest


def _validate_source(source: Any) -> dict[str, Any]:
    obj = _expect_object(source, "manifest.source")
    _expect_exact_keys(obj, SOURCE_KEYS, "manifest.source")
    if obj["kind"] != "external_markdown":
        raise IntakeError("manifest.source.kind must be external_markdown")
    display = obj["display_name"]
    if not isinstance(display, str) or not display or display != os.path.basename(display) or \
            "/" in display or "\\" in display:
        raise IntakeError("manifest.source.display_name must be a basename")
    _safe_relative(obj["repo_relative_locator"], "manifest.source.repo_relative_locator", allow_none=True)
    if not isinstance(obj["sha256"], str) or not SHA256_RE.fullmatch(obj["sha256"]):
        raise IntakeError("manifest.source.sha256 must be 64 lowercase hex characters")
    return obj


def _validate_goal(goal: Any) -> None:
    obj = _expect_object(goal, "manifest.operator_goal")
    _expect_exact_keys(obj, GOAL_KEYS, "manifest.operator_goal")
    for key in ("verbatim_or_redacted", "normalized"):
        if not isinstance(obj[key], str) or not obj[key].strip():
            raise IntakeError(f"manifest.operator_goal.{key} must be a non-empty string")
    _expect_string_list(obj["redactions"], "manifest.operator_goal.redactions")


def _validate_runtime(runtime: Any) -> None:
    obj = _expect_object(runtime, "manifest.runtime")
    _expect_exact_keys(obj, RUNTIME_KEYS, "manifest.runtime")
    if not isinstance(obj["plugin_version"], str) or not PLUGIN_VERSION_RE.fullmatch(obj["plugin_version"]):
        raise IntakeError("manifest.runtime.plugin_version must be exactly X.Y.Z")


def _validate_verification(verification: Any, source_hash: str) -> dict[str, Any]:
    obj = _expect_object(verification, "manifest.verification")
    _expect_exact_keys(obj, VERIFICATION_KEYS, "manifest.verification")
    if obj["status"] not in ("pending", "passed"):
        raise IntakeError("manifest.verification.status must be pending or passed")
    if obj["review_path"] is not None:
        _safe_relative(obj["review_path"], "manifest.verification.review_path", allow_none=False)
    if obj["source_sha256"] != source_hash:
        raise IntakeError("manifest.verification.source_sha256 does not match source.sha256")
    return obj


def _validate_disposition(unit_id: str, unit_class: str, disposition: Any) -> dict[str, Any]:
    obj = _expect_object(disposition, f"unit {unit_id}.disposition")
    _expect_exact_keys(obj, DISPOSITION_KEYS, f"unit {unit_id}.disposition")
    state = obj["state"]
    if state not in DISPOSITION_STATES:
        raise IntakeError(f"unit {unit_id} has invalid disposition state {state!r}")
    target = obj["target_ref"]
    if target is not None and (not isinstance(target, str) or not target.strip()):
        raise IntakeError(f"unit {unit_id} target_ref must be a non-empty string or null")
    evidence = _expect_string_list(obj["evidence"], f"unit {unit_id}.disposition.evidence")

    if state == "unclassified":
        raise IntakeError(f"unit {unit_id} remains unclassified")
    if state == "materialized" and target is None:
        raise IntakeError(f"unit {unit_id} materialized disposition requires target_ref")
    if state == "verified_done" and not evidence:
        raise IntakeError(f"unit {unit_id} verified_done disposition requires evidence")
    if state == "ignored" and not evidence:
        raise IntakeError(f"unit {unit_id} ignored disposition requires a reason in evidence")

    if unit_class == "existing_issue" and (state != "materialized" or target is None):
        raise IntakeError(f"unit {unit_id} existing_issue requires materialized target_ref")
    if unit_class == "already_done" and (state != "verified_done" or not evidence):
        raise IntakeError(f"unit {unit_id} already_done requires verified_done evidence")
    if unit_class == "ignored_non_execution" and (state != "ignored" or not evidence):
        raise IntakeError(f"unit {unit_id} ignored_non_execution requires ignored reason evidence")
    return obj


def _validate_acyclic(graph: dict[str, list[str]]) -> None:
    state: dict[str, int] = {}

    def visit(unit_id: str, trail: list[str]) -> None:
        mark = state.get(unit_id, 0)
        if mark == 1:
            cycle = " -> ".join([*trail, unit_id])
            raise IntakeError(f"dependency cycle detected: {cycle}")
        if mark == 2:
            return
        state[unit_id] = 1
        for dependency in graph[unit_id]:
            visit(dependency, [*trail, unit_id])
        state[unit_id] = 2

    for unit_id in graph:
        visit(unit_id, [])


def validate_manifest(data: dict[str, Any], *, require_classified: bool = True) -> dict[str, Any]:
    _expect_exact_keys(data, TOP_KEYS, "manifest")
    if not _is_int(data["schema_version"]) or data["schema_version"] != SCHEMA_VERSION:
        raise IntakeError("manifest.schema_version must be integer 1")
    if not isinstance(data["intake_id"], str) or not INTAKE_ID_RE.fullmatch(data["intake_id"]):
        raise IntakeError("manifest.intake_id must be <YYYY-MM-DD>-<lowercase-slug>")

    source = _validate_source(data["source"])
    _validate_goal(data["operator_goal"])
    _validate_runtime(data["runtime"])
    _validate_verification(data["verification"], source["sha256"])

    expected = _expect_string_list(data["expected_unit_ids"], "manifest.expected_unit_ids", allow_empty=False)
    if any(not VALID_UNIT_ID_RE.fullmatch(unit_id) for unit_id in expected):
        raise IntakeError("manifest.expected_unit_ids contains an invalid unit id")
    if len(set(expected)) != len(expected):
        raise IntakeError("manifest.expected_unit_ids contains duplicates")
    if expected != sorted(expected, key=_natural_key):
        raise IntakeError("manifest.expected_unit_ids is not naturally sorted")

    units = data["units"]
    if not isinstance(units, list):
        raise IntakeError("manifest.units must be a list")
    ids: list[str] = []
    graph: dict[str, list[str]] = {}
    for index, raw_unit in enumerate(units):
        unit = _expect_object(raw_unit, f"manifest.units[{index}]")
        _expect_exact_keys(unit, UNIT_KEYS, f"manifest.units[{index}]")
        unit_id = unit["id"]
        if not isinstance(unit_id, str) or not VALID_UNIT_ID_RE.fullmatch(unit_id):
            raise IntakeError(f"manifest.units[{index}].id is invalid")
        ids.append(unit_id)

        anchor = _expect_object(unit["source_anchor"], f"unit {unit_id}.source_anchor")
        _expect_exact_keys(anchor, ANCHOR_KEYS, f"unit {unit_id}.source_anchor")
        if not isinstance(anchor["heading"], str) or not anchor["heading"].strip():
            raise IntakeError(f"unit {unit_id} source heading must be non-empty")
        if not _is_int(anchor["line_start"]) or not _is_int(anchor["line_end"]) or \
                anchor["line_start"] <= 0 or anchor["line_end"] < anchor["line_start"]:
            raise IntakeError(f"unit {unit_id} source line range is invalid")
        if not isinstance(unit["summary"], str) or not unit["summary"].strip():
            raise IntakeError(f"unit {unit_id} summary must be non-empty")

        dependencies = _expect_string_list(unit["dependencies"], f"unit {unit_id}.dependencies")
        if len(set(dependencies)) != len(dependencies):
            raise IntakeError(f"unit {unit_id} has duplicate dependencies")
        _expect_string_list(unit["operator_stops"], f"unit {unit_id}.operator_stops")
        graph[unit_id] = dependencies

        unit_class, route = unit["class"], unit["route"]
        if not require_classified and unit_class is None and route is None \
                and unit["disposition"].get("state") == "unclassified":
            disposition = _expect_object(unit["disposition"], f"unit {unit_id}.disposition")
            _expect_exact_keys(disposition, DISPOSITION_KEYS, f"unit {unit_id}.disposition")
            continue
        if unit_class not in CLASS_ROUTES:
            raise IntakeError(f"unit {unit_id} has invalid class {unit_class!r}")
        if route in FORBIDDEN_ROUTES:
            raise IntakeError(f"unit {unit_id} may not route directly to {route}")
        if route not in CLASS_ROUTES[unit_class]:
            raise IntakeError(f"unit {unit_id} class {unit_class} cannot route to {route!r}")
        _validate_disposition(unit_id, unit_class, unit["disposition"])

    counts = Counter(ids)
    duplicate_ids = sorted((unit_id for unit_id, count in counts.items() if count != 1), key=_natural_key)
    if duplicate_ids:
        raise IntakeError(f"manifest.units contains duplicate ids: {duplicate_ids}")
    missing = sorted(set(expected) - set(ids), key=_natural_key)
    extra = sorted(set(ids) - set(expected), key=_natural_key)
    if missing or extra:
        raise IntakeError(f"manifest exact-once unit mismatch (missing={missing}, extra={extra})")

    known = set(ids)
    for unit_id, dependencies in graph.items():
        unknown = sorted(set(dependencies) - known, key=_natural_key)
        if unknown:
            raise IntakeError(f"unit {unit_id} names unknown dependencies: {unknown}")
        if unit_id in dependencies:
            raise IntakeError(f"unit {unit_id} depends on itself")
    _validate_acyclic(graph)
    return data


def validate_review(review: dict[str, Any], manifest: dict[str, Any]) -> None:
    _expect_exact_keys(review, REVIEW_KEYS, "review")
    if not _is_int(review["schema_version"]) or review["schema_version"] != SCHEMA_VERSION:
        raise IntakeError("review.schema_version must be integer 1")
    if review["intake_id"] != manifest["intake_id"]:
        raise IntakeError("review intake_id does not match manifest")
    if review["source_sha256"] != manifest["source"]["sha256"]:
        raise IntakeError("review source_sha256 does not match manifest source")
    if review["verdict"] != "PASS":
        raise IntakeError("review verdict must be PASS")
    for key in ("missing_unit_ids", "duplicate_unit_ids", "misrouted_unit_ids", "notes"):
        _expect_string_list(review[key], f"review.{key}")
    for key in ("missing_unit_ids", "duplicate_unit_ids", "misrouted_unit_ids"):
        if review[key]:
            raise IntakeError(f"review.{key} must be empty for PASS")


def _status(data: dict[str, Any]) -> dict[str, Any]:
    validate_manifest(data, require_classified=False)
    counts = Counter(unit["disposition"]["state"] for unit in data["units"])
    queued = sorted((unit["id"] for unit in data["units"] if unit["disposition"]["state"] == "queued"),
                    key=_natural_key)
    unclassified = sorted(
        (unit["id"] for unit in data["units"] if unit["disposition"]["state"] == "unclassified"),
        key=_natural_key,
    )
    complete = data["verification"]["status"] == "passed" and all(
        unit["disposition"]["state"] in TERMINAL_DISPOSITIONS for unit in data["units"]
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "intake_id": data["intake_id"],
        "verification_status": data["verification"]["status"],
        "expected_unit_count": len(data["expected_unit_ids"]),
        "disposition_counts": {state: counts.get(state, 0) for state in sorted(DISPOSITION_STATES)},
        "queued_unit_ids": queued,
        "unclassified_unit_ids": unclassified,
        "complete": complete,
        "units": [
            {
                "id": unit["id"],
                "class": unit["class"],
                "route": unit["route"],
                "state": unit["disposition"]["state"],
                "target_ref": unit["disposition"]["target_ref"],
                "evidence": list(unit["disposition"]["evidence"]),
            }
            for unit in data["units"]
        ],
    }


def cmd_extract(args: argparse.Namespace) -> int:
    manifest = extract_manifest(args.source, args.out, args.goal, args.plugin_version)
    print(json.dumps({"intake_id": manifest["intake_id"], "manifest": args.out,
                      "unit_count": len(manifest["expected_unit_ids"])}, sort_keys=True))
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    manifest = _load_json(args.manifest, "manifest")
    validate_manifest(manifest)
    if not args.review:
        raise IntakeError("independent --review is required; verification.status cannot self-certify")
    review = _load_json(args.review, "review")
    validate_review(review, manifest)
    manifest["verification"] = {
        "status": "passed",
        "review_path": _review_locator(args.review),
        "source_sha256": manifest["source"]["sha256"],
    }
    _atomic_write_json(args.manifest, manifest)
    receipt = {"intake_id": manifest["intake_id"], "review_path": manifest["verification"]["review_path"],
               "status": "passed", "unit_count": len(manifest["units"])}
    if args.json:
        print(json.dumps(receipt, sort_keys=True))
    else:
        print(f"idc-intake: PASS {manifest['intake_id']} ({len(manifest['units'])} units)")
    return 0


def cmd_link(args: argparse.Namespace) -> int:
    manifest = _load_json(args.manifest, "manifest")
    validate_manifest(manifest)
    if manifest["verification"]["status"] != "passed" or not manifest["verification"]["review_path"]:
        raise IntakeError("link requires an independently reviewed manifest")
    matches = [unit for unit in manifest["units"] if unit["id"] == args.unit]
    if len(matches) != 1:
        raise IntakeError(f"link unit {args.unit!r} must exist exactly once")
    unit = matches[0]
    current = unit["disposition"]
    evidence = list(current["evidence"])
    for ref in args.evidence:
        if ref not in evidence:
            evidence.append(ref)
    unit["disposition"] = {
        "state": args.state,
        "target_ref": args.target_ref if args.target_ref is not None else current["target_ref"],
        "evidence": evidence,
    }
    validate_manifest(manifest)
    _atomic_write_json(args.manifest, manifest)
    print(json.dumps({"intake_id": manifest["intake_id"], "unit": args.unit, "state": args.state,
                      "target_ref": unit["disposition"]["target_ref"],
                      "evidence": unit["disposition"]["evidence"]}, sort_keys=True))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    status = _status(_load_json(args.manifest, "manifest"))
    if args.json:
        print(json.dumps(status, sort_keys=True))
    else:
        print(f"idc-intake: {status['intake_id']} verification={status['verification_status']} "
              f"queued={len(status['queued_unit_ids'])} complete={str(status['complete']).lower()}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    extract = sub.add_parser("extract", help="extract stable units from an external Markdown file")
    extract.add_argument("--source", required=True)
    extract.add_argument("--out", required=True)
    extract.add_argument("--goal", required=True)
    extract.add_argument("--plugin-version", required=True)
    extract.set_defaults(func=cmd_extract)

    validate = sub.add_parser("validate", help="validate exact-once mapping and independent review")
    validate.add_argument("--manifest", required=True)
    validate.add_argument("--review")
    validate.add_argument("--json", action="store_true")
    validate.set_defaults(func=cmd_validate)

    link = sub.add_parser("link", help="record one unit's durable disposition")
    link.add_argument("--manifest", required=True)
    link.add_argument("--unit", required=True)
    link.add_argument("--state", required=True, choices=sorted(DISPOSITION_STATES))
    link.add_argument("--target-ref")
    link.add_argument("--evidence", action="append", default=[])
    link.set_defaults(func=cmd_link)

    status = sub.add_parser("status", help="report intake verification and disposition progress")
    status.add_argument("--manifest", required=True)
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_status)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except IntakeError as exc:
        print(f"idc-intake: FAIL — {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
