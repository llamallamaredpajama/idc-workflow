#!/usr/bin/env python3
"""idc_provenance_check.py — Plan's provenance post-condition (design §B.4, T1a).

Plan mints Buildable issues and stamps each with a provenance marker
(`<!-- idc-provenance: {"matrix":"<phase-tag>-matrix.yaml","pillar":"<id>"} -->`, the exact format
already documented at `agents/idc-plan.md:98`). Today the stamp is a prose step: if Plan skips it,
nothing catches the gap until `idc_recirc_sweep.py`'s SessionEnd sweep (or the autorun preflight)
happens to run — and even then a legacy/inactive-regime board only SURFACEs the ambiguity, it never
auto-corrects (`idc_recirc_sweep.py`'s `decide()` — a rogue Buildable is only auto-restaged once the
provenance regime is already active). This helper converts the stamp from PROSE-ONLY to a
DET-VERIFY post-condition Plan runs on itself before it can report Phase 5 done: it re-reads each
just-minted issue's LIVE github body (not Plan's own in-memory belief of what it wrote) and checks
the marker is present and names a pillar id that is actually in the matrix Plan just authored — so
a dropped stamp, a truncated write, or a stale/mistyped pillar id all halt Plan instead of silently
leaving the Recirculator's provenance regime under-armed.

github-only, matching the stamp itself (`agents/idc-plan.md`: "Filesystem trackers have no issue
bodies, so the stamp is github-only").

Usage: idc_provenance_check.py --matrix <phase-tag>-matrix.yaml --issues N[,N...] [--repo DIR]
  exit 0  every listed issue's live body carries a valid idc-provenance marker
          (marker.matrix == the given matrix's basename AND marker.pillar in that matrix's id set)
          — prints `provenance: ok <N>`.
  exit 2  usage error, matrix/gh read failure, or >=1 issue missing/invalid provenance — prints
          `provenance: missing #A #B ...` (Plan halts and re-stamps exactly those issues, then
          re-runs this check before continuing to Phase 5 step 3).
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_matrix_check  # noqa: E402 — parse_matrix (constrained-YAML pillar scanner)
import idc_recirc_sweep  # noqa: E402 — PROVENANCE_MARKER + provenance_of (the sweep's own parser;
                          # reused, not re-derived, so Plan's post-condition can never drift from
                          # what the sweep itself will accept as valid provenance)


def _die(msg):
    sys.stderr.write(f"idc-provenance-check: {msg}\n")
    sys.exit(2)


def _gh(args, repo):
    try:
        p = subprocess.run(["gh"] + args, cwd=repo, capture_output=True, text=True)
    except OSError as e:
        _die(f"gh invocation failed: {e}")
    if p.returncode != 0:
        _die(f"gh {' '.join(args[:2])} failed: {p.stderr.strip()[:200]}")
    return p.stdout


def parse_issue_numbers(raw):
    try:
        numbers = [int(x) for x in raw.split(",") if x.strip()]
    except ValueError:
        _die(f"--issues must be a comma-separated list of integers, got {raw!r}")
    if not numbers:
        _die("--issues must name at least one issue number")
    return numbers


def load_pillar_ids(matrix_path):
    try:
        text = open(matrix_path, encoding="utf-8").read()
    except OSError as e:
        _die(f"cannot read matrix {matrix_path}: {e}")
    ids = {p["id"] for p in idc_matrix_check.parse_matrix(text) if p.get("id")}
    if not ids:
        _die(f"matrix {matrix_path} names no pillars — cannot validate provenance against it")
    return ids


def missing_provenance(numbers, matrix_name, pillar_ids, repo):
    """Issue numbers whose LIVE body lacks a valid idc-provenance marker for this matrix.

    One `gh issue view` per issue, not batched: `idc_gh_board.py`'s paginated board reader (the
    shared whole-board helper elsewhere in this repo) never requests issue `body` at all, only
    flattened single-select field values, so it is not a drop-in substitute here — and a Plan run
    mints a small, single-wave batch of Buildables (not the whole board), so the per-issue cost is
    bounded and low, unlike the O(K·M) whole-board-per-mutation sink this fix package targets
    elsewhere."""
    missing = []
    for n in numbers:
        body = _gh(["issue", "view", str(n), "--json", "body", "-q", ".body"], repo)
        prov = idc_recirc_sweep.provenance_of(body)
        if not prov or prov["matrix"] != matrix_name or prov["pillar"] not in pillar_ids:
            missing.append(n)
    return missing


def main():
    ap = argparse.ArgumentParser(
        description="Plan post-condition: every Buildable Plan minted this run carries a valid "
                    "idc-provenance marker on its live github body (github-only).")
    ap.add_argument("--matrix", required=True,
                     help="path to the phase matrix YAML Plan just authored")
    ap.add_argument("--issues", required=True,
                     help="comma-separated issue numbers Plan minted this run")
    ap.add_argument("--repo", default=".", help="repo dir to run gh in (default: cwd)")
    args = ap.parse_args()

    numbers = parse_issue_numbers(args.issues)
    pillar_ids = load_pillar_ids(args.matrix)
    matrix_name = os.path.basename(args.matrix)
    repo = os.path.abspath(args.repo)

    missing = missing_provenance(numbers, matrix_name, pillar_ids, repo)
    if missing:
        print("provenance: missing " + " ".join(f"#{n}" for n in missing))
        sys.exit(2)
    print(f"provenance: ok {len(numbers)}")
    sys.exit(0)


if __name__ == "__main__":
    main()
