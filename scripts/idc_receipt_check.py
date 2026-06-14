#!/usr/bin/env python3
"""Install-receipt substrate for the IDC plugin lifecycle commands.

`/idc:init` writes `docs/workflow/install-receipt.yaml` — a manifest of every IDC-owned file
it stamped, each with a SHA-256 fingerprint of its final on-disk bytes. This helper is the
deterministic, dependency-free core that the two lifecycle commands consume:

  * `/idc:update`   — `verify` proves which stamped files are untouched (safe to re-stamp) vs
                      customized (show-diff-and-ask); `stamp` rewrites a fresh receipt at the
                      end of a successful run (and graduates a pre-receipt repo).
  * `/idc:uninstall`— `verify` turns the receipt into the removal manifest ("only delete what
                      IDC created"), and flags operator-customized files before removal.

The compare is safety-critical, so it fails toward asking: a missing or invalid receipt exits
non-zero rather than silently treating files as untouched.

Format (kept byte-compatible with commands/init.md:137-151):

    receipt_version: 1
    fingerprint_method: sha256
    written_by: idc:init
    files:
      - path: WORKFLOW.md
        fingerprint: <64-lowercase-hex>
        state: stamped

Rules: entry keys exactly path/fingerprint/state; sorted by path; the receipt never lists
itself (docs/workflow/install-receipt.yaml), TRACKER.md (runtime footprint), or
.claude/settings.json (operator-owned). No third-party deps — stdlib hashlib + a small parser
for the fixed format above (the receipt ships to repos that may not have PyYAML).
"""
from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import tempfile

RECEIPT_VERSION = 1
FINGERPRINT_METHOD = "sha256"
RECEIPT_RELPATH = "docs/workflow/install-receipt.yaml"
# Paths the receipt must never list, by exact repo-relative path or basename.
EXCLUDED_RELPATHS = {"TRACKER.md", ".claude/settings.json"}
EXCLUDED_BASENAMES = {"install-receipt.yaml"}


def die(message: str, code: int = 2) -> None:
    print(f"idc-receipt: {message}", file=sys.stderr)
    raise SystemExit(code)


def norm_rel(path: str) -> str:
    """Repo-relative, forward-slash, no leading ./ — the on-disk path key shape.
    normpath already drops a leading ./ and collapses // and /./ (but preserves a leading
    dot in a real name like .claude/)."""
    return os.path.normpath(path).replace(os.sep, "/")


def is_excluded(rel: str) -> bool:
    return rel in EXCLUDED_RELPATHS or os.path.basename(rel) in EXCLUDED_BASENAMES


def fingerprint(abs_path: str) -> str:
    h = hashlib.sha256()
    with open(abs_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# --- stamp ------------------------------------------------------------------------------------

def cmd_stamp(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    # Files the operator kept customized at /idc:update's diff-and-ask: recorded state:
    # customized so the NEXT update asks again instead of silently re-stamping over them.
    customized = {norm_rel(p) for p in (args.customized or [])}
    entries: list[tuple[str, str, str]] = []
    seen: set[str] = set()
    for raw in args.paths:
        rel = norm_rel(raw)
        if is_excluded(rel):
            print(f"idc-receipt: excluded {rel} (never receipt-listed)", file=sys.stderr)
            continue
        if rel in seen:
            continue
        abs_path = os.path.join(repo, rel)
        if not os.path.isfile(abs_path):
            die(f"cannot stamp missing file: {rel}")
        seen.add(rel)
        state = "customized" if rel in customized else "stamped"
        entries.append((rel, fingerprint(abs_path), state))

    entries.sort(key=lambda e: e[0])
    lines = [
        f"receipt_version: {RECEIPT_VERSION}",
        f"fingerprint_method: {FINGERPRINT_METHOD}",
        f"written_by: {args.written_by}",
        "files:",
    ]
    for rel, fp, state in entries:
        lines.append(f"  - path: {rel}")
        lines.append(f"    fingerprint: {fp}")
        lines.append(f"    state: {state}")
    text = "\n".join(lines) + "\n"

    if args.out:
        atomic_write(args.out, text)
        print(f"idc-receipt: stamped {len(entries)} file(s) -> {args.out}")
    else:
        sys.stdout.write(text)
    return 0


def atomic_write(path: str, text: str) -> None:
    # Same-dir temp + fsync + os.replace; mirrors scripts/idc_settings_json.py atomic_write_json
    # (incl. the fd guard, so a chmod failure before fdopen can't leak the descriptor).
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = ""
    fd = -1
    try:
        fd, tmp = tempfile.mkstemp(prefix=".install-receipt-", suffix=".tmp", dir=parent)
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
        die(f"could not write receipt {path}: {exc}", code=1)
    finally:
        if fd != -1:
            os.close(fd)
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


# --- verify -----------------------------------------------------------------------------------

def parse_receipt(path: str) -> list[dict[str, str]]:
    """Parse the fixed receipt format. Fail loud on anything that isn't a valid v1 receipt."""
    if not os.path.isfile(path):
        die(f"receipt not found at {path} — run /idc:init (or /idc:update to graduate one)")
    try:
        raw = open(path, "r", encoding="utf-8").read()
    except OSError as exc:
        die(f"could not read receipt {path}: {exc}")

    lines = raw.splitlines()
    method = None
    files_seen = False
    entries: list[dict[str, str]] = []
    cur: dict[str, str] | None = None
    cur_lineno = 0
    for lineno, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("fingerprint_method:"):
            method = line.split(":", 1)[1].strip()
        elif line.startswith("files:"):
            files_seen = True
            rest = line.split(":", 1)[1].strip()
            if rest and rest != "[]":
                die(f"invalid receipt: 'files:' must be a block list, got inline {rest!r}")
        elif line.startswith("  - path:"):
            if cur is not None:
                entries.append(finish_entry(cur, cur_lineno))
            cur = {"path": line.split(":", 1)[1].strip()}
            cur_lineno = lineno
        elif line.startswith("    fingerprint:") and cur is not None:
            cur["fingerprint"] = line.split(":", 1)[1].strip()
        elif line.startswith("    state:") and cur is not None:
            cur["state"] = line.split(":", 1)[1].strip()
        # top-level scalars other than the above (receipt_version, written_by) are ignored
    if cur is not None:
        entries.append(finish_entry(cur, cur_lineno))

    if method != FINGERPRINT_METHOD:
        die(f"invalid receipt: fingerprint_method must be {FINGERPRINT_METHOD}, got {method!r}")
    if not files_seen:
        die("invalid receipt: missing 'files:' block")
    return entries


def finish_entry(cur: dict[str, str], lineno: int) -> dict[str, str]:
    for key in ("path", "fingerprint", "state"):
        if key not in cur:
            die(f"invalid receipt: entry near line {lineno} missing '{key}'")
    if len(cur["fingerprint"]) != 64 or any(c not in "0123456789abcdef" for c in cur["fingerprint"]):
        die(f"invalid receipt: entry {cur['path']} has a non-sha256 fingerprint")
    return cur


def cmd_verify(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    receipt = args.receipt or os.path.join(repo, RECEIPT_RELPATH)
    entries = parse_receipt(receipt)

    classified: list[tuple[str, str]] = []
    counts = {"unchanged": 0, "modified": 0, "missing": 0}
    for entry in sorted(entries, key=lambda e: e["path"]):
        rel = entry["path"]
        abs_path = os.path.join(repo, rel)
        if not os.path.isfile(abs_path):
            state = "missing"
        elif fingerprint(abs_path) == entry["fingerprint"]:
            state = "unchanged"
        else:
            state = "modified"
        counts[state] += 1
        classified.append((state, rel))

    if args.json:
        import json
        out: dict[str, object] = {"unchanged": [], "modified": [], "missing": []}
        for state, rel in classified:
            out[state].append(rel)  # type: ignore[union-attr]
        # Additive top-level pass/fail + human summary (existing buckets unchanged for
        # back-compat): a consumer no longer has to derive "ok" from two empty lists.
        out["ok"] = counts["modified"] == 0 and counts["missing"] == 0
        out["summary"] = (
            f"{counts['unchanged']} unchanged, "
            f"{counts['modified']} modified, {counts['missing']} missing"
        )
        print(json.dumps(out, indent=2, sort_keys=True))
    else:
        for state, rel in classified:
            print(f"{state}\t{rel}")
        print(
            f"summary: {counts['unchanged']} unchanged, "
            f"{counts['modified']} modified, {counts['missing']} missing",
            file=sys.stderr,
        )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="idc_receipt_check.py", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("stamp", help="compute fingerprints + emit an install receipt")
    sp.add_argument("--repo", required=True, help="repo root the paths are relative to")
    sp.add_argument("--out", help="write the receipt here (default: stdout)")
    sp.add_argument("--written-by", default="idc:init", help="written_by value (default idc:init)")
    sp.add_argument("--customized", action="append", metavar="RELPATH",
                    help="mark this stamped file state: customized (repeatable) — for files the "
                         "operator kept at update's diff-and-ask, so the next update asks again")
    sp.add_argument("paths", nargs="+", help="repo-relative paths to stamp")
    sp.set_defaults(func=cmd_stamp)

    vp = sub.add_parser("verify", help="classify each stamped file as unchanged/modified/missing")
    vp.add_argument("--repo", required=True, help="repo root the receipt paths are relative to")
    vp.add_argument("--receipt", help=f"receipt path (default: <repo>/{RECEIPT_RELPATH})")
    vp.add_argument("--json", action="store_true", help="emit JSON buckets instead of TSV lines")
    vp.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
