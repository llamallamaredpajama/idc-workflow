#!/usr/bin/env python3
"""Release-discipline guard for the IDC plugin (called by scripts/lint-references.sh).

Catches the 2026-06-14 stale-cache release bug — shipped changes that never got a version
bump, so Claude Code's version-keyed cache never refreshes (see
docs/dev/2026-06-14-install-test-pr37-audit.md F1/F1b). Two deterministic, dependency-free
checks (stdlib only — the plugin ships to repos without PyYAML):

  1. Lockstep — `.claude-plugin/plugin.json` `version` must equal the `idc` plugin entry's
     `version` in `.claude-plugin/marketplace.json`. (`claude plugin tag` validates the same
     agreement at release time; this fails earlier, on every commit/CI run.)
  2. Bump-on-ship — if `CHANGELOG.md`'s `## Unreleased` section has content while
     `plugin.json` `version` still equals the latest dated release heading, the shipped
     changes were never given a new version. FAIL: convert `## Unreleased` to a dated
     release heading and bump `plugin.json` (+ `marketplace.json`) in lockstep.

Exit 0 = clean. Exit 1 = one finding per line on stderr (lint-references.sh surfaces them).
"""
from __future__ import annotations

import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PLUGIN_JSON = os.path.join(ROOT, ".claude-plugin", "plugin.json")
MARKETPLACE_JSON = os.path.join(ROOT, ".claude-plugin", "marketplace.json")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def heading_version(line: str) -> str:
    """First token after `## ` — `## 2.1.0 — 2026-06-14` -> `2.1.0`, `## Unreleased` -> `Unreleased`."""
    rest = line[len("## "):].strip()
    return rest.split()[0] if rest else ""


def parse_changelog(path: str) -> tuple[bool, str | None]:
    """Return (unreleased_has_content, latest_released_version)."""
    lines = open(path, "r", encoding="utf-8").read().splitlines()
    unreleased_has_content = False
    latest_released = None
    in_unreleased = False
    for line in lines:
        if line.startswith("## "):
            ver = heading_version(line)
            if ver == "Unreleased":
                in_unreleased = True
                continue
            in_unreleased = False
            if latest_released is None:
                latest_released = ver
            continue
        if in_unreleased and line.strip() and not line.strip().startswith("<!--"):
            unreleased_has_content = True
    return unreleased_has_content, latest_released


def main() -> int:
    findings: list[str] = []

    plugin_version = str(load_json(PLUGIN_JSON).get("version", "")).strip()
    if not plugin_version:
        findings.append(".claude-plugin/plugin.json: [release-discipline] missing 'version'")

    mkt = load_json(MARKETPLACE_JSON)
    entry = next((p for p in mkt.get("plugins", []) if p.get("name") == "idc"), None)
    if entry is None:
        findings.append(".claude-plugin/marketplace.json: [release-discipline] no 'idc' plugin entry")
    else:
        mkt_version = str(entry.get("version", "")).strip()
        if not mkt_version:
            findings.append(
                ".claude-plugin/marketplace.json: [release-discipline] 'idc' entry missing 'version' "
                f"(must match plugin.json {plugin_version!r})"
            )
        elif plugin_version and mkt_version != plugin_version:
            findings.append(
                ".claude-plugin/marketplace.json: [release-discipline] version "
                f"{mkt_version!r} != plugin.json {plugin_version!r} (keep them in lockstep)"
            )

    unreleased_has_content, latest_released = parse_changelog(CHANGELOG)
    if unreleased_has_content and plugin_version and latest_released == plugin_version:
        findings.append(
            "CHANGELOG.md: [release-discipline] '## Unreleased' has content but plugin.json "
            f"version is still {plugin_version!r} (the latest released heading) — convert "
            "'## Unreleased' to a dated release heading and bump plugin.json + marketplace.json"
        )

    for f in findings:
        print(f, file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
