#!/usr/bin/env python3
"""Fixed-code verification-handle registry validation / resolution / doctor audit.

The governed registry lives at docs/workflow/verification-handles.yaml. U6 requires that it be
schema-checked and secret-free before any entry is cited, resolved, or used. Missing handles do not
silently weaken the gate: fixed code returns a NAMED recirculation or blocked-dependency obligation.

Commands:
  validate        schema-check + secret-free validation
  resolve         resolve one handle for a declared surface, or return a named obligation on miss
  audit-citations warn (read-only) when a cited handle_id does not exist in the registry
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_schema_check as SC  # noqa: E402

DEFAULT_RELPATH = "docs/workflow/verification-handles.yaml"
ALLOWED_MISSING_ACTIONS = {"recirculation", "blocked-dependency"}
ALLOWED_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "example.com", "www.example.com", "example.invalid"}

TOKEN_PATTERNS = [
    re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"AIza[A-Za-z0-9_-]{20,}"),
    re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
]
SUSPICIOUS_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"),
    re.compile(r"(?i)(password|secret|api[_-]?key|auth[_-]?token|client[_-]?secret|private[_-]?key)\s*[:=]\s*\S+"),
    re.compile(r"op://"),
    re.compile(r"(^|[\s/])\.env([.\w-]*)?($|[\s'\"/])"),
]
URL_RE = re.compile(r"https?://([^/\s'\"]+)")


class HandleError(Exception):
    pass


def die(message: str, code: int = 2) -> None:
    print(f"idc-verification-handles: {message}", file=sys.stderr)
    raise SystemExit(code)


def _repo_root(repo: str) -> str:
    root = os.path.abspath(repo)
    if not os.path.isdir(root):
        raise HandleError(f"repo directory does not exist: {repo}")
    return root


def registry_path(repo: str, override: str | None) -> str:
    root = _repo_root(repo)
    if override:
        return os.path.abspath(override)
    return os.path.join(root, DEFAULT_RELPATH)


def _is_placeholder(value: str) -> bool:
    text = value.lower()
    return any(marker in text for marker in (
        "<placeholder>",
        "placeholder",
        "redacted",
        "example.com",
        "example.invalid",
        "localhost",
        "127.0.0.1",
        "dummy",
        "fake",
        "sandbox-user",
        "sample-account",
    ))


def _secret_problem(value: str) -> str | None:
    text = str(value or "")
    if not text:
        return None
    for pattern in TOKEN_PATTERNS + SUSPICIOUS_PATTERNS:
        if pattern.search(text):
            return f"contains secret/credential/auth material matching {pattern.pattern!r}"
    if _is_placeholder(text):
        return None
    for match in URL_RE.finditer(text):
        host = match.group(1).split("@")[-1].split(":")[0].lower()
        if host not in ALLOWED_LOCAL_HOSTS:
            return f"contains a private URL host {host!r}; only localhost/example placeholders are allowed"
    return None


def _list_problem(key: str, values) -> str | None:
    if not isinstance(values, list):
        return f"{key} must be a list"
    for item in values:
        if not isinstance(item, str) or not item.strip():
            return f"{key} must contain only non-empty strings"
        problem = _secret_problem(item)
        if problem:
            return f"{key} entry {item!r} {problem}"
    return None


def load_registry(repo: str, override: str | None = None):
    path = registry_path(repo, override)
    try:
        doc = SC.load_verification_registry(path)
    except ValueError as exc:
        raise HandleError(str(exc)) from exc
    for idx, handle in enumerate(doc.get("handles") or []):
        for key in (
            "build_commands",
            "launch_commands",
            "verify_commands",
            "fixtures",
            "accounts",
            "emulators",
        ):
            problem = _list_problem(f"handle[{idx}].{key}", handle.get(key))
            if problem:
                raise HandleError(problem)
    return path, doc


def validate_registry(repo: str, override: str | None = None):
    path, doc = load_registry(repo, override)
    return {
        "ok": True,
        "path": path,
        "schema_version": doc.get("schema_version"),
        "handle_ids": [h.get("handle_id") for h in (doc.get("handles") or [])],
    }


def _named_obligation(handle_id: str, surface: str, action: str, name: str):
    if action not in ALLOWED_MISSING_ACTIONS:
        raise HandleError(
            f"missing handle requires --missing-action in {sorted(ALLOWED_MISSING_ACTIONS)}, got {action!r}")
    if not isinstance(name, str) or not name.strip():
        raise HandleError("missing handle requires a non-empty --obligation-name")
    return {
        "kind": action,
        "name": name.strip(),
        "handle_id": handle_id,
        "surface": surface,
        "reason": "missing verification handle",
    }


def resolve_handle(repo: str, handle_id: str, surface: str, *, override: str | None = None,
                   missing_action: str | None = None, obligation_name: str | None = None):
    _path, doc = load_registry(repo, override)
    expected_kind = SC.SURFACE_EVIDENCE_TABLE.get(surface)
    if expected_kind in (None, "none"):
        raise HandleError(f"surface must be one of {sorted(set(SC.SURFACE_EVIDENCE_TABLE) - {'none'})}, got {surface!r}")
    for handle in doc.get("handles") or []:
        if handle.get("handle_id") != handle_id:
            continue
        if handle.get("surface") != surface:
            raise HandleError(
                f"handle {handle_id!r} is for surface {handle.get('surface')!r}, not the declared surface {surface!r}")
        if handle.get("evidence_kind") != expected_kind:
            raise HandleError(
                f"handle {handle_id!r} carries evidence_kind {handle.get('evidence_kind')!r}, expected {expected_kind!r}")
        return {"ok": True, "handle": handle}
    if missing_action is None or obligation_name is None:
        raise HandleError(
            f"missing verification handle {handle_id!r} for surface {surface!r} — create a named recirculation or blocked-dependency obligation")
    return {"ok": False, "obligation": _named_obligation(handle_id, surface, missing_action, obligation_name)}


def _audit_contract(path: str, known_ids: set[str]) -> list[str]:
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except OSError as exc:
        return [f"WARNING: could not read contract {path}: {exc}"]
    except ValueError as exc:
        return [f"WARNING: contract {path} is invalid JSON: {exc}"]
    handle_id = doc.get("handle_id")
    if not handle_id:
        return []
    if handle_id not in known_ids:
        return [f"WARNING: contract {path} cites unknown handle_id {handle_id!r}"]
    return []


def audit_citations(repo: str, override: str | None = None, contracts: list[str] | None = None,
                    contracts_dir: str | None = None) -> list[str]:
    _path, doc = load_registry(repo, override)
    known_ids = {h.get("handle_id") for h in (doc.get("handles") or [])}
    paths: list[str] = []
    for path in contracts or []:
        paths.append(os.path.abspath(path))
    if contracts_dir:
        for name in sorted(os.listdir(contracts_dir)):
            if name.endswith(".json"):
                paths.append(os.path.join(contracts_dir, name))
    warnings: list[str] = []
    for path in paths:
        warnings.extend(_audit_contract(path, known_ids))
    return warnings


def cmd_validate(args: argparse.Namespace) -> int:
    result = validate_registry(args.repo, args.registry)
    if args.json:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print("verification-handles: PASS")
        print(f"path: {result['path']}")
        print(f"handles: {len(result['handle_ids'])}")
    return 0


def cmd_resolve(args: argparse.Namespace) -> int:
    result = resolve_handle(
        args.repo,
        args.handle_id,
        args.surface,
        override=args.registry,
        missing_action=args.missing_action,
        obligation_name=args.obligation_name,
    )
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0 if result.get("ok") else 3


def cmd_audit(args: argparse.Namespace) -> int:
    warnings = audit_citations(args.repo, args.registry, args.contract or [], args.contracts_dir)
    if warnings:
        for line in warnings:
            print(line)
    else:
        print("verification-handles: no citation warnings")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    vp = sub.add_parser("validate", help="schema-check + secret-free validation")
    vp.add_argument("--repo", required=True)
    vp.add_argument("--registry")
    vp.add_argument("--json", action="store_true")
    vp.set_defaults(func=cmd_validate)

    rp = sub.add_parser("resolve", help="resolve one verification handle or return a named obligation on miss")
    rp.add_argument("--repo", required=True)
    rp.add_argument("--registry")
    rp.add_argument("--handle-id", required=True)
    rp.add_argument("--surface", required=True)
    rp.add_argument("--missing-action")
    rp.add_argument("--obligation-name")
    rp.set_defaults(func=cmd_resolve)

    ap = sub.add_parser("audit-citations", help="read-only warning pass over cited handle ids")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--registry")
    ap.add_argument("--contract", action="append")
    ap.add_argument("--contracts-dir")
    ap.set_defaults(func=cmd_audit)

    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return args.func(args)
    except HandleError as exc:
        die(str(exc), code=2)


if __name__ == "__main__":
    raise SystemExit(main())
