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

Format (v2; kept byte-compatible with commands/init.md:266-310):

    receipt_version: 2
    plugin_version: 4.1.0
    fingerprint_method: sha256
    written_by: idc:init
    files:
      - path: WORKFLOW.md
        fingerprint: <64-lowercase-hex>
        state: stamped

`plugin_version` is a repo contract, not just metadata: `scripts/idc_plugin_freshness.py`
reads it as the running plugin's REQUIRED version, so a session whose loaded command body is
older than the version that stamped this repo's scaffold is refused as stale-runtime (exit 4)
rather than silently running old logic against a newer repo. A v1 receipt (no `plugin_version`)
still parses — `read_required_version()` treats it as "no requirement recorded" — and is
migrated to v2 the next time `/idc:init` or `/idc:update` stamps a fresh one.

Rules: entry keys exactly path/fingerprint/state; sorted by path; the receipt never lists
itself (docs/workflow/install-receipt.yaml), TRACKER.md (runtime footprint), or
.claude/settings.json (operator-owned). No third-party deps — stdlib hashlib + a small parser
for the fixed format above (the receipt ships to repos that may not have PyYAML).
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

RECEIPT_VERSION = 2
PLUGIN_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
FINGERPRINT_METHOD = "sha256"
RECEIPT_RELPATH = "docs/workflow/install-receipt.yaml"
# Paths the receipt must never list, by exact repo-relative path or basename.
EXCLUDED_RELPATHS = {"TRACKER.md", ".claude/settings.json"}
EXCLUDED_BASENAMES = {"install-receipt.yaml"}
# Operator-data scaffold files: /idc:init writes operator/board data into the two configs AFTER
# copying the template (WORKFLOW-config.yaml gets the derived `domains:`; tracker-config.yaml gets
# project_number + board field_ids), and U6 adds the verification-handle registry as operator-owned
# evidence/recipe data that update must preserve as-is. /idc:update must ALWAYS route these through
# its preserve/advisory logic regardless of receipt state — a pre-guard receipt can still mark one
# `state: stamped`, and silently re-stamping would wipe operator data. This set is the single source
# of truth update consumes (verify --json -> "always_ask"); never silently refresh a path listed here.
ALWAYS_ASK_RELPATHS = {
    "WORKFLOW-config.yaml",
    "docs/workflow/tracker-config.yaml",
    "docs/workflow/verification-handles.yaml",
}
# Fixed governed dests OUTSIDE the docs-tree, dest -> template source relative to the plugin root
# (the same mapping idc_template_for.py / idc_init_scaffold.sh encode). Used by verify to derive
# the CURRENT plugin's expected stamped set: a receipt written by an older plugin version does not
# list files a newer version scaffolds (e.g. a 3.x receipt has no docs/workflow/workflow-machine.yaml),
# so classifying only receipt entries silently skips them — the /idc:update 4.0.0 migration gap.
GOVERNED_FIXED_DESTS = {
    "WORKFLOW.md": "templates/WORKFLOW.md",
    "WORKFLOW-config.yaml": "templates/WORKFLOW-config.yaml",
    "docs/workflow/tracker-config.yaml": "templates/tracker-config.yaml",
    "docs/workflow/workflow-machine.yaml": "templates/workflow-machine.yaml",
}
DOCS_TREE_TEMPLATE_DIR = "templates/docs-tree"


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

def validate_plugin_version(version: str) -> str:
    """`--plugin-version` is REQUIRED and explicitly supplied by every caller (no auto-resolve
    fallback) — a v2 receipt must never be stamped with a silently-guessed version. Validate the
    format only."""
    if not PLUGIN_VERSION_RE.fullmatch(version):
        die(f"invalid --plugin-version {version!r}: must match X.Y.Z")
    return version


def cmd_stamp(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    plugin_version = validate_plugin_version(args.plugin_version)
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
        f"plugin_version: {plugin_version}",
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

def parse_receipt_document(path: str) -> tuple[dict[str, str], list[dict[str, str]]]:
    """Parse the fixed receipt format, returning (top-level metadata, file entries).

    Fail loud on anything that isn't a valid v1 or v2 receipt: v1 predates `plugin_version`
    (idc_plugin_freshness.py's repo-freshness contract migrates it on the next /idc:init or
    /idc:update stamp); v2 requires `plugin_version` so a repo's receipt is a binding statement
    of the plugin version its scaffold was stamped by.
    """
    if not os.path.isfile(path):
        die(f"receipt not found at {path} — run /idc:init (or /idc:update to graduate one)")
    try:
        raw = open(path, "r", encoding="utf-8").read()
    except OSError as exc:
        die(f"could not read receipt {path}: {exc}")

    top: dict[str, str] = {}
    for line in raw.splitlines():
        if line and not line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            top[key.strip()] = value.strip()
    version = top.get("receipt_version")
    if version not in {"1", "2"}:
        die(f"invalid receipt: receipt_version must be 1 or 2, got {version!r}")
    if version == "2" and not top.get("plugin_version"):
        die("invalid receipt: v2 receipt missing plugin_version")
    return top, _parse_entries(raw, path)


def _parse_entries(raw: str, path: str) -> list[dict[str, str]]:
    method = None
    files_seen = False
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    current_line = 0
    for line_number, line in enumerate(raw.splitlines(), 1):
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
            if current is not None:
                entries.append(finish_entry(current, current_line))
            current = {"path": line.split(":", 1)[1].strip()}
            current_line = line_number
        elif line.startswith("    fingerprint:") and current is not None:
            current["fingerprint"] = line.split(":", 1)[1].strip()
        elif line.startswith("    state:") and current is not None:
            current["state"] = line.split(":", 1)[1].strip()
        # top-level scalars other than the above (receipt_version, plugin_version, written_by)
        # are ignored here — parse_receipt_document's caller reads them from `top`.
    if current is not None:
        entries.append(finish_entry(current, current_line))
    if method != FINGERPRINT_METHOD:
        die(f"invalid receipt: fingerprint_method must be {FINGERPRINT_METHOD}, got {method!r}")
    if not files_seen:
        die("invalid receipt: missing 'files:' block")
    return entries


def parse_receipt(path: str) -> list[dict[str, str]]:
    """Back-compat entry point for existing callers that only need the file entries."""
    return parse_receipt_document(path)[1]


def finish_entry(cur: dict[str, str], lineno: int) -> dict[str, str]:
    for key in ("path", "fingerprint", "state"):
        if key not in cur:
            die(f"invalid receipt: entry near line {lineno} missing '{key}'")
    if len(cur["fingerprint"]) != 64 or any(c not in "0123456789abcdef" for c in cur["fingerprint"]):
        die(f"invalid receipt: entry {cur['path']} has a non-sha256 fingerprint")
    return cur


def governed_expected_paths() -> list[str]:
    """The CURRENT plugin version's expected stamped set, enumerated from this script's own
    plugin root exactly the way idc_init_scaffold.sh lays files down: the fixed dests whose
    template source exists, plus every file under each VISIBLE top-level templates/docs-tree
    entry (inner dotfiles like .gitkeep are copied by cp -R, so they count). Fail-soft: an
    absent templates tree (broken install) yields [] with a stderr note — receipt
    classification must keep working regardless."""
    plugin_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    expected: list[str] = []
    for dest, tmpl in GOVERNED_FIXED_DESTS.items():
        if os.path.isfile(os.path.join(plugin_root, tmpl)):
            expected.append(dest)
    tree = os.path.join(plugin_root, DOCS_TREE_TEMPLATE_DIR)
    if not os.path.isdir(tree):
        print(f"idc-receipt: note: {DOCS_TREE_TEMPLATE_DIR} not found under {plugin_root} — "
              "unrecorded detection limited to fixed dests", file=sys.stderr)
        return sorted(rel for rel in expected if not is_excluded(rel))
    for name in sorted(os.listdir(tree)):
        if name.startswith("."):
            continue  # scaffold copies visible top-level entries only
        top = os.path.join(tree, name)
        if os.path.isfile(top):
            expected.append(f"docs/workflow/{name}")
        elif os.path.isdir(top):
            for dirpath, _dirnames, filenames in os.walk(top):
                for fn in filenames:
                    rel_in_tree = os.path.relpath(os.path.join(dirpath, fn), tree)
                    expected.append(norm_rel(f"docs/workflow/{rel_in_tree}"))
    return sorted(rel for rel in expected if not is_excluded(rel))


def classify_receipt(repo: str, entries: list[dict[str, str]]) -> tuple[dict[str, int], list[tuple[str, str]]]:
    """Fingerprint-verify every receipt entry against the repo's CURRENT on-disk bytes, returning
    (counts, classified) where each classification is `unchanged` (bytes match the stamped
    fingerprint), `modified` (bytes differ), or `missing` (file gone). This is the deterministic
    fingerprint check — not a syntax parse — the /idc:init and /idc:update closeouts re-run to prove
    the scaffold actually landed intact (a modified or missing stamped file fails the closeout closed)."""
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
    return counts, classified


def verify_receipt_fingerprints(repo: str, receipt_path: str) -> tuple[bool, dict[str, int]]:
    """Parse `receipt_path` and fingerprint-verify every listed file, returning (ok, counts) where
    ok == (no modified AND no missing entries). Raises SystemExit (via parse_receipt_document/die) on
    an invalid/unreadable receipt — a caller that must fail closed catches SystemExit. The one library
    entry point the command contract re-runs to re-derive an init/update `complete`."""
    _top, entries = parse_receipt_document(receipt_path)
    counts, _classified = classify_receipt(repo, entries)
    return counts["modified"] == 0 and counts["missing"] == 0, counts


def cmd_verify(args: argparse.Namespace) -> int:
    repo = os.path.abspath(args.repo)
    receipt = args.receipt or os.path.join(repo, RECEIPT_RELPATH)
    entries = parse_receipt(receipt)

    counts, classified = classify_receipt(repo, entries)

    if args.json:
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
        # Data-bearing files /idc:update must always show-diff-and-ask for, never silently refresh —
        # even when classified unchanged + state: stamped (legacy-receipt guard). Single source of
        # truth for the guard; intersected with the receipt's own paths so a consumer sees only
        # files this repo actually stamps.
        receipt_paths = {e["path"] for e in entries}
        out["always_ask"] = sorted(ALWAYS_ASK_RELPATHS & receipt_paths)
        # Files the CURRENT plugin stamps that this receipt does not list — new in a newer
        # plugin version (the receipt predates them). update routes these to §B restore
        # (absent on disk) / diff-and-ask (present); they are NOT in `ok` (back-compat: ok
        # stays a modified+missing contract) and NOT in the TSV output (uninstall consumes
        # TSV as its removal manifest and must never see never-stamped paths).
        out["unrecorded"] = [rel for rel in governed_expected_paths()
                             if rel not in receipt_paths]
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
    sp.add_argument("--plugin-version", metavar="X.Y.Z", required=True,
                    help="REQUIRED. The running plugin's version, stamped into the v2 receipt as "
                         "plugin_version (the /idc:update stale-runtime guard's required-version "
                         "contract). Never auto-resolved or guessed — the caller must pass its "
                         "own real running version explicitly.")
    sp.add_argument("--customized", action="append", metavar="RELPATH",
                    help="mark this stamped file state: customized (repeatable) — for files the "
                         "operator kept at update's diff-and-ask, so the next update asks again")
    sp.add_argument("paths", nargs="+", help="repo-relative paths to stamp")
    sp.set_defaults(func=cmd_stamp)

    vp = sub.add_parser("verify", help="classify each stamped file as unchanged/modified/missing")
    vp.add_argument("--repo", required=True, help="repo root the receipt paths are relative to")
    vp.add_argument("--receipt", help=f"receipt path (default: <repo>/{RECEIPT_RELPATH})")
    vp.add_argument("--json", action="store_true",
                    help="emit JSON instead of TSV. Schema: {\"unchanged\":[paths], "
                         "\"modified\":[paths], \"missing\":[paths], \"ok\": bool (true iff "
                         "modified+missing both empty), \"summary\": str, \"always_ask\":[paths] "
                         "(operator-data files update must always preserve/advisory-check rather "
                         "than silently refresh), \"unrecorded\":[paths] (files the current plugin stamps that "
                         "the receipt does not list — new in a newer plugin version; update "
                         "restores absent ones / diff-and-asks present ones)}")
    vp.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
