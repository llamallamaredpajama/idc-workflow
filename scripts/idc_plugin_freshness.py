#!/usr/bin/env python3
"""idc_plugin_freshness.py — bind the running IDC session's version to the governed repo's
install receipt, so a stale cached plugin runtime is detected before a lifecycle command acts.

Claude Code caches a command's markdown at session start and runs `/idc:*` from a **version-keyed
cache** dir (`${CLAUDE_PLUGIN_ROOT}` = .../plugins/cache/idc-workflow/idc/<version>/). If the plugin
is updated mid-session, a newer version dir appears in that cache but the running command body is
still the OLD version's — so update would execute stale logic against a newer install (the exact
trap that re-introduces just-fixed bugs). This helper compares the RUNNING version against two
independent freshness signals:

  * the governed repo's own install receipt (`docs/workflow/install-receipt.yaml`'s
    `plugin_version` — the version that last stamped this repo's scaffold). A repo contract: the
    running session must never be OLDER than what the repo itself was last stamped by.
  * the highest version present in Claude Code's version-keyed cache (a same-session update that
    hasn't been reloaded yet).

`evaluate()` is the public entry point and returns an explicit `FreshnessResult` rather than a
best-effort guess. A `--plugin-dir` dev load (whose root is not a version-keyed cache dir) is
never compared against unrelated cache siblings — only against the repo's receipt, if any.

Usage:
  idc_plugin_freshness.py --plugin-root ROOT [--repo REPO] [--cache-root DIR] [--json]
    --plugin-root ROOT   the running plugin root (${CLAUDE_PLUGIN_ROOT})
    --repo REPO          the governed repo to read docs/workflow/install-receipt.yaml from
                         (optional — omit when there is no repo yet, e.g. before /idc:init)
    --cache-root DIR     the version-keyed cache dir holding <version>/ subdirs; if omitted, it is
                         inferred as ROOT's parent when ROOT looks like .../idc/<version>.
    --json               emit dataclasses.asdict(FreshnessResult) instead of the legacy one-liner.
Exit 0 = current, development-current, or unknown (safe to proceed); 4 = stale-runtime (running
version is behind the repo's receipt or the installed cache); 2 = usage error OR an invalid
receipt (a `receipt_version: 2` repo receipt whose `plugin_version` is missing or not X.Y.Z — a
v1 receipt, or no receipt at all, is NOT invalid: it yields required_version=None, the documented
pre-guard migration path, and is allowed).
"""
from __future__ import annotations

import dataclasses
import json
import os
import re
import sys

_VER = re.compile(r"^\d+(\.\d+)*$")


class InvalidReceiptError(ValueError):
    """Raised when a repo's install-receipt.yaml cannot be trusted for freshness evaluation:
    specifically, a `receipt_version: 2` receipt whose `plugin_version` is missing or does not
    match `_VER`. A v1 receipt (or no receipt) is NOT an error — it is the documented pre-guard
    migration path and yields required_version=None (see read_required_version)."""


def version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(p) for p in v.split("."))


def read_version(plugin_root: str) -> str | None:
    manifest = os.path.join(plugin_root, ".claude-plugin", "plugin.json")
    try:
        with open(manifest, "r", encoding="utf-8") as f:
            return json.load(f).get("version")
    except (OSError, ValueError):
        # Fall back to the cache dir name (.../idc/<version>), which is the version key.
        base = os.path.basename(os.path.normpath(plugin_root))
        return base if _VER.match(base) else None


@dataclasses.dataclass(frozen=True)
class FreshnessResult:
    running_version: str | None
    required_version: str | None
    installed_max: str | None
    load_mode: str
    verdict: str
    reason_code: str


def evaluate(plugin_root: str, repo: str | None = None,
             cache_root: str | None = None) -> FreshnessResult:
    running = read_version(plugin_root)
    required = read_required_version(repo) if repo else None
    mode = "cache" if cache_version_root(plugin_root) else "plugin-dir"
    installed = newest_cached_version(plugin_root, cache_root) if mode == "cache" else None
    if running and required and version_tuple(running) < version_tuple(required):
        return FreshnessResult(running, required, installed, mode, "stale", "running-behind-receipt")
    if mode == "cache" and running and installed and version_tuple(running) < version_tuple(installed):
        return FreshnessResult(running, required, installed, mode, "stale", "running-behind-cache")
    if mode == "plugin-dir" and running:
        return FreshnessResult(running, required, installed, mode, "development-current", "plugin-dir-current")
    if running:
        return FreshnessResult(running, required, installed, mode, "current", "versions-current")
    return FreshnessResult(running, required, installed, mode, "unknown", "version-unavailable")


def read_required_version(repo: str | None) -> str | None:
    """Read the repo's required plugin_version from its install receipt.

    Reads `receipt_version` FIRST to decide how to treat a missing/malformed `plugin_version`:
      * receipt_version != "2" (v1, or absent/garbled — no receipt file at all also lands here)
        — no requirement was ever recorded; this is the documented migration path, so return
        None (allowed) rather than erroring.
      * receipt_version == "2" — plugin_version is a REQUIRED, binding field. Missing or not
        matching `_VER` means the receipt itself is invalid (never fail open to "no
        requirement"); raise so the CLI can surface it as exit 2.
    """
    if not repo:
        return None
    receipt = os.path.join(repo, "docs", "workflow", "install-receipt.yaml")
    if not os.path.isfile(receipt):
        return None
    receipt_version: str | None = None
    plugin_version: str | None = None
    for line in open(receipt, "r", encoding="utf-8"):
        if line.startswith("receipt_version:"):
            receipt_version = line.split(":", 1)[1].strip()
        elif line.startswith("plugin_version:"):
            plugin_version = line.split(":", 1)[1].strip()
    if receipt_version != "2":
        return None
    if not plugin_version or not _VER.fullmatch(plugin_version):
        raise InvalidReceiptError(
            f"{receipt}: receipt_version: 2 requires a valid plugin_version (X.Y[.Z...]), "
            f"got {plugin_version!r}"
        )
    return plugin_version


def cache_version_root(plugin_root: str) -> bool:
    root = os.path.normpath(plugin_root)
    return bool(_VER.fullmatch(os.path.basename(root)))


def newest_cached_version(plugin_root: str, cache_root: str | None) -> str | None:
    root = cache_root or os.path.dirname(os.path.normpath(plugin_root))
    try:
        versions = [name for name in os.listdir(root)
                    if _VER.fullmatch(name) and os.path.isdir(os.path.join(root, name))]
    except OSError:
        return None
    return max(versions, key=version_tuple) if versions else None


# Legacy plain-text display collapses the fine-grained verdict back to the original three-way
# vocabulary (current/stale/unknown) that existing non-JSON callers already grep for. Both
# "development-current" and "unknown" print as "unknown" in this mode — a dev/plugin-dir load
# was already reported "unknown" pre-receipt-binding, and --json is how a caller gets the
# precise verdict now.
_LEGACY_DISPLAY = {"current": "current", "stale": "stale"}


def legacy_display_verdict(verdict: str) -> str:
    return _LEGACY_DISPLAY.get(verdict, "unknown")


def main(argv: list[str]) -> int:
    plugin_root = cache_root = repo = None
    as_json = False
    i = 0
    while i < len(argv):
        if argv[i] == "--plugin-root" and i + 1 < len(argv):
            plugin_root = argv[i + 1]; i += 2; continue
        if argv[i] == "--cache-root" and i + 1 < len(argv):
            cache_root = argv[i + 1]; i += 2; continue
        if argv[i] == "--repo" and i + 1 < len(argv):
            repo = argv[i + 1]; i += 2; continue
        if argv[i] == "--json":
            as_json = True; i += 1; continue
        print("usage: idc_plugin_freshness.py --plugin-root ROOT [--repo REPO] "
              "[--cache-root DIR] [--json]", file=sys.stderr)
        return 2
    if not plugin_root:
        print("usage: idc_plugin_freshness.py --plugin-root ROOT [--repo REPO] "
              "[--cache-root DIR] [--json]", file=sys.stderr)
        return 2

    try:
        result = evaluate(plugin_root, repo=repo, cache_root=cache_root)
    except InvalidReceiptError as exc:
        print(f"idc-freshness: invalid receipt: {exc}", file=sys.stderr)
        return 2

    if as_json:
        print(json.dumps(dataclasses.asdict(result), indent=2, sort_keys=True))
    else:
        print(f"running {result.running_version or 'unknown'}; "
              f"installed-max {result.installed_max or 'unknown'}; "
              f"verdict {legacy_display_verdict(result.verdict)}")
    return 4 if result.verdict == "stale" else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
