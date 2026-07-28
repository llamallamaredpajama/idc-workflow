#!/usr/bin/env python3
"""Fixed-code verification-handle registry validation / resolution / doctor audit.

The governed registry lives at docs/workflow/verification-handles.yaml. U6 requires that it be
schema-checked and secret-free before any entry is cited, resolved, or used. Missing handles do not
silently weaken the gate: fixed code returns a NAMED recirculation or blocked-dependency obligation.

Commands:
  validate        schema-check + secret-free validation
  resolve         resolve one handle for a declared surface, or return a named obligation on miss
  append          persist a newly-proven recipe back into the registry (Build/Finisher, at finish)
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
    """Read-only citation audit — ADVISORY, so it never raises on an ABSENT input.

    This is `/idc:doctor` Row 9, documented as "advisory; never FAIL". It used to `die()` on a
    missing registry (exit 2) and raise an unhandled `FileNotFoundError` (exit 1) on a missing
    contracts directory — and `idc_init_scaffold.sh` never creates `docs/workflow/build-validation/`,
    so EVERY freshly initialized repo and every pre-registry repo hit the traceback. A traceback is
    neither a warning nor a SKIP. Absent inputs are now explicit `SKIP:` lines: there is nothing to
    audit, which is not the same as nothing being wrong. A registry that EXISTS but does not validate
    stays visible as a `WARNING:` (the hard gate on registry validity is `validate`, which /idc:update
    and Plan run — this row must not turn an advisory pass into a hard doctor failure)."""
    lines: list[str] = []
    path = registry_path(repo, override)
    if not os.path.exists(path):
        return [f"SKIP: no verification-handle registry at {path} — nothing to audit"]
    try:
        _path, doc = load_registry(repo, override)
    except HandleError as exc:
        return [f"WARNING: verification-handle registry {path} does not validate: {exc}"]
    known_ids = {h.get("handle_id") for h in (doc.get("handles") or [])}
    paths: list[str] = []
    for contract in contracts or []:
        paths.append(os.path.abspath(contract))
    if contracts_dir:
        if not os.path.isdir(contracts_dir):
            lines.append(f"SKIP: no frozen-contract directory at {contracts_dir} — nothing to audit")
        else:
            for name in sorted(os.listdir(contracts_dir)):
                if name.endswith(".json"):
                    paths.append(os.path.join(contracts_dir, name))
    for contract_path in paths:
        lines.extend(_audit_contract(contract_path, known_ids))
    return lines


# ── append: Build/Finisher writes a newly-proven recipe back into the registry --------------------
# The compounding half of the verification-handle design: the first run that figures out how to drive
# a surface PERSISTS the recipe, so every later Plan resolves it by lookup instead of re-deriving it
# and every later Build stops minting a redundant script. It is FIXED CODE (never a model-authored
# YAML edit) and it writes IN PLACE on the ticket's own branch, so the new recipe arrives as an
# ordinary tracked doc diff that goes through the normal review/PR path — never a side-channel write.
APPEND_LIST_FIELDS = ("build_commands", "launch_commands", "verify_commands",
                      "fixtures", "accounts", "emulators")


def _entry_block(entry: dict) -> str:
    """The new handle as YAML text in the one shape BOTH readers accept — PyYAML and the constrained
    stdlib fallback parser (2-space `- key: value`, 4-space fields, inline JSON-style lists)."""
    lines = [f"  - handle_id: {entry['handle_id']}",
             f"    surface: {entry['surface']}",
             f"    evidence_kind: {entry['evidence_kind']}"]
    for key in APPEND_LIST_FIELDS:
        lines.append(f"    {key}: {json.dumps(entry[key])}")
    return "\n".join(lines)


def _insert_entry(text: str, block: str) -> str:
    """Splice the entry into the existing file text, preserving every other byte (comments included).

    A whole-file rewrite would work and would also delete the operator's header comments, which is
    exactly the kind of "helpful" data loss the registry is preserved as operator data to avoid."""
    lines = text.splitlines()
    idx = None
    for i, line in enumerate(lines):
        if re.fullmatch(r"handles:\s*(\[\s*\])?\s*", line):
            idx = i
            break
    if idx is None:
        raise HandleError("registry has no top-level `handles:` key to append to")
    if re.fullmatch(r"handles:\s*\[\s*\]\s*", lines[idx]):
        lines[idx] = "handles:"                       # an empty inline list cannot host block entries
    end = idx + 1
    while end < len(lines) and (not lines[end].strip() or lines[end].startswith((" ", "\t"))):
        end += 1
    while end > idx + 1 and not lines[end - 1].strip():
        end -= 1                                      # append tight, before any trailing blank lines
    lines[end:end] = block.splitlines()
    return "\n".join(lines) + "\n"


def _entry_from_execution(execution_path: str):
    """Derive `(surface, evidence_kind, verify_commands)` from a machine-owned execution receipt.

    Only a PROVEN recipe earns a registry entry, so the receipt must be source-owned, witnessed, and
    PASSING, and must not already cite a handle (a handle-backed run proves nothing new)."""
    try:
        import idc_validation_contract as VC  # noqa: E402 — lazy, mirroring VC's own lazy import here
    except ImportError as exc:
        raise HandleError(
            f"cannot read the execution receipt: idc_validation_contract.py is unavailable ({exc})") from exc
    try:
        doc = VC.load_execution(execution_path)
    except VC.ValidationError as exc:
        raise HandleError(f"execution receipt did not verify: {exc}") from exc
    if doc.get("result") != "pass":
        raise HandleError(
            "only a PROVEN recipe is appended: the execution receipt did not record a passing run")
    if doc.get("handle_id"):
        raise HandleError(
            f"execution receipt already cites handle_id {doc.get('handle_id')!r} — nothing new to append")
    commands = [str(row.get("command") or "").strip()
                for row in (doc.get("verification") or []) if isinstance(row, dict)]
    commands = [cmd for cmd in commands if cmd]
    if not commands:
        raise HandleError("execution receipt records no verification commands to persist")
    return str(doc.get("surface") or ""), str(doc.get("evidence_kind") or ""), commands


def append_handle(repo: str, *, handle_id: str, surface: str | None = None,
                  verify_commands: list[str] | None = None, build_commands: list[str] | None = None,
                  launch_commands: list[str] | None = None, fixtures: list[str] | None = None,
                  accounts: list[str] | None = None, emulators: list[str] | None = None,
                  from_execution: str | None = None, override: str | None = None):
    path = registry_path(repo, override)
    if not os.path.exists(path):
        raise HandleError(
            f"no verification-handle registry at {path} — run /idc:init or /idc:update to scaffold it "
            "before appending a proven recipe")
    _path, doc = load_registry(repo, override)          # fail closed on an already-broken registry

    if from_execution:
        surface, evidence_kind, proven = _entry_from_execution(from_execution)
        if verify_commands and [c.strip() for c in verify_commands] != proven:
            raise HandleError(
                f"--verify-command {list(verify_commands)!r} does not match the executed commands "
                f"{proven!r}; the registry records what was PROVEN, not what was retyped")
        verify_commands = proven
    else:
        if not surface:
            raise HandleError("append requires --surface (or --from-execution to derive it)")
        evidence_kind = SC.SURFACE_EVIDENCE_TABLE.get(surface)
    if evidence_kind in (None, "none") or surface in (None, "", "none"):
        raise HandleError(
            f"surface must be one of {sorted(set(SC.SURFACE_EVIDENCE_TABLE) - {'none'})}, got {surface!r}")

    entry = {
        "handle_id": str(handle_id or "").strip(),
        "surface": surface,
        "evidence_kind": evidence_kind,
        "build_commands": [str(c).strip() for c in (build_commands or []) if str(c).strip()],
        "launch_commands": [str(c).strip() for c in (launch_commands or []) if str(c).strip()],
        "verify_commands": [str(c).strip() for c in (verify_commands or []) if str(c).strip()],
        "fixtures": [str(c).strip() for c in (fixtures or []) if str(c).strip()],
        "accounts": [str(c).strip() for c in (accounts or []) if str(c).strip()],
        "emulators": [str(c).strip() for c in (emulators or []) if str(c).strip()],
    }
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", entry["handle_id"]):
        raise HandleError(f"handle_id must match [a-z0-9][a-z0-9-]*, got {entry['handle_id']!r}")
    if any(h.get("handle_id") == entry["handle_id"] for h in (doc.get("handles") or [])):
        raise HandleError(
            f"handle_id {entry['handle_id']!r} already exists in {path} — a proven recipe never "
            "silently replaces an operator's entry; pick a new id or edit the existing one by hand")
    if not entry["verify_commands"]:
        raise HandleError("append requires at least one verify command")
    for key in APPEND_LIST_FIELDS:
        problem = _list_problem(key, entry[key])
        if problem:
            raise HandleError(problem)

    original = open(path, encoding="utf-8").read()
    updated = _insert_entry(original, _entry_block(entry))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(updated)
    try:                                                # re-validate the WHOLE file, not just the entry
        load_registry(repo, override)
        resolve_handle(repo, entry["handle_id"], entry["surface"], override=override)
    except HandleError as exc:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(original)                          # leave the operator's registry exactly as found
        raise HandleError(
            f"appending {entry['handle_id']!r} would leave {path} invalid ({exc}); the registry was "
            "restored unchanged") from exc
    return {"ok": True, "path": path, "handle_id": entry["handle_id"], "handle": entry}


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
    lines = audit_citations(args.repo, args.registry, args.contract or [], args.contracts_dir)
    if lines:
        for line in lines:
            print(line)
    else:
        print("verification-handles: no citation warnings")
    return 0


def cmd_append(args: argparse.Namespace) -> int:
    result = append_handle(
        args.repo,
        handle_id=args.handle_id,
        surface=args.surface,
        verify_commands=args.verify_command,
        build_commands=args.build_command,
        launch_commands=args.launch_command,
        fixtures=args.fixture,
        accounts=args.account,
        emulators=args.emulator,
        from_execution=args.from_execution,
        override=args.registry,
    )
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
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

    pp = sub.add_parser("append", help="append a newly-proven verification recipe to the registry")
    pp.add_argument("--repo", required=True)
    pp.add_argument("--registry")
    pp.add_argument("--handle-id", required=True)
    pp.add_argument("--surface")
    pp.add_argument("--from-execution",
                    help="derive surface/evidence_kind/verify_commands from a passing, witnessed "
                         "execution receipt (the only way a recipe is PROVEN)")
    pp.add_argument("--verify-command", action="append")
    pp.add_argument("--build-command", action="append")
    pp.add_argument("--launch-command", action="append")
    pp.add_argument("--fixture", action="append")
    pp.add_argument("--account", action="append")
    pp.add_argument("--emulator", action="append")
    pp.set_defaults(func=cmd_append)

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
