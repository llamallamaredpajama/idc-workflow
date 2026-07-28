#!/usr/bin/env python3
"""Fixed schema validator/aggregator for the source-heavy pilot's `pilot-metrics.json`.

Graph spec `§15.5.7` makes "at least one source-heavy pilot repository measures provider usefulness"
a MUST for release, and `§15.6` names the ten operational metrics that pilot records. Release
evidence is therefore only as trustworthy as the artifact carrying it, so the artifact gets a FIXED
schema and this fixed validator — no model judgment anywhere on the path from measurement to gate.

What it refuses, and why each refusal exists:

  * **A metric that silently vanished.** All ten `§15.6` metrics are required AT THEIR EXACT field
    path, with an exact type. A missing or mistyped leaf is not "no data", it is unmeasured — and an
    unmeasured metric read as a pass is precisely the forged-concordance failure the run guards.
  * **Evidence that drifted off its head.** The pilot names the one reviewed SHA final evidence binds
    to. Measurements taken on some other commit cannot be recycled onto this one.
  * **Lane receipts that do not back the numbers.** Each receipt is bound BY DIGEST, so a receipt
    that is absent, or whose bytes changed after the metrics were written, is refused rather than
    quietly trusted.
  * **A pilot that is not actually source-heavy.** Provider precision/recall measured on a docs- or
    config-dominated repository says nothing about a code-intelligence provider's usefulness. The
    criterion below is deterministic and stated, not a judgment call.

Stdlib only (the plugin ships to repos without PyYAML) and compiles under the repo's ambient
Python 3.9.

Usage:
  python3 scripts/idc_pilot_metrics.py validate --metrics <path> [--reviewed-sha SHA] [--json]
  python3 scripts/idc_pilot_metrics.py summary  --metrics <path>

Exit 0 = the pilot artifact satisfies the contract. Exit 1 = one finding per line on stderr.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

SCHEMA_VERSION = 1

# ── The source-heavy criterion (graph spec §15.5.7) ────────────────────────────────────────────────
# "Source-heavy" has to be mechanical, or the release gate is a matter of opinion. Three thresholds,
# each closing a different way a weak pilot could pass:
#   * MIN_SOURCE_FILES  — a provider's affected-surface prediction is trivial on a handful of files;
#     50 files is the smallest corpus where surface selection is a real choice rather than "all of
#     them".
#   * MIN_SOURCE_LOC    — file count alone is gameable with stubs, so the corpus must also carry real
#     volume. 5,000 source lines is roughly the point where a change's blast radius stops being
#     obvious by inspection.
#   * MIN_SOURCE_SHARE  — a repository can clear both bars and still be dominated by documentation or
#     generated config, which would make precision/recall a measurement of prose. Requiring source to
#     be a MAJORITY of total lines keeps the pilot a code pilot.
# All three are necessary: drop any one and a docs repo, a stub repo, or a toy repo qualifies.
MIN_SOURCE_FILES = 50
MIN_SOURCE_LOC = 5000
MIN_SOURCE_SHARE = 0.50

# The lane whose receipts must be bound; §8.3 of the dispatch manifest names its artifacts.
REQUIRED_LANE = "pilot-source-heavy"

# ── The ten §15.6 metrics at the exact field paths release evidence is bound to ────────────────────
# group -> {leaf field: kind}. Order is the §15.6 order (M1..M10) so `summary` reads like the spec.
METRIC_CONTRACT = (
    ("planning_horizon_omissions", (("count", "count"),)),
    ("dependency_order_corrections_before_build", (("count", "count"),)),
    ("graph_board_divergence_frequency", (("count", "count"), ("rate_per_run", "rate"))),
    ("merge_file_surface_conflicts", (("count", "count"),)),
    ("missing_boundary_detections", (("count", "count"),)),
    ("outside_path_work_routed", (("count", "count"),)),
    ("recirculation", (("rate", "rate"), ("repeat_count", "count"))),
    ("janitor_convergence", (("pass_counts", "pass_counts"), ("false_positive_count", "count"))),
    ("planning_cost", (("planning_seconds", "seconds"), ("api_cost_delta", "delta"))),
    ("provider_precision_recall", (("surfaces_precision", "ratio"), ("surfaces_recall", "ratio"),
                                   ("tests_precision", "ratio"), ("tests_recall", "ratio"))),
)

PILOT_REQUIRED = ("repository", "reviewed_sha", "approved_by", "backend", "pathway_mode",
                  "composition", "lane_receipts")
COMPOSITION_REQUIRED = ("source_files", "source_loc", "total_files", "total_loc")
RECEIPT_REQUIRED = ("lane", "path", "sha256")

_HEX = set("0123456789abcdef")


def _is_int(value) -> bool:
    # bool is a subclass of int; a True count is a type error, not a 1.
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_sha(value) -> bool:
    return isinstance(value, str) and len(value) == 40 and all(c in _HEX for c in value.lower())


def _check_leaf(findings: list, path: str, kind: str, value) -> None:
    if kind == "count":
        if not _is_int(value) or value < 0:
            findings.append("%s: must be a non-negative integer, got %r" % (path, value))
    elif kind in ("rate", "seconds"):
        if not _is_number(value) or value < 0:
            findings.append("%s: must be a non-negative number, got %r" % (path, value))
    elif kind == "delta":
        if not _is_number(value):
            findings.append("%s: must be a number, got %r" % (path, value))
    elif kind == "ratio":
        if not _is_number(value) or not (0.0 <= float(value) <= 1.0):
            findings.append("%s: must be a number in [0, 1], got %r" % (path, value))
    elif kind == "pass_counts":
        if not isinstance(value, list) or not value:
            findings.append("%s: must be a non-empty list of per-run Janitor pass counts, got %r"
                            % (path, value))
        elif not all(_is_int(v) and v >= 1 for v in value):
            findings.append("%s: every Janitor pass count must be an integer >= 1, got %r"
                            % (path, value))


def _check_metrics(findings: list, metrics) -> None:
    if not isinstance(metrics, dict):
        findings.append("metrics: must be an object carrying the ten §15.6 metrics, got %r"
                        % type(metrics).__name__)
        return
    known = set()
    for group, leaves in METRIC_CONTRACT:
        known.add(group)
        body = metrics.get(group)
        if body is None:
            findings.append("metrics.%s: MISSING — all ten §15.6 metrics are required; an "
                            "unmeasured metric is not a passing metric" % group)
            continue
        if not isinstance(body, dict):
            findings.append("metrics.%s: must be an object, got %r" % (group, type(body).__name__))
            continue
        for leaf, kind in leaves:
            full = "metrics.%s.%s" % (group, leaf)
            if leaf not in body:
                findings.append("%s: MISSING — release evidence binds to this exact field path"
                                % full)
                continue
            _check_leaf(findings, full, kind, body[leaf])
        extra = sorted(set(body) - {leaf for leaf, _ in leaves})
        if extra:
            findings.append("metrics.%s: unknown field(s) %s — the pilot schema is fixed"
                            % (group, ", ".join(extra)))
    unknown = sorted(set(metrics) - known)
    if unknown:
        findings.append("metrics: unknown metric group(s) %s — the pilot schema is fixed"
                        % ", ".join(unknown))


def _check_composition(findings: list, composition) -> None:
    """The deterministic source-heavy criterion (§15.5.7)."""
    if not isinstance(composition, dict):
        findings.append("pilot.composition: MISSING — the pilot must carry the repository's "
                        "composition evidence so 'source-heavy' is a measurement, not a claim")
        return
    missing = [k for k in COMPOSITION_REQUIRED if k not in composition]
    if missing:
        findings.append("pilot.composition: missing %s" % ", ".join(missing))
        return
    bad = [k for k in COMPOSITION_REQUIRED
           if not _is_int(composition[k]) or composition[k] < 0]
    if bad:
        findings.append("pilot.composition: %s must be non-negative integers"
                        % ", ".join(sorted(bad)))
        return

    source_files = composition["source_files"]
    source_loc = composition["source_loc"]
    total_loc = composition["total_loc"]

    if source_files < MIN_SOURCE_FILES:
        findings.append("pilot.composition: not source-heavy — %d source file(s), the criterion "
                        "requires >= %d (§15.5.7)" % (source_files, MIN_SOURCE_FILES))
    if source_loc < MIN_SOURCE_LOC:
        findings.append("pilot.composition: not source-heavy — %d source line(s), the criterion "
                        "requires >= %d (§15.5.7)" % (source_loc, MIN_SOURCE_LOC))
    if total_loc <= 0:
        findings.append("pilot.composition: total_loc must be > 0 to compute the source share")
    else:
        share = float(source_loc) / float(total_loc)
        if share < MIN_SOURCE_SHARE:
            findings.append(
                "pilot.composition: not source-heavy — source is %.1f%% of total lines, the "
                "criterion requires >= %.0f%% (a docs/config-dominated repository cannot measure "
                "code-provider usefulness) (§15.5.7)" % (share * 100.0, MIN_SOURCE_SHARE * 100.0))
    if composition["total_files"] < source_files:
        findings.append("pilot.composition: total_files (%d) is smaller than source_files (%d)"
                        % (composition["total_files"], source_files))
    if total_loc > 0 and total_loc < source_loc:
        findings.append("pilot.composition: total_loc (%d) is smaller than source_loc (%d)"
                        % (total_loc, source_loc))


def _check_receipts(findings: list, receipts, base_dir: str) -> None:
    """Lane receipts are bound by digest — absence and staleness both fail."""
    if not isinstance(receipts, list) or not receipts:
        findings.append("pilot.lane_receipts: MISSING — the pilot must bind the lane receipts its "
                        "numbers came from")
        return
    lanes = set()
    for index, receipt in enumerate(receipts):
        where = "pilot.lane_receipts[%d]" % index
        if not isinstance(receipt, dict):
            findings.append("%s: must be an object with lane/path/sha256" % where)
            continue
        missing = [k for k in RECEIPT_REQUIRED if k not in receipt]
        if missing:
            findings.append("%s: missing %s" % (where, ", ".join(missing)))
            continue
        extra = sorted(set(receipt) - set(RECEIPT_REQUIRED))
        if extra:
            findings.append("%s: unknown field(s) %s — the receipt schema is fixed"
                            % (where, ", ".join(extra)))
            continue
        lanes.add(receipt["lane"])
        if not _is_sha_256(receipt["sha256"]):
            findings.append("%s: sha256 must be a 64-character hex digest" % where)
            continue
        path = receipt["path"]
        if not isinstance(path, str) or not path:
            findings.append("%s: path must be a non-empty string" % where)
            continue
        resolved = path if os.path.isabs(path) else os.path.join(base_dir, path)
        if not os.path.isfile(resolved):
            findings.append("%s: lane receipt not found: %s" % (where, path))
            continue
        with open(resolved, "rb") as handle:
            actual = hashlib.sha256(handle.read()).hexdigest()
        if actual != receipt["sha256"]:
            findings.append(
                "%s: STALE — %s changed after the metrics were written (recorded %s…, actual %s…); "
                "re-run the lane and re-record the metrics"
                % (where, path, receipt["sha256"][:12], actual[:12]))
    if REQUIRED_LANE not in lanes:
        findings.append("pilot.lane_receipts: no receipt for the required %r lane" % REQUIRED_LANE)


def _is_sha_256(value) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in _HEX for c in value.lower())


def load(path: str) -> dict:
    """Read the pilot artifact. Raises ValueError with a named reason."""
    if not os.path.isfile(path):
        raise ValueError("pilot metrics file not found: %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError("pilot metrics file is not valid JSON (%s): %s" % (exc, path))
    if not isinstance(doc, dict):
        raise ValueError("pilot metrics file must be a JSON object: %s" % path)
    return doc


def validate(path: str, reviewed_sha: str | None = None) -> list:
    """Return a list of findings; empty means the pilot artifact satisfies the contract."""
    try:
        doc = load(path)
    except ValueError as exc:
        return [str(exc)]

    findings: list = []
    base_dir = os.path.dirname(os.path.abspath(path))

    if doc.get("schema_version") != SCHEMA_VERSION:
        findings.append("schema_version: expected %d, got %r — refusing to interpret an unknown "
                        "pilot schema" % (SCHEMA_VERSION, doc.get("schema_version")))
        return findings

    unknown_top = sorted(set(doc) - {"schema_version", "pilot", "metrics"})
    if unknown_top:
        findings.append("unknown top-level key(s) %s — the pilot schema is fixed"
                        % ", ".join(unknown_top))

    pilot = doc.get("pilot")
    if not isinstance(pilot, dict):
        findings.append("pilot: MISSING — the artifact must identify the pilot repository, the "
                        "exact reviewed SHA, and its operator approval")
    else:
        for key in PILOT_REQUIRED:
            if key not in pilot:
                findings.append("pilot.%s: MISSING" % key)
        extra = sorted(set(pilot) - set(PILOT_REQUIRED))
        if extra:
            findings.append("pilot: unknown field(s) %s — the pilot schema is fixed"
                            % ", ".join(extra))

        if "repository" in pilot and not (isinstance(pilot["repository"], str)
                                          and pilot["repository"].strip()):
            findings.append("pilot.repository: must name the pilot repository")
        if "approved_by" in pilot and not (isinstance(pilot["approved_by"], str)
                                           and pilot["approved_by"].strip()):
            findings.append("pilot.approved_by: must record the operator approval "
                            "(a source-heavy pilot repository is a reserved approval)")
        if "reviewed_sha" in pilot:
            if not _is_sha(pilot["reviewed_sha"]):
                findings.append("pilot.reviewed_sha: must be a full 40-character commit SHA, got %r"
                                % pilot["reviewed_sha"])
            elif reviewed_sha and pilot["reviewed_sha"].lower() != reviewed_sha.lower():
                findings.append(
                    "pilot.reviewed_sha: %s does not match the head this evidence is being bound to "
                    "(%s) — pilot measurements cannot be recycled onto a different commit"
                    % (pilot["reviewed_sha"], reviewed_sha))
        if "backend" in pilot and pilot["backend"] != "github":
            findings.append("pilot.backend: the pilot must run on the github backend "
                            "(got %r) — a filesystem repo has no integration boundary to measure"
                            % pilot["backend"])
        if "pathway_mode" in pilot and pilot["pathway_mode"] not in ("controlled", "app-locked"):
            findings.append("pilot.pathway_mode: the pilot must exercise an enforcing profile "
                            "(controlled or app-locked), got %r" % pilot["pathway_mode"])

        if "composition" in pilot:
            _check_composition(findings, pilot["composition"])
        if "lane_receipts" in pilot:
            _check_receipts(findings, pilot["lane_receipts"], base_dir)

    _check_metrics(findings, doc.get("metrics"))
    return findings


def summarize(path: str) -> list:
    """The exact `metrics.*` field paths and values, for the release evidence index."""
    doc = load(path)
    metrics = doc.get("metrics") or {}
    rows = []
    for group, leaves in METRIC_CONTRACT:
        body = metrics.get(group) or {}
        for leaf, _kind in leaves:
            rows.append(("metrics.%s.%s" % (group, leaf), body.get(leaf, "MISSING")))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate/summarize the source-heavy pilot's metrics artifact.")
    sub = parser.add_subparsers(dest="command", required=True)

    v = sub.add_parser("validate", help="validate a pilot-metrics.json against the fixed schema")
    v.add_argument("--metrics", required=True, help="path to pilot-metrics.json")
    v.add_argument("--reviewed-sha", default=None,
                   help="the exact reviewed SHA this evidence is bound to")
    v.add_argument("--json", action="store_true", help="emit a machine-readable verdict")

    s = sub.add_parser("summary", help="print the exact metric field paths and values")
    s.add_argument("--metrics", required=True, help="path to pilot-metrics.json")

    args = parser.parse_args()

    if args.command == "validate":
        findings = validate(args.metrics, args.reviewed_sha)
        if args.json:
            print(json.dumps({"ok": not findings, "findings": findings,
                              "metrics": args.metrics}, indent=2))
        else:
            for finding in findings:
                print("idc-pilot-metrics: " + finding, file=sys.stderr)
            if not findings:
                print("idc-pilot-metrics: OK — %d §15.6 metrics present, source-heavy criterion "
                      "met, lane receipts bound" % len(METRIC_CONTRACT))
        return 1 if findings else 0

    try:
        rows = summarize(args.metrics)
    except ValueError as exc:
        print("idc-pilot-metrics: %s" % exc, file=sys.stderr)
        return 1
    width = max(len(name) for name, _ in rows)
    for name, value in rows:
        print("%-*s  %s" % (width, name, value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
