#!/usr/bin/env python3
"""Release-discipline guard for the IDC plugin (called by scripts/lint-references.sh).

Catches the 2026-06-14 stale-cache release bug — shipped changes that never got a version
bump, so Claude Code's version-keyed cache never refreshes (see
docs/dev/2026-06-14-install-test-pr37-audit.md F1/F1b). Four deterministic, dependency-free
checks (stdlib only — the plugin ships to repos without PyYAML):

  1. Lockstep — `.claude-plugin/plugin.json` `version` must equal the `idc` plugin entry's
     `version` in `.claude-plugin/marketplace.json`. (`claude plugin tag` validates the same
     agreement at release time; this fails earlier, on every commit/CI run.)
  2. Changelog lockstep — the latest dated release heading must equal both manifest versions.
  3. README lockstep — exactly one version badge must carry matching alt text and shields URL.
  4. Bump-on-ship — if `CHANGELOG.md`'s `## Unreleased` section has content while
     `plugin.json` `version` still equals the latest dated release heading, the shipped
     changes were never given a new version. FAIL: convert `## Unreleased` to a dated
     release heading and bump `plugin.json` (+ `marketplace.json`) in lockstep.

An optional `--governance` flag runs the `tests/smoke/governance` lane, asserting that
all deterministic behavioral guards are green. This is used as a final release gate.

Exit 0 = clean. Exit 1 = one finding per line on stderr (lint-references.sh surfaces them).
"""
from __future__ import annotations

import argparse
import glob
from html.parser import HTMLParser
import json
import os
import re
import subprocess
import sys
from urllib.parse import unquote

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PLUGIN_JSON = os.path.join(ROOT, ".claude-plugin", "plugin.json")
MARKETPLACE_JSON = os.path.join(ROOT, ".claude-plugin", "marketplace.json")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
README = os.path.join(ROOT, "README.md")


class _VersionBadgeParser(HTMLParser):
    """Collect images that identify themselves as the README version badge."""

    def __init__(self):
        super().__init__()
        self.badges = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "img":
            return
        values = dict(attrs)
        alt, src = values.get("alt", ""), values.get("src", "")
        if (str(alt).strip().lower().startswith("version ")
                or str(src).startswith("https://img.shields.io/badge/version-")):
            self.badges.append({"alt": str(alt), "src": str(src)})


def readme_version_badges(path: str) -> list[dict[str, str]]:
    parser = _VersionBadgeParser()
    with open(path, "r", encoding="utf-8") as handle:
        parser.feed(handle.read())
    return parser.badges


def run_governance_lane() -> int:
    """Discover and run the governance smoke tests."""
    gov_lane_dir = os.environ.get(
        "IDC_OVERRIDE_GOVERNANCE_LANE_DIR", os.path.join(ROOT, "tests", "smoke", "governance")
    )
    if not os.path.isdir(gov_lane_dir):
        print(f"FAIL: governance lane directory not found: {gov_lane_dir}", file=sys.stderr)
        return 1

    findings = []
    print(f"--- Running governance lane from: {gov_lane_dir} ---", file=sys.stderr)

    # 1. Self-check is mandatory
    self_check_path = os.path.join(gov_lane_dir, "_lane-selfcheck.sh")
    if not os.path.isfile(self_check_path):
        findings.append("governance/_lane-selfcheck.sh (MISSING)")
    else:
        res = subprocess.run(
            ["bash", self_check_path], capture_output=True, text=True, check=False
        )
        if res.returncode == 0:
            print("  PASS  governance/_lane-selfcheck.sh", file=sys.stderr)
        else:
            findings.append(f"governance/_lane-selfcheck.sh\n        {res.stdout}{res.stderr}".strip())

    # 2. Discover and run scenarios
    scenarios = sorted(glob.glob(os.path.join(gov_lane_dir, "*.sh")))
    real_scenarios = 0
    for s_path in scenarios:
        base = os.path.basename(s_path)
        if base == "lib.sh" or base.startswith("_"):
            continue
        real_scenarios += 1
        res = subprocess.run(
            ["bash", s_path], capture_output=True, text=True, check=False
        )
        if res.returncode == 0:
            print(f"  PASS  governance/{base}", file=sys.stderr)
        else:
            findings.append(f"governance/{base}\n        {res.stdout}{res.stderr}".strip())

    print("------------------------------------------------", file=sys.stderr)
    if findings:
        print(f"governance lane: {len(findings)} FAILED", file=sys.stderr)
        for f in findings:
            print(f"  FAIL  {f}", file=sys.stderr)
        return 1

    print(f"governance lane: ALL GREEN ({real_scenarios} real scenario(s) + self-check)", file=sys.stderr)
    return 0


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
    parser = argparse.ArgumentParser(
        description="Release-discipline guard for the IDC plugin."
    )
    parser.add_argument(
        "--governance",
        action="store_true",
        help="Run the governance test lane as a release gate.",
    )
    args = parser.parse_args()

    if args.governance:
        return run_governance_lane()

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
    if plugin_version and latest_released != plugin_version:
        findings.append(
            "CHANGELOG.md: [release-discipline] latest released heading "
            f"{latest_released!r} != plugin.json {plugin_version!r} (close release metadata together)"
        )

    badges = readme_version_badges(README)
    if len(badges) != 1:
        findings.append(
            f"README.md: [release-discipline] expected exactly one version badge, found {len(badges)}"
        )
    elif plugin_version:
        badge = badges[0]
        expected_alt = f"version {plugin_version}"
        if badge["alt"] != expected_alt:
            findings.append(
                "README.md: [release-discipline] version badge alt text "
                f"{badge['alt']!r} != {expected_alt!r}"
            )
        match = re.match(r"^https://img\.shields\.io/badge/version-([^-/?]+)-", badge["src"])
        url_version = unquote(match.group(1)) if match else None
        if url_version != plugin_version:
            findings.append(
                "README.md: [release-discipline] version badge URL names "
                f"{url_version!r}, expected {plugin_version!r}: {badge['src']!r}"
            )

    for f in findings:
        print(f, file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
