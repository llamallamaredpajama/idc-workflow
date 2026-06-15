#!/usr/bin/env python3
"""idc_plugin_freshness.py — detect a stale-session plugin load before /idc:update acts.

Claude Code caches a command's markdown at session start and runs `/idc:*` from a **version-keyed
cache** dir (`${CLAUDE_PLUGIN_ROOT}` = .../plugins/cache/idc-workflow/idc/<version>/). If the plugin
is updated mid-session, a newer version dir appears in that cache but the running command body is
still the OLD version's — so update would execute stale logic against a newer install (the exact
trap that re-introduces just-fixed bugs). This helper compares the RUNNING version against the
highest version present in the cache so Phase 0 can halt and tell the operator to reload.

It is best-effort and fail-open: when it can't tell (e.g. a `--plugin-dir` dev load whose root is
not a version-keyed cache dir), it reports `unknown` and exits 0 so real runs are never blocked.

Usage:
  idc_plugin_freshness.py --plugin-root ROOT [--cache-root DIR]
    --plugin-root ROOT   the running plugin root (${CLAUDE_PLUGIN_ROOT})
    --cache-root DIR     the version-keyed cache dir holding <version>/ subdirs; if omitted, it is
                         inferred as ROOT's parent when ROOT looks like .../idc/<version>.
Prints: `running <v>; installed-max <v|unknown>; verdict <current|stale|unknown>`
Exit 0 = current or unknown (safe to proceed); 4 = stale (a newer version is installed); 2 = usage.
"""
from __future__ import annotations

import json
import os
import re
import sys

_VER = re.compile(r"^\d+(\.\d+)*$")


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


def main(argv: list[str]) -> int:
    plugin_root = cache_root = None
    i = 0
    while i < len(argv):
        if argv[i] == "--plugin-root" and i + 1 < len(argv):
            plugin_root = argv[i + 1]; i += 2; continue
        if argv[i] == "--cache-root" and i + 1 < len(argv):
            cache_root = argv[i + 1]; i += 2; continue
        print("usage: idc_plugin_freshness.py --plugin-root ROOT [--cache-root DIR]", file=sys.stderr)
        return 2
    if not plugin_root:
        print("usage: idc_plugin_freshness.py --plugin-root ROOT [--cache-root DIR]", file=sys.stderr)
        return 2

    running = read_version(plugin_root)
    if cache_root is None:
        cache_root = os.path.dirname(os.path.normpath(plugin_root))

    installed = []
    try:
        for name in os.listdir(cache_root):
            if _VER.match(name) and os.path.isdir(os.path.join(cache_root, name)):
                installed.append(name)
    except OSError:
        pass

    max_installed = max(installed, key=version_tuple) if installed else None

    if running is None or max_installed is None:
        verdict = "unknown"
    elif version_tuple(max_installed) > version_tuple(running):
        verdict = "stale"
    else:
        verdict = "current"

    print(f"running {running or 'unknown'}; installed-max {max_installed or 'unknown'}; verdict {verdict}")
    return 4 if verdict == "stale" else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
