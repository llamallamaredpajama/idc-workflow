#!/usr/bin/env python3
"""Governance compiler for long-lived pi residents.

A pi resident lives across many issues; re-reading `WORKFLOW.md` prose on every decision is slow
and lets a resident silently drift when the governing contract changes mid-life. This compiler
emits a compact, hash-pinned **sidecar** of the three governing source files —

    WORKFLOW.md                          (normative contract)
    WORKFLOW-config.yaml                 (repo/workflow compatibility, at the governed root)
    docs/workflow/tracker-config.yaml    (tracker backend + field IDs)

— that a resident loads once and consults instead. The sidecar carries a raw-byte SHA-256 of each
source under `source_hashes:`, so the companion `idc_governance_check.py` can prove in O(3 hashes)
whether the resident's loaded contract still matches disk and, if not, emit a reload-on-drift
signal. The check is **fail-closed**: a missing/stale sidecar fails rather than assuming current.

Episodic Claude/Codex runs are unaffected — they read `WORKFLOW.md` directly and cannot go stale
within a single run, so they never consume this file. Pi-mode only.

Determinism is the contract: two compiles over byte-identical sources MUST produce a byte-identical
sidecar (no timestamps, no randomness, no absolute paths; fixed key order, sorted field list). The
emitter and the config reader are stdlib-only — the sidecar ships to repos that may not have PyYAML,
and the reader is a deliberately tiny, format-specific scanner (NOT a general YAML parser) that
only lifts the few summary scalars; the SHA-256 source hashes are the safety-critical core and do
not depend on it.

Sidecar shape (schema_version 1):

    schema_version: 1
    compiler: {name, version}
    workflow: {schema, version, project}
    source_hashes:                     # raw-byte sha256 of the three source files, fixed order
      WORKFLOW.md: <64-hex>
      WORKFLOW-config.yaml: <64-hex>
      docs/workflow/tracker-config.yaml: <64-hex>
    tracker: {backend, fields}         # fields sorted; [] for the filesystem backend
    glass_wall: {planning_to_build, build_to_planning}
"""
from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import tempfile

SCHEMA_VERSION = 1
COMPILER_NAME = "idc-governance-compile"
COMPILER_VERSION = 1
SIDECAR_RELPATH = "docs/workflow/idc-governance-contract.yaml"
# The three governing source files, in fixed emit order (deterministic regardless of FS order).
SOURCES = ["WORKFLOW.md", "WORKFLOW-config.yaml", "docs/workflow/tracker-config.yaml"]
# Glass-wall flow is an IDC v2 invariant (WORKFLOW.md §1.2): planning reaches Build only through
# tracker issues; Build reaches planning only through the Recirculator.
GLASS_WALL = (("planning_to_build", "github_issues_only"), ("build_to_planning", "recirculator_only"))


def die(message: str, code: int = 2) -> None:
    print(f"idc-governance: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_text(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read()
    except OSError as exc:
        die(f"could not read {path}: {exc}")
        return ""  # unreachable; die raises


def fingerprint(abs_path: str) -> str:
    """Raw-byte SHA-256 of the file's final on-disk bytes (the drift-detection anchor)."""
    h = hashlib.sha256()
    with open(abs_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _unquote(s: str) -> str:
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def parse_config_scalars(text: str) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """Lift top-level `key: value` and one level of two-space nesting from an IDC config file.

    Deliberately NOT a general YAML parser — it reads only the handful of summary scalars this
    compiler needs (workflow.schema/version, project.name, backend, field_ids keys) and ignores
    everything deeper (model_routing flow maps, folded scalars, etc.). Dependency-free so the
    governed repo never needs PyYAML.
    """
    top: dict[str, str] = {}
    nested: dict[str, dict[str, str]] = {}
    parent: str | None = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if ":" not in line:
            continue
        key, _, val = line.strip().partition(":")
        key = key.strip()
        val = _unquote(val.strip())
        if indent == 0:
            parent = key
            if val == "":
                nested.setdefault(key, {})
            else:
                top[key] = val
        elif indent == 2 and parent is not None:
            nested.setdefault(parent, {})[key] = val
    return top, nested


def render_sidecar(
    hashes: list[tuple[str, str]],
    schema: str,
    version: str,
    project: str,
    backend: str,
    fields: list[str],
) -> str:
    """Build the sidecar text with a fixed key order — the determinism guarantee lives here."""
    lines = [
        "# idc-governance-contract.yaml — COMPILED, do not hand-edit.",
        "# Emitted by scripts/idc_governance_compile.py from WORKFLOW.md + the two configs.",
        "# Long-lived pi residents consume THIS instead of re-reading WORKFLOW.md prose; run",
        "# scripts/idc_governance_check.py to prove it still matches source before trusting it.",
        "# (Episodic Claude/Codex runs ignore this file — they read WORKFLOW.md directly.)",
        f"schema_version: {SCHEMA_VERSION}",
        "compiler:",
        f"  name: {COMPILER_NAME}",
        f"  version: {COMPILER_VERSION}",
        "workflow:",
        f"  schema: {schema}",
        f"  version: {version}",
        f"  project: {project}",
        "source_hashes:",
    ]
    lines.extend(f"  {rel}: {fp}" for rel, fp in hashes)
    lines.append("tracker:")
    lines.append(f"  backend: {backend}")
    lines.append(f"  fields: [{', '.join(fields)}]")
    lines.append("glass_wall:")
    lines.extend(f"  {key}: {val}" for key, val in GLASS_WALL)
    return "\n".join(lines) + "\n"


def atomic_write(path: str, text: str) -> None:
    """Same-dir temp + fsync + os.replace (mirrors scripts/idc_receipt_check.py atomic_write)."""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = ""
    fd = -1
    try:
        fd, tmp = tempfile.mkstemp(prefix=".idc-governance-", suffix=".tmp", dir=parent)
        if os.path.exists(path):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            fd = -1
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        tmp = ""
    except OSError as exc:
        die(f"could not write sidecar {path}: {exc}", code=1)
    finally:
        if fd != -1:
            os.close(fd)
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def cmd_compile(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)

    # Hash the three sources first — the safety-critical core. Fail-closed if any is absent:
    # a partial sidecar would let a resident trust a contract that isn't fully present.
    hashes: list[tuple[str, str]] = []
    for rel in SOURCES:
        abs_path = os.path.join(repo, rel)
        if not os.path.isfile(abs_path):
            die(f"cannot compile: source not found: {rel} (is {repo} a governed repo root?)")
        hashes.append((rel, fingerprint(abs_path)))

    # Best-effort summary scalars (the hashes above are authoritative; these are convenience).
    _, wf = parse_config_scalars(read_text(os.path.join(repo, "WORKFLOW-config.yaml")))
    tr_top, tr = parse_config_scalars(read_text(os.path.join(repo, "docs/workflow/tracker-config.yaml")))
    schema = wf.get("workflow", {}).get("schema", "idc")
    version = wf.get("workflow", {}).get("version", "")
    project = wf.get("project", {}).get("name", "")
    backend = tr_top.get("backend", "")
    fields = sorted(tr.get("field_ids", {}).keys())

    text = render_sidecar(hashes, schema, version, project, backend, fields)
    out = args.out or os.path.join(repo, SIDECAR_RELPATH)
    atomic_write(out, text)
    print(f"idc-governance: compiled sidecar -> {out}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="idc_governance_compile.py", description=__doc__)
    parser.add_argument("--repo", required=True, help="governed repo root the sources live under")
    parser.add_argument("--out", help=f"write the sidecar here (default: <repo>/{SIDECAR_RELPATH})")
    parser.set_defaults(func=cmd_compile)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
