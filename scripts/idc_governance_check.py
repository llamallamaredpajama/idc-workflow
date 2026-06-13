#!/usr/bin/env python3
"""Drift check for the compiled governance sidecar (the reload-on-drift signal).

A long-lived pi resident loads `docs/workflow/idc-governance-contract.yaml` once (emitted by
`idc_governance_compile.py`) and consults it instead of re-reading `WORKFLOW.md`. Before trusting
that loaded contract — and periodically while it lives — the resident runs this check. It re-hashes
each governing source on disk and compares to the `source_hashes:` the sidecar pinned at compile
time:

  * all match            -> exit 0, the resident keeps using its loaded contract.
  * any source changed    -> exit 1 + a RELOAD-REQUIRED signal on stderr; the resident must
    or was removed         recompile and reload before acting on stale governance.
  * sidecar missing       -> non-zero (fail-closed): never assume sources are current.
    or malformed

**Never auto-compiles.** Recompilation is an explicit operator/launcher step; this check only
detects and signals. Pi-mode only — episodic Claude/Codex runs read `WORKFLOW.md` directly and do
not consume the sidecar, so they are never gated on it.

Stdlib-only (hashlib + a tiny fixed-format reader for the sidecar this repo's compiler emits).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile

SCHEMA_VERSION = 1
SIDECAR_RELPATH = "docs/workflow/idc-governance-contract.yaml"
# The fixed governing source set the compiler pins (idc_governance_compile.py::SOURCES). A valid
# sidecar must cover EXACTLY these — no missing source (or its drift goes unchecked), no extras.
EXPECTED_SOURCES = ("WORKFLOW.md", "WORKFLOW-config.yaml", "docs/workflow/tracker-config.yaml")


def die(message: str, code: int = 2) -> None:
    print(f"idc-governance: {message}", file=sys.stderr)
    raise SystemExit(code)


def fingerprint(abs_path: str) -> str:
    h = hashlib.sha256()
    with open(abs_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_sidecar(path: str) -> list[tuple[str, str]]:
    """Lift `schema_version` + the `source_hashes:` block; fail loud on anything not a valid v1
    sidecar. Returns [(source_relpath, expected_sha256), ...]."""
    if not os.path.isfile(path):
        die(
            f"compiled sidecar not found at {path} — run scripts/idc_governance_compile.py "
            "(fail-closed: refusing to assume the governance sources are current)"
        )
    try:
        raw = open(path, "r", encoding="utf-8").read()
    except OSError as exc:
        die(f"could not read sidecar {path}: {exc}")
        return []  # unreachable

    schema_version: str | None = None
    entries: list[tuple[str, str]] = []
    in_hashes = False
    for line in raw.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):  # a top-level key ends any open block
            in_hashes = line.startswith("source_hashes:")
            if line.startswith("schema_version:"):
                schema_version = line.split(":", 1)[1].strip()
            continue
        if in_hashes and line.startswith("  ") and not line.startswith("    "):
            key, _, val = line.strip().partition(":")
            entries.append((key.strip(), val.strip()))

    if schema_version != str(SCHEMA_VERSION):
        die(f"invalid sidecar: schema_version must be {SCHEMA_VERSION}, got {schema_version!r}")
    if not entries:
        die("invalid sidecar: empty or missing source_hashes block")
    for rel, h in entries:
        if len(h) != 64 or any(c not in "0123456789abcdef" for c in h):
            die(f"invalid sidecar: source {rel} has a non-sha256 hash")
    # Fail-closed completeness (codex round-6): a sidecar must cover EXACTLY the governing source
    # set — reject duplicate keys, absolute/traversal paths, and any missing/extra source, so an
    # incomplete or hand-edited sidecar can't pass the gate while skipping a file's drift check.
    keys = [rel for rel, _ in entries]
    if len(keys) != len(set(keys)):
        die("invalid sidecar: duplicate key(s) in source_hashes")
    for rel in keys:
        if os.path.isabs(rel) or rel != os.path.normpath(rel) or ".." in rel.split("/"):
            die(f"invalid sidecar: source key {rel!r} must be a clean relative path")
    if set(keys) != set(EXPECTED_SOURCES):
        die(f"invalid sidecar: source_hashes must cover exactly {sorted(EXPECTED_SOURCES)}, got {sorted(keys)}")
    return entries


def cmd_check(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    sidecar = args.sidecar or os.path.join(repo, SIDECAR_RELPATH)
    entries = parse_sidecar(sidecar)

    drift: list[tuple[str, str]] = []
    for rel, expected in entries:
        abs_path = os.path.join(repo, rel)
        if not os.path.isfile(abs_path):
            drift.append(("missing", rel))
        elif fingerprint(abs_path) != expected:
            drift.append(("modified", rel))

    if drift:
        for why, rel in drift:
            print(f"DRIFT\t{why}\t{rel}", file=sys.stderr)
        print(
            "idc-governance: RELOAD REQUIRED — the compiled sidecar is stale; recompile with "
            "scripts/idc_governance_compile.py before acting on governance.",
            file=sys.stderr,
        )
        return 1

    # Content integrity (codex round-7): matching source_hashes is not enough — the rest of the
    # sidecar (the workflow/tracker/glass_wall summary residents trust) must ALSO be the deterministic
    # compile of the current sources. A hand-edit or merge-conflict that alters those fields while
    # leaving valid hashes must be rejected, or residents boot on corrupted governance. The compiler
    # is byte-stable (phase8-governance.sh), so we recompile to a temp and byte-compare.
    compiler = os.path.join(os.path.dirname(os.path.abspath(__file__)), "idc_governance_compile.py")
    if os.path.isfile(compiler):
        fd, tmp = tempfile.mkstemp(prefix=".gov-recompile-", suffix=".yaml")
        os.close(fd)
        try:
            res = subprocess.run([sys.executable, compiler, "--repo", repo, "--out", tmp],
                                 capture_output=True, text=True)
            if res.returncode != 0:
                die(f"could not recompile for the integrity check: {res.stderr.strip()}")
            with open(tmp, "rb") as a, open(sidecar, "rb") as b:
                if a.read() != b.read():
                    print("DRIFT\tcontent\tsidecar body differs from a fresh deterministic compile", file=sys.stderr)
                    print("idc-governance: RELOAD REQUIRED — the sidecar was edited/corrupted (hashes "
                          "intact but the compiled body differs); recompile before acting.", file=sys.stderr)
                    return 1
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass

    print(f"idc-governance: ok — sidecar matches all {len(entries)} source hashes + the deterministic compile")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="idc_governance_check.py", description=__doc__)
    parser.add_argument("--repo", required=True, help="governed repo root the sources live under")
    parser.add_argument("--sidecar", help=f"sidecar path (default: <repo>/{SIDECAR_RELPATH})")
    parser.set_defaults(func=cmd_check)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
