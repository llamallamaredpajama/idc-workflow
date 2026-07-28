#!/usr/bin/env python3
"""idc_schema_check.py — the mechanical schema checks for IDC issue bodies + verification handles.

Plan runs this on every issue body before board admission. The board carries three shapes,
told apart by the `Stage:` field:

* a **buildable goal-contract** (`Stage: Buildable`, or no Stage on a legacy 4-field repo) —
  the glass-wall contract a builder works cold, so it must carry the full 6-element goal
  contract plus declared boundaries, dependencies, and trace;
* an upstream **pointer item** (`Stage: Consideration` or `Stage: Planning`) — a lightweight
  reference to a repo file (consideration / in-flight plan / pillar) carrying only a
  repo-file reference + Stage/Phase/Domain. A pointer MUST NOT duplicate canonical file
  content — it is a reference + labels, never a goal-contract; and
* a **recirculation ticket** (`Stage: Recirculation`) — the non-Buildable inbox for scope
  discovered mid-build (drained by /idc:recirculate). It carries five required scope fields
  (Discovered / Area / Suggested-scope / Provenance / PRD-TRD-impact) and, like a pointer,
  MUST NOT carry a goal-contract.

U6 adds one more fixed schema surface:

* a governed **verification-handle registry** (`docs/workflow/verification-handles.yaml`) — one
  entry per reusable verification surface recipe. The fixed validator rejects malformed,
  unversioned, unknown-field, and invalid-shape entries before any handle is cited or used.

This is a lean guardrail — it checks structure and non-emptiness, not prose quality.

Usage:
  idc_schema_check.py <issue-body.md>              exit 0 = PASS, 1 = FAIL, 2 = usage
  idc_schema_check.py registry <handles.yaml>      exit 0 = PASS, 1 = FAIL, 2 = usage
"""
from __future__ import annotations

import ast
import json
import re
import sys

CONTRACT_REQUIRED = [
    "GOAL", "VERIFICATION SURFACE", "CONSTRAINTS", "BOUNDARIES",
    "ITERATION POLICY", "BLOCKED-STOP", "ASSUMPTIONS", "Dependencies", "Trace",
]

POINTER_STAGES = ("Consideration", "Planning")
BUILDABLE_STAGE = "Buildable"
RECIRC_STAGE = "Recirculation"
STAGES = POINTER_STAGES + (BUILDABLE_STAGE, RECIRC_STAGE)
POINTER_FORBIDDEN = ("GOAL", "VERIFICATION SURFACE")
RECIRC_REQUIRED = ("Discovered", "Area", "Suggested-scope", "Provenance", "PRD-TRD-impact")

REGISTRY_SCHEMA_VERSION = 1
SURFACE_EVIDENCE_TABLE = {
    "cli": "pane-capture",
    "api": "response-body",
    "gui": "screenshot-or-recording",
    "library": "public-import-sample",
    "agent": "agent-run-capture",
    "ci": "check-run",
    "none": "none",
}
REGISTRY_HANDLE_KEYS = {
    "handle_id",
    "surface",
    "evidence_kind",
    "build_commands",
    "launch_commands",
    "verify_commands",
    "fixtures",
    "accounts",
    "emulators",
}


def value_after(text, label):
    m = re.search(rf"^{re.escape(label)}:[ \t]*(.*)$", text, re.M)
    return (m.group(1).strip() if m else None)


# ── issue-body schema ---------------------------------------------------------------------------

def check(text):
    """Dispatch on Stage: pointer items and buildable goal-contracts have distinct shapes."""
    stage = value_after(text, "Stage")
    if stage and stage not in STAGES:
        return [f"unknown `Stage:` value '{stage}' (one of {', '.join(STAGES)})"]
    if stage in POINTER_STAGES:
        return check_pointer(text)
    if stage == RECIRC_STAGE:
        return check_recirculation(text)
    return check_contract(text)


def check_pointer(text):
    """A pointer carries a repo-file reference + Stage/Phase/Domain — never a goal-contract."""
    problems = []
    if not value_after(text, "File"):
        problems.append("pointer missing a repo-file reference (`File: <repo path>`)")
    for label in ("Phase", "Domain"):
        if not value_after(text, label):
            problems.append(f"pointer missing `{label}:` (a pointer carries Stage/Phase/Domain)")
    for label in POINTER_FORBIDDEN:
        if re.search(rf"^{re.escape(label)}:", text, re.M):
            problems.append(
                f"pointer must not carry `{label}:` — a pointer is a reference + labels only, "
                "never a full goal-contract (that would duplicate canonical file content)")
    return problems


def check_recirculation(text):
    """A Recirculation ticket records scope discovered mid-build — never a goal-contract."""
    problems = []
    for label in RECIRC_REQUIRED:
        if not value_after(text, label):
            problems.append(
                f"recirculation ticket missing or empty `{label}:` (a non-empty value is required)")
    for label in POINTER_FORBIDDEN:
        if re.search(rf"^{re.escape(label)}:", text, re.M):
            problems.append(
                f"recirculation ticket must not carry `{label}:` — it records discovered scope, "
                "never a full goal-contract (Plan authors the contract once the scope is admitted)")
    return problems


def check_contract(text):
    """A buildable issue is the full 6-element goal contract a builder works cold."""
    problems = []
    for label in CONTRACT_REQUIRED:
        if not re.search(rf"^{re.escape(label)}:", text, re.M):
            problems.append(f"missing `{label}:` element")
    goal = value_after(text, "GOAL")
    if goal is not None and not goal:
        problems.append("`GOAL:` is empty (needs a single observable end-state)")
    vs = value_after(text, "VERIFICATION SURFACE")
    if vs is not None and not vs:
        problems.append("`VERIFICATION SURFACE:` is empty (needs runnable commands + what passing looks like)")
    bnd = re.search(r"^BOUNDARIES:.*$", text, re.M)
    if bnd:
        line = bnd.group(0)
        if "touch" not in line.lower():
            problems.append("`BOUNDARIES:` must declare `touch` (in-scope surfaces)")
        if "off-limits" not in line.lower():
            problems.append("`BOUNDARIES:` must declare `off-limits` (out-of-scope surfaces)")
    return problems


# ── verification-handle registry schema ---------------------------------------------------------

def _strip_comment(text: str) -> str:
    in_single = False
    in_double = False
    escape = False
    bracket_depth = 0
    for i, ch in enumerate(text):
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            continue
        if not in_single and not in_double:
            if ch in "[{":
                bracket_depth += 1
            elif ch in "]}" and bracket_depth > 0:
                bracket_depth -= 1
            elif ch == "#" and bracket_depth == 0:
                return text[:i]
    return text


def _parse_inline(value: str):
    value = value.strip()
    if value == "":
        return ""
    if value in {"null", "~"}:
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    if value.startswith("[") or value.startswith("{"):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            try:
                return ast.literal_eval(value)
            except (SyntaxError, ValueError) as exc:
                raise ValueError(f"unsupported inline value {value!r}: {exc}") from exc
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    return value


def _fallback_registry_load(text: str):
    top = {}
    handles = []
    current = None
    in_handles = False
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = _strip_comment(raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if indent == 0:
            if current is not None:
                handles.append(current)
                current = None
            if stripped == "handles:":
                in_handles = True
                continue
            if ":" not in stripped:
                raise ValueError(f"line {lineno}: expected 'key: value' at top level")
            key, value = stripped.split(":", 1)
            top[key.strip()] = _parse_inline(value.strip())
            continue
        if indent == 2 and stripped.startswith("- "):
            if not in_handles:
                raise ValueError(f"line {lineno}: handle entry appeared before 'handles:'")
            if current is not None:
                handles.append(current)
            current = {}
            rest = stripped[2:].strip()
            if ":" not in rest:
                raise ValueError(f"line {lineno}: expected '- key: value' in a handle entry")
            key, value = rest.split(":", 1)
            current[key.strip()] = _parse_inline(value.strip())
            continue
        if indent == 4:
            if current is None:
                raise ValueError(f"line {lineno}: indented handle field without a handle entry")
            if ":" not in stripped:
                raise ValueError(f"line {lineno}: expected 'key: value' inside a handle entry")
            key, value = stripped.split(":", 1)
            current[key.strip()] = _parse_inline(value.strip())
            continue
        raise ValueError(
            f"line {lineno}: unsupported indentation/shape in verification-handles.yaml; "
            "use top-level scalars, `handles:`, `- key: value`, and inline JSON-style lists")
    if current is not None:
        handles.append(current)
    top["handles"] = handles
    return top


def _read_registry(path: str):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    try:
        import yaml  # prefer PyYAML when present; fall back to the constrained parser
        doc = yaml.safe_load(text)
    except ImportError:
        doc = _fallback_registry_load(text)
    except Exception as exc:  # noqa: BLE001
        raise ValueError(f"invalid YAML in {path}: {exc}") from exc
    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        raise ValueError("registry root must be a mapping")
    return doc


def registry_problems(doc) -> list[str]:
    problems: list[str] = []
    if not isinstance(doc, dict):
        return ["registry root must be a mapping"]
    top_keys = set(doc)
    expected_top = {"schema_version", "handles"}
    extra_top = sorted(top_keys - expected_top)
    missing_top = sorted(expected_top - top_keys)
    if missing_top:
        problems.append("registry missing top-level key(s): " + ", ".join(missing_top))
    if extra_top:
        problems.append("registry has unknown top-level key(s): " + ", ".join(extra_top))
    if doc.get("schema_version") != REGISTRY_SCHEMA_VERSION:
        problems.append(
            f"registry schema_version must be {REGISTRY_SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    handles = doc.get("handles")
    if not isinstance(handles, list):
        problems.append("registry `handles` must be a list")
        return problems

    seen_ids = set()
    allowed_surfaces = set(SURFACE_EVIDENCE_TABLE) - {"none"}
    for idx, handle in enumerate(handles):
        prefix = f"handle[{idx}]"
        if not isinstance(handle, dict):
            problems.append(f"{prefix} must be a mapping")
            continue
        keys = set(handle)
        missing = sorted(REGISTRY_HANDLE_KEYS - keys)
        extra = sorted(keys - REGISTRY_HANDLE_KEYS)
        if missing:
            problems.append(f"{prefix} missing key(s): " + ", ".join(missing))
        if extra:
            problems.append(f"{prefix} has unknown key(s): " + ", ".join(extra))
        handle_id = handle.get("handle_id")
        if not isinstance(handle_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", handle_id):
            problems.append(f"{prefix}.handle_id must match [a-z0-9][a-z0-9-]*")
        elif handle_id in seen_ids:
            problems.append(f"{prefix}.handle_id {handle_id!r} is duplicated")
        else:
            seen_ids.add(handle_id)
        surface = handle.get("surface")
        if surface not in allowed_surfaces:
            problems.append(f"{prefix}.surface must be one of {sorted(allowed_surfaces)}, got {surface!r}")
        evidence_kind = handle.get("evidence_kind")
        expected_evidence = SURFACE_EVIDENCE_TABLE.get(surface)
        if expected_evidence is None:
            pass
        elif evidence_kind != expected_evidence:
            problems.append(
                f"{prefix}.evidence_kind must be {expected_evidence!r} for surface {surface!r}, "
                f"got {evidence_kind!r}")
        for key in (
            "build_commands",
            "launch_commands",
            "verify_commands",
            "fixtures",
            "accounts",
            "emulators",
        ):
            value = handle.get(key)
            if not isinstance(value, list) or any(not isinstance(it, str) or not it.strip() for it in value):
                problems.append(f"{prefix}.{key} must be a list of non-empty strings")
        if isinstance(handle.get("verify_commands"), list) and not handle.get("verify_commands"):
            problems.append(f"{prefix}.verify_commands must list at least one executable verification command")
    return problems


def load_verification_registry(path: str):
    doc = _read_registry(path)
    problems = registry_problems(doc)
    if problems:
        raise ValueError("; ".join(problems))
    return doc


def registry_main(path: str) -> int:
    try:
        doc = load_verification_registry(path)
    except ValueError as exc:
        print("registry schema: FAIL")
        for part in str(exc).split("; "):
            print(f"  - {part}")
        return 1
    print("registry schema: PASS")
    print(f"  handles: {len(doc.get('handles') or [])}")
    return 0


# ── CLI ----------------------------------------------------------------------------------------

def issue_main(path: str) -> int:
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        sys.stderr.write(f"idc-schema-check: cannot read {path}: {e}\n")
        return 2
    problems = check(text)
    if problems:
        print("schema check: FAIL")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("schema check: PASS")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) == 2 and argv[0] == "registry":
        return registry_main(argv[1])
    if len(argv) != 1:
        sys.stderr.write("usage: idc_schema_check.py <issue-body.md> | idc_schema_check.py registry <verification-handles.yaml>\n")
        return 2
    return issue_main(argv[0])


if __name__ == "__main__":
    raise SystemExit(main())
